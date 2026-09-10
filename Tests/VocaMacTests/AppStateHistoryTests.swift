// AppStateHistoryTests.swift
// VocaMac
//
// History, paste-last, cancel, retry, hands-free, and dictionary wiring.

import XCTest
@testable import VocaMac

@MainActor
final class AppStateHistoryTests: XCTestCase {

    private let speech = [Float](repeating: 0.2, count: 8_000)

    private func dictate(_ appState: AppState, _ mocks: TestMocks, text: String) async {
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: text, duration: 0.1, detectedLanguage: "en", audioLengthSeconds: 0.5, modelUsed: .tiny
        )
        mocks.audioEngine.stopRecordingResult = speech
        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()
    }

    func testDictationIsRecordedInHistory() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.frontmostAppResolver.frontmostApp = RunningAppSnapshot(displayName: "Notes", bundleIdentifier: "com.apple.Notes")

        await dictate(appState, mocks, text: "hello there")

        let entry = appState.historyStore.entries.first
        XCTAssertEqual(entry?.status, .completed)
        XCTAssertEqual(entry?.rawText, "hello there")
        XCTAssertEqual(entry?.finalText, mocks.textInjector.lastInjectedText)
        XCTAssertEqual(entry?.appName, "Notes")
    }

    func testHistoryDefaultsToTextWithoutSuccessfulAudio() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocaMacHistoryDefaults-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (appState, mocks) = AppState.makeTestState(historyStore: DictationHistoryStore(directory: directory))

        XCTAssertTrue(appState.historyEnabled)
        XCTAssertFalse(appState.historyKeepsAudio)

        await dictate(appState, mocks, text: "keep the words")

        let entry = try XCTUnwrap(appState.historyStore.entries.first)
        XCTAssertEqual(entry.finalText, mocks.textInjector.lastInjectedText)
        XCTAssertFalse(entry.hasAudio)
    }

    func testHistoryCanBeTurnedOff() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.historyEnabled = false
        await dictate(appState, mocks, text: "private words")
        XCTAssertTrue(appState.historyStore.entries.isEmpty)
    }

    func testFailedTranscriptionIsKeptAsFailed() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.whisperService.shouldThrow = true
        mocks.audioEngine.stopRecordingResult = speech
        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(appState.historyStore.entries.first?.status, .failed)
        XCTAssertEqual(appState.appStatus, .error)
    }

    func testPasteLastDictationReinjectsTheLastText() async {
        let (appState, mocks) = AppState.makeTestState()
        await dictate(appState, mocks, text: "ship it")
        let delivered = mocks.textInjector.lastInjectedText

        appState.pasteLastDictation()

        XCTAssertEqual(mocks.textInjector.injectCallCount, 2)
        XCTAssertEqual(mocks.textInjector.lastInjectedText, delivered)
    }

    func testPasteLastWithNothingDictatedShowsAMessage() {
        let (appState, mocks) = AppState.makeTestState()
        appState.pasteLastDictation()
        XCTAssertEqual(mocks.textInjector.injectCallCount, 0)
        XCTAssertEqual(appState.appStatus, .error)
    }

    func testShortcutActionsRouteToHandlers() async {
        let (appState, mocks) = AppState.makeTestState()
        await dictate(appState, mocks, text: "again please")
        await appState.handleShortcut(.pasteLastDictation)
        XCTAssertEqual(mocks.textInjector.injectCallCount, 2)
    }

    func testShortcutsAndMouseAreSyncedToTheListener() {
        let (appState, mocks) = AppState.makeTestState()
        XCTAssertEqual(mocks.hotKeyManager.shortcuts[.pasteLastDictation], .defaultPasteLast)
        XCTAssertNil(mocks.hotKeyManager.shortcuts[.handsFreeToggle])

        appState.setShortcut(HotKeyCombo(keyCode: 49, modifiers: .option), for: .handsFreeToggle)
        appState.setShortcut(nil, for: .pasteLastDictation)
        appState.mouseTriggerButton = MouseTriggerButton.back.rawValue
        appState.syncShortcutConfiguration()

        XCTAssertEqual(mocks.hotKeyManager.shortcuts[.handsFreeToggle], HotKeyCombo(keyCode: 49, modifiers: .option))
        XCTAssertNil(mocks.hotKeyManager.shortcuts[.pasteLastDictation])
        XCTAssertEqual(mocks.hotKeyManager.mouseTriggerButton, 3)
    }

    func testEscapeIsArmedOnlyWhileRecording() async {
        let (appState, mocks) = AppState.makeTestState()
        XCTAssertFalse(mocks.hotKeyManager.isCancelKeyArmed)
        await appState.startRecording()
        XCTAssertTrue(mocks.hotKeyManager.isCancelKeyArmed)

        await appState.cancelDictation()
        XCTAssertFalse(appState.isRecording)
        XCTAssertEqual(appState.appStatus, .idle)
        XCTAssertFalse(mocks.hotKeyManager.isCancelKeyArmed)
        XCTAssertNil(mocks.whisperService.lastTranscribedAudioData, "Cancelled audio is never transcribed")
        XCTAssertTrue(appState.historyStore.entries.isEmpty)
    }

    func testEscapeStaysOffWhenDisabled() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.escapeCancelsDictation = false
        await appState.startRecording()
        XCTAssertFalse(mocks.hotKeyManager.isCancelKeyArmed)
        await appState.cancelRecording()
    }

    func testHandsFreeToggleStartsAndStops() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.audioEngine.stopRecordingResult = speech

        await appState.toggleHandsFreeDictation()
        XCTAssertTrue(appState.isRecording)

        await appState.toggleHandsFreeDictation()
        XCTAssertFalse(appState.isRecording)
        XCTAssertEqual(mocks.textInjector.injectCallCount, 1)
    }

    func testHandsFreeSessionStopsOnSilenceInPushToTalkMode() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.activationMode = .pushToTalk
        mocks.audioEngine.stopRecordingResult = speech
        await appState.toggleHandsFreeDictation()

        mocks.audioEngine.onSilenceDetected?()
        for _ in 0..<50 where appState.isRecording {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(appState.isRecording)
    }

    func testRetryTranscribesSavedAudioAgain() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocaMacRetry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationHistoryStore(directory: directory)
        let (appState, mocks) = AppState.makeTestState(historyStore: store)

        mocks.whisperService.shouldThrow = true
        mocks.audioEngine.stopRecordingResult = speech
        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()
        let failed = try XCTUnwrap(appState.recoverableHistoryEntry)

        mocks.whisperService.shouldThrow = false
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "second time lucky", duration: 0.1, detectedLanguage: "en", audioLengthSeconds: 0.5, modelUsed: .tiny
        )
        let text = await appState.retryHistoryEntry(failed.id)

        XCTAssertNotNil(text)
        XCTAssertEqual(mocks.whisperService.lastTranscribedAudioData?.count, speech.count)
        XCTAssertEqual(store.entry(id: failed.id)?.status, .completed)
        XCTAssertEqual(store.entry(id: failed.id)?.retryCount, 1)
        XCTAssertNil(appState.recoverableHistoryEntry)
    }

    func testDismissingRecoveryKeepsTheEntry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocaMacDismiss-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (appState, mocks) = AppState.makeTestState(historyStore: DictationHistoryStore(directory: directory))
        mocks.whisperService.shouldThrow = true
        mocks.audioEngine.stopRecordingResult = speech
        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()

        let entry = try XCTUnwrap(appState.recoverableHistoryEntry)
        appState.dismissRecovery(entry.id)
        XCTAssertNil(appState.recoverableHistoryEntry)
        XCTAssertNotNil(appState.historyStore.entry(id: entry.id))
    }

    // MARK: Dictionary

    func testReplacementsApplyToDictation() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.addWordReplacement(heard: "get hub", replacement: "GitHub")
        await dictate(appState, mocks, text: "push it to get hub")
        XCTAssertTrue(mocks.textInjector.lastInjectedText?.contains("GitHub") == true,
                      mocks.textInjector.lastInjectedText ?? "")
        XCTAssertEqual(appState.historyStore.entries.first?.rawText, "push it to get hub")
    }

    func testVocabularyAppliesForEveryEngine() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.addVocabularyTerm("VocaMac")
        await dictate(appState, mocks, text: "I use voca mac daily")
        XCTAssertTrue(mocks.textInjector.lastInjectedText?.contains("VocaMac") == true,
                      mocks.textInjector.lastInjectedText ?? "")
    }

    func testScreenContextSpellsIdentifiersInCodeApps() async {
        let reader = MockScreenContextReader()
        reader.text = "let userId = request.userId"
        let (appState, mocks) = AppState.makeTestState(screenContextReader: reader)
        appState.writingStyleDefault = .code
        await dictate(appState, mocks, text: "log the user id")
        XCTAssertEqual(reader.captureCallCount, 1)
        XCTAssertTrue(mocks.whisperService.lastVocabulary?.contains("userId") == true)
        XCTAssertTrue(mocks.textInjector.lastInjectedText?.contains("userId") == true,
                      mocks.textInjector.lastInjectedText ?? "")
    }

    func testWebsiteRuleOverridesBrowserAppRule() async {
        let reader = MockScreenContextReader()
        reader.documentURL = URL(string: "https://docs.example.com/editor")
        let (appState, mocks) = AppState.makeTestState(screenContextReader: reader)
        appState.useScreenContext = false
        appState.writingStyleDefault = .chat
        appState.websiteStyleBindings = [WebsiteStyleBinding(
            hostPattern: "docs.example.com", displayName: "Docs", style: .code
        )]

        await dictate(appState, mocks, text: "open config dot json")

        XCTAssertEqual(reader.documentURLCallCount, 1)
        XCTAssertEqual(mocks.textInjector.lastInjectedText, "open config.json")
        XCTAssertEqual(appState.activeWritingStyle.matchedAppName, "Docs")
    }

    func testScreenContextCanBeTurnedOff() async {
        let reader = MockScreenContextReader()
        let (appState, mocks) = AppState.makeTestState(screenContextReader: reader)
        appState.useScreenContext = false
        await dictate(appState, mocks, text: "anything")
        XCTAssertEqual(reader.captureCallCount, 0)
    }

    func testInjectedTextIsWatchedForCorrections() async {
        let observer = MockCorrectionObserver()
        let (appState, mocks) = AppState.makeTestState(correctionObserver: observer)
        await dictate(appState, mocks, text: "first")
        await appState.startRecording()
        XCTAssertGreaterThanOrEqual(observer.flushCallCount, 2, "Each new dictation flushes the last one")
        await appState.cancelRecording()
    }

    func testSuggestionsCanBeAcceptedOrDismissed() {
        let (appState, _) = AppState.makeTestState()
        appState._receiveCorrectionsForTesting([
            .init(heard: "Namratha", corrected: "Namrata"),
            .init(heard: "github", corrected: "GitHub"),
        ])
        XCTAssertEqual(appState.dictionarySuggestions.count, 2)

        let namrata = appState.dictionarySuggestions.first { $0.corrected == "Namrata" }!
        appState.acceptDictionarySuggestion(namrata)
        XCTAssertTrue(appState.vocabularyTerms.contains("Namrata"))
        XCTAssertEqual(appState.wordReplacements.first?.heard, "Namratha")

        let github = appState.dictionarySuggestions.first { $0.corrected == "GitHub" }!
        appState.dismissDictionarySuggestion(github)
        XCTAssertTrue(appState.dictionarySuggestions.isEmpty)

        // A dismissed fix isn't suggested again.
        appState._receiveCorrectionsForTesting([.init(heard: "github", corrected: "GitHub")])
        XCTAssertTrue(appState.dictionarySuggestions.isEmpty)
    }

    func testAutomaticLearningAddsWordsDirectly() {
        let (appState, _) = AppState.makeTestState()
        appState.learnCorrectionsMode = .automatic
        appState._receiveCorrectionsForTesting([.init(heard: "github", corrected: "GitHub")])
        XCTAssertTrue(appState.dictionarySuggestions.isEmpty)
        XCTAssertEqual(appState.vocabularyTerms, ["GitHub"])
        XCTAssertTrue(appState.wordReplacements.isEmpty, "A casing fix needs no replacement")
    }

    func testVocabularyTermsDeduplicateIgnoringCase() {
        let (appState, _) = AppState.makeTestState()
        appState.addVocabularyTerm("github")
        appState.addVocabularyTerm("GitHub")
        XCTAssertEqual(appState.vocabularyTerms, ["GitHub"])
        appState.removeVocabularyTerm("GitHub")
        XCTAssertTrue(appState.vocabularyTerms.isEmpty)
    }
}
