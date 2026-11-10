// AppState+Dictionary.swift
// VocaMac
//
// The Dictionary: teaching words, vocabulary boost, and suggested terms. Moved out of AppState.swift unchanged.

import Foundation
import SwiftUI
import Combine
import AppKit
import os

extension AppState {

    // MARK: - Teaching a Dictionary word

    /// Whether the microphone and the speech model are free for a take.
    var canTeachWord: Bool {
        isFreeForMediaTranscription && !isTranscribing && !isStartingAudio && earlyCapture == nil
    }

    /// Open the microphone for one take of a word being taught. Returns
    /// false when something else holds it or it could not start.
    func startTeachingTake() async -> Bool {
        guard canTeachWord else { return false }
        isTeachingWord = true
        audioEngine.onAudioSamples = nil
        let start = Task { @MainActor [weak self] () -> Bool in
            await self?.startConfiguredAudioEngine() ?? false
        }
        teachingStart = start
        let started = await start.value
        if teachingStart == start { teachingStart = nil }
        // Cancelled or finished while the microphone was opening: that call
        // waited for this start and has already closed it.
        guard isTeachingWord else { return false }
        if !started {
            isTeachingWord = false
            VocaLogger.warning(.dictionary, "Could not open the microphone to teach a word")
        }
        return started
    }

    /// Wait for a take's microphone start still under way, so the stop that
    /// follows closes it rather than running first on the audio queue.
    private func settleTeachingStart() async {
        guard let start = teachingStart else { return }
        _ = await start.value
        teachingStart = nil
    }

    /// End the take and decode it without recognition hints, so the result
    /// is what the engine hears on its own. "" when nothing was heard; nil
    /// when the model could not run.
    func finishTeachingTake() async -> String? {
        guard isTeachingWord else { return nil }
        defer { isTeachingWord = false }
        await settleTeachingStart()
        let samples = await stopAudioEngine()
        // Under a quarter of a second at 16 kHz is a click, not a word.
        guard samples.count >= 4_000 else { return "" }
        if !transcriber.isModelLoaded { await ensureModelLoaded() }
        guard transcriber.isModelLoaded else { return nil }
        do {
            let result = try await transcriber.transcribe(
                audioData: samples,
                language: selectedLanguage == "auto" ? nil : selectedLanguage,
                translate: false,
                vocabulary: ""
            )
            return result.text
        } catch {
            VocaLogger.warning(.dictionary, "Could not decode a take of a Dictionary word: \(error.localizedDescription)")
            return nil
        }
    }

    /// Close the microphone without decoding (the dialog closed mid-take).
    func cancelTeachingTake() async {
        guard isTeachingWord else { return }
        await settleTeachingStart()
        _ = await stopAudioEngine()
        isTeachingWord = false
    }

    /// Save what a teaching session found: the word stays (or is put) in the
    /// vocabulary, and each chosen spoken form becomes part of its
    /// replacement, as a learned correction would (`learn`).
    func teachWord(_ term: String, heardForms: [String]) {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        if !vocabularyTerms.contains(where: { $0.lowercased() == term.lowercased() }) {
            addVocabularyTerm(term)
        }
        for form in heardForms {
            addWordReplacement(heard: form, replacement: term)
        }
        VocaLogger.info(.dictionary, "Taught a word by voice with \(heardForms.count) spoken form(s)")
    }

    static func sameOutputTarget(_ first: RunningAppSnapshot?, _ second: RunningAppSnapshot?) -> Bool {
        switch (first, second) {
        case (nil, nil): return true
        case let (first?, second?):
            return AppIdentityMatching.matches(
                configuredBundleIdentifier: first.bundleIdentifier,
                configuredProcessName: first.processName,
                configuredID: first.bundleIdentifier ?? first.processName ?? first.displayName,
                snapshot: second
            )
        default: return false
        }
    }

    // MARK: Dictionary

    /// Replacement targets offered to engines as recognition hints.
    var replacementTargets: [String] {
        wordReplacements.filter(\.isValid).map(\.replacement)
    }

    /// Vocabulary and replacement targets as a recognition hint, for decodes
    /// with no screen context (live sessions, files, history retries).
    var recognitionHintVocabulary: String {
        Self.recognitionVocabulary(
            customVocabulary, replacementTargets: replacementTargets, contextTerms: [], usage: termUsage
        )
    }

