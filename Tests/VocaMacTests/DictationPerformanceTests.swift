import XCTest
import Speech
@testable import VocaMac

#if compiler(>=6.2)
final class DictationPerformanceTests: XCTestCase {
    /// Explicit benchmark, not a hosted-runner timing gate. Input and output stay
    /// outside the repo; transcripts in the report permit an accuracy comparison.
    func testAppleSpeechStopLatencyBenchmark() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Apple Speech requires macOS 26") }
        let environment = ProcessInfo.processInfo.environment
        guard let inputPath = environment["VOCAMAC_BENCHMARK_AUDIO"],
              let outputPath = environment["VOCAMAC_BENCHMARK_OUTPUT"] else {
            throw XCTSkip("Set VOCAMAC_BENCHMARK_AUDIO and VOCAMAC_BENCHMARK_OUTPUT for release timing")
        }
        let installed = await SpeechTranscriber.installedLocales
        guard let locale = installed.first(where: { $0.language.languageCode?.identifier == "en" }) else {
            throw XCTSkip("English system assets must already be installed")
        }
        let samples = try AudioFileLoader().loadAudio(at: URL(fileURLWithPath: inputPath)).samples
        struct Measurement: Codable {
            let batchSeconds: Double
            let streamingStopSeconds: Double
            let batchText: String
            let streamingText: String
        }
        struct Report: Codable {
            let os: String
            let audioSeconds: Double
            let measurements: [Measurement]
        }
        var measurements: [Measurement] = []
        let service = AppleSpeechService()
        do {
            for _ in 0..<3 {
                try await service.loadModel(language: locale.identifier)
                let batchStart = ProcessInfo.processInfo.systemUptime
                let batch = try await service.transcribe(audioData: samples, language: locale.identifier)
                let batchSeconds = ProcessInfo.processInfo.systemUptime - batchStart
                try await service.loadModel(language: locale.identifier)
                let live = RecordingTranscription(language: locale.identifier) { chunks in
                    try await service.transcribe(chunks: chunks, language: locale.identifier)
                }
                for offset in stride(from: 0, to: samples.count, by: 1024) {
                    let end = min(samples.count, offset + 1024)
                    live.append(Array(samples[offset..<end]), at: offset)
                    try await Task.sleep(nanoseconds: UInt64(Double(end - offset) / 16_000 * 1_000_000_000))
                }
                let stop = ProcessInfo.processInfo.systemUptime
                let result = try await live.finish(expectedSampleCount: samples.count)
                let streamingStopSeconds = ProcessInfo.processInfo.systemUptime - stop
                XCTAssertFalse(batch.text.isEmpty)
                XCTAssertFalse(result.text.isEmpty)
                measurements.append(Measurement(batchSeconds: batchSeconds, streamingStopSeconds: streamingStopSeconds,
                                                batchText: batch.text, streamingText: result.text))
            }
            await service.unloadModel()
            let report = Report(os: ProcessInfo.processInfo.operatingSystemVersionString,
                                audioSeconds: Double(samples.count) / 16_000, measurements: measurements)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        } catch {
            await service.unloadModel()
            throw error
        }
    }
}
#endif

/// Explicit benchmark for "Process while speaking", not a CI timing gate.
/// Feeds a recording at microphone pace through a real engine, once as today
/// (decode and clean after stop) and once committing pieces while "speaking",
/// and reports the wait after stop for each. Audio and output stay outside
/// the repo.
///
///     VOCAMAC_BENCHMARK_AUDIO=/path/clip.wav \
///     VOCAMAC_BENCHMARK_OUTPUT=/tmp/report.json \
///     VOCAMAC_BENCHMARK_MODEL=canary-180m-flash \
///     VOCAMAC_BENCHMARK_CLEANUP=ministral3_3b_q4_k_m \
///     swift test --filter ProcessWhileSpeakingBenchmarkTests
@MainActor
final class ProcessWhileSpeakingBenchmarkTests: XCTestCase {
    struct Run: Codable {
        let mode: String
        let stopToResultSeconds: Double
        let text: String
        let pieces: Int
        let cleanupHits: Int
        let cleanupMisses: Int
    }

    struct Report: Codable {
        let model: String
        let cleanupModel: String?
        let audioSeconds: Double
        let runs: [Run]
        let batchMedianSeconds: Double
        let batchP95Seconds: Double
        let committedMedianSeconds: Double
        let committedP95Seconds: Double
        let peakResidentMegabytes: Double
    }

