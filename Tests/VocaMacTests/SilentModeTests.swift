// SilentModeTests.swift
// VocaMacTests
//
// Silent Mode end to end with a fake camera: its own shortcut (hold, or
// press and press again), the camera on only while it records, only what
// the lips said decoded, nothing typed when they never moved, and a
// mouthed command pressing its key instead of being typed.

import XCTest
@testable import VocaMac

@MainActor
final class SilentModeTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "SilentModeTests"
    private let silentKeys = HotKeyCombo(keyCode: 1, modifiers: [.control, .option, .command])

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// A state with Silent Mode on and a 3-second recording waiting in the microphone.
    private func silentState() -> (AppState, TestMocks) {
        let (state, mocks) = AppState.makeTestState()
        state.setShortcut(silentKeys, for: .silentMode)
        mocks.audioEngine.stopRecordingResult = [Float](repeating: 0.2, count: 48_000)
        return (state, mocks)
    }

    /// Start a silent recording by holding the shortcut, and wait for the camera.
    private func holdSilentShortcut(_ state: AppState, _ mocks: TestMocks) async {
        await state.handleShortcut(.silentMode)
        await waitUntil { state.silentMode.isCameraRequested && mocks.lipTracker.startCount > 0 }
    }

    /// Feed the camera frames covering the last three seconds, ending now.
    private func feed(_ state: AppState, _ build: (TimeInterval) -> [LipFrame]) {
        let start = ProcessInfo.processInfo.systemUptime - 3
        for frame in build(start) { state.silentMode.ingest(frame) }
    }

    // MARK: On and off

    func testSilentModeIsOnOnlyWithAShortcut() {
        let (state, _) = AppState.makeTestState()
        XCTAssertFalse(state.isSilentModeOn)
        XCTAssertTrue(state.setSilentModeOn(true, defaults: defaults))
        XCTAssertTrue(state.isSilentModeOn)
        XCTAssertEqual(state.shortcut(for: .silentMode), silentKeys, "⌃⌥⌘S is suggested first")
    }

    func testTurningOffRemembersTheKeys() {
        let (state, _) = AppState.makeTestState()
        let custom = HotKeyCombo(keyCode: 46, modifiers: [.control, .option])
        state.setShortcut(custom, for: .silentMode)
        state.setSilentModeOn(false, defaults: defaults)
        XCTAssertNil(state.shortcut(for: .silentMode))
        state.setSilentModeOn(true, defaults: defaults)
        XCTAssertEqual(state.shortcut(for: .silentMode), custom)
    }

    func testTheSuggestionSkipsKeysAnotherShortcutHas() {
        let (state, _) = AppState.makeTestState()
        state.setShortcut(silentKeys, for: .commandMode)
        XCTAssertEqual(
            ShortcutValidation.suggestion(for: .silentMode, appState: state),
            HotKeyCombo(keyCode: 46, modifiers: [.control, .option, .command])
        )
    }

    func testAModifierAloneCantBeTheSilentShortcut() {
        let (state, _) = AppState.makeTestState()
        let rightCommand = HotKeyCombo(keyCode: 54, modifiers: [])
        XCTAssertNotNil(ShortcutValidation.problem(with: rightCommand, action: .silentMode, appState: state))
    }

    func testTheShortcutReachesTheListener() {
        let (state, mocks) = silentState()
        state.syncShortcutConfiguration()
        XCTAssertEqual(mocks.hotKeyManager.shortcuts[.silentMode], silentKeys)
    }

    // MARK: The shortcut

    func testHoldingTheShortcutRecordsSilentlyAndLettingGoTypes() async {
        let (state, mocks) = silentState()
        state.silentModeHoldThreshold = 0

        await holdSilentShortcut(state, mocks)
        XCTAssertTrue(state.isRecording)
        XCTAssertTrue(state.isSilentSession)
        XCTAssertTrue(mocks.cursorOverlay.silentSession === state.silentMode.live)
        XCTAssertEqual(state.overlayStopHint, .hold(key: "⌃⌥⌘S"))

        await state.handleShortcutReleased(.silentMode)
        await waitUntil { mocks.textInjector.injectCallCount == 1 }

        XCTAssertFalse(state.isRecording)
        XCTAssertFalse(state.isSilentSession)
        XCTAssertEqual(mocks.lipTracker.stopCount, 1, "The camera goes off with the microphone")
        // No frames came: the camera couldn't judge, so it is an ordinary dictation.
        XCTAssertEqual(mocks.whisperService.lastTranscribedAudioData?.count, 48_000)
    }

    func testAQuickPressRecordsUntilTheNextPress() async {
        let (state, mocks) = silentState()
        state.silentModeHoldThreshold = 10

        await holdSilentShortcut(state, mocks)
        await state.handleShortcutReleased(.silentMode)
        XCTAssertTrue(state.isRecording, "A quick press keeps recording")
        XCTAssertEqual(state.overlayStopHint, .press(key: "⌃⌥⌘S"))

        await state.handleShortcut(.silentMode)
        XCTAssertFalse(state.isRecording)
    }

    func testTheDictationKeyStaysOrdinaryUnlessAskedToo() async {
        let (state, mocks) = silentState()
        await state.startRecordingFromActivationShortcut()
        XCTAssertTrue(state.isRecording)
        XCTAssertFalse(state.isSilentSession)
        XCTAssertNil(mocks.cursorOverlay.silentSession)
        await state.cancelRecording()
        XCTAssertEqual(mocks.lipTracker.startCount, 0)

        state.silentModeUsesDictationKey = true
        await state.startRecordingFromActivationShortcut()
        XCTAssertTrue(state.isSilentSession)
        await state.cancelRecording()
    }

    func testCancellingTurnsTheCameraOff() async {
        let (state, mocks) = silentState()
        await holdSilentShortcut(state, mocks)
        await state.cancelRecording()
        XCTAssertFalse(state.isSilentSession)
        XCTAssertFalse(state.silentMode.isCameraRequested)
        XCTAssertEqual(mocks.lipTracker.stopCount, 1)
        XCTAssertEqual(state.silentMode.live.phase, .off)
    }

    func testARecordingThatEndsAtOnceNeverTurnsTheCameraOn() async {
        let (state, mocks) = AppState.makeTestState()
        state.silentMode.beginDictation()
        _ = state.silentMode.finishDictation()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(mocks.lipTracker.startCount, 0)
        XCTAssertFalse(state.silentMode.isCameraRequested)
    }

    func testACameraThatWontStartStillDictates() async {
        let (state, mocks) = silentState()
        mocks.lipTracker.startError = CameraLipTrackerError.noCamera
        state.silentModeHoldThreshold = 0
        await holdSilentShortcut(state, mocks)
        await waitUntil { state.silentMode.live.phase != .starting }
        guard case .unavailable = state.silentMode.live.phase else { return XCTFail("Expected unavailable") }

        await state.handleShortcutReleased(.silentMode)
        await waitUntil { mocks.textInjector.injectCallCount == 1 }
        XCTAssertEqual(mocks.whisperService.lastTranscribedAudioData?.count, 48_000)
    }

    // MARK: What is decoded

    func testOnlyWhatTheLipsSaidIsDecoded() async throws {
        let (state, mocks) = silentState()
        state.silentModeHoldThreshold = 0
        await holdSilentShortcut(state, mocks)
        feed(state) { start in
            LipFrameFactory.still(from: start, seconds: 1)
                + LipFrameFactory.speaking(from: start + 1, seconds: 1)
                + LipFrameFactory.still(from: start + 2, seconds: 1)
        }

        await state.handleShortcutReleased(.silentMode)
        await waitUntil { mocks.textInjector.injectCallCount == 1 }

        let decoded = try XCTUnwrap(mocks.whisperService.lastTranscribedAudioData)
        // About a second of movement plus lead-in and tail, not all three.
        XCTAssertGreaterThan(decoded.count, 16_000)
        XCTAssertLessThan(decoded.count, 40_000)
    }

    func testStillLipsTypeNothing() async {
        let (state, mocks) = silentState()
        state.silentModeHoldThreshold = 0
        await holdSilentShortcut(state, mocks)
        feed(state) { LipFrameFactory.still(from: $0, seconds: 3) }

        await state.handleShortcutReleased(.silentMode)

        XCTAssertNil(mocks.whisperService.lastTranscribedAudioData)
        XCTAssertEqual(mocks.textInjector.injectCallCount, 0)
        XCTAssertEqual(mocks.cursorOverlay.failureMessages.last, "Silent Mode didn't see your lips move.")
        XCTAssertTrue(state.errorMessage?.contains("didn't see your lips move") == true)
    }

    // MARK: Commands

    func testAMouthedCommandPressesItsKeyInsteadOfTyping() async throws {
        let (state, mocks) = silentState()
        state.silentModeHoldThreshold = 0
        var takes: [LipTake] = []
        for index in 0..<3 {
            let start = 1_000 + Double(index) * 10
            let frames = LipFrameFactory.still(from: start, seconds: 0.5)
                + LipFrameFactory.speaking(from: start + 0.5, seconds: 0.6)
                + LipFrameFactory.still(from: start + 1.1, seconds: 0.5)
            takes.append(try XCTUnwrap(state.silentTake(from: frames)))
        }
        state.saveSilentCommand(id: nil, action: .pressReturn, word: "send", takes: takes)

        await holdSilentShortcut(state, mocks)
        feed(state) { start in
            LipFrameFactory.still(from: start, seconds: 1.2)
                + LipFrameFactory.speaking(from: start + 1.2, seconds: 0.6)
                + LipFrameFactory.still(from: start + 1.8, seconds: 1.2)
        }
        await state.handleShortcutReleased(.silentMode)

        XCTAssertEqual(mocks.keyPresser.presses, [.returnKey])
        XCTAssertEqual(mocks.cursorOverlay.doneMessages, ["Send ↩"])
        XCTAssertNil(mocks.whisperService.lastTranscribedAudioData, "A command isn't dictated")
        XCTAssertEqual(mocks.textInjector.injectCallCount, 0)
    }

    func testATakeWithoutMovementIsNotSaved() {
        let (state, _) = AppState.makeTestState()
        XCTAssertNil(state.silentTake(from: LipFrameFactory.still(from: 0, seconds: 2)))
    }

    func testUntaughtActionsLeaveOutTaughtOnes() {
        let (state, _) = AppState.makeTestState()
        state.saveSilentCommand(id: nil, action: .pressReturn, word: "send", takes: [])
        XCTAssertFalse(state.untaughtSilentActions.contains(.pressReturn))
        XCTAssertTrue(state.untaughtSilentActions.contains(.undo))
    }

    func testOtherActionsPressTheirKeys() async {
        let (state, mocks) = AppState.makeTestState()
        await state.performSilentAction(.undo)
        await state.performSilentAction(.newLine)
        await state.performSilentAction(.tab)
        XCTAssertEqual(mocks.keyPresser.presses.map(\.flags), [[.maskCommand], [.maskShift], []])
    }

    // MARK: Storage

    func testCommandsSurviveARestartAndLoadingWritesNothing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SilentCommandStore(fileURL: folder.appendingPathComponent("silent-commands.json"))
        XCTAssertEqual(store.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))

        let command = SilentCommand(action: .runShortcut("Focus"), word: "focus", takes: [LipTake(frames: [[0.1, 0.2]])])
        store.save([command])
        XCTAssertEqual(store.load(), [command])
    }
}
