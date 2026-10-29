// DictationModeTests.swift
// VocaMac
//
// Modes: the spoken prefix, storage, the profile a mode produces, and how a
// mode's shortcut and a spoken name drive a dictation.

import XCTest
@testable import VocaMac

final class ModePrefixTests: XCTestCase {

    private let formal = DictationMode(name: "Formal", style: .email, intent: .professional)
    private let code = DictationMode(name: "Code", style: .code)
    private let formalEmail = DictationMode(name: "Formal email", style: .email)

    func testNameWithAPauseMarkSwitches() {
        for transcript in ["Formal, dear team, the report is late.", "Formal: dear team", "Formal. Dear team", "formal — dear team"] {
            let match = ModePrefix.match(transcript, modes: [formal, code])
            XCTAssertEqual(match?.mode, formal, transcript)
        }
    }

    func testRemainderLosesTheNameAndKeepsTheSentenceCapital() {
        XCTAssertEqual(ModePrefix.match("Formal, dear team, the report is late.", modes: [formal])?.remainder,
                       "Dear team, the report is late.")
        // A lower-case transcript stays lower case.
        XCTAssertEqual(ModePrefix.match("formal, dear team", modes: [formal])?.remainder, "dear team")
    }

    func testTheWordModeSetsTheNameOffToo() {
        XCTAssertEqual(ModePrefix.match("Code mode user id equals five", modes: [code])?.remainder, "User id equals five")
        XCTAssertEqual(ModePrefix.match("code mode, user id", modes: [code])?.remainder, "user id")
    }

    func testANameStartingASentenceIsNotAPrefix() {
        XCTAssertNil(ModePrefix.match("Formal dress is required tonight.", modes: [formal]))
        XCTAssertNil(ModePrefix.match("Code reviews take time.", modes: [code]))
    }

    func testANameOnItsOwnIsNotAPrefix() {
        XCTAssertNil(ModePrefix.match("Formal.", modes: [formal]))
        XCTAssertNil(ModePrefix.match("  formal,  ", modes: [formal]))
        XCTAssertNil(ModePrefix.match("Code mode", modes: [code]))
    }

    func testOtherWordsAndHyphenatedWordsDontMatch() {
        XCTAssertNil(ModePrefix.match("Formally, I object.", modes: [formal]))
        XCTAssertNil(ModePrefix.match("Formal-wear, please.", modes: [formal]))
        XCTAssertNil(ModePrefix.match("Hello, formal, world", modes: [formal]))
    }

    func testTheLongestNameWins() {
        let match = ModePrefix.match("Formal email, hi Sam", modes: [formal, formalEmail])
        XCTAssertEqual(match?.mode, formalEmail)
        XCTAssertEqual(match?.remainder, "Hi Sam")
    }

    func testHyphenatedNamesMatchTheSameSpelling() {
        let email = DictationMode(name: "E-mail", style: .email)
        XCTAssertEqual(ModePrefix.match("E-mail, hello Sam", modes: [email])?.remainder, "Hello Sam")
        XCTAssertNil(ModePrefix.match("E mail, hello", modes: [email]), "Split the way the name is written")
        XCTAssertNil(DictationModeStore.nameProblem("one two three-four", id: UUID(), in: []), "Three words as heard")
    }

    func testCaseAndAccentsAreIgnored() {
        let resume = DictationMode(name: "Résumé", style: .notes)
        XCTAssertEqual(ModePrefix.match("RESUME: worked at Acme", modes: [resume])?.mode, resume)
    }

    func testModesThatDontListenAreSkipped() {
        var quiet = formal
        quiet.listensForName = false
        XCTAssertNil(ModePrefix.match("Formal, dear team", modes: [quiet]))
    }

    func testNormalization() {
        XCTAssertEqual(ModePrefix.normalized("  Formal   E-mail! "), "formal e mail")
        XCTAssertEqual(ModePrefix.normalized(""), "")
    }
}

final class DictationModeStoreTests: XCTestCase {

    func testRoundTrip() {
        let modes = [
            DictationMode(name: "Code", style: .code, shortcut: "8:4096"),
            DictationMode(
                name: "Deutsch", style: .email, intent: .professional, cleanup: .inherit,
                cleanupLevel: .light, cleanupPrompt: "Keep it short.", language: "de", listensForName: false
            ),
        ]
        XCTAssertEqual(DictationModeStore.decode(DictationModeStore.encode(modes)), modes)
    }

