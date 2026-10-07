// SpeechAccuracyBenchmarkTests.swift
// VocaMac

import XCTest
@testable import VocaMac

/// Explicit accuracy benchmark for the speech engines, not a CI gate.
///
/// Decodes a corpus of `<name>.wav` + `<name>.txt` reference pairs with each
/// model through the same `TranscriptionRouter` the app uses (silence trim,
/// decoding options, retries), and reports word error rate per file and per
/// model. The corpus and report stay outside the repo.
///
///     VOCAMAC_ACCURACY_CORPUS=/path/to/corpus \
///     VOCAMAC_ACCURACY_MODELS=tiny,parakeet-tdt-0.6b-v3 \
///     swift test --filter SpeechAccuracyBenchmarkTests
///
/// Optional: `VOCAMAC_ACCURACY_OUTPUT` (report path or directory, default
/// `$TMPDIR`), `VOCAMAC_ACCURACY_LANGUAGE` (default auto-detect),
/// `VOCAMAC_ACCURACY_VOCABULARY` (comma-separated Dictionary terms),
/// `VOCAMAC_ACCURACY_MAX_WER` (fail when a model's corpus WER is above it,
/// e.g. `0.15`), `VOCAMAC_ACCURACY_ALLOW_DOWNLOAD=1` (fetch missing models;
/// otherwise they are skipped).
final class SpeechAccuracyBenchmarkTests: XCTestCase {

    struct FileResult: Codable {
        let name: String
        let reference: String
        let hypothesis: String
        let wer: WordErrorRate
        let werRate: Double
        let audioSeconds: Double
        let decodeSeconds: Double
    }

    struct ModelResult: Codable {
        let model: String
        let corpus: WordErrorRate
        let corpusWER: Double
        let emptyHypotheses: Int
        let loadSeconds: Double
        /// The first decode after the load: includes CoreML's first
        /// prediction unless the engine warmed itself up.
        let firstDecodeSeconds: Double
        /// Median of the decodes after the first.
        let medianWarmDecodeSeconds: Double
        let files: [FileResult]
    }

    struct Report: Codable {
        let os: String
        let corpus: String
        let language: String?
        let vocabulary: String
        let models: [ModelResult]
        let skippedModels: [String]
    }

    struct CorpusEntry {
        let name: String
        let audio: URL
        let reference: String
    }

    func testCorpusWordErrorRate() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let corpusPath = environment["VOCAMAC_ACCURACY_CORPUS"], !corpusPath.isEmpty else {
            throw XCTSkip("Set VOCAMAC_ACCURACY_CORPUS to a directory of <name>.wav + <name>.txt pairs")
        }
        let corpusURL = URL(fileURLWithPath: corpusPath, isDirectory: true)
        let entries = try Self.corpusEntries(in: corpusURL)
        guard !entries.isEmpty else { throw XCTSkip("No <name>.wav + <name>.txt pairs in \(corpusPath)") }

        let modelNames = (environment["VOCAMAC_ACCURACY_MODELS"] ?? ModelSize.tiny.rawValue)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let language = environment["VOCAMAC_ACCURACY_LANGUAGE"].flatMap { $0.isEmpty || $0 == "auto" ? nil : $0 }
        let vocabulary = environment["VOCAMAC_ACCURACY_VOCABULARY"] ?? ""
        let allowDownload = environment["VOCAMAC_ACCURACY_ALLOW_DOWNLOAD"] == "1"
        let maxWER = environment["VOCAMAC_ACCURACY_MAX_WER"].flatMap(Double.init)

        let loader = AudioFileLoader()
        let audio = try entries.map { try loader.loadAudio(at: $0.audio).samples }
        let modelManager = ModelManager()

        var results: [ModelResult] = []
        var skipped: [String] = []
        for name in modelNames {
            guard let model = ModelSize(rawValue: name) else {
                XCTFail("Unknown model \(name)")
                continue
            }
            if !model.isSystemManaged, !model.isRemotelyHosted, !modelManager.isModelDownloaded(model) {
                guard allowDownload else {
                    skipped.append(name)
                    continue
                }
                try await modelManager.downloadModel(size: model) { _ in }
            }
            results.append(try await measure(
                model: model, entries: entries, audio: audio,
                language: language, vocabulary: vocabulary, modelManager: modelManager
            ))
        }