    func testStopLatencyWithAndWithoutPieces() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let inputPath = environment["VOCAMAC_BENCHMARK_AUDIO"],
              let outputPath = environment["VOCAMAC_BENCHMARK_OUTPUT"],
              let model = environment["VOCAMAC_BENCHMARK_MODEL"].flatMap(ModelSize.init(rawValue:)) else {
            throw XCTSkip("Set VOCAMAC_BENCHMARK_AUDIO, VOCAMAC_BENCHMARK_OUTPUT and VOCAMAC_BENCHMARK_MODEL")
        }
        let cleanupKind = environment["VOCAMAC_BENCHMARK_CLEANUP"].flatMap(CleanupModelKind.init(rawValue:))
        let repeats = environment["VOCAMAC_BENCHMARK_RUNS"].flatMap(Int.init) ?? 3
        let samples = try AudioFileLoader().loadAudio(at: URL(fileURLWithPath: inputPath)).samples

        let modelManager = ModelManager()
        let router = TranscriptionRouter(languagePreferenceProvider: { nil })
        try await router.loadModel(name: modelManager.modelIdentifier(for: model), folder: modelManager.modelFolder(for: model))
        defer { Task { await router.unloadModel() } }

        let cleaner = TranscriptCleanupService()
        // The app's reclaimable-memory estimate is conservative while the
        // test runner and toolchain are resident; the benchmark is run on
        // purpose, so load anyway.
        cleaner.modelFitsInMemory = { _ in true }
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
        if let cleanupKind {
            await cleaner.load(cleanupKind)
            guard cleaner.isLoaded else { throw XCTSkip("The cleanup model could not load (download it, and free memory)") }
        }
        func options(language: String) -> DictationOutputOptions {
            DictationOutputOptions(
                profile: WritingProfile(format: .plain, rules: WritingStyle.plain.defaultRules),
                snippetList: [], cleanupEnabled: cleanupKind != nil, rewritingEnabled: false,
                model: cleanupKind ?? .defaultKind, customPrompt: "", language: language,
                autoCapitalize: true, trailingSpace: false
            )
        }

        func feedAtMicrophonePace(_ session: RecordingTranscription?) async throws {
            for offset in stride(from: 0, to: samples.count, by: 1_024) {
                let end = min(samples.count, offset + 1_024)
                session?.append(Array(samples[offset..<end]), at: offset)
                try await Task.sleep(nanoseconds: UInt64(Double(end - offset) / 16_000 * 1_000_000_000))
            }
        }

        var runs: [Run] = []
        for _ in 0..<repeats {
            // Today: record, then decode and clean everything after stop.
            try await feedAtMicrophonePace(nil)
            var stop = ProcessInfo.processInfo.systemUptime
            let batch = try await router.transcribe(audioData: samples, language: nil, translate: false, vocabulary: "")
            let batchOutput = await pipeline.process(batch.text, options: options(language: batch.detectedLanguage))
            runs.append(Run(
                mode: "batch", stopToResultSeconds: ProcessInfo.processInfo.systemUptime - stop,
                text: batchOutput.text, pieces: 0, cleanupHits: 0, cleanupMisses: 0
            ))

            // Process while speaking.
            let speculator = cleanupKind == nil ? nil : CleanupSpeculator(pipeline: pipeline) { options(language: $0) }
            let commit = StreamingCommitOptions(onPiece: { index, piece in
                Task { @MainActor in speculator?.submit(piece, index: index) }
            })
            let session = try XCTUnwrap(router.startStreaming(language: nil, vocabulary: "", onPartial: nil, commit: commit))
            try await feedAtMicrophonePace(session)
            stop = ProcessInfo.processInfo.systemUptime
            let result = try await session.finish(expectedSampleCount: samples.count)
            let output = await pipeline.process(
                result.text, options: options(language: result.detectedLanguage),
                pieces: speculator == nil ? [] : result.pieces, speculator: speculator
            )
            runs.append(Run(
                mode: "committed", stopToResultSeconds: ProcessInfo.processInfo.systemUptime - stop,
                text: output.text, pieces: result.pieces.count,
                cleanupHits: speculator?.hitCount ?? 0, cleanupMisses: speculator?.missCount ?? 0
            ))
            await speculator?.finish()
        }
        cleaner.unload()

        func percentile(_ mode: String, _ fraction: Double) -> Double {
            let values = runs.filter { $0.mode == mode }.map(\.stopToResultSeconds).sorted()
            return values[min(values.count - 1, Int(Double(values.count - 1) * fraction + 0.5))]
        }
        let report = Report(
            model: model.rawValue, cleanupModel: cleanupKind?.rawValue,
            audioSeconds: Double(samples.count) / 16_000, runs: runs,
            batchMedianSeconds: percentile("batch", 0.5), batchP95Seconds: percentile("batch", 0.95),
            committedMedianSeconds: percentile("committed", 0.5), committedP95Seconds: percentile("committed", 0.95),
            peakResidentMegabytes: Self.peakResidentMegabytes()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    private static func peakResidentMegabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size_peak) / 1_048_576
    }
}
