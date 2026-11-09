// SpeechAccuracyBenchmarkTests.swift
// VocaMac

import XCTest
@testable import VocaMac

/// Explicit accuracy benchmark for the speech engines. It skips in ordinary
/// `swift test` runs; the opt-in nightly workflow (`accuracy-nightly.yml`)
/// runs it against a stored baseline. See docs/ACCURACY.md.
///
/// Decodes a corpus of `<name>.wav` + `<name>.txt` reference pairs with each
/// model through the same `TranscriptionRouter` the app uses (silence trim,
/// decoding options, retries), and reports word error rate per file and per
/// model (character error rate for Chinese, Japanese, Thai and other
/// scripts written without spaces), plus how often the first or last word
/// was dropped. The corpus and report stay outside the repo.
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
/// otherwise they are skipped), `VOCAMAC_ACCURACY_FINAL=1` (also run each
/// transcript through the output rules a Plain app gets at Medium, with no
/// model, and score it against `<name>.intended.txt` when present, else
/// `<name>.txt`). Recognition and the rules are then reported side by side:
/// a recording of "tomorrow, sorry, let's meet Friday" has the verbatim words
/// in `.txt` and "let's meet Friday" in `.intended.txt`.
///
/// More options:
/// - `VOCAMAC_ACCURACY_CLEANUP_MODEL`: a cleanup model id
///   (`CleanupModelKind`) or the path to its `.gguf`. Turns on FINAL and
///   runs the real model at `VOCAMAC_ACCURACY_CLEANUP_LEVEL` (default
///   `medium`), as the app does with Smart Cleanup on. The final text is also
///   scored for punctuation and capitalization against the intended text,
///   which then has to be written as text, with punctuation.
/// - `<name>.terms.txt` (one term per line): words that must come through
///   spelled exactly so. They join the vocabulary for that file and are
///   scored for recall and false insertions.
/// - `VOCAMAC_ACCURACY_VOCABULARY_PAIRED=1`: decode every file twice, with
///   and without the vocabulary, and report what the hints changed.
/// - `VOCAMAC_ACCURACY_BASELINE` (a JSON `AccuracyBaseline`) and
///   `VOCAMAC_ACCURACY_TOLERANCE`: fail when a model is worse than the
///   baseline. `VOCAMAC_ACCURACY_CORPUS_ID` names the corpus version; a
///   baseline recorded on another one is not compared.
///   `VOCAMAC_ACCURACY_WRITE_BASELINE=<path>` writes this run's numbers in
///   the baseline format.
final class SpeechAccuracyBenchmarkTests: XCTestCase {

    struct FileResult: Codable {
        let name: String
        let reference: String
        let hypothesis: String
        /// Words, or characters for scripts written without spaces.
        let unit: WordErrorRate.Unit
        /// Errors in `unit`; `referenceWords` counts characters for `.characters`.
        let wer: WordErrorRate
        let werRate: Double
        let audioSeconds: Double
        let decodeSeconds: Double
        /// Reference words lost at the start and end (word-scored files only).
        var edges: TranscriptScoring.EdgeWords?
        /// Terms from the vocabulary and `<name>.terms.txt` said in the file.
        var terms: TranscriptScoring.TermRecall?
        /// With `VOCAMAC_ACCURACY_VOCABULARY_PAIRED=1`: the decode without hints.
        var withoutVocabulary: Unhinted?
        /// With `VOCAMAC_ACCURACY_FINAL=1`: the text after the output rules
        /// (and the cleanup model, when loaded), scored against the intended text.
        var finalText: String?
        var intended: String?
        var finalWER: WordErrorRate?
        var finalFormatting: TranscriptScoring.Formatting?
        var finalTerms: TranscriptScoring.TermRecall?
    }

    struct Unhinted: Codable {
        let hypothesis: String
        let wer: WordErrorRate
        var terms: TranscriptScoring.TermRecall?
    }