    // MARK: - Vocabulary Boost

    /// Fetch Parakeet's vocabulary boost model once it would help: Parakeet
    /// is selected and the Dictionary has a word to listen for. It is about
    /// 98 MB and loads in the background, so nothing waits on it. Never in a
    /// test run, which must not touch the network.
    func downloadVocabularyBoostIfUseful() {
        guard NSClassFromString("XCTestCase") == nil,
              VocabularyBoostStatus.downloadsAutomatically(
                  engine: ModelSize(rawValue: selectedModelSize)?.engine,
                  vocabulary: recognitionHintVocabulary, status: vocabularyBoostStatus,
                  removedByUser: vocabularyBoostRemovedByUser
              ) else { return }
        VocaLogger.info(.appState, "Fetching Parakeet's vocabulary boost: the Dictionary has words to listen for")
        downloadVocabularyBoost()
    }

    /// Download Parakeet's vocabulary boost model.
    func downloadVocabularyBoost() {
        guard vocabularyBoostStatus != .downloading else { return }
        vocabularyBoostRemovedByUser = false
        vocabularyBoostStatus = .downloading
        Task { @MainActor [weak self] in
            do {
                try await TranscriptionRouter.downloadVocabularyBoost()
                self?.vocabularyBoostStatus = .ready
                VocaLogger.info(.appState, "Parakeet vocabulary boost downloaded")
            } catch {
                VocaLogger.error(.appState, "Vocabulary boost download failed: \(error.localizedDescription)")
                self?.vocabularyBoostStatus = .failed(error.localizedDescription)
            }
        }
    }

    /// Delete Parakeet's vocabulary boost model.
    func removeVocabularyBoost() {
        do {
            try TranscriptionRouter.removeVocabularyBoost()
            vocabularyBoostStatus = .notDownloaded
            vocabularyBoostRemovedByUser = true
        } catch {
            VocaLogger.error(.appState, "Could not remove vocabulary boost: \(error.localizedDescription)")
            vocabularyBoostStatus = .failed(error.localizedDescription)
        }
    }

    /// Vocabulary terms, one per entry. Stored in `customVocabulary` so the
    /// Whisper recognition hint keeps working.
    var vocabularyTerms: [String] {
        RecognitionHints.vocabularyTerms(from: customVocabulary)
    }

