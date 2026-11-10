// DictionaryTeachingTests.swift
// VocaMac Tests
//
// Teaching a word by saying it (`WordTeaching` and the AppState take flow),
// imports from other dictation apps, and Dictionary entries not said in a
// while.

import XCTest
@testable import VocaMac

// MARK: - Imports from other apps

final class OtherAppDictionaryImportTests: XCTestCase {

    /// VoiceInk's dictionary file, written from its `DictionaryArchive`
    /// (github.com/Beingpax/VoiceInk, schema 1): ISO 8601 dates, an array of
    /// spoken forms per replacement, `sortedKeys` pretty printing.
    private let voiceInkDictionary = """
    {
      "appVersion" : "1.73",
      "exportedAt" : "2026-10-01T09:30:00Z",
      "format" : "voiceink.dictionary",
      "replacements" : [
        {
          "createdAt" : "2026-09-20T12:00:00Z",
          "replacement" : "GitHub",
          "sources" : [
            "get hub",
            "git hub"
          ]
        },
        {
          "replacement" : "Kubernetes",
          "sources" : [
            "cooper netties"
          ]
        }
      ],
      "schemaVersion" : 1,
      "vocabulary" : [
        {
          "createdAt" : "2026-09-18T08:00:00Z",
          "term" : "VocaMac"
        },
        {
          "term" : "Priya Raman"
        }
      ]
    }
    """

    /// VoiceInk's settings backup (`BackupFile`): the dictionary is
    /// `vocabularyWords` and `wordReplacements` beside unrelated settings.
    private let voiceInkBackup = """
    {
      "version" : "1.73",
      "customPrompts" : [],
      "modeConfigs" : [],
      "vocabularyWords" : [ { "word" : "Anthropic" }, { "word" : "SwiftUI" } ],
      "wordReplacements" : { "get hub, git hub" : "GitHub", "btw" : "by the way" },
      "customEmojis" : [ "🚀" ]
    }
    """

    func testVoiceInkDictionaryFileIsRecognised() throws {
        let contents = try DictionaryTransfer.parse(voiceInkDictionary, format: .json)
        XCTAssertEqual(contents.source, .voiceInk)
        XCTAssertEqual(contents.words, ["VocaMac", "Priya Raman"])
        XCTAssertEqual(contents.replacements, [
            DictionaryTransferReplacement(heard: "get hub, git hub", replacement: "GitHub"),
            DictionaryTransferReplacement(heard: "cooper netties", replacement: "Kubernetes"),
        ], "spoken forms join like a VocaMac replacement, and replacement text is never taken for a word")
    }

    func testVoiceInkSettingsBackupIsRecognised() throws {
        let contents = try DictionaryTransfer.parse(voiceInkBackup, format: .json)
        XCTAssertEqual(contents.source, .voiceInk)
        XCTAssertEqual(contents.words, ["Anthropic", "SwiftUI"])
        XCTAssertEqual(Set(contents.replacements.map(\.replacement)), ["GitHub", "by the way"])
        XCTAssertEqual(
            contents.replacements.first { $0.replacement == "GitHub" }?.heard, "get hub, git hub"
        )
    }

    func testVoiceInkReplacementWithNoSpokenFormIsSkipped() throws {
        let file = """
        {"format": "voiceink.dictionary", "schemaVersion": 1, "vocabulary": [{"term": "Zed"}],
         "replacements": [{"sources": [], "replacement": "Nothing"}, {"replacement": "Also nothing"}]}
        """
        let contents = try DictionaryTransfer.parse(file, format: .json)
        XCTAssertEqual(contents.words, ["Zed"])
        XCTAssertTrue(contents.replacements.isEmpty)
    }

    func testPlainJSONIsNotTakenForVoiceInk() throws {
        let contents = try DictionaryTransfer.parse(#"{"words": ["Kubernetes"]}"#, format: .json)
        XCTAssertNil(contents.source)
        XCTAssertEqual(contents.words, ["Kubernetes"])
    }

    /// Wispr Flow's documented bulk-import CSV (one column of words, or
    /// misspelling and correction) already reads as a VocaMac CSV.
    func testWisprFlowImportShapedCSVReads() throws {
        let csv = "Anthropic\n\"get hub\",GitHub\n"
        let contents = try DictionaryTransfer.parse(csv, format: .csv)
        XCTAssertEqual(contents.words, ["Anthropic"])
        XCTAssertEqual(contents.replacements, [DictionaryTransferReplacement(heard: "get hub", replacement: "GitHub")])
    }

    func testConfirmationNamesTheSourceApp() throws {
        let contents = try DictionaryTransfer.parse(voiceInkDictionary, format: .json)
        let plan = DictionaryTransfer.plan(
            importing: contents, existingWords: ["VocaMac"], existingReplacements: []
        )
        XCTAssertEqual(plan.source, .voiceInk)
        let summary = CalmDictionaryPendingImport(plan: plan).summary
        XCTAssertTrue(summary.hasPrefix("From VoiceInk: "), summary)
        XCTAssertTrue(summary.contains("1 new word"), summary)
        XCTAssertTrue(summary.contains("2 new replacements"), summary)
    }
}

// MARK: - Teaching a word

final class WordTeachingTests: XCTestCase {

