// AppStateRecoveryTests.swift
// VocaMac
//
// Pressing the hotkey while a dictation is still finishing, after an error,
// or cancelling right after release must never lose or wrongly paste text.

import XCTest
@testable import VocaMac

/// Stops the way a real engine can: slowly, on the audio queue.
private final class SlowStopAudioEngine: AudioRecording {
    var isCurrentlyRecording = false
    var onAudioLevel: ((Float) -> Void)?
    var onAudioSamples: (([Float], Int) -> Void)?
    var onSilenceDetected: (() -> Void)?
    var onMaxDurationReached: (() -> Void)?
    var onAudioDeviceChanged: (() -> Void)?
    var onInputDeviceFallback: ((String) -> Void)?

    let samples: [Float]
    let stopDelay: TimeInterval

    init(samples: [Float], stopDelay: TimeInterval) {
        self.samples = samples
        self.stopDelay = stopDelay
    }

    func startRecording(
        silenceThreshold: Float, silenceDuration: Double, maxDuration: TimeInterval,
        preferredInputDeviceID: String?, preferredInputChannel: Int,
        preferredInputChannelDeviceID: String?, preferredInputChannelCount: Int
    ) -> Bool {
        isCurrentlyRecording = true
        return true
    }

    func stopRecording() -> [Float] {
        Thread.sleep(forTimeInterval: stopDelay)
        let wasRecording = isCurrentlyRecording
        isCurrentlyRecording = false
        return wasRecording ? samples : []
    }

    func cancelPendingStart() {}
    func forceReset() { isCurrentlyRecording = false }
    func checkPermissionStatus() -> PermissionStatus { .granted }
    func requestPermission(completion: @escaping (Bool) -> Void) { completion(true) }
}

@MainActor
final class AppStateRecoveryTests: XCTestCase {

    private let speech = Array(repeating: Float(0.1), count: 16_000)

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: Hotkey while the previous dictation is finishing

    func testHotKeyWhileTranscribingDeliversThatDictationThenStartsTheNext() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.audioEngine.stopRecordingResult = speech
        mocks.whisperService.transcribeDelayNanoseconds = 300_000_000

        await appState.startRecording()
        XCTAssertTrue(appState.isRecording)
        let stop = Task { await appState.stopRecordingAndTranscribe() }
        await waitUntil { appState.appStatus == .processing }
        XCTAssertEqual(appState.appStatus, .processing)

        // The user presses the hotkey for the next sentence.
        await appState.startRecording()
        XCTAssertFalse(appState.isRecording, "The next recording waits for the first dictation's delivery")

        await stop.value
        XCTAssertEqual(mocks.textInjector.injectCallCount, 1, "The first dictation must still be delivered")

        await waitUntil { appState.isRecording }
        XCTAssertTrue(appState.isRecording, "The queued dictation starts once delivery finishes")
        XCTAssertEqual(appState.appStatus, .recording)

