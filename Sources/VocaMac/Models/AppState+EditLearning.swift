// AppState+EditLearning.swift
// VocaMac
//
// What VocaMac learns from the user's edits to dictated text, beyond the
// Dictionary's spellings: the edited text for History, fillers they always
// delete, and apps where they start in lowercase. The rules for what counts
// live in `DictationEditLearning.swift`; this is the state around them.

import Foundation

extension AppState {

    // MARK: - Learning mode default

    /// Settle the learning mode's default once per install.
    ///
    /// The default became Add automatically. Someone who already uses the
    /// Dictionary (has words, replacements, or dismissed suggestions) and
    /// never chose a mode has been living with Suggest, so they keep it,
    /// stored so it no longer follows the default. Everyone else — new
    /// installs included — gets the new default. Runs once: a new install
    /// that later adds words stays on Add automatically.
    func settleLearnModeDefault(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: PreferenceKey.learnModeDefaultSettled) else { return }
        defaults.set(true, forKey: PreferenceKey.learnModeDefaultSettled)
        guard defaults.object(forKey: PreferenceKey.learnCorrectionsMode) == nil else { return }
        let usesDictionary = !vocabularyTerms.isEmpty || !wordReplacements.isEmpty
            || !(defaults.stringArray(forKey: PreferenceKey.dismissedDictionarySuggestions) ?? []).isEmpty
        if usesDictionary {
            learnCorrectionsMode = .suggest
            VocaLogger.info(.dictionary, "Kept Suggest words for an install that already uses the Dictionary")
        }
    }

    /// Whether a fix is a name or term worth adding unasked: it has a
    /// capital ("Priya", "GitHub") or a word the spell checker doesn't know
    /// ("kubectl"). A plain lowercase word is grammar, not spelling. A
    /// capital that only opens a sentence never gets here: the learner drops
    /// "Whether" → "Weather" there (`CorrectionLearner.isLikelyCorrection`).
    static func learnsWithoutAsking(_ corrected: String, isKnownWord: (String) -> Bool) -> Bool {
        if corrected.contains(where: \.isUppercase) { return true }
        return corrected.split(whereSeparator: { !$0.isLetter }).contains { !isKnownWord(String($0).lowercased()) }
    }

    /// A term short enough for the overlay's one line.
    static func shortened(_ text: String, limit: Int = 28) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    // MARK: - Edits

    /// Dictations whose capital the user lowercased in an app, or that a
    /// filler was deleted from, before VocaMac learns it.
    static let editsBeforeLearning = 3

    /// A dictation read back after the user had time to edit it.
    func receiveEdit(_ observation: DictationEditObservation) {
        guard learnCorrectionsMode != .off else { return }
        if let id = observation.historyID, let edited = observation.editedText {
            historyStore.recordEdit(id, editedText: edited)
        }
        guard observation.wasEdited, let edited = observation.editedText else { return }
        notePersonalFillerDeletions(dictated: observation.inserted, edited: edited)
        if let app = observation.app,
           LearnedCasing.lowercasedStart(
               dictated: observation.inserted, edited: edited, precedingCharacter: observation.precedingCharacter
           ) {
            noteLowercaseStart(in: app)
        }
    }

    // MARK: - Personal fillers

    private var personalFillerCounts: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: PreferenceKey.personalFillerCounts) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: PreferenceKey.personalFillerCounts) }
    }

    private var rejectedPersonalFillers: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: PreferenceKey.rejectedPersonalFillers) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: PreferenceKey.rejectedPersonalFillers) }
    }

    /// Count the fillers deleted from one dictation; one deleted in enough
    /// dictations is removed from then on.
    func notePersonalFillerDeletions(dictated: String, edited: String) {
        let terms = Set((vocabularyTerms + wordReplacements.map(\.replacement)).map { $0.lowercased() })
        let rejected = rejectedPersonalFillers
        let learned = Set(personalFillers)
        let deleted = PersonalFillers.deletions(dictated: dictated, edited: edited) {
            terms.contains($0) || rejected.contains($0) || learned.contains($0)
        }
        guard !deleted.isEmpty else { return }
        var counts = personalFillerCounts
        var newlyLearned: [String] = []
        for word in deleted {
            counts[word, default: 0] += 1
            if counts[word, default: 0] >= Self.editsBeforeLearning {
                counts[word] = nil
                newlyLearned.append(word)
            }
        }
        personalFillerCounts = counts
        guard !newlyLearned.isEmpty else { return }
        personalFillers += newlyLearned
        savePersonalFillers()
        VocaLogger.info(.dictionary, "Learned \(newlyLearned.count) filler(s) the user always deletes")
        let names = newlyLearned.map { "“\($0)”" }.joined(separator: " and ")
        cursorOverlay.showLearned(message: "Learned to leave out \(names)") { [weak self] in
            self?.forgetPersonalFillers(newlyLearned)
        }
    }

    /// Stop removing fillers and never learn them again.
    func forgetPersonalFillers(_ words: [String]) {
        personalFillers.removeAll { words.contains($0) }
        savePersonalFillers()
        rejectedPersonalFillers.formUnion(words)
    }

    /// Remove a learned filler from Settings, offering Undo.
    func removePersonalFillerWithUndo(_ word: String) {
        guard let index = personalFillers.firstIndex(of: word) else { return }
        forgetPersonalFillers([word])
        undoCenter.offer("VocaMac keeps “\(word)” again") { [weak self] in
            guard let self, !personalFillers.contains(word) else { return }
            personalFillers.insert(word, at: min(index, personalFillers.count))
            savePersonalFillers()
            rejectedPersonalFillers.remove(word)
        }
    }

    // MARK: - Lowercase starts

    /// Per app ID: lowercased starts seen so far, and when the last one was.
    private var lowercaseStartTallies: [String: (count: Int, lastSeen: TimeInterval)] {
        get {
            let stored = UserDefaults.standard.dictionary(forKey: PreferenceKey.lowercaseStartCounts) as? [String: [Double]] ?? [:]
            return stored.compactMapValues { $0.count == 2 ? (Int($0[0]), $0[1]) : nil }
        }
        set {
            UserDefaults.standard.set(
                newValue.mapValues { [Double($0.count), $0.lastSeen] }, forKey: PreferenceKey.lowercaseStartCounts
            )
        }
    }

    /// Apps whose lowercased starts are remembered until learned; past it,
    /// those seen longest ago are forgotten.
    static let maximumLowercaseStartTallies = 100

    private var rejectedLowercaseApps: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: PreferenceKey.rejectedLowercaseApps) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: PreferenceKey.rejectedLowercaseApps) }
    }

    /// Count one lowercased start in `app`; after enough, dictation there
    /// starts in lowercase.
    func noteLowercaseStart(in app: RunningAppSnapshot, now: Date = Date()) {
        let entry = LearnedLowercaseApp(snapshot: app)
        guard !learnedLowercaseApps.contains(where: { $0.matches(app) }),
              !rejectedLowercaseApps.contains(entry.id) else { return }
        var tallies = lowercaseStartTallies
        let count = (tallies[entry.id]?.count ?? 0) + 1
        let learned = count >= Self.editsBeforeLearning
        tallies[entry.id] = learned ? nil : (count, now.timeIntervalSince1970)
        // Bounded by recency: the apps whose last lowercased start is oldest
        // go first. The one just counted is the newest, so it stays.
        if tallies.count > Self.maximumLowercaseStartTallies {
            let kept = tallies.sorted { $0.value.lastSeen > $1.value.lastSeen }.prefix(Self.maximumLowercaseStartTallies)
            tallies = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        lowercaseStartTallies = tallies
        guard learned else { return }
        learnedLowercaseApps.append(entry)
        saveLearnedLowercaseApps()
        refreshActiveWritingStyle()
        VocaLogger.info(.appState, "Learned a lowercase start for an app")
        cursorOverlay.showLearned(message: "Learned to start in lowercase in \(Self.shortened(entry.displayName))") { [weak self] in
            self?.forgetLowercaseStart(entry)
        }
    }

    /// Capitalize again in an app, and don't learn otherwise for it.
    func forgetLowercaseStart(_ app: LearnedLowercaseApp) {
        learnedLowercaseApps.removeAll { $0.id == app.id }
        saveLearnedLowercaseApps()
        rejectedLowercaseApps.insert(app.id)
        refreshActiveWritingStyle()
    }

    /// Remove a learned lowercase start from Settings, offering Undo.
    func removeLearnedLowercaseAppWithUndo(_ app: LearnedLowercaseApp) {
        guard let index = learnedLowercaseApps.firstIndex(of: app) else { return }
        forgetLowercaseStart(app)
        undoCenter.offer("\(app.displayName) starts with a capital again") { [weak self] in
            guard let self, !learnedLowercaseApps.contains(where: { $0.id == app.id }) else { return }
            learnedLowercaseApps.insert(app, at: min(index, learnedLowercaseApps.count))
            saveLearnedLowercaseApps()
            rejectedLowercaseApps.remove(app.id)
            refreshActiveWritingStyle()
        }
    }

    /// `resolved` starting in lowercase when the user taught that for
    /// `target`. Not with styles switched off, and not for a coding agent's
    /// prose, which is formatted as Plain text.
    func applyingLearnedCasing(_ resolved: ResolvedWritingStyle, for target: RunningAppSnapshot?) -> ResolvedWritingStyle {
        guard writingStyleEnabled, !resolved.codingAgent, let target,
              learnedLowercaseApps.contains(where: { $0.matches(target) }) else { return resolved }
        return resolved.startingInLowercase()
    }
}