    func testMissingFieldsGetDefaults() throws {
        let id = UUID()
        let json = #"[{"id":"\#(id.uuidString)","name":"Notes"}]"#
        let mode = try XCTUnwrap(DictationModeStore.decode(json).first)
        XCTAssertEqual(mode.id, id)
        XCTAssertEqual(mode.style, .plain)
        XCTAssertEqual(mode.intent, .preserve)
        XCTAssertEqual(mode.cleanup, .inherit)
        XCTAssertEqual(mode.shortcut, "")
        XCTAssertTrue(mode.listensForName)
    }

    func testGarbageDecodesToNothing() {
        XCTAssertEqual(DictationModeStore.decode("not json"), [])
        XCTAssertEqual(DictationModeStore.decode(""), [])
    }

    func testNameProblems() {
        let existing = [DictationMode(name: "Formal")]
        XCTAssertNotNil(DictationModeStore.nameProblem("  ", id: UUID(), in: existing))
        XCTAssertNotNil(DictationModeStore.nameProblem("formal!", id: UUID(), in: existing), "Heard the same")
        XCTAssertNil(DictationModeStore.nameProblem("Formal", id: existing[0].id, in: existing), "Its own name")
        XCTAssertNotNil(DictationModeStore.nameProblem("one two three four", id: UUID(), in: []))
        XCTAssertNil(DictationModeStore.nameProblem("Formal email", id: UUID(), in: existing))
    }

    func testProfile() {
        let mode = DictationMode(name: "Mail", style: .email, intent: .casual, cleanupLevel: .high, cleanupPrompt: "  ")
        let profile = mode.profile
        XCTAssertEqual(profile.format, .email)
        XCTAssertEqual(profile.rules, WritingStyle.email.defaultRules)
        XCTAssertEqual(profile.intent, .casual)
        XCTAssertEqual(profile.cleanupLevel, .high)
        XCTAssertNil(profile.cleanupPrompt, "A blank prompt keeps Smart Cleanup's")
    }

    func testLanguageOverride() {
        XCTAssertNil(DictationMode(name: "A").languageOverride)
        XCTAssertNil(DictationMode(name: "A", language: "auto").languageOverride)
        XCTAssertNil(DictationMode(name: "A", language: " ").languageOverride)
        XCTAssertEqual(DictationMode(name: "A", language: "de").languageOverride, "de")
    }
}

@MainActor
final class DictationModeFlowTests: XCTestCase {

    private let speech = [Float](repeating: 0.2, count: 8_000)