    struct ModelResult: Codable {
        let model: String
        /// Over the files scored in words.
        let corpus: WordErrorRate
        let corpusWER: Double
        /// Over the files scored in characters, when there are any.
        var characterCorpus: WordErrorRate?
        var corpusCER: Double?
        let emptyHypotheses: Int
        /// Word-scored files whose first / last reference word was dropped.
        var firstWordDrops = 0
        var lastWordDrops = 0
        var wordScoredFiles = 0
        let loadSeconds: Double
        /// The first decode after the load: includes CoreML's first
        /// prediction unless the engine warmed itself up.
        let firstDecodeSeconds: Double
        /// Median of the decodes after the first.
        let medianWarmDecodeSeconds: Double
        var files: [FileResult]
        var terms: TranscriptScoring.TermRecall?
        /// Paired mode, over the word-scored files that had hints: the
        /// decode with them, and the same files decoded without them.
        var hintedCorpus: WordErrorRate?
        var unhintedCorpus: WordErrorRate?
        var unhintedTerms: TranscriptScoring.TermRecall?
        var finalCorpus: WordErrorRate?
        var finalCorpusWER: Double?
        var finalFormatting: TranscriptScoring.Formatting?
        var finalTerms: TranscriptScoring.TermRecall?

        /// Share of word-scored files that lost their first or last word.
        var edgeDropRate: Double? {
            guard wordScoredFiles > 0 else { return nil }
            let dropped = files.filter { $0.edges?.firstWordDropped == true || $0.edges?.lastWordDropped == true }
            return Double(dropped.count) / Double(wordScoredFiles)
        }

        var baselineEntry: AccuracyBaseline.Entry {
            AccuracyBaseline.Entry(
                corpusWER: corpus.referenceWords > 0 ? corpusWER : nil,
                corpusCER: corpusCER, finalCorpusWER: finalCorpusWER, edgeDropRate: edgeDropRate
            )
        }
    }

    struct Report: Codable {
        let os: String
        let corpus: String
        var corpusID: String?
        let language: String?
        let vocabulary: String
        var cleanupModel: String?
        var cleanupLevel: String?
        let models: [ModelResult]
        let skippedModels: [String]
        var baselineRegressions: [String]?
        /// Why the baseline was not compared, when it was skipped on purpose.
        var baselineNote: String?
        /// Models whose vocabulary hints could not take effect, and why.
        var hintsNotTested: [String]?
    }

    struct CorpusEntry {
        let name: String
        let audio: URL
        let reference: String
        /// What the speaker meant, when it differs from what they said.
        var intended: String?
        /// Words that must come through spelled exactly so (`<name>.terms.txt`).
        var terms: [String] = []
    }

    /// The real cleanup model a FINAL run uses.
    struct FinalCleanup {
        let kind: CleanupModelKind
        let level: CleanupLevel
        let service: TranscriptCleanupService
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
        let paired = environment["VOCAMAC_ACCURACY_VOCABULARY_PAIRED"] == "1"
        let cleanupValue = environment["VOCAMAC_ACCURACY_CLEANUP_MODEL"].flatMap { $0.isEmpty ? nil : $0 }
        let scoresFinalText = environment["VOCAMAC_ACCURACY_FINAL"] == "1" || cleanupValue != nil
        let corpusID = environment["VOCAMAC_ACCURACY_CORPUS_ID"].flatMap { $0.isEmpty ? nil : $0 }

        let finalCleanup = try await cleanupValue.asyncMap {
            try await Self.loadCleanup(
                $0, level: environment["VOCAMAC_ACCURACY_CLEANUP_LEVEL"], allowDownload: allowDownload
            )
        }

        let loader = AudioFileLoader()
        let audio = try entries.map { try loader.loadAudio(at: $0.audio).samples }
        let modelManager = ModelManager()

        var results: [ModelResult] = []
        var skipped: [String] = []
        var hintsNotTested: [String] = []
        let hasBoostTerms = !RecognitionHints.boostTerms(from: vocabulary).isEmpty
            || entries.contains { !RecognitionHints.boostTerms(from: Self.vocabulary(vocabulary, adding: $0.terms)).isEmpty }
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
            // Parakeet applies hints through a separate boost model. Without
            // it the hinted and unhinted decodes are the same, so a paired
            // run would wrongly show that hints change nothing.
            if model.engine == .parakeet, hasBoostTerms, !TranscriptionRouter.isVocabularyBoostDownloaded {
                if allowDownload {
                    try await TranscriptionRouter.downloadVocabularyBoost()
                } else {
                    hintsNotTested.append("\(name): Parakeet vocabulary boost model is not downloaded")
                }
            }
            var result = try await measure(
                model: model, entries: entries, audio: audio, language: language,
                vocabulary: vocabulary, paired: paired, modelManager: modelManager
            )
            if scoresFinalText {
                result = await Self.scoringFinalText(
                    result, entries: entries, language: language, vocabulary: vocabulary, cleanup: finalCleanup
                )
            }
            results.append(result)
        }
        await finalCleanup?.service.unload()