    private let knownWords: Set<String> = ["cloud", "pie", "torch", "the", "a", "is", "this", "my", "word", "and", "get", "hub"]

    private func isKnown(_ word: String) -> Bool { knownWords.contains(word.lowercased()) }

    func testSpokenFormDropsPunctuationAndCase() {
        XCTAssertEqual(WordTeaching.spokenForm(of: " Cooper Netties. "), "cooper netties")
        XCTAssertEqual(WordTeaching.spokenForm(of: "“Pie-torch!”"), "pie-torch")
        XCTAssertEqual(WordTeaching.spokenForm(of: "Don’t, stop"), "don’t stop")
        XCTAssertEqual(WordTeaching.spokenForm(of: " ... "), "")
    }

    func testReviewSortsWhatWasHeard() {
        let heard = WordTeaching.review(
            term: "Kubernetes",
            transcripts: ["Cooper netties.", "Kuber netes", "cooper netties", "", "cloud"],
            replacements: [],
            isKnownWord: isKnown
        )
        XCTAssertEqual(heard.map(\.form), ["cooper netties", "kuber netes", "cloud"])
        XCTAssertEqual(heard[0].verdict, .learnable)
        XCTAssertEqual(heard[0].count, 2, "the same mishearing twice is one row")
        XCTAssertEqual(heard[1].verdict, .matches, "the term's own letters are already joined by the Dictionary")
        XCTAssertEqual(heard[2].verdict, .ordinaryWord, "one everyday word never becomes a replacement")
    }

    func testPhraseOfRealWordsIsLearnableLikeACorrection() {
        // Same rule as a learned correction: a phrase is rarely said for itself.
        let verdict = WordTeaching.verdict(for: "pie torch", term: "PyTorch", replacements: [], isKnownWord: isKnown)
        XCTAssertEqual(verdict, .learnable)
    }

    func testExistingReplacementsAreRespected() {
        let replacements = [
            WordReplacement(heard: "get hub", replacement: "GitHub"),
            WordReplacement(heard: "cooper netties", replacement: "Kubernetes"),
        ]
        XCTAssertEqual(
            WordTeaching.verdict(for: "cooper netties", term: "Kubernetes", replacements: replacements, isKnownWord: isKnown),
            .alreadyLearned
        )
        XCTAssertEqual(
            WordTeaching.verdict(for: "get hub", term: "GitBook", replacements: replacements, isKnownWord: isKnown),
            .taken(by: "GitHub"),
            "a spoken form another replacement answers to can't be given to this word"
        )
    }

    func testASentenceIsNotTheWord() {
        let verdict = WordTeaching.verdict(
            for: "is this thing on can you hear me", term: "Kubernetes", replacements: [], isKnownWord: isKnown
        )
        XCTAssertEqual(verdict, .unlikely)
    }

    @MainActor
    func testTakeIsDecodedWithoutHintsAndSaved() async {
        let (state, mocks) = AppState.makeTestState()
        defer {
            state.setVocabularyTerms([])
            state.wordReplacements = []
        }
        state.setVocabularyTerms(["Kubernetes"])
        state.wordReplacements = [WordReplacement(heard: "kube", replacement: "Kubernetes")]
        mocks.audioEngine.stopRecordingResult = [Float](repeating: 0.1, count: 16_000)
        mocks.transcriber.mockTranscriptionResult = VocaTranscription(
            text: "Cooper netties.", duration: 0.2, detectedLanguage: "en", audioLengthSeconds: 1, modelUsed: .tiny
        )

        XCTAssertTrue(state.canTeachWord)
        let started = await state.startTeachingTake()
        XCTAssertTrue(started)
        XCTAssertTrue(state.isTeachingWord)
        XCTAssertFalse(state.canTeachWord, "one take at a time")
        let text = await state.finishTeachingTake()
        XCTAssertEqual(text, "Cooper netties.")
        XCTAssertEqual(mocks.transcriber.lastVocabulary, "", "takes are decoded without hints")
        XCTAssertFalse(state.isTeachingWord)

        state.teachWord("Kubernetes", heardForms: ["cooper netties"])
        XCTAssertEqual(state.vocabularyTerms, ["Kubernetes"], "the word isn't added twice")
        XCTAssertEqual(state.wordReplacements.count, 1, "the form joins the word's existing replacement")
        XCTAssertEqual(state.wordReplacements.first?.heardForms, ["kube", "cooper netties"])
    }