    private func prepare(_ mocks: TestMocks, text: String) {
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: text, duration: 0.1, detectedLanguage: "en", audioLengthSeconds: 0.5, modelUsed: .tiny
        )
        mocks.audioEngine.stopRecordingResult = speech
    }

    func testSpokenNameUsesTheModeAndDropsTheName() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.dictationModes = [DictationMode(name: "Exact", cleanup: .raw)]
        prepare(mocks, text: "Exact, um so this stays as said")

        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.textInjector.lastInjectedText, "Um so this stays as said")
        let entry = appState.historyStore.entries.first
        XCTAssertEqual(entry?.rawText, "Exact, um so this stays as said", "History keeps what was heard")
        XCTAssertTrue(entry?.summary?.hasPrefix("Exact mode") == true, entry?.summary ?? "")
    }

    func testWithoutAPrefixTheAppStyleApplies() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.dictationModes = [DictationMode(name: "Exact", cleanup: .raw)]
        prepare(mocks, text: "Exactly what I wanted")

        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()

        XCTAssertTrue(mocks.textInjector.lastInjectedText?.hasPrefix("Exactly what I wanted") == true)
        XCTAssertFalse(appState.historyStore.entries.first?.summary?.contains("mode") == true)
    }

    func testModeShortcutHeldStartsAndStopsInThatMode() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.commandModeHoldThreshold = 0
        let mode = DictationMode(name: "Exact", cleanup: .raw, language: "de", shortcut: "14:\(HotKeyModifiers([.control, .option]).rawValue)")
        appState.dictationModes = [mode]
        prepare(mocks, text: "Exact, but no prefix is needed here")

        await appState.handleShortcut(.dictationMode(mode.id))
        XCTAssertTrue(appState.isRecording)
        XCTAssertEqual(mocks.cursorOverlay.modeName, "Exact")
        XCTAssertEqual(mocks.cursorOverlay.stopHint, .hold(key: "⌃⌥E"))

        await appState.handleShortcutReleased(.dictationMode(mode.id))
        XCTAssertFalse(appState.isRecording)
        // The shortcut chose the mode, so the words are kept as said,
        // including a leading word that matches its name.
        XCTAssertEqual(mocks.textInjector.lastInjectedText, "Exact, but no prefix is needed here")
        XCTAssertEqual(mocks.whisperService.lastLanguage, "de", "The mode's language is used")
        XCTAssertTrue(appState.historyStore.entries.first?.summary?.hasPrefix("Exact mode") == true)
    }

    func testModeShortcutQuickPressKeepsRecordingUntilPressedAgain() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.commandModeHoldThreshold = 60
        let mode = DictationMode(name: "Exact", cleanup: .raw, shortcut: "14:\(HotKeyModifiers([.control, .option]).rawValue)")
        appState.dictationModes = [mode]
        prepare(mocks, text: "hands free in a mode")

        await appState.handleShortcut(.dictationMode(mode.id))
        await appState.handleShortcutReleased(.dictationMode(mode.id))
        XCTAssertTrue(appState.isRecording, "A quick press keeps recording")
        XCTAssertEqual(mocks.cursorOverlay.stopHint, .press(key: "⌃⌥E"))

        await appState.handleShortcut(.dictationMode(mode.id))
        XCTAssertFalse(appState.isRecording)
        XCTAssertEqual(mocks.textInjector.lastInjectedText, "hands free in a mode")
    }

    private func mode(_ appState: AppState) -> DictationMode {
        let mode = DictationMode(name: "Exact", cleanup: .raw, shortcut: "14:\(HotKeyModifiers([.control, .option]).rawValue)")
        appState.dictationModes = [mode]
        return mode
    }

    func testASecondPressWhileTheModelLoadsStopsWithoutLosingTheMode() async {
        let (appState, mocks) = AppState.makeTestState()
        let mode = mode(appState)
        mocks.whisperService.isModelLoaded = false
        let gate = StepGate()
        mocks.whisperService.loadGate = gate
        prepare(mocks, text: "said while loading")

        let first = Task { await appState.handleShortcut(.dictationMode(mode.id)) }
        _ = await gate.waitUntilReached()
        XCTAssertTrue(appState.isLoadingModelForRecording)
        await appState.handleShortcut(.dictationMode(mode.id))
        XCTAssertEqual(appState.pendingModeID, mode.id, "The second press doesn't erase the first press's mode")
        XCTAssertEqual(mocks.whisperService.loadRequests.count, 1, "It doesn't start another dictation")

        gate.open()
        await first.value
        XCTAssertNil(appState.pendingModeID)
    }

    func testAQuickPressWhileTheModelLoadsMakesTheRecordingHandsFree() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.commandModeHoldThreshold = 60
        appState.activationMode = .pushToTalk
        let mode = mode(appState)
        mocks.whisperService.isModelLoaded = false
        let gate = StepGate()
        mocks.whisperService.loadGate = gate
        prepare(mocks, text: "tapped while loading")

        let first = Task { await appState.handleShortcut(.dictationMode(mode.id)) }
        _ = await gate.waitUntilReached()
        await appState.handleShortcutReleased(.dictationMode(mode.id))
        gate.open()
        await first.value

        XCTAssertTrue(appState.isRecording)
        XCTAssertTrue(appState.isHandsFreeSession, "The tap is remembered for the recording it started")
        await appState.handleShortcut(.dictationMode(mode.id))
        XCTAssertFalse(appState.isRecording)
    }

    func testSilenceDoesntEndAModeRecordingWhileItsKeysAreHeld() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.activationMode = .doubleTapToggle
        appState.commandModeHoldThreshold = 0
        let mode = mode(appState)
        prepare(mocks, text: "a long thought with pauses")

        await appState.handleShortcut(.dictationMode(mode.id))
        mocks.audioEngine.onSilenceDetected?()
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(appState.isRecording, "Held keys mean push to talk")

        await appState.handleShortcutReleased(.dictationMode(mode.id))
        XCTAssertFalse(appState.isRecording)
    }

    func testTheNextDictationIsBackToNormal() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.commandModeHoldThreshold = 0
        let mode = DictationMode(name: "Exact", cleanup: .raw, language: "de")
        appState.dictationModes = [mode]
        prepare(mocks, text: "first one")
        await appState.handleShortcut(.dictationMode(mode.id))
        await appState.handleShortcutReleased(.dictationMode(mode.id))

        prepare(mocks, text: "second one")
        await appState.startRecording()
        XCTAssertNil(mocks.cursorOverlay.modeName)
        await appState.stopRecordingAndTranscribe()
        XCTAssertNotEqual(mocks.whisperService.lastLanguage, "de")
        XCTAssertFalse(appState.historyStore.entries.first?.summary?.contains("Exact mode") == true)
    }

    func testRetryHonoursASpokenModeName() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocaMacModeRetry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationHistoryStore(directory: directory)
        let (appState, mocks) = AppState.makeTestState(historyStore: store)
        appState.dictationModes = [DictationMode(name: "Exact", cleanup: .raw)]
        mocks.whisperService.shouldThrow = true
        mocks.audioEngine.stopRecordingResult = speech
        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()
        let failed = try XCTUnwrap(appState.recoverableHistoryEntry)

        mocks.whisperService.shouldThrow = false
        prepare(mocks, text: "Exact, um keep this")
        let text = await appState.retryHistoryEntry(failed.id)

        XCTAssertEqual(text, "Um keep this")
        XCTAssertTrue(store.entry(id: failed.id)?.summary?.hasPrefix("Exact mode") == true)
    }

    func testModeShortcutsReachTheListener() {
        let (appState, mocks) = AppState.makeTestState()
        let combo = HotKeyCombo(keyCode: 8, modifiers: [.control, .option])
        let mode = DictationMode(name: "Code", style: .code, shortcut: combo.storageString)
        appState.dictationModes = [mode]
        XCTAssertEqual(mocks.hotKeyManager.shortcuts[.dictationMode(mode.id)], combo)
        XCTAssertEqual(appState.shortcut(for: .dictationMode(mode.id)), combo)
        XCTAssertEqual(appState.shortcutName(for: .dictationMode(mode.id)), "“Code” mode")

        appState.setShortcut(nil, for: .dictationMode(mode.id))
        XCTAssertNil(mocks.hotKeyManager.shortcuts[.dictationMode(mode.id)])
    }

    func testAModeShortcutConflictIsReported() {
        let (appState, _) = AppState.makeTestState()
        let combo = HotKeyCombo(keyCode: 8, modifiers: [.control, .option])
        let code = DictationMode(name: "Code", shortcut: combo.storageString)
        appState.dictationModes = [code]
        let problem = ShortcutValidation.problem(with: combo, action: .dictationMode(UUID()), appState: appState)
        XCTAssertEqual(problem, "That's already the “Code” mode shortcut.")
    }

    func testStarterModesAreAddedOnce() {
        let (appState, _) = AppState.makeTestState()
        appState.addStarterModes()
        appState.addStarterModes()
        XCTAssertEqual(appState.dictationModes.map(\.name), DictationMode.starters.map(\.name))
        XCTAssertNotEqual(appState.dictationModes.first?.id, DictationMode.starters.first?.id)
    }

    func testSaveAndDeleteMode() {
        let (appState, _) = AppState.makeTestState()
        var mode = DictationMode(name: "Notes", style: .notes)
        appState.saveDictationMode(mode)
        mode.style = .email
        appState.saveDictationMode(mode)
        XCTAssertEqual(appState.dictationModes, [mode])
        appState.deleteDictationMode(mode.id)
        XCTAssertTrue(appState.dictationModes.isEmpty)
    }
}