    func setVocabularyTerms(_ terms: [String]) {
        var seen = Set<String>()
        // A comma or new line inside a term would read back as two terms
        // (and could duplicate one already listed), so split them here.
        let cleaned = terms
            .flatMap { RecognitionHints.vocabularyTerms(from: $0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        customVocabulary = cleaned.joined(separator: "\n")
        noteDictionaryTermsSeen()
        downloadVocabularyBoostIfUseful()
    }

    /// Add a term, replacing a differently-cased copy of it.
    func addVocabularyTerm(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var terms = vocabularyTerms.filter { $0.lowercased() != trimmed.lowercased() }
        terms.append(trimmed)
        setVocabularyTerms(terms)
    }

    /// Put a removed term back where it was, so undoing an early term in a long
    /// list does not push a different one out of the recognition hints (which
    /// keep the last terms). Does nothing if the term was added again meanwhile.
    func restoreVocabularyTerm(_ term: String, at index: Int) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        var terms = vocabularyTerms
        guard !trimmed.isEmpty, !terms.contains(where: { $0.lowercased() == trimmed.lowercased() }) else { return }
        terms.insert(trimmed, at: min(max(index, 0), terms.count))
        setVocabularyTerms(terms)
    }

    func removeVocabularyTerm(_ term: String) {
        setVocabularyTerms(vocabularyTerms.filter { $0 != term })
    }

    /// Add a replacement, merging into an existing one that already writes
    /// the same text.
    func addWordReplacement(heard: String, replacement: String) {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !replacement.isEmpty else { return }
        if let index = wordReplacements.firstIndex(where: { $0.replacement == replacement }) {
            let forms = wordReplacements[index].heardForms
            guard !forms.contains(where: { $0.lowercased() == heard.lowercased() }) else { return }
            wordReplacements[index].heard = (forms + [heard]).joined(separator: ", ")
        } else {
            wordReplacements.append(WordReplacement(heard: heard, replacement: replacement))
        }
    }

    /// - Parameter segments: The decode's timings; the words the engine was
    ///   unsure of let the Dictionary respell real words that sound like a
    ///   term (`RecognitionConfidence`).
    func dictionaryContext(
        contextTerms: [String], language: String?, segments: [TimedSegment] = []
    ) -> DictionaryContext {
        let isKnownWord = self.isKnownWord
        // "auto" from Parakeet or Apple Speech isn't a language; passed on, it
        // made every word count as known and switched off name fixes.
        let language = DictationOutputPipeline.knownLanguage(language)
        return DictionaryContext(
            vocabulary: vocabularyTerms,
            replacements: wordReplacements,
            contextTerms: contextTerms,
            isKnownWord: { isKnownWord($0, language) },
            removedWords: personalFillers,
            lowConfidenceWords: RecognitionConfidence.lowConfidenceWords(in: segments)
        )
    }

    /// Accept a noticed correction: the corrected spelling becomes a
    /// vocabulary term, plus a replacement when the engine heard different
    /// letters (not just different casing or spacing).
    func acceptDictionarySuggestion(_ suggestion: CorrectionSuggestion) {
        learn(heard: suggestion.heard, corrected: suggestion.corrected, language: suggestion.language)
        dictionarySuggestions.removeAll { $0.id == suggestion.id }
        saveSuggestions()
    }

    func dismissDictionarySuggestion(_ suggestion: CorrectionSuggestion) {
        dictionarySuggestions.removeAll { $0.id == suggestion.id }
        dismissedSuggestionKeys.insert(suggestion.id)
        saveSuggestions()
    }

    /// - Parameter language: The language of the dictation the correction
    ///   was seen in; the selected one when unknown.
    private func learn(heard: String, corrected: String, language: String?) {
        addVocabularyTerm(corrected)
        // A replacement fires on every later match. "cloud" fixed to
        // "Claude" once must not turn every cloud into Claude, so a single
        // ordinary word only teaches the term; the engines are then asked to
        // listen for it, and cleanup may respell it in context. A phrase
        // ("get hub" → "GitHub") is rarely said for itself, so it still
        // becomes a replacement.
        if DictionaryCorrector.normalized(heard) != DictionaryCorrector.normalized(corrected),
           !Self.isOrdinaryWord(heard, isKnownWord: { self.isKnownWord($0, language ?? self.spellingLanguage) }) {
            addWordReplacement(heard: heard, replacement: corrected)
        }
        VocaLogger.info(.dictionary, "Learned a spelling from a correction")
    }

    /// Whether `text` is one ordinary word, so a replacement from it would
    /// rewrite ordinary speech.
    nonisolated static func isOrdinaryWord(_ text: String, isKnownWord: (String) -> Bool) -> Bool {
        let words = text.lowercased().split { !($0.isLetter || $0 == "'" || $0 == "’") }.map(String.init)
        return words.count == 1 && isKnownWord(words[0])
    }

    /// The language to judge ordinary words in when no dictation says
    /// which: the selected one, else English.
    var spellingLanguage: String {
        DictationOutputPipeline.knownLanguage(selectedLanguage) ?? "en"
    }

    func receiveCorrections(_ corrections: [CorrectionLearner.Correction]) {
        let mode = learnCorrectionsMode
        guard mode != .off else { return }
        let known = Set(vocabularyTerms)
        var learned: [LearnedCorrection] = []
        for correction in corrections where !known.contains(correction.corrected) {
            let key = CorrectionSuggestion.key(heard: correction.heard, corrected: correction.corrected)
            guard !dismissedSuggestionKeys.contains(key) else { continue }
            // Only the user's own fix of a name or term is added unasked;
            // screen and History finds, and anything else, are suggested.
            if mode == .automatic, correction.source == nil,
               Self.learnsWithoutAsking(correction.corrected, isKnownWord: {
                   self.isKnownWord($0, correction.language ?? self.spellingLanguage)
               }) {
                learned.append(learnUndoably(correction))
                continue
            }
            if let index = dictionarySuggestions.firstIndex(where: { $0.id == key }) {
                dictionarySuggestions[index].occurrences += 1
                dictionarySuggestions[index].lastSeen = Date()
                dictionarySuggestions[index].language = correction.language ?? dictionarySuggestions[index].language
            } else {
                dictionarySuggestions.insert(
                    CorrectionSuggestion(heard: correction.heard, corrected: correction.corrected,
                                         occurrences: 1, lastSeen: Date(), language: correction.language,
                                         source: correction.source),
                    at: 0
                )
            }
        }
        dictionarySuggestions = Array(dictionarySuggestions.prefix(50))
        saveSuggestions()
        offerUndo(for: learned)
    }

    /// What one automatic learn added, so Undo takes back exactly that.
    struct LearnedCorrection {
        let heard: String
        let corrected: String
        let addedTerm: Bool
        let addedReplacement: Bool
    }

    private func learnUndoably(_ correction: CorrectionLearner.Correction) -> LearnedCorrection {
        let hadTerm = vocabularyTerms.contains(correction.corrected)
        let replacementsBefore = wordReplacements
        learn(heard: correction.heard, corrected: correction.corrected, language: correction.language)
        return LearnedCorrection(
            heard: correction.heard, corrected: correction.corrected,
            addedTerm: !hadTerm && vocabularyTerms.contains(correction.corrected),
            addedReplacement: wordReplacements != replacementsBefore
        )
    }

    /// "Learned “Priya”" on the overlay, with Undo.
    private func offerUndo(for learned: [LearnedCorrection]) {
        guard !learned.isEmpty else { return }
        let names = learned.map { "“\(Self.shortened($0.corrected))”" }
        let message = "Learned " + (names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + (names.last ?? ""))
        cursorOverlay.showLearned(message: message) { [weak self] in
            self?.unlearn(learned)
        }
    }

    /// Take back automatic learns, and don't learn the same fixes again.
    func unlearn(_ learned: [LearnedCorrection]) {
        for item in learned {
            if item.addedTerm { removeVocabularyTerm(item.corrected) }
            if item.addedReplacement,
               let index = wordReplacements.firstIndex(where: { $0.replacement == item.corrected }) {
                let forms = wordReplacements[index].heardForms.filter { $0.lowercased() != item.heard.lowercased() }
                if forms.isEmpty {
                    wordReplacements.remove(at: index)
                } else {
                    wordReplacements[index].heard = forms.joined(separator: ", ")
                }
            }
            dismissedSuggestionKeys.insert(CorrectionSuggestion.key(heard: item.heard, corrected: item.corrected))
        }
        saveSuggestions()
        VocaLogger.info(.dictionary, "Took back \(learned.count) learned spelling(s)")
    }

    // MARK: - Suggested terms

    /// Screen respellings seen before, by suggestion key, until one has
    /// been seen often enough to suggest.
    private var screenRespellingCounts: [String: Int] {
        get { userDefaultsStore.dictionary(forKey: PreferenceKey.screenRespellingCounts) as? [String: Int] ?? [:] }
        set { userDefaultsStore.set(newValue, forKey: PreferenceKey.screenRespellingCounts) }
    }

    /// Times a screen term must replace the same words before it is
    /// suggested: once may be a coincidence, twice is a pattern.
    static let screenRespellingsBeforeSuggesting = 2

    /// Count each place `final` has a screen term where the engine heard
    /// other words, and suggest the term once it keeps happening.
    func noteScreenRespellings(raw: String, final: String, screenTerms: [String], language: String?) {
        guard learnCorrectionsMode != .off, !screenTerms.isEmpty else { return }
        let listed = Set(vocabularyTerms.map { $0.lowercased() })
        var counts = screenRespellingCounts
        var due: [CorrectionLearner.Correction] = []
        for (heard, term) in TermSuggestionFinder.screenRespellings(raw: raw, final: final, terms: screenTerms)
        where !listed.contains(term.lowercased()) {
            let key = CorrectionSuggestion.key(heard: heard, corrected: term)
            counts[key, default: 0] += 1
            if counts[key, default: 0] >= Self.screenRespellingsBeforeSuggesting {
                due.append(CorrectionLearner.Correction(heard: heard, corrected: term, language: language, source: .screen))
            }
        }
        // Bounded: the rarest go first.
        if counts.count > 200 {
            counts = Dictionary(uniqueKeysWithValues: counts.sorted { $0.value > $1.value }.prefix(150).map { ($0.key, $0.value) })
        }
        screenRespellingCounts = counts
        if !due.isEmpty { receiveCorrections(due) }
    }

    /// Once a day, look through recent History for names the spell checker
    /// doesn't know that keep coming up, and suggest them.
    func suggestFrequentNamesIfDue(now: Date = Date()) {
        guard learnCorrectionsMode != .off else { return }
        if let last = userDefaultsStore.object(forKey: PreferenceKey.lastFrequentNameScan) as? Date,
           now.timeIntervalSince(last) < 24 * 60 * 60 { return }
        userDefaultsStore.set(now, forKey: PreferenceKey.lastFrequentNameScan)
        // History keeps the newest first: these are the most recent.
        let entries = historyStore.entries.filter { $0.status == .completed && $0.commandOriginal == nil }
            .prefix(TermSuggestionFinder.maximumDictations)
        let texts = entries.map(\.finalText)
        // The commonest language decides which spell checker judges a name.
        let language = Dictionary(grouping: entries.compactMap { DictationOutputPipeline.knownLanguage($0.language) }) { $0 }
            .max { $0.value.count < $1.value.count }?.key ?? spellingLanguage
        Task { @MainActor [weak self] in
            let candidates = await Task.detached(priority: .utility) {
                TermSuggestionFinder.capitalizedCandidates(in: texts)
            }.value
            guard let self, !candidates.isEmpty else { return }
            let names = TermSuggestionFinder.unknownNames(
                candidates, vocabulary: vocabularyTerms, isKnownWord: { self.isKnownWord($0, language) }
            )
            guard !names.isEmpty else { return }
            VocaLogger.info(.dictionary, "Found \(names.count) name(s) said in several dictations")
            receiveCorrections(names.map {
                CorrectionLearner.Correction(heard: $0, corrected: $0, language: language, source: .frequent)
            })
        }
    }

    /// Feed corrections through the same path the observer uses. Tests only.
    func _receiveCorrectionsForTesting(_ corrections: [CorrectionLearner.Correction]) {
        receiveCorrections(corrections)
    }

    func observeCorrections(
        to text: String, language: String, historyID: UUID?, app: RunningAppSnapshot?
    ) {
        guard learnCorrectionsMode != .off, let correctionObserver,
              let processID = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let isKnownWord = self.isKnownWord
        correctionObserver.observe(
            insertedText: text, processID: processID, language: language, historyID: historyID, app: app
        ) {
            isKnownWord($0, language)
        }
    }

    /// Whether `rules` start sentences with a capital.
    static func capitalizes(_ rules: WritingStyleRules, autoCapitalize: Bool) -> Bool {
        switch rules.capitalization {
        case .inherit, .lowercaseStart: return autoCapitalize
        case .sentences: return true
        case .off: return false
        }
    }

    /// What History and the menu say for a dictation to a coding agent.
    static let codingAgentSummary = "Coding agent in Terminal — prose cleanup"

    /// Look, off the main thread, for a coding agent in `target`'s tab in
    /// front, when `target` gets the Terminal style and the setting allows.
    /// The task returns `target` when one runs there, nil otherwise.
    func codingAgentDetection(for target: RunningAppSnapshot) -> Task<RunningAppSnapshot?, Never>? {
        guard codingAgentsAsProse, AppDistribution.canReadOtherProcesses,
              resolveWritingStyle(for: target).style == .terminal,
              let app = NSWorkspace.shared.runningApplications.first(where: {
                  Self.sameOutputTarget(target, RunningAppSnapshot(
                      displayName: $0.localizedName ?? "", bundleIdentifier: $0.bundleIdentifier,
                      processName: $0.executableURL?.lastPathComponent
                  ))
              }) else { return nil }
        let processID = app.processIdentifier
        return Task.detached(priority: .userInitiated) {
            let title = AccessibilityTextReader.focusedWindowTitle(processID: processID)
            let found = CodingAgentDetector.detect(terminalProcessID: processID, windowTitle: title)
            if found { VocaLogger.debug(.appState, "Coding agent running in \(target.displayName): prose cleanup") }
            return found ? target : nil
        }
    }

    /// Start reading names and identifiers from the screen while the user speaks.
    func startScreenContextCapture(injectResult: Bool) {
        screenContextTask?.cancel()
        screenContextTask = nil
        screenDocumentURLTask?.cancel()
        screenDocumentURLTask = nil
        insertionContextTask?.cancel()
        insertionContextTask = nil
        guard injectResult, let reader = screenContextReader else { return }
        if useScreenContext {
            let isKnownWord = self.isKnownWord
            let language = spellingLanguage
            screenContextTask = Task { @MainActor in
                guard let text = await reader.captureFrontmostContext(), !Task.isCancelled else { return [] }
                return ScreenContextTerms.extract(from: text) { isKnownWord($0, language) }
            }
        }
        if !websiteStyleBindings.isEmpty {
            screenDocumentURLTask = Task { @MainActor in
                await reader.captureFrontmostDocumentURL()
            }
        }
        if writingStyleEnabled {
            insertionContextTask = Task { @MainActor in
                await reader.captureInsertionContext()
            }
        }
    }

    /// The screen terms, if they arrive in time. Never holds up a dictation
    /// for more than a moment on a slow app.
    static func awaitContextTerms(_ task: Task<[String], Never>?) async -> [String] {
        await value(of: task, within: screenContextTimeout, otherwise: [])
    }

    static func awaitDocumentURL(_ task: Task<URL?, Never>?) async -> URL? {
        await value(of: task, within: screenContextTimeout, otherwise: nil)
    }

    static let screenContextTimeout: TimeInterval = 0.3
    /// How long cleanup ahead of time waits for the screen's terms.
    static let speculationContextTimeout: TimeInterval = 2

    /// A task's value if it arrives within `timeout`, otherwise `fallback`.
    ///
    /// Returns at the deadline even when the task ignores cancellation: a
    /// task group would wait for every child, and `Task.value` does not stop
    /// waiting when cancelled, so a slow Accessibility read would hold up the
    /// dictation for as long as it took. The task is left to finish on its own.
    static func value<T: Sendable>(
        of task: Task<T, Never>?,
        within timeout: TimeInterval,
        otherwise fallback: T
    ) async -> T {
        guard let task else { return fallback }
        let gate = FirstValueGate<T>()
        return await withCheckedContinuation { continuation in
            gate.install(continuation)
            Task.detached {
                gate.resume(with: await task.value)
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                gate.resume(with: fallback)
            }
        }
    }

    /// A browser can navigate while transcription runs. Apply a website rule
    /// only when the output is still going to the host captured at recording
    /// start; a failed refresh is safer than formatting for a stale page.
    func revalidatedDocumentURL(_ capturedURL: URL?) async -> URL? {
        guard !websiteStyleBindings.isEmpty,
              let capturedURL,
              let reader = screenContextReader else { return nil }
        let refresh = Task { @MainActor in await reader.captureFrontmostDocumentURL() }
        guard let currentURL = await Self.value(of: refresh, within: Self.screenContextTimeout, otherwise: nil) else {
            VocaLogger.warning(.appState, "Couldn't re-read the website before dictation output; skipping the captured website rule")
            return nil
        }
        guard capturedURL.host?.lowercased() == currentURL.host?.lowercased() else {
            VocaLogger.warning(.appState, "Website changed before dictation output; skipping the captured website rule")
            return nil
        }
        return currentURL
    }

    /// The hint list every engine reads its vocabulary from: screen terms,
    /// then replacement targets and the user's own terms.
    ///
    /// Each engine keeps what it can take from the end of the list: Whisper
    /// `WhisperService.maximumPromptTokens`, Apple Speech and Parakeet 100
    /// terms each (`RecognitionHints`), the custom endpoint a short prompt.
    /// So the user's words go last and are never cut, and the screen terms
    /// most worth hearing (`ScreenContextTerms.extract` puts them first) sit
    /// right before them. The budget here only bounds the list as a whole; a
    /// tighter one sized for Whisper left Apple Speech and Parakeet without
    /// screen terms once the user had about 40 words.
    /// - Parameter usage: How recently each term was dictated; the user's
    ///   terms are ordered by it so the ones said lately are kept when an
    ///   engine trims the list from the front (`TermUsage`).
    static func recognitionVocabulary(
        _ vocabulary: String,
        replacementTargets: [String] = [],
        contextTerms: [String],
        usage: [String: TermUsage] = [:]
    ) -> String {
        // Replacement targets ("GitHub" for "get hub") are words the user
        // wants heard, so they join the vocabulary ahead of the user's terms.
        var userTerms = RecognitionHints.vocabularyTerms(from: vocabulary)
        let listed = Set(userTerms.map { $0.lowercased() })
        var targetSeen = Set<String>()
        let targets = replacementTargets.filter {
            RecognitionHints.isHintableReplacement($0)
                && !listed.contains($0.lowercased())
                && targetSeen.insert($0.lowercased()).inserted
        }
        userTerms = TermUsage.ordered(targets + userTerms, by: usage)
        let known = Set(userTerms.map { $0.lowercased() })
        let characterBudget = max(0, recognitionPromptCharacterBudget - userTerms.joined(separator: ", ").count)
        var screenTerms: [String] = []
        var used = 0
        var seen = Set<String>()
        for term in contextTerms where !known.contains(term.lowercased()) && seen.insert(term.lowercased()).inserted {
            guard screenTerms.count < maximumRecognitionContextTerms,
                  used + term.count + 2 <= characterBudget else { break }
            screenTerms.append(term)
            used += term.count + 2
        }
        // Most relevant last among them, so a trim from the front drops the
        // least relevant first.
        return (screenTerms.reversed() + userTerms).joined(separator: ", ")
    }

    /// How recently each Dictionary term was dictated (`TermUsage`).
    var termUsage: [String: TermUsage] {
        TermUsage.decode(userDefaultsStore.dictionary(forKey: PreferenceKey.dictionaryTermUsage))
    }

    /// Count the Dictionary terms that appear in a dictation's final text.
    func recordTermUsage(in text: String) {
        let terms = vocabularyTerms + replacementTargets
        guard !terms.isEmpty else { return }
        noteDictionaryTermsSeen()
        let usage = termUsage
        let updated = TermUsage.recording(text, terms: terms, in: usage)
        guard updated != usage else { return }
        userDefaultsStore.set(TermUsage.encode(updated), forKey: PreferenceKey.dictionaryTermUsage)
    }

    /// When VocaMac first saw each Dictionary term listed (`TermUsage.noting`).
    var dictionaryTermFirstSeen: [String: Date] {
        TermUsage.decodeDates(userDefaultsStore.dictionary(forKey: PreferenceKey.dictionaryTermFirstSeen))
    }

    /// Start the clock for terms not seen before, and forget removed ones.
    func noteDictionaryTermsSeen(now: Date = Date()) {
        let firstSeen = dictionaryTermFirstSeen
        let updated = TermUsage.noting(vocabularyTerms + replacementTargets, in: firstSeen, now: now)
        guard updated != firstSeen else { return }
        userDefaultsStore.set(TermUsage.encodeDates(updated), forKey: PreferenceKey.dictionaryTermFirstSeen)
    }

    /// Enough for the 100 terms Apple Speech and Parakeet take.
    static let recognitionPromptCharacterBudget = 2_000
    static let maximumRecognitionContextTerms = 100

    func loadDictionary() {
        wordReplacements = loadJSON([WordReplacement].self, forKey: PreferenceKey.wordReplacements) ?? []
        personalFillers = loadJSON([String].self, forKey: PreferenceKey.personalFillers) ?? []
        learnedLowercaseApps = loadJSON([LearnedLowercaseApp].self, forKey: PreferenceKey.learnedLowercaseApps) ?? []
        dictionarySuggestions = loadJSON([CorrectionSuggestion].self, forKey: PreferenceKey.dictionarySuggestions) ?? []
        dismissedSuggestionKeys = Set(
            userDefaultsStore.stringArray(forKey: PreferenceKey.dismissedDictionarySuggestions) ?? []
        )
        noteDictionaryTermsSeen()
    }

    private func saveSuggestions() {
        saveJSON(dictionarySuggestions, forKey: PreferenceKey.dictionarySuggestions)
        userDefaultsStore.set(Array(dismissedSuggestionKeys), forKey: PreferenceKey.dismissedDictionarySuggestions)
    }

    fileprivate func loadJSON<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = userDefaultsStore.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            VocaLogger.error(.dictionary, "Could not read \(key): \(error)")
            return nil
        }
    }

    func savePersonalFillers() {
        saveJSON(personalFillers, forKey: PreferenceKey.personalFillers)
    }

    func saveLearnedLowercaseApps() {
        saveJSON(learnedLowercaseApps, forKey: PreferenceKey.learnedLowercaseApps)
    }

    func saveJSON<T: Encodable>(_ value: T, forKey key: String) {
        do {
            userDefaultsStore.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            VocaLogger.error(.dictionary, "Could not save \(key): \(error)")
        }
    }
}