    @MainActor
    func testTooShortTakeIsNothingHeard() async {
        let (state, mocks) = AppState.makeTestState()
        mocks.audioEngine.stopRecordingResult = [Float](repeating: 0, count: 800)
        let started = await state.startTeachingTake()
        XCTAssertTrue(started)
        let text = await state.finishTeachingTake()
        XCTAssertEqual(text, "")
        XCTAssertNil(mocks.transcriber.lastTranscribedAudioData, "a click is not decoded")
    }

    @MainActor
    func testCancelledTakeFreesTheMicrophone() async {
        let (state, _) = AppState.makeTestState()
        let started = await state.startTeachingTake()
        XCTAssertTrue(started)
        await state.cancelTeachingTake()
        XCTAssertFalse(state.isTeachingWord)
        XCTAssertTrue(state.canTeachWord)
    }

    /// The timer that ends a take must not cancel the decode it starts.
    @MainActor
    func testTakeEndedByTheTimerIsStillDecoded() async {
        let (state, mocks) = AppState.makeTestState()
        defer { state.wordReplacements = [] }
        mocks.audioEngine.stopRecordingResult = [Float](repeating: 0.1, count: 16_000)
        // A cancelled task throws out of this sleep, as the router rejects it.
        mocks.transcriber.transcribeDelayNanoseconds = 20_000_000
        mocks.transcriber.mockTranscriptionResult = VocaTranscription(
            text: "Cooper netties", duration: 0.2, detectedLanguage: "en", audioLengthSeconds: 1, modelUsed: .tiny
        )
        let session = WordTeachingSession(term: "Kubernetes", appState: state, takeSeconds: 0.02)
        await session.startTake()
        XCTAssertEqual(session.phase, .listening)

        let deadline = Date().addingTimeInterval(5)
        while session.takes == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(session.transcripts, ["Cooper netties"])
        XCTAssertNil(session.notice)
        XCTAssertEqual(session.chosenForms, ["cooper netties"], "a new mishearing starts chosen")
        XCTAssertEqual(session.phase, .ready)
    }

    /// Cancel while the microphone is still opening waits for the start,
    /// then closes it: it never stays open after the dialog has gone.
    @MainActor
    func testCancelWhileTheMicrophoneOpensClosesIt() async {
        let (state, mocks) = AppState.makeTestState()
        let gate = StepGate()
        mocks.audioEngine.startRecordingGate = gate
        let session = WordTeachingSession(term: "Kubernetes", appState: state)

        let start = Task { await session.startTake() }
        let reached = await gate.waitUntilReached()
        XCTAssertTrue(reached)
        let cancel = Task { await session.cancel() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(state.isTeachingWord, "the stop waits for the start")
        gate.open()
        await cancel.value
        await start.value

        XCTAssertFalse(mocks.audioEngine.isCurrentlyRecording, "the microphone opened, then was closed")
        XCTAssertFalse(state.isTeachingWord)
        XCTAssertEqual(session.phase, .ready)
        XCTAssertNil(session.notice, "a cancelled start isn't reported as a busy microphone")
        XCTAssertTrue(state.canTeachWord)
    }

    @MainActor
    func testMicrophoneThatWontOpenEndsTheTake() async {
        let (state, mocks) = AppState.makeTestState()
        mocks.audioEngine.startRecordingResult = false
        let started = await state.startTeachingTake()
        XCTAssertFalse(started)
        XCTAssertFalse(state.isTeachingWord)
    }
}

// MARK: - Not said in a while

final class UnusedDictionaryTermTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    func testNotingStartsTheClockOnceAndForgetsRemovedTerms() {
        let first = TermUsage.noting(["Kubernetes", "Priya"], in: [:], now: daysAgo(90))
        XCTAssertEqual(first, ["kubernetes": daysAgo(90), "priya": daysAgo(90)])
        let later = TermUsage.noting(["kubernetes", "VocaMac"], in: first, now: now)
        XCTAssertEqual(later, ["kubernetes": daysAgo(90), "vocamac": now],
                       "a term keeps its first date; a removed one is forgotten")
    }

    func testUnusedNeedsSixtyDaysWithoutUse() {
        let usage = [
            "kubernetes": TermUsage(count: 4, lastUsed: daysAgo(10)),
            "pytorch": TermUsage(count: 1, lastUsed: daysAgo(75)),
        ]
        let firstSeen = [
            "kubernetes": daysAgo(200), "pytorch": daysAgo(200),
            "priya": daysAgo(61), "vocamac": daysAgo(5),
        ]
        let unused = TermUsage.unused(
            ["Kubernetes", "PyTorch", "Priya", "VocaMac", "Unseen"], usage: usage, firstSeen: firstSeen, now: now
        )
        XCTAssertEqual(unused, ["PyTorch", "Priya"],
                       "used lately or listed lately stays; a term with no record is never called unused")
    }