        await appState.cancelRecording()
    }

    func testReleasingBeforeDeliveryFinishesStartsNothingAndKeepsTheFirstDictation() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.audioEngine.stopRecordingResult = speech
        mocks.whisperService.transcribeDelayNanoseconds = 300_000_000

        await appState.startRecording()
        let stop = Task { await appState.stopRecordingAndTranscribe() }
        await waitUntil { appState.appStatus == .processing }

        await appState.startRecording()
        // Push-to-talk released while the first dictation is still processing.
        await appState.stopRecordingAndTranscribe()

        await stop.value
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(mocks.textInjector.injectCallCount, 1)
        XCTAssertFalse(appState.isRecording)
        XCTAssertEqual(appState.appStatus, .idle)
    }

    func testEscapeDropsAQueuedDictation() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.audioEngine.stopRecordingResult = speech
        mocks.whisperService.transcribeDelayNanoseconds = 300_000_000

        await appState.startRecording()
        let stop = Task { await appState.stopRecordingAndTranscribe() }
        await waitUntil { appState.appStatus == .processing }

        await appState.startRecording()
        await appState.cancelDictation()
        await stop.value
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(appState.isRecording)
        XCTAssertEqual(appState.appStatus, .idle)
    }

    func testHotKeyAfterAnErrorStartsRecordingInTheSamePress() async {
        let (appState, _) = AppState.makeTestState()
        appState.errorMessage = "Transcription failed: mock error"
        appState.appStatus = .error

        await appState.startRecording()

        XCTAssertTrue(appState.isRecording)
        XCTAssertEqual(appState.appStatus, .recording)
        XCTAssertNil(appState.errorMessage)
        await appState.cancelRecording()
    }

    func testHotKeyAfterDestinationChangeStartsRecording() async {
        let (appState, mocks) = AppState.makeTestState()
        let originalCleanup = appState.transcriptCleanupEnabled
        defer { appState.transcriptCleanupEnabled = originalCleanup }
        mocks.frontmostAppResolver.frontmostApp = RunningAppSnapshot(
            displayName: "Mail", bundleIdentifier: "com.apple.mail"
        )
        // The user switches apps while the dictation is being cleaned up.
        mocks.transcriptCleanup.cleanHandler = { text in
            mocks.frontmostAppResolver.frontmostApp = RunningAppSnapshot(
                displayName: "Terminal", bundleIdentifier: "com.apple.Terminal"
            )
            return text
        }
        appState.transcriptCleanupEnabled = true
        mocks.audioEngine.stopRecordingResult = speech

        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()
        XCTAssertNotNil(appState.heldOutput)
        XCTAssertEqual(appState.appStatus, .error)

        await appState.startRecording()
        XCTAssertTrue(appState.isRecording, "A changed destination must not leave the hotkey stuck")
        await appState.cancelRecording()
    }

    // MARK: Double-tap toggle stays in step

    func testStopsOutsideTheHotKeyEndTheDoubleTapSession() async {
        let (appState, mocks) = AppState.makeTestState()
        let originalMode = appState.activationMode
        defer { appState.activationMode = originalMode }
        appState.activationMode = .doubleTapToggle
        mocks.audioEngine.stopRecordingResult = speech

        await appState.startRecording()
        let before = mocks.hotKeyManager.resetKeyStateCallCount
        // Menu, overlay, silence, and the time limit all stop this way.
        await appState.stopRecordingAndTranscribe()
        XCTAssertEqual(mocks.hotKeyManager.resetKeyStateCallCount, before + 1)

        await appState.startRecording()
        let beforeHotKeyStop = mocks.hotKeyManager.resetKeyStateCallCount
        mocks.hotKeyManager.onRecordingStop?()
        await waitUntil { !appState.isRecording && appState.appStatus == .idle }
        XCTAssertEqual(
            mocks.hotKeyManager.resetKeyStateCallCount, beforeHotKeyStop,
            "A double-tap stop already ended the session in the hotkey manager"
        )
    }

    func testRejectedToggleStartEndsTheDoubleTapSession() async {
        let (appState, mocks) = AppState.makeTestState()
        let originalMode = appState.activationMode
        defer { appState.activationMode = originalMode }
        appState.activationMode = .doubleTapToggle
        mocks.permissionManager.micPermission = .denied

        await appState.startRecording()

        XCTAssertFalse(appState.isRecording)
        XCTAssertEqual(mocks.hotKeyManager.resetKeyStateCallCount, 1)
    }

    func testPushToTalkStopsLeaveTheHeldKeyAlone() async {
        let (appState, mocks) = AppState.makeTestState()
        let originalMode = appState.activationMode
        defer { appState.activationMode = originalMode }
        appState.activationMode = .pushToTalk
        mocks.audioEngine.stopRecordingResult = speech

        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.hotKeyManager.resetKeyStateCallCount, 0)
    }

    // MARK: Escape right after release

    func testEscapeWhileTheStopIsStillWaitingOnTheEngineDoesNotPaste() async throws {
        let (template, mocks) = AppState.makeTestState()
        _ = template
        let engine = SlowStopAudioEngine(samples: speech, stopDelay: 0.3)
        let appState = AppState(
            audioEngine: engine,
            whisperService: mocks.whisperService,
            textInjector: mocks.textInjector,
            hotKeyManager: mocks.hotKeyManager,
            modelManager: mocks.modelManager,
            soundManager: mocks.soundManager,
            audioDucker: mocks.audioDucker,
            cursorOverlay: mocks.cursorOverlay,
            statsManager: mocks.statsManager,
            transcriptCleanup: mocks.transcriptCleanup,
            permissionManager: mocks.permissionManager,
            frontmostAppResolver: mocks.frontmostAppResolver,
            skipSystemIntegration: true
        )
        appState.modelFitsInMemory = { _, _ in true }

        await appState.startRecording()
        XCTAssertTrue(appState.isRecording)

        // Hotkey released: the stop is now waiting on the audio queue.
        let stop = Task { await appState.stopRecordingAndTranscribe() }
        try await Task.sleep(nanoseconds: 50_000_000)
        // Escape a moment later.
        await appState.cancelRecording()
        await stop.value

        XCTAssertNil(mocks.whisperService.lastTranscribedAudioData, "A cancelled dictation must not be transcribed")
        XCTAssertEqual(mocks.textInjector.injectCallCount, 0, "A cancelled dictation must not be pasted")
        XCTAssertEqual(appState.appStatus, .idle)
        XCTAssertFalse(appState.isRecording)
    }

    // MARK: Failures near the caret

    private func withOverlay(
        _ appState: AppState,
        style: OverlayStyle,
        _ body: () async -> Void
    ) async {
        let originalStyle = appState.overlayStyle
        let originalIndicator = appState.showCursorIndicator
        appState.overlayStyle = style
        appState.showCursorIndicator = true
        await body()
        appState.overlayStyle = originalStyle
        appState.showCursorIndicator = originalIndicator
    }

    func testNothingHeardIsSaidInTheOverlay() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.audioEngine.stopRecordingResult = speech
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "  ", duration: 1, detectedLanguage: "en", audioLengthSeconds: 1, modelUsed: .tiny
        )

        await withOverlay(appState, style: .minimal) {
            await appState.startRecording()
            await appState.stopRecordingAndTranscribe()
        }

        XCTAssertEqual(mocks.cursorOverlay.failureMessages, ["Didn't catch that."])
        XCTAssertEqual(appState.appStatus, .idle)
    }

    func testNothingHeardFallsBackToTheMenuBarWhenOverlaysAreOff() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.audioEngine.stopRecordingResult = speech
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "", duration: 1, detectedLanguage: "en", audioLengthSeconds: 1, modelUsed: .tiny
        )

        await withOverlay(appState, style: .off) {
            await appState.startRecording()
            await appState.stopRecordingAndTranscribe()
        }

        XCTAssertTrue(mocks.cursorOverlay.failureMessages.isEmpty, "An Off overlay must stay off")
        XCTAssertEqual(appState.appStatus, .error)
        XCTAssertNotNil(appState.errorMessage)
    }

    func testFailedTranscriptionIsSaidInTheOverlay() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.audioEngine.stopRecordingResult = speech
        mocks.whisperService.shouldThrow = true

        await withOverlay(appState, style: .minimal) {
            await appState.startRecording()
            await appState.stopRecordingAndTranscribe()
        }

        XCTAssertEqual(mocks.cursorOverlay.failureMessages.count, 1)
        XCTAssertTrue(mocks.cursorOverlay.failureMessages.first?.hasPrefix("Transcription failed") == true)
        XCTAssertEqual(appState.appStatus, .error)
    }

    func testRecordingOverlayKnowsTheTimeLimit() async {
        let (appState, mocks) = AppState.makeTestState()
        let originalLimit = appState.maxRecordingDuration
        appState.maxRecordingDuration = 30

        await withOverlay(appState, style: .minimal) {
            await appState.startRecording()
        }

        XCTAssertEqual(mocks.cursorOverlay.recordingLimit, 30)
        await appState.cancelRecording()
        appState.maxRecordingDuration = originalLimit
    }

    // MARK: Model downloads

    func testCancelledDownloadIsNotReportedAsAFailure() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.modelManager.downloadError = CancellationError()

        await appState.downloadModel(.base)

        XCTAssertNil(appState.errorMessage)
        XCTAssertNil(appState.availableModels.first { $0.size == .base }?.downloadProgress)
    }

    func testLowDiskSpaceMessageIsShownAsIs() async {
        let (appState, mocks) = AppState.makeTestState()
        let error = ModelManagerError.insufficientDiskSpace(
            model: "Base", requiredBytes: 500_000_000, availableBytes: 10_000_000
        )
        mocks.modelManager.downloadError = error

        await appState.downloadModel(.base)

        XCTAssertEqual(appState.errorMessage, error.localizedDescription)
    }

    // MARK: Screen context time limit

    func testSlowScreenReadDoesNotHoldUpTheDictation() async {
        let slow = Task<[String], Never>.detached {
            // Ignores cancellation, like a blocked Accessibility read.
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return ["late"]
        }
        let started = Date()

        let terms = await AppState.value(of: slow, within: 0.3, otherwise: [])

        XCTAssertEqual(terms, [])
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    func testScreenReadThatArrivesInTimeIsUsed() async {
        let fast = Task<[String], Never> { ["Kanban", "VocaMac"] }

        let terms = await AppState.value(of: fast, within: 0.3, otherwise: [])

        XCTAssertEqual(terms, ["Kanban", "VocaMac"])
    }

    func testMissingScreenReadUsesTheFallback() async {
        let url = await AppState.value(of: Optional<Task<URL?, Never>>.none, within: 0.3, otherwise: nil)
        XCTAssertNil(url)
    }
}
