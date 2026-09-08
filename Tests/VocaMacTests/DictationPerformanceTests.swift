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