        var report = Report(
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            corpus: corpusURL.path, corpusID: corpusID, language: language, vocabulary: vocabulary,
            cleanupModel: finalCleanup?.kind.rawValue, cleanupLevel: finalCleanup?.level.rawValue,
            models: results, skippedModels: skipped
        )
        report.hintsNotTested = hintsNotTested.isEmpty ? nil : hintsNotTested
        let measured = Dictionary(uniqueKeysWithValues: results.map { ($0.model, $0.baselineEntry) })
        let comparison = try Self.baselineRegressions(measured, corpusID: corpusID, environment: environment)
        let regressions = comparison.regressions
        report.baselineRegressions = regressions.map(\.description)
        report.baselineNote = comparison.note

        let outputURL = Self.outputURL(environment["VOCAMAC_ACCURACY_OUTPUT"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: outputURL, options: .atomic)
        if let path = environment["VOCAMAC_ACCURACY_WRITE_BASELINE"], !path.isEmpty {
            try AccuracyBaseline(
                note: "Recorded by SpeechAccuracyBenchmarkTests on \(report.os)",
                corpus: corpusID, tolerance: nil, models: measured
            ).write(to: URL(fileURLWithPath: path))
        }
        print(Self.summary(report, outputURL: outputURL))

        guard !results.isEmpty else {
            throw XCTSkip("None of \(modelNames.joined(separator: ", ")) is downloaded; set VOCAMAC_ACCURACY_ALLOW_DOWNLOAD=1")
        }
        if let maxWER {
            for result in results where result.corpusWER > maxWER {
                XCTFail(String(format: "%@ corpus WER %.3f is above %.3f", result.model, result.corpusWER, maxWER))
            }
        }
        for regression in regressions {
            XCTFail(regression.description)
        }
    }

    // MARK: - Measuring

    private func measure(
        model: ModelSize,
        entries: [CorpusEntry],
        audio: [[Float]],
        language: String?,
        vocabulary: String,
        paired: Bool,
        modelManager: ModelManager
    ) async throws -> ModelResult {
        let router = TranscriptionRouter(languagePreferenceProvider: { language }, skipSilenceProvider: { true })
        let loadStart = ProcessInfo.processInfo.systemUptime
        try await router.loadModel(name: modelManager.modelIdentifier(for: model), folder: modelManager.modelFolder(for: model))
        let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart

        var files: [FileResult] = []
        do {
            for (entry, samples) in zip(entries, audio) {
                let hints = Self.vocabulary(vocabulary, adding: entry.terms)
                let terms = RecognitionHints.terms(from: hints)
                // The hinted decode is the one the app makes, so it is timed
                // first: the first file's time stays the first decode after
                // the load. The paired decode without hints follows, untimed.
                let start = ProcessInfo.processInfo.systemUptime
                let result = try await router.transcribe(
                    audioData: samples, language: language, translate: false, vocabulary: hints
                )
                let decodeSeconds = ProcessInfo.processInfo.systemUptime - start
                var unhinted: Unhinted?
                if paired, !hints.isEmpty {
                    let plain = try await router.transcribe(
                        audioData: samples, language: language, translate: false, vocabulary: ""
                    )
                    unhinted = Unhinted(
                        hypothesis: plain.text,
                        wer: WordErrorRate.measure(
                            reference: entry.reference, hypothesis: plain.text,
                            unit: WordErrorRate.unit(for: entry.reference)
                        ),
                        terms: terms.isEmpty ? nil : TranscriptScoring.termRecall(
                            terms: terms, reference: entry.reference, hypothesis: plain.text
                        )
                    )
                }
                var file = Self.scored(
                    entry: entry, hypothesis: result.text, terms: terms,
                    audioSeconds: Double(samples.count) / 16_000, decodeSeconds: decodeSeconds
                )
                file.withoutVocabulary = unhinted
                files.append(file)
            }
        } catch {
            await router.unloadModel()
            throw error
        }
        await router.unloadModel()
        return Self.summarized(model: model.rawValue, files: files, loadSeconds: loadSeconds)
    }