        let report = Report(
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            corpus: corpusURL.path, language: language, vocabulary: vocabulary,
            models: results, skippedModels: skipped
        )
        let outputURL = Self.outputURL(environment["VOCAMAC_ACCURACY_OUTPUT"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: outputURL, options: .atomic)
        print(Self.summary(report, outputURL: outputURL))

        guard !results.isEmpty else {
            throw XCTSkip("None of \(modelNames.joined(separator: ", ")) is downloaded; set VOCAMAC_ACCURACY_ALLOW_DOWNLOAD=1")
        }
        if let maxWER {
            for result in results where result.corpusWER > maxWER {
                XCTFail(String(format: "%@ corpus WER %.3f is above %.3f", result.model, result.corpusWER, maxWER))
            }
        }
    }

    // MARK: - Measuring

    private func measure(
        model: ModelSize,
        entries: [CorpusEntry],
        audio: [[Float]],
        language: String?,
        vocabulary: String,
        modelManager: ModelManager
    ) async throws -> ModelResult {
        let router = TranscriptionRouter(languagePreferenceProvider: { language }, skipSilenceProvider: { true })
        let loadStart = ProcessInfo.processInfo.systemUptime
        try await router.loadModel(name: modelManager.modelIdentifier(for: model), folder: modelManager.modelFolder(for: model))
        let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart

        var files: [FileResult] = []
        do {
            for (entry, samples) in zip(entries, audio) {
                let start = ProcessInfo.processInfo.systemUptime
                let result = try await router.transcribe(
                    audioData: samples, language: language, translate: false, vocabulary: vocabulary
                )
                let decodeSeconds = ProcessInfo.processInfo.systemUptime - start
                let wer = WordErrorRate.measure(reference: entry.reference, hypothesis: result.text)
                files.append(FileResult(
                    name: entry.name, reference: entry.reference, hypothesis: result.text,
                    wer: wer, werRate: wer.rate,
                    audioSeconds: Double(samples.count) / 16_000, decodeSeconds: decodeSeconds
                ))
            }
        } catch {
            await router.unloadModel()
            throw error
        }
        await router.unloadModel()

        let corpus = files.map(\.wer).reduce(.zero, +)
        let warm = files.dropFirst().map(\.decodeSeconds).sorted()
        return ModelResult(
            model: model.rawValue,
            corpus: corpus,
            corpusWER: corpus.rate,
            emptyHypotheses: files.filter { $0.hypothesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count,
            loadSeconds: loadSeconds,
            firstDecodeSeconds: files.first?.decodeSeconds ?? 0,
            medianWarmDecodeSeconds: warm.isEmpty ? 0 : warm[warm.count / 2],
            files: files
        )
    }

    // MARK: - Corpus and report

    static func corpusEntries(in directory: URL) throws -> [CorpusEntry] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return try names
            .filter { $0.lowercased().hasSuffix(".wav") }
            .sorted()
            .compactMap { file in
                let base = (file as NSString).deletingPathExtension
                let referenceURL = directory.appendingPathComponent(base + ".txt")
                guard FileManager.default.fileExists(atPath: referenceURL.path) else { return nil }
                let reference = try String(contentsOf: referenceURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return CorpusEntry(name: base, audio: directory.appendingPathComponent(file), reference: reference)
            }
    }

    static func outputURL(_ path: String?) -> URL {
        let fileName = "vocamac-accuracy-\(Int(Date().timeIntervalSince1970)).json"
        guard let path, !path.isEmpty else {
            return FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(fileName)
        }
        return URL(fileURLWithPath: path)
    }

    static func summary(_ report: Report, outputURL: URL) -> String {
        var lines = ["", "Speech accuracy — \(report.corpus)"]
        lines.append("model                               WER     errors/words  empty  first s  warm s")
        for model in report.models {
            let name = model.model.padding(toLength: max(34, model.model.count), withPad: " ", startingAt: 0)
            lines.append(name + String(
                format: "  %6.2f%%  %5d/%-6d  %5d  %7.2f  %6.2f",
                model.corpusWER * 100, model.corpus.errors, model.corpus.referenceWords,
                model.emptyHypotheses, model.firstDecodeSeconds, model.medianWarmDecodeSeconds
            ))
        }
        if !report.skippedModels.isEmpty {
            lines.append("skipped (not downloaded): \(report.skippedModels.joined(separator: ", "))")
        }
        lines.append("report: \(outputURL.path)")
        return lines.joined(separator: "\n")
    }
}