final class HotKeyModeShortcutTests: XCTestCase {

    private func keyEvent(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) throws -> CGEvent {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else {
            throw XCTSkip("Could not create keyboard event")
        }
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        event.flags = flags
        return event
    }

    func testModeShortcutReportsPressAndRelease() throws {
        let manager = HotKeyManager()
        let id = UUID()
        manager.updateShortcuts([.dictationMode(id): HotKeyCombo(keyCode: 14, modifiers: [.control, .option])])
        let pressed = expectation(description: "Pressed")
        let released = expectation(description: "Released")
        manager.onShortcut = { action in
            XCTAssertEqual(action, .dictationMode(id))
            pressed.fulfill()
        }
        manager.onShortcutReleased = { action in
            XCTAssertEqual(action, .dictationMode(id))
            released.fulfill()
        }
        let flags: CGEventFlags = [.maskControl, .maskAlternate]
        XCTAssertTrue(manager._handleTestEvent(type: .keyDown, event: try keyEvent(14, down: true, flags: flags)))
        XCTAssertTrue(manager._handleTestEvent(type: .keyUp, event: try keyEvent(14, down: false, flags: flags)))
        wait(for: [pressed, released], timeout: 1)
    }

    func testModeActionsSortAfterBuiltIns() {
        let id = UUID()
        let ordered = HotKeyShortcutAction.ordered([.dictationMode(id), .handsFreeToggle])
        XCTAssertEqual(ordered, [.handsFreeToggle, .dictationMode(id)])
        XCTAssertEqual(HotKeyShortcutAction.dictationMode(id).id, "dictationMode-\(id.uuidString)")
    }
}
