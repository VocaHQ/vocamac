// ParakeetVocabularyBoost.swift
// VocaMac
//
// Dictionary vocabulary boost for Parakeet, using FluidAudio's CTC word
// spotter (NeMo CTC-WS) and constrained rescoring.
//
// A separate Parakeet CTC 110M model scores the audio for each vocabulary
// term; the rescorer then swaps a transcript word for a term only where the
// acoustic evidence supports it. This fixes terms Parakeet heard far off
// ("in video" → NVIDIA), which the text-only `DictionaryCorrector` cannot.
//
// The CTC model is an explicit ~98 MB download from the Dictionary page. It
// loads lazily, only while Parakeet is the engine and the Dictionary has
// terms, and unloads with Parakeet.

import Foundation
import FluidAudio

actor ParakeetVocabularyBoost {

    /// Everything the boost needs from the rescorer, for unit tests.
    struct Replacement: Equatable {
        let original: String
        let replacement: String
    }

    static let variant: CtcModelVariant = .ctc110m

    /// Most replacements one transcript may take: one per eight words, at
    /// least one. More than that means the spotter is matching noise.
    static func maximumReplacements(wordCount: Int) -> Int {
        max(1, wordCount / 8)
    }

    private var models: CtcModels?
    private var isLoadingModels = false
    /// Bumped by `unload()`, so a load that finishes afterwards is dropped
    /// instead of reinstalling the model behind the engine's back.
    private var generation = 0
    private var session: VocabularyBoostingSession?
    private var sessionTerms: [String] = []

    // MARK: - Model files

    static var modelDirectory: URL { CtcModels.defaultCacheDirectory(for: variant) }

    static var isModelDownloaded: Bool {
        CtcModels.modelsExist(at: modelDirectory) && CoreMLModelCache.isComplete(modelDirectory)
    }

    /// Download the CTC model into FluidAudio's cache. Its tokenizer is read
    /// from that same directory, so the model cannot live elsewhere.
    static func downloadModel() async throws {
        CoreMLModelCache.removeIfIncomplete(modelDirectory)
        try await CtcModels.download(variant: variant)
    }

    static func removeModel() throws {
        let directory = modelDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Lifecycle

    /// Load the CTC model in the background. The first load after a download
    /// compiles it for this Mac, which can take tens of seconds, so no
    /// dictation ever waits for it: until it is ready, boosting is skipped.
    func prepare() {
        guard models == nil, !isLoadingModels, Self.isModelDownloaded else { return }
        isLoadingModels = true
        let generation = generation
        Task {
            let start = CFAbsoluteTimeGetCurrent()
            do {
                let models = try await CtcModels.load(from: Self.modelDirectory, variant: Self.variant)
                guard self.finishLoading(models, generation: generation) else { return }
                VocaLogger.info(
                    .parakeetService,
                    "Vocabulary boost model loaded in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s"
                )
            } catch {
                self.finishLoading(nil, generation: generation)
                VocaLogger.warning(.parakeetService, "Vocabulary boost unavailable: \(error.localizedDescription)")
            }
        }
    }

    /// Install a finished load. Returns false when `unload()` ran meanwhile;
    /// the load still ends here, so a new one can start only after it, and
    /// two copies of the model are never compiling or resident at once.
    @discardableResult
    private func finishLoading(_ models: CtcModels?, generation: Int) -> Bool {
        isLoadingModels = false
        guard generation == self.generation else { return false }
        self.models = models
        return true
    }

    func unload() {
        generation &+= 1
        session = nil
        sessionTerms = []
        models = nil
    }

    // MARK: - Boosting

    /// Rescore a Parakeet transcript against the Dictionary.
    ///
    /// - Returns: The boosted text, or nil when there is nothing to boost,
    ///   the model is not ready, or no replacement passed the safety checks.
    ///   A nil result always means "keep the plain transcript".
    func boost(
        text: String,
        tokenTimings: [TokenTiming]?,
        audio: [Float],
        terms: [String]
    ) async -> String? {
        guard !terms.isEmpty, let tokenTimings, !tokenTimings.isEmpty else { return nil }
        // Removed from Settings while Parakeet stays loaded: turn off now.
        guard Self.isModelDownloaded else {
            if models != nil { unload() }
            return nil
        }
        guard let session = await session(for: terms) else {
            prepare()
            return nil
        }

        let start = CFAbsoluteTimeGetCurrent()
        guard let output = await session.rescore(text: text, tokenTimings: tokenTimings, audioSamples: audio),
              output.wasModified else { return nil }
        let proposed = output.replacements.compactMap { result -> Replacement? in
            guard result.shouldReplace, let word = result.replacementWord else { return nil }
            return Replacement(original: result.originalWord, replacement: word)
        }
        let accepted = Self.accepted(proposed, in: text, terms: terms)
        let elapsed = String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start)
        VocaLogger.info(
            .parakeetService,
            "Vocabulary boost kept \(accepted.count) of \(proposed.count) replacement(s) in \(elapsed)s"
        )
        guard !accepted.isEmpty else { return nil }
        return Self.apply(accepted, to: text)
    }

    /// The rescorer's replacements worth taking.
    ///
    /// FluidAudio's rescorer also swaps whole phrases for a term the audio
    /// only faintly supports ("send the report" → NVIDIA). A replacement is
    /// kept only when it writes one of the user's terms over words spelled
    /// close to it, with the same first sound; at most one per eight words.
    static func accepted(_ replacements: [Replacement], in text: String, terms: [String]) -> [Replacement] {
        let known = Set(terms.map(DictionaryCorrector.normalized))
        let close = replacements.filter { replacement in
            let heard = DictionaryCorrector.normalized(replacement.original)
            let term = DictionaryCorrector.normalized(replacement.replacement)
            guard known.contains(term), !heard.isEmpty, heard != term,
                  DictionaryCorrector.firstSound(heard) == DictionaryCorrector.firstSound(term) else { return false }
            let limit = max(1, Int(Double(max(heard.count, term.count)) * 0.34))
            return DictionaryCorrector.levenshtein(heard, term, limit: limit) <= limit
        }
        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        return close.count <= maximumReplacements(wordCount: wordCount) ? close : []
    }

    /// Write each term over the words it replaces, keeping the punctuation
    /// around them. Occurrences are matched in order, left to right.
    static func apply(_ replacements: [Replacement], to text: String) -> String {
        var result = text
        var searchStart = result.startIndex
        for replacement in replacements {
            guard let found = result.range(of: replacement.original, range: searchStart..<result.endIndex) else {
                continue
            }
            let words = result[found]
            guard let first = words.firstIndex(where: { $0.isLetter || $0.isNumber }),
                  let last = words.lastIndex(where: { $0.isLetter || $0.isNumber }) else { continue }
            let core = first..<result.index(after: last)
            result.replaceSubrange(core, with: replacement.replacement)
            searchStart = result.index(first, offsetBy: replacement.replacement.count, limitedBy: result.endIndex)
                ?? result.endIndex
        }
        return result
    }

    /// The boosting session for this term list, or nil until the CTC model
    /// has loaded. Rebuilding re-tokenizes every term (a few milliseconds),
    /// so it only happens when the list changes.
    private func session(for terms: [String]) async -> VocabularyBoostingSession? {
        if let session, sessionTerms == terms { return session }
        guard let models else { return nil }
        do {
            let vocabulary = CustomVocabularyContext(
                terms: terms.map { CustomVocabularyTerm(text: $0) },
                minTermLength: RecognitionHints.minimumBoostTermLength
            )
            let session = try await VocabularyBoostingSession(vocabulary: vocabulary, ctcModels: models)
            self.session = session
            sessionTerms = terms
            return session
        } catch {
            VocaLogger.warning(.parakeetService, "Vocabulary boost unavailable: \(error.localizedDescription)")
            session = nil
            sessionTerms = []
            return nil
        }
    }
}