    /// One file's recognition scores.
    static func scored(
        entry: CorpusEntry, hypothesis: String, terms: [String], audioSeconds: Double, decodeSeconds: Double
    ) -> FileResult {
        let unit = WordErrorRate.unit(for: entry.reference)
        let wer = WordErrorRate.measure(reference: entry.reference, hypothesis: hypothesis, unit: unit)
        let isEmpty = hypothesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return FileResult(
            name: entry.name, reference: entry.reference, hypothesis: hypothesis,
            unit: unit, wer: wer, werRate: wer.rate,
            audioSeconds: audioSeconds, decodeSeconds: decodeSeconds,
            // An empty transcript is counted as empty, not as clipped edges.
            edges: unit == .words && !isEmpty
                ? TranscriptScoring.edgeWords(reference: entry.reference, hypothesis: hypothesis) : nil,
            terms: terms.isEmpty ? nil : TranscriptScoring.termRecall(
                terms: terms, reference: entry.reference, hypothesis: hypothesis
            )
        )
    }

    /// Corpus totals for one model's files.
    static func summarized(model: String, files: [FileResult], loadSeconds: Double) -> ModelResult {
        let wordFiles = files.filter { $0.unit == .words }
        let characterFiles = files.filter { $0.unit == .characters }
        let corpus = wordFiles.map(\.wer).reduce(.zero, +)
        let characterCorpus = characterFiles.isEmpty ? nil : characterFiles.map(\.wer).reduce(.zero, +)
        let warm = files.dropFirst().map(\.decodeSeconds).sorted()
        let termResults = files.compactMap(\.terms)
        let unhinted = files.compactMap(\.withoutVocabulary)
        let pairedFiles = files.filter { $0.unit == .words && $0.withoutVocabulary != nil }
        let unhintedWords = pairedFiles.compactMap { $0.withoutVocabulary?.wer }
        return ModelResult(
            model: model,
            corpus: corpus,
            corpusWER: corpus.rate,
            characterCorpus: characterCorpus,
            corpusCER: characterCorpus?.rate,
            emptyHypotheses: files.filter { $0.hypothesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count,
            firstWordDrops: files.filter { $0.edges?.firstWordDropped == true }.count,
            lastWordDrops: files.filter { $0.edges?.lastWordDropped == true }.count,
            wordScoredFiles: wordFiles.count,
            loadSeconds: loadSeconds,
            firstDecodeSeconds: files.first?.decodeSeconds ?? 0,
            medianWarmDecodeSeconds: warm.isEmpty ? 0 : warm[warm.count / 2],
            files: files,
            terms: termResults.isEmpty ? nil : termResults.reduce(TranscriptScoring.TermRecall(), +),
            hintedCorpus: pairedFiles.isEmpty ? nil : pairedFiles.map(\.wer).reduce(.zero, +),
            unhintedCorpus: pairedFiles.isEmpty ? nil : unhintedWords.reduce(.zero, +),
            unhintedTerms: unhinted.compactMap(\.terms).isEmpty
                ? nil : unhinted.compactMap(\.terms).reduce(TranscriptScoring.TermRecall(), +)
        )
    }

    /// The global vocabulary with a file's own terms added, as the
    /// comma-separated hint list the router takes.
    static func vocabulary(_ vocabulary: String, adding terms: [String]) -> String {
        RecognitionHints.terms(from: (RecognitionHints.vocabularyTerms(from: vocabulary) + terms).joined(separator: "\n"))
            .joined(separator: ", ")
    }

    // MARK: - Final text

    /// Runs each transcript through the rules a Plain app gets at the
    /// default Medium level and scores the result against what the speaker
    /// meant. Without `cleanup` Smart Cleanup is off; with it, the real model
    /// runs as the app runs it (skipped when the rules left nothing to do).
    @MainActor
    static func scoringFinalText(
        _ result: ModelResult, entries: [CorpusEntry], language: String?,
        vocabulary: String = "", cleanup: FinalCleanup? = nil
    ) async -> ModelResult {
        let cleaner: TranscriptCleaning = cleanup?.service ?? MockTranscriptCleanup()
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
        var files: [FileResult] = []
        for (file, entry) in zip(result.files, entries) {
            let terms = RecognitionHints.terms(from: Self.vocabulary(vocabulary, adding: entry.terms))
            let output = await pipeline.process(
                file.hypothesis,
                options: DictationOutputOptions(
                    profile: WritingProfile(format: .plain, rules: WritingStyle.plain.defaultRules), snippetList: [],
                    cleanupEnabled: cleanup != nil, rewritingEnabled: false,
                    model: cleanup?.kind ?? .defaultKind, customPrompt: "",
                    cleanupLevel: cleanup?.level ?? .medium, language: language,
                    autoCapitalize: true, trailingSpace: false,
                    dictionary: terms.isEmpty ? nil : DictionaryContext(
                        vocabulary: terms, replacements: [], contextTerms: [],
                        isKnownWord: { SpellingOracle.shared.isKnownWord($0, language: language ?? "en") }
                    ),
                    skipWhenClean: true
                )
            )
            let intended = entry.intended ?? entry.reference
            var updated = file
            updated.finalText = output.text
            updated.intended = intended
            updated.finalWER = WordErrorRate.measure(
                reference: intended, hypothesis: output.text, unit: WordErrorRate.unit(for: intended)
            )
            updated.finalFormatting = TranscriptScoring.formatting(reference: intended, hypothesis: output.text)
            updated.finalTerms = terms.isEmpty ? nil : TranscriptScoring.termRecall(
                terms: terms, reference: intended, hypothesis: output.text
            )
            files.append(updated)
        }
        var updated = result
        updated.files = files
        let wordFinal = files.filter { $0.unit == .words }.compactMap(\.finalWER)
        let corpus = wordFinal.reduce(.zero, +)
        updated.finalCorpus = corpus
        updated.finalCorpusWER = wordFinal.isEmpty ? nil : corpus.rate
        updated.finalFormatting = files.compactMap(\.finalFormatting).reduce(TranscriptScoring.Formatting(), +)
        let finalTerms = files.compactMap(\.finalTerms)
        updated.finalTerms = finalTerms.isEmpty ? nil : finalTerms.reduce(TranscriptScoring.TermRecall(), +)
        return updated
    }

    /// Resolves `VOCAMAC_ACCURACY_CLEANUP_MODEL` (a model id or a `.gguf`
    /// path), downloads it when allowed, and loads it.
    @MainActor
    static func loadCleanup(_ value: String, level: String?, allowDownload: Bool) async throws -> FinalCleanup {
        let (kind, directory) = try cleanupModel(from: value)
        let cleanupLevel = try level.flatMap { $0.isEmpty ? nil : $0 }.map { name in
            guard let parsed = CleanupLevel(rawValue: name.lowercased()) else {
                throw CleanupModelError(message: "VOCAMAC_ACCURACY_CLEANUP_LEVEL: unknown level \(name)")
            }
            return parsed
        } ?? .medium
        let service = TranscriptCleanupService(modelsDirectory: directory)
        if !service.isDownloaded(kind) {
            guard allowDownload, directory == nil else {
                throw XCTSkip("Cleanup model \(kind.rawValue) is not downloaded; set VOCAMAC_ACCURACY_ALLOW_DOWNLOAD=1")
            }
            await service.download(kind)
        }
        await service.load(kind)
        guard service.loadedKind == kind else {
            throw CleanupModelError(message: "Cleanup model \(kind.rawValue) did not load")
        }
        return FinalCleanup(kind: kind, level: cleanupLevel, service: service)
    }

    struct CleanupModelError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// A model id, or a `.gguf` file whose name matches a known model's
    /// (the service loads models by kind). For a file, also its directory.
    static func cleanupModel(from value: String) throws -> (CleanupModelKind, URL?) {
        if let kind = CleanupModelKind(rawValue: value) { return (kind, nil) }
        let url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            let known = CleanupModelKind.allCases.map(\.rawValue).joined(separator: ", ")
            throw CleanupModelError(message: "VOCAMAC_ACCURACY_CLEANUP_MODEL: \(value) is neither a file nor one of \(known)")
        }
        guard let kind = CleanupModelKind.allCases.first(where: { $0.descriptor.fileName == url.lastPathComponent }) else {
            throw CleanupModelError(message: "\(url.lastPathComponent) is not the file name of a known cleanup model")
        }
        return (kind, url.deletingLastPathComponent())
    }

