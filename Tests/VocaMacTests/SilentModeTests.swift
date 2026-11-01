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

    /// Teach "send" (Return) from three clean takes.
    private func teachSend(_ state: AppState) throws {
        var takes: [LipTake] = []
        for index in 0..<3 {
            let start = 1_000 + Double(index) * 10
            let frames = LipFrameFactory.still(from: start, seconds: 0.5)
                + LipFrameFactory.speaking(from: start + 0.5, seconds: 0.6)
                + LipFrameFactory.still(from: start + 1.1, seconds: 0.5)
            takes.append(try XCTUnwrap(state.silentTake(from: frames)))
        }
        state.saveSilentCommand(id: nil, action: .pressReturn, word: "send", takes: takes)
    }

    private func mouthSend(_ state: AppState) {
        feed(state) { start in
            LipFrameFactory.still(from: start, seconds: 1.2)
                + LipFrameFactory.speaking(from: start + 1.2, seconds: 0.6)
                + LipFrameFactory.still(from: start + 1.8, seconds: 1.2)
        }
    }

    func testEscapeDuringTheCommandPauseDropsIt() async throws {
        let (state, mocks) = silentState()
        state.silentModeHoldThreshold = 0
        try teachSend(state)
        await holdSilentShortcut(state, mocks)
        mouthSend(state)
        let release = Task { await state.handleShortcutReleased(.silentMode) }
        await waitUntil { !mocks.cursorOverlay.doneMessages.isEmpty }
        XCTAssertEqual(mocks.cursorOverlay.doneMessages, ["Send ↩"])
        await state.cancelDictation()
        await release.value

        XCTAssertEqual(mocks.keyPresser.presses, [], "Escape drops the command")
        XCTAssertEqual(state.appStatus, .idle)
    }

    func testAnotherAppInFrontDropsTheCommand() async throws {
        let (state, mocks) = silentState()
        state.silentModeHoldThreshold = 0
        mocks.frontmostAppResolver.frontmostApp = RunningAppSnapshot(displayName: "Mail", bundleIdentifier: "com.apple.mail")
        try teachSend(state)
        await holdSilentShortcut(state, mocks)
        mouthSend(state)
        let release = Task { await state.handleShortcutReleased(.silentMode) }
        await waitUntil { !mocks.cursorOverlay.doneMessages.isEmpty }
        mocks.frontmostAppResolver.frontmostApp = RunningAppSnapshot(displayName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap")
        await release.value

        XCTAssertEqual(mocks.keyPresser.presses, [])
        XCTAssertEqual(mocks.cursorOverlay.failureMessages.last, "Another app came to the front, so Send wasn't run.")
    }

    /// The camera came up late and the microphone heard speech before it:
    /// those words win over a mouthed command.
    func testSpeechTheCameraMissedIsDictatedNotACommand() async throws {
        let (state, mocks) = silentState()
        state.silentModeHoldThreshold = 0
        try teachSend(state)
        await holdSilentShortcut(state, mocks)
        feed(state) { start in
            LipFrameFactory.noFace(from: start, seconds: 1.2)
                + LipFrameFactory.speaking(from: start + 1.2, seconds: 0.6)
                + LipFrameFactory.still(from: start + 1.8, seconds: 1.2)
        }
        await state.handleShortcutReleased(.silentMode)
        await waitUntil { mocks.textInjector.injectCallCount == 1 }

        XCTAssertEqual(mocks.keyPresser.presses, [])
        XCTAssertNotNil(mocks.whisperService.lastTranscribedAudioData)
    }

    /// A camera that saw under half the recording can't stand in for it.
    func testTooLittleCoverageIsNeverACommand() async throws {
        let (state, mocks) = silentState()
        state.silentModeHoldThreshold = 0
        mocks.audioEngine.stopRecordingResult = [Float](repeating: 0.001, count: 48_000)
        try teachSend(state)
        await holdSilentShortcut(state, mocks)
        feed(state) { start in
            LipFrameFactory.noFace(from: start, seconds: 2)
                + LipFrameFactory.speaking(from: start + 2, seconds: 0.6)
                + LipFrameFactory.still(from: start + 2.6, seconds: 0.4)
        }
        await state.handleShortcutReleased(.silentMode)
        await waitUntil { mocks.textInjector.injectCallCount == 1 }
        XCTAssertEqual(mocks.keyPresser.presses, [])
    }

    /// The Silent Mode key pressed while an ordinary dictation waits for its
    /// speech model must not end that dictation.
    func testTheSilentKeyLeavesALoadingDictationAlone() async {
        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.tiny]
        let whisperService = MockWhisperService()
        whisperService.loadedModelName = nil
        whisperService.isModelLoaded = false
        let gate = StepGate()
        whisperService.loadGate = gate
        let (state, _) = AppState.makeTestState(modelManager: modelManager, whisperService: whisperService)
        let originalModel = state.selectedModelSize
        defer { state.selectedModelSize = originalModel }
        state.selectedModelSize = ModelSize.tiny.rawValue
        state.setShortcut(silentKeys, for: .silentMode)

        let start = Task { await state.startRecording() }
        let reachedGate = await gate.waitUntilReached()
        XCTAssertTrue(reachedGate)
        await state.handleSilentModePress()
        gate.open()
        await start.value

        XCTAssertTrue(state.isRecording, "The ordinary dictation carries on")
        XCTAssertFalse(state.isSilentSession)
        await state.cancelRecording()
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

    /// Takes saved before lip points were measured in pixels don't match
    /// today's frames; the command stays, asking for new takes.
    func testTakesMeasuredTheOldWayAreDropped() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("silent-commands.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID()
        let json = """
        [{"id":"\(id.uuidString)","action":{"pressReturn":{}},"word":"send",
          "takes":[{"frames":[[0.1,0.2]],"recordedAt":0}]}]
        """
        try Data(json.utf8).write(to: url)

        let loaded = SilentCommandStore(fileURL: url).load()
        XCTAssertEqual(loaded.map(\.id), [id])
        XCTAssertEqual(loaded.first?.takes, [])
        XCTAssertEqual(loaded.first?.isReady, false)
    }

    // MARK: Camera

    /// Crops are smoothed over neighbouring frames: after a camera switch
    /// the new camera's crops are built from its frames alone.
    func testACameraSwitchDoesntMixTheTwoCamerasCrops() async throws {
        let (state, _) = AppState.makeTestState()
        let controller = state.silentMode
        controller.beginDictation(readsLips: true)
        await controller.begin(.dictation)
        let (before, _) = try MouthCropTests.face(shift: .zero)
        // The second camera frames the face larger.
        let (after, _) = try MouthCropTests.face(shift: CGPoint(x: 20, y: 10), scale: 1.5)
        func frames(_ patch: MouthPatch, from start: TimeInterval) -> [LipFrame] {
            LipFrameFactory.speaking(from: start, seconds: 0.4).map { frame in
                var frame = frame
                frame.mouth = patch
                return frame
            }
        }
        let first = frames(before, from: 100), second = frames(after, from: 100.4)
        first.forEach(controller.ingest)
        await controller.useCamera("external")
        second.forEach(controller.ingest)
        let crops = controller.finishDictationCapture().crops

        func alone(_ frames: [LipFrame]) -> [MouthCrop] {
            var builder = MouthCropBuilder()
            var crops: [MouthCrop] = []
            for frame in frames {
                if let patch = frame.mouth { crops += builder.ingest(time: frame.time, patch: patch) }
            }
            return crops + builder.finish()
        }
        XCTAssertEqual(crops, alone(first) + alone(second))
    }

    func testChoosingAnotherCameraMovesARunningCamera() async {
        let (state, mocks) = AppState.makeTestState()
        await state.silentMode.begin(.preview)
        let session = state.silentMode.live.cameraSession
        await state.silentMode.useCamera("external")
        XCTAssertEqual(mocks.lipTracker.startCount, 2)
        XCTAssertEqual(mocks.lipTracker.lastCameraID, "external")
        XCTAssertEqual(state.silentMode.live.cameraSession, session + 1)
        state.silentMode.end(.preview)

        // Off, it is only remembered for the next start.
        await state.silentMode.useCamera(nil)
        XCTAssertEqual(mocks.lipTracker.startCount, 2)
    }
}
