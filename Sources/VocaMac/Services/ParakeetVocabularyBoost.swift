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
// The CTC model is a ~98 MB download, fetched on its own once Parakeet is
// the engine and the Dictionary has a word to listen for (unless the user
// removed it from the Dictionary page). It loads lazily, only while Parakeet
// is the engine and the Dictionary has terms, and unloads with Parakeet.

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
    /// Whether `session` was built for written-form (ITN) output.
    private var sessionWritesNumbers = false

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
        sessionWritesNumbers = false
        models = nil
    }

    // MARK: - Boosting

    /// Rescore a Parakeet transcript against the Dictionary.
    ///
    /// - Parameter language: The dictation language, if known. Decides
    ///   whether heard words are checked against the English spell checker.
    /// - Parameter writesNumbers: The model writes numbers and symbols
    ///   ("35.3%"), as Parakeet Unified does, so the rescorer uses FluidAudio's
    ///   stricter settings for that kind of text.
    /// - Returns: The boosted text, or nil when there is nothing to boost,
    ///   the model is not ready, or no replacement passed the safety checks.
    ///   A nil result always means "keep the plain transcript".
    func boost(
        text: String,
        tokenTimings: [TokenTiming]?,
        audio: [Float],
        terms: [String],
        language: String?,
        writesNumbers: Bool = false
    ) async -> String? {
        guard !terms.isEmpty, let tokenTimings, !tokenTimings.isEmpty else { return nil }
        // Removed from Settings while Parakeet stays loaded: turn off now.
        guard Self.isModelDownloaded else {
            // Also retire a load still in flight, so it cannot install the
            // model after the download was removed.
            if models != nil || isLoadingModels { unload() }
            return nil
        }
        guard let session = await session(for: terms, writesNumbers: writesNumbers) else {
            prepare()
            return nil
        }

        // The CTC pass costs a third to half a second. When no run of the
        // words Parakeet heard is spelled close enough to a term to pass
        // `accepted`, nothing it proposes could be kept, so skip it.
        let words = buildWordTimings(from: tokenTimings).map(\.word)
        guard Self.couldAcceptReplacement(heardWords: words, terms: terms) else {
            VocaLogger.debug(.parakeetService, "Vocabulary boost skipped: no words close to a Dictionary term")
            return nil
        }

        let start = CFAbsoluteTimeGetCurrent()
        guard let output = await session.rescore(text: text, tokenTimings: tokenTimings, audioSamples: audio),
              output.wasModified else { return nil }
        let proposed = output.replacements.compactMap { result -> Replacement? in
            guard result.shouldReplace, let word = result.replacementWord else { return nil }
            return Replacement(original: result.originalWord, replacement: word)
        }
        let heardWords = Set(proposed.flatMap { DictionaryCorrector.tokens(in: $0.original).map(\.text) })
        let knownWords = await Self.knownWords(heardWords, language: language)
        let accepted = Self.accepted(proposed, in: text, terms: terms, isKnownWord: knownWords.contains)
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
    ///
    /// Words Parakeet heard that are all real words stay, as they do in
    /// `DictionaryCorrector`: the rescorer scores a short term well almost
    /// anywhere, so "restart the server" became "restart the sergey" with
    /// Sergey in the Dictionary.
    static func accepted(
        _ replacements: [Replacement],
        in text: String,
        terms: [String],
        isKnownWord: (String) -> Bool
    ) -> [Replacement] {
        let known = Set(terms.map(DictionaryCorrector.normalized))
        let close = replacements.filter { replacement in
            let heardWords = DictionaryCorrector.tokens(in: replacement.original).map(\.text)
            guard !heardWords.allSatisfy(isKnownWord) else { return false }
            let heard = DictionaryCorrector.normalized(replacement.original)
            let term = DictionaryCorrector.normalized(replacement.replacement)
            return known.contains(term) && isSpelledClose(heard: heard, term: term)
        }
        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        return close.count <= maximumReplacements(wordCount: wordCount) ? close : []
    }

    /// Whether heard words (normalized) could be written over with `term`
    /// (normalized): spelled close to it, with the same first sound.
    static func isSpelledClose(heard: String, term: String) -> Bool {
        guard !heard.isEmpty, heard != term,
              DictionaryCorrector.firstSound(heard) == DictionaryCorrector.firstSound(term) else { return false }
        let limit = closenessLimit(heardCount: heard.count, termCount: term.count)
        return DictionaryCorrector.levenshtein(heard, term, limit: limit) <= limit
    }

    /// Edits allowed between heard words and a term: a third of the longer.
    private static func closenessLimit(heardCount: Int, termCount: Int) -> Int {
        max(1, Int(Double(max(heardCount, termCount)) * 0.34))
    }

    /// Whether any run of consecutive words in the transcript passes
    /// `isSpelledClose` for one of `terms`.
    ///
    /// The rescorer only ever proposes a run of the decoder's own words (its
    /// word timings, which `heardWords` must be), and `accepted` keeps a
    /// proposal only when that run is spelled close to a term. So when this is
    /// false, rescoring cannot change the transcript and can be skipped. It
    /// leaves out `accepted`'s other checks (real words, how many), so it is
    /// never false where they would have let something through.
    static func couldAcceptReplacement(heardWords: [String], terms: [String]) -> Bool {
        let words = heardWords.map(DictionaryCorrector.normalized)
        let keys = Set(terms.map(DictionaryCorrector.normalized)).filter { !$0.isEmpty }
        for term in keys {
            for start in words.indices {
                var heard = ""
                for word in words[start...] {
                    heard += word
                    // Longer runs only differ more in length: once a run is
                    // further from the term than the limit allows, so is every
                    // longer one.
                    let limit = closenessLimit(heardCount: heard.count, termCount: term.count)
                    if heard.count - term.count > limit { break }
                    if heard.count + limit < term.count { continue }
                    if isSpelledClose(heard: heard, term: term) { return true }
                }
            }
        }
        return false
    }

    /// The words in `words` that the system spell checker knows. It checks
    /// English only, so in another language no word counts as known and the
    /// boost keeps its other checks rather than switching off.
    @MainActor
    private static func knownWords(_ words: Set<String>, language: String?) -> Set<String> {
        if let language = DictationOutputPipeline.knownLanguage(language), !language.hasPrefix("en") {
            return []
        }
        return words.filter { SpellingOracle.shared.isKnownWord($0, language: "en") }
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
    private func session(for terms: [String], writesNumbers: Bool) async -> VocabularyBoostingSession? {
        if let session, sessionTerms == terms, sessionWritesNumbers == writesNumbers { return session }
        guard let models else { return nil }
        do {
            let vocabulary = CustomVocabularyContext(
                terms: terms.map { CustomVocabularyTerm(text: $0) },
                minTermLength: RecognitionHints.minimumBoostTermLength
            )
            let session = try await VocabularyBoostingSession(
                vocabulary: vocabulary, ctcModels: models,
                config: writesNumbers ? VocabularyBoostingSession.itnDefaultConfig : nil
            )
            self.session = session
            sessionTerms = terms
            sessionWritesNumbers = writesNumbers
            return session
        } catch {
            VocaLogger.warning(.parakeetService, "Vocabulary boost unavailable: \(error.localizedDescription)")
            session = nil
            sessionTerms = []
            sessionWritesNumbers = false
            return nil
        }
    }
}