    // MARK: - Baseline

    static func baselineRegressions(
        _ measured: [String: AccuracyBaseline.Entry], corpusID: String?, environment: [String: String]
    ) throws -> (regressions: [AccuracyBaseline.Regression], note: String?) {
        guard let path = environment["VOCAMAC_ACCURACY_BASELINE"], !path.isEmpty else { return ([], nil) }
        let baseline = try AccuracyBaseline.load(from: URL(fileURLWithPath: path))
        if let recorded = baseline.corpus, let corpusID, recorded != corpusID {
            return ([], "Baseline was recorded on corpus \(recorded), not \(corpusID); not compared.")
        }
        let tolerance = environment["VOCAMAC_ACCURACY_TOLERANCE"].flatMap(Double.init)
        return (baseline.regressions(in: measured, tolerance: tolerance), nil)
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
                let intendedURL = directory.appendingPathComponent(base + ".intended.txt")
                let intended = try? String(contentsOf: intendedURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let termsURL = directory.appendingPathComponent(base + ".terms.txt")
                let terms = (try? String(contentsOf: termsURL, encoding: .utf8))
                    .map { RecognitionHints.terms(from: $0) } ?? []
                return CorpusEntry(name: base, audio: directory.appendingPathComponent(file),
                                   reference: reference, intended: intended, terms: terms)
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
        func percent(_ value: Double?) -> String {
            value.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a"
        }
        var lines = ["", "Speech accuracy — \(report.corpus)"]
        lines.append("model                               WER     errors/words  empty  first s  warm s")
        for model in report.models {
            let name = model.model.padding(toLength: max(34, model.model.count), withPad: " ", startingAt: 0)
            lines.append(name + String(
                format: "  %6.2f%%  %5d/%-6d  %5d  %7.2f  %6.2f",
                model.corpusWER * 100, model.corpus.errors, model.corpus.referenceWords,
                model.emptyHypotheses, model.firstDecodeSeconds, model.medianWarmDecodeSeconds
            ))
            if let characters = model.characterCorpus {
                lines.append("  CER (unspaced scripts): " + String(
                    format: "%6.2f%%  %5d/%-6d", characters.rate * 100, characters.errors, characters.referenceWords
                ))
            }
            if model.wordScoredFiles > 0 {
                lines.append("  first word dropped in \(model.firstWordDrops)/\(model.wordScoredFiles) files, "
                    + "last word in \(model.lastWordDrops)/\(model.wordScoredFiles)")
            }
            if let terms = model.terms {
                lines.append("  terms: \(terms.recalled)/\(terms.expected) spelled right (\(percent(terms.recall))), "
                    + "\(terms.falseInsertions) inserted where not said")
            }
            if let unhinted = model.unhintedCorpus, let hinted = model.hintedCorpus {
                let unhintedTerms = model.unhintedTerms
                lines.append("  files with hints: WER \(percent(hinted.rate)) with them, "
                    + "\(percent(unhinted.rate)) without; terms without them "
                    + "\(unhintedTerms?.recalled ?? 0)/\(unhintedTerms?.expected ?? 0) "
                    + "(\(percent(unhintedTerms?.recall))), \(unhintedTerms?.falseInsertions ?? 0) inserted")
            }
            if let finalCorpus = model.finalCorpus {
                lines.append("  final text against the intended text: " + String(
                    format: "%6.2f%%  %5d/%-6d", finalCorpus.rate * 100, finalCorpus.errors, finalCorpus.referenceWords
                ))
            }
            if let formatting = model.finalFormatting {
                lines.append("  final punctuation F1 \(percent(formatting.punctuation.f1)), "
                    + "capitalization F1 \(percent(formatting.capitalization.f1))")
            }
            if let terms = model.finalTerms {
                lines.append("  final terms: \(terms.recalled)/\(terms.expected) (\(percent(terms.recall))), "
                    + "\(terms.falseInsertions) inserted")
            }
        }
        if let cleanupModel = report.cleanupModel {
            lines.append("cleanup model: \(cleanupModel) at \(report.cleanupLevel ?? "medium")")
        }
        if !report.skippedModels.isEmpty {
            lines.append("skipped (not downloaded): \(report.skippedModels.joined(separator: ", "))")
        }
        for note in report.hintsNotTested ?? [] {
            lines.append("hints not tested: \(note); set VOCAMAC_ACCURACY_ALLOW_DOWNLOAD=1")
        }
        if let note = report.baselineNote {
            lines.append(note)
        }
        for regression in report.baselineRegressions ?? [] {
            lines.append("REGRESSION: \(regression)")
        }
        lines.append("report: \(outputURL.path)")
        return lines.joined(separator: "\n")
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}