    func testWordAddedAgainCountsFromItsReturn() {
        // Last said 90 days ago, removed, then added again five days ago.
        let unused = TermUsage.unused(
            ["Kubernetes"],
            usage: ["kubernetes": TermUsage(count: 3, lastUsed: daysAgo(90))],
            firstSeen: ["kubernetes": daysAgo(5)],
            now: now
        )
        XCTAssertEqual(unused, [])
    }

    func testListedTermsKeepTheirUsageRecords() {
        // More records than the cap: unlisted ones go, listed ones stay.
        var usage: [String: TermUsage] = [:]
        for index in 0..<TermUsage.maximumEntries {
            usage["old\(index)"] = TermUsage(count: 1, lastUsed: daysAgo(Double(400 - index % 300)))
        }
        usage["kubernetes"] = TermUsage(count: 1, lastUsed: daysAgo(500))
        let listed = ["Kubernetes"] + (0..<10).map { "old\($0)" }
        let updated = TermUsage.recording("new term here", terms: listed + ["new"], in: usage, now: now)
        XCTAssertEqual(updated.count, TermUsage.maximumEntries)
        XCTAssertNotNil(updated["kubernetes"], "a listed term's record is never the one dropped")
        XCTAssertNotNil(updated["new"])
        for index in 0..<10 { XCTAssertNotNil(updated["old\(index)"]) }
    }

    @MainActor
    func testRemovingAndAddingAWordRestartsItsClock() {
        let (state, _) = AppState.makeTestState()
        defer {
            state.setVocabularyTerms([])
            TestDefaults.store.removeObject(forKey: PreferenceKey.dictionaryTermFirstSeen)
        }
        state.setVocabularyTerms(["Kubernetes"])
        TestDefaults.store.set(
            TermUsage.encodeDates(["kubernetes": Date(timeIntervalSinceNow: -200 * 86_400)]),
            forKey: PreferenceKey.dictionaryTermFirstSeen
        )
        state.setVocabularyTerms([])
        XCTAssertNil(state.dictionaryTermFirstSeen["kubernetes"], "a removed word is forgotten at once")
        state.addVocabularyTerm("Kubernetes")
        let seen = state.dictionaryTermFirstSeen["kubernetes"]
        XCTAssertNotNil(seen)
        XCTAssertLessThan(abs(seen?.timeIntervalSinceNow ?? -1_000), 60)
    }

    func testUnusedItemsCoverWordsAndReplacements() {
        let replacements = [
            WordReplacement(heard: "get hub", replacement: "GitHub"),
            WordReplacement(heard: "btw", replacement: "by the way"),
        ]
        let items = DictionaryEditing.unusedItems(
            terms: ["Kubernetes", "Priya"], replacements: replacements,
            usage: ["by the way": TermUsage(count: 3, lastUsed: daysAgo(2))],
            firstSeen: ["kubernetes": daysAgo(100), "priya": daysAgo(3), "github": daysAgo(100), "by the way": daysAgo(100)],
            now: now
        )
        XCTAssertEqual(items, [.word("Kubernetes"), .replacement(replacements[0])])
    }

    @MainActor
    func testRemovingUnusedEntriesCanBeUndone() {
        let (state, _) = AppState.makeTestState()
        defer {
            state.setVocabularyTerms([])
            state.wordReplacements = []
        }
        let replacement = WordReplacement(heard: "get hub", replacement: "GitHub")
        state.setVocabularyTerms(["Kubernetes", "Priya", "VocaMac"])
        state.wordReplacements = [replacement]

        state.removeDictionaryItems([.word("Priya"), .replacement(replacement)])
        XCTAssertEqual(state.vocabularyTerms, ["Kubernetes", "VocaMac"])
        XCTAssertTrue(state.wordReplacements.isEmpty)

        state.addVocabularyTerm("Anthropic")
        state.undoCenter.undo()
        XCTAssertEqual(state.vocabularyTerms, ["Kubernetes", "Priya", "VocaMac", "Anthropic"],
                       "removed words go back in place; one added since stays")
        XCTAssertEqual(state.wordReplacements, [replacement])
    }

    @MainActor
    func testDictationsStartTheClockForNewTerms() {
        let (state, _) = AppState.makeTestState()
        defer {
            state.setVocabularyTerms([])
            TestDefaults.store.removeObject(forKey: PreferenceKey.dictionaryTermFirstSeen)
        }
        state.setVocabularyTerms(["Kubernetes"])
        state.recordTermUsage(in: "nothing relevant")
        XCTAssertNotNil(state.dictionaryTermFirstSeen["kubernetes"])
    }
}
