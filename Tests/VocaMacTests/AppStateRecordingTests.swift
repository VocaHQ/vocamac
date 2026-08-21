// AppStateRecordingTests.swift
// VocaMac
//
// Tests for AppState recording flow and state transitions.

import XCTest
@testable import VocaMac

// MARK: - AppState Recording State Transition Tests

@MainActor
final class AppStateRecordingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "vocamac.soundEffectsEnabled")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "vocamac.soundEffectsEnabled")
        super.tearDown()
    }

    func testInitialState() {
        let (appState, _) = AppState.makeTestState()

        XCTAssertEqual(appState.appStatus, .idle, "App should start in idle state")
        XCTAssertFalse(appState.isRecording, "Should not be recording initially")
        XCTAssertNil(appState.errorMessage, "No error message initially")
        XCTAssertEqual(appState.audioLevel, 0.0, "Audio level should be zero")
    }

    func testStartRecordingWithDeniedMicPermission() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.permissionManager.micPermission = .denied

        await appState.startRecording()

        XCTAssertEqual(appState.appStatus, .error,
                      "Should transition to error when mic permission is denied")
        XCTAssertNotNil(appState.errorMessage,
                       "Should set an error message about microphone permission")
        XCTAssertTrue(appState.errorMessage?.contains("Microphone") == true,
                     "Error message should mention microphone")
    }

    func testStartRecordingPassesOverlayStyleAndPosition() async {
        let (appState, mocks) = AppState.makeTestState()
        let originalStyle = appState.overlayStyle
        let originalPosition = appState.overlayPosition
        defer {
            appState.overlayStyle = originalStyle
            appState.overlayPosition = originalPosition
        }

        appState.overlayStyle = .live
        appState.overlayPosition = .top

        await appState.startRecording()

        XCTAssertEqual(mocks.cursorOverlay.lastStyle, .live)
        XCTAssertEqual(mocks.cursorOverlay.lastPosition, .top)
    }

    func testCancelRecordingReturnsToIdleWithoutTranscribing() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.isRecording = true
        appState.appStatus = .recording
        appState.audioLevel = 0.8

        await appState.cancelRecording()

        XCTAssertEqual(appState.appStatus, .idle)
        XCTAssertFalse(appState.isRecording)
        XCTAssertEqual(appState.audioLevel, 0.0)
        XCTAssertNil(mocks.whisperService.lastTranscribedAudioData)
        XCTAssertEqual(mocks.cursorOverlay.hideCallCount, 1)
        XCTAssertEqual(mocks.hotKeyManager.resetKeyStateCallCount, 1)
    }

    func testStartRecordingDoesNotBlockMainActorDuringAudioStart() async throws {
        let (appState, mocks) = AppState.makeTestState()
        mocks.audioEngine.startRecordingDelay = 0.3

        let start = Date()
        let task = Task {
            await appState.startRecording()
        }

        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3,
                          "Core Audio startup should not block the main actor")

        await task.value
        XCTAssertEqual(appState.appStatus, .recording)
    }

    func testStartSoundIsNotPlayedIfRecordingStopsDuringAudioStart() async throws {
        let (appState, mocks) = AppState.makeTestState()
        mocks.audioEngine.startRecordingDelay = 0.3

        let task = Task {
            await appState.startRecording()
        }

        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)
        await appState.stopRecordingAndTranscribe()
        await task.value

        XCTAssertEqual(mocks.soundManager.startSoundCallCount, 0)
        XCTAssertEqual(mocks.soundManager.stopSoundCallCount, 1)
        XCTAssertEqual(appState.appStatus, .idle)
        XCTAssertEqual(mocks.audioEngine.forceResetCallCount, 0)
    }

    func testStartRecordingInProcessingStateForceRecovers() async {
        let (appState, _) = AppState.makeTestState()
        appState.appStatus = .processing

        await appState.startRecording()

        XCTAssertEqual(appState.appStatus, .idle,
                      "startRecording in processing state should force recover to idle")
    }

    func testStopRecordingWhenNotRecording() async {
        let (appState, _) = AppState.makeTestState()

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(appState.appStatus, .idle,
                      "Should remain idle when stopping without recording")
        XCTAssertFalse(appState.isRecording)
    }

    func testStopRecordingResetsAudioLevel() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.isRecording = true
        appState.appStatus = .recording
        appState.audioLevel = 0.75

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(appState.audioLevel, 0.0,
                      "Audio level should be reset to 0 after stopping")
        XCTAssertFalse(appState.isRecording,
                      "isRecording should be false after stopping")
        XCTAssertEqual(mocks.soundManager.stopSoundCallCount, 1,
                      "Stop sound should be played once")
    }

    func testStopRecordingWithEmptyAudioReturnsToIdle() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.isRecording = true
        appState.appStatus = .recording

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(appState.appStatus, .idle)
        XCTAssertNil(appState.errorMessage)
        XCTAssertNil(mocks.whisperService.lastTranscribedAudioData)
        XCTAssertEqual(mocks.textInjector.injectCallCount, 0)
        XCTAssertEqual(mocks.audioEngine.forceResetCallCount, 0,
                       "Cancelling before the first buffer should not be reported as a broken route")
    }

    func testStopRecordingWithSilentAudioShowsInputError() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.audioEngine.stopRecordingResult = Array(repeating: 0, count: 16_000)
        appState.isRecording = true
        appState.appStatus = .recording

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(appState.appStatus, .error)
        XCTAssertTrue(appState.errorMessage?.contains("selected microphone") == true)
        XCTAssertNil(mocks.whisperService.lastTranscribedAudioData)
        XCTAssertEqual(mocks.textInjector.injectCallCount, 0)
        XCTAssertEqual(mocks.audioEngine.forceResetCallCount, 1,
                       "Silent capture should force-reset the engine so a dead route is not kept warm")
    }

    func testSelectedModelSizeDefault() {
        let (appState, _) = AppState.makeTestState()

        XCTAssertEqual(appState.selectedModelSize, ModelSize.tiny.rawValue,
                      "Default model size should be tiny")
    }

    func testPreserveClipboardDefault() {
        let (appState, _) = AppState.makeTestState()

        XCTAssertTrue(appState.preserveClipboard,
                     "preserveClipboard should default to true")
    }

    func testOutputPolishDefaults() {
        let (appState, _) = AppState.makeTestState()
        XCTAssertTrue(appState.appendTrailingSpace)
        XCTAssertTrue(appState.autoCapitalize)
        XCTAssertFalse(appState.autoPauseEnabled)
        XCTAssertFalse(appState.modelKeepAliveEnabled)
    }

    func testStopRecordingInjectsPolishedText() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.audioEngine.stopRecordingResult = Array(repeating: Float(0.1), count: 16_000)
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "hello world. goodbye",
            duration: 1.0,
            detectedLanguage: "en",
            audioLengthSeconds: 1.0,
            modelUsed: .tiny
        )
        appState.appendTrailingSpace = true
        appState.autoCapitalize = true
        appState.isRecording = true
        appState.appStatus = .recording

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.textInjector.injectCallCount, 1)
        XCTAssertEqual(mocks.textInjector.lastInjectedText, "Hello world. Goodbye ")
        XCTAssertEqual(appState.appStatus, .idle)
    }

    func testSettingsTestDictationDoesNotInject() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.audioEngine.stopRecordingResult = Array(repeating: Float(0.1), count: 16_000)
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "settings only",
            duration: 1.0,
            detectedLanguage: "en",
            audioLengthSeconds: 1.0,
            modelUsed: .tiny
        )
        appState.appendTrailingSpace = false
        appState.autoCapitalize = true
        appState.isRecording = true
        appState.appStatus = .recording

        await appState.stopRecordingAndTranscribe(injectResult: false)

        XCTAssertEqual(mocks.textInjector.injectCallCount, 0)
        XCTAssertEqual(appState.settingsTestResultText, "Settings only")
        XCTAssertEqual(appState.appStatus, .idle)
    }

    func testStartRecordingBlockedWhenAutoPaused() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.isAutoPaused = true

        await appState.startRecording()

        XCTAssertFalse(appState.isRecording)
        XCTAssertEqual(mocks.audioEngine.lastSilenceThreshold, nil)
        XCTAssertNotNil(appState.errorMessage)
        XCTAssertTrue(appState.errorMessage?.contains("paused") == true)
    }

    func testSoundEffectsEnabledDefault() {
        let (appState, _) = AppState.makeTestState()

        XCTAssertTrue(appState.soundEffectsEnabled,
                     "Sound effects should be enabled by default")
    }

    func testDictationToneDefaultsToVoca() {
        UserDefaults.standard.removeObject(forKey: PreferenceKey.dictationTone)
        let (appState, _) = AppState.makeTestState()

        XCTAssertEqual(appState.dictationTone, .voca,
                      "Unset tone preference should resolve to voca")
    }

    func testSoundEffectsDisabledSkipsCues() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.soundEffectsEnabled = false

        await appState.startRecording()
        XCTAssertEqual(mocks.soundManager.startSoundCallCount, 0)

        await appState.stopRecordingAndTranscribe()
        XCTAssertEqual(mocks.soundManager.stopSoundCallCount, 0)
    }

    func testShowCursorIndicatorDefault() {
        let (appState, _) = AppState.makeTestState()

        XCTAssertTrue(appState.showCursorIndicator,
                     "Cursor indicator should be shown by default")
    }

    func testTranslationDisabledByDefault() {
        let (appState, _) = AppState.makeTestState()

        XCTAssertFalse(appState.translationEnabled,
                      "Translation should be disabled by default")
    }

    func testSelectedLanguageDefault() {
        let (appState, _) = AppState.makeTestState()

        XCTAssertEqual(appState.selectedLanguage, "auto",
                      "Default language should be 'auto'")
    }

    func testSelectedAudioDeviceDefaultsToSystemDefault() {
        let (appState, _) = AppState.makeTestState()

        XCTAssertEqual(appState.selectedAudioDeviceID, "",
                      "Default audio input should follow the system default")
        XCTAssertEqual(appState.selectedAudioDeviceName, "",
                      "No device name should be persisted for system default")
    }

    func testSelectingAudioDevicePersistsIDAndName() {
        let (appState, _) = AppState.makeTestState()
        let device = AudioDevice(
            id: "test-microphone-uid",
            name: "USB Microphone",
            isDefault: false,
            sampleRate: 48_000,
            channelCount: 1
        )

        appState.selectAudioDevice(device)

        XCTAssertEqual(appState.selectedAudioDeviceID, device.id)
        XCTAssertEqual(appState.selectedAudioDeviceName, device.name)

        appState.selectAudioDevice(nil)

        XCTAssertEqual(appState.selectedAudioDeviceID, "")
        XCTAssertEqual(appState.selectedAudioDeviceName, "")
    }

    func testActivationModeDefault() {
        let (appState, _) = AppState.makeTestState()

        XCTAssertEqual(appState.activationMode, .pushToTalk,
                      "Default activation mode should be push-to-talk")
    }

    func testDoubleTapThresholdDefault() {
        let (appState, _) = AppState.makeTestState()

        XCTAssertEqual(appState.doubleTapThreshold, 0.4,
                      "Default double-tap threshold should be 0.4 seconds")
    }

    func testMaxRecordingDurationDefault() {
        let (appState, _) = AppState.makeTestState()

        XCTAssertEqual(appState.maxRecordingDuration, 60,
                      "Default max recording duration should be 60 seconds")
    }

    func testAvailableModelsPopulated() {
        let (appState, _) = AppState.makeTestState()

        XCTAssertFalse(appState.availableModels.isEmpty,
                      "Available models should be populated on init")

        // The catalog leaves out models whose engine cannot run here at all,
        // so the expected count depends on the machine: Apple Speech needs
        // macOS 26, and Parakeet needs Apple Silicon.
        let runnable = ModelSize.allCases.filter { $0.isAvailableOnThisSystem }
        XCTAssertEqual(appState.availableModels.count, runnable.count,
                      "Should have one entry per model this system can run")

        for model in appState.availableModels {
            XCTAssertTrue(model.size.isAvailableOnThisSystem,
                         "\(model.size.rawValue) cannot run on this system and should not be offered")
        }
    }

    func testSystemCapabilitiesDetected() {
        let (appState, _) = AppState.makeTestState()

        XCTAssertNotNil(appState.systemCapabilities,
                       "System capabilities should be detected on init")
    }

    func testDeviceRecommendedModelSet() {
        let (appState, _) = AppState.makeTestState()

        XCTAssertNotNil(appState.deviceRecommendedModel,
                       "Device recommended model should be set on init")
    }

    func testPermissionManagerIntegration() {
        let (appState, _) = AppState.makeTestState()

        XCTAssertNotNil(appState.permissionManager,
                       "PermissionManager should be initialized")

        let mic = appState.micPermission
        XCTAssertEqual(mic, appState.permissionManager.micPermission,
                      "micPermission should delegate to PermissionManager")
    }

    func testTriggerStartupIdempotent() {
        // Reset the global flag so this test is self-contained regardless of
        // test execution order.
        AppState.hasStartedGlobally = false
        defer { AppState.hasStartedGlobally = false }

        let (appState, _) = AppState.makeTestState()

        appState.triggerStartupIfNeeded()
        appState.triggerStartupIfNeeded()
        appState.triggerStartupIfNeeded()
    }

    func testStartRecordingPassesNilDeviceForSystemDefault() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.selectedAudioDeviceID = ""

        await appState.startRecording()

        XCTAssertNil(mocks.audioEngine.lastPreferredInputDeviceID,
                     "System Default should not pass a preferred input device")
    }

    func testStartRecordingPassesSelectedAudioDeviceID() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.selectedAudioDeviceID = "coreaudio-device-uid"

        await appState.startRecording()

        XCTAssertEqual(mocks.audioEngine.lastPreferredInputDeviceID, "coreaudio-device-uid",
                       "Selected audio device ID should be forwarded to AudioEngine")
    }
}

// MARK: - AppState Error Recovery Tests

@MainActor
final class AppStateErrorRecoveryTests: XCTestCase {

    func testErrorStateCanBeCleared() {
        let (appState, _) = AppState.makeTestState()
        appState.appStatus = .error
        appState.errorMessage = "Test error"

        appState.appStatus = .idle
        appState.errorMessage = nil

        XCTAssertEqual(appState.appStatus, .idle)
        XCTAssertNil(appState.errorMessage)
    }

    func testStartRecordingWhileRecordingTriggersRecovery() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.isRecording = true
        appState.appStatus = .recording

        await appState.startRecording()

        XCTAssertFalse(appState.isRecording,
                      "Recovery path should stop recording")
        XCTAssertEqual(mocks.soundManager.stopSoundCallCount, 1,
                      "Stop sound should play during recovery")
    }
}

// MARK: - AppState Force Recovery Tests

final class AppStateForceRecoveryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "vocamac.hasCompletedOnboarding")
        UserDefaults.standard.removeObject(forKey: "vocamac.launchAtLogin")
    }

    @MainActor
    func testForceRecoveryResetsToIdle() {
        let (appState, mocks) = AppState.makeTestState()

        appState.appStatus = .recording
        appState.isRecording = true
        appState.audioLevel = 0.5

        appState.forceRecovery()

        XCTAssertEqual(appState.appStatus, .idle,
            "appStatus should be idle after force recovery")
        XCTAssertFalse(appState.isRecording,
            "isRecording should be false after force recovery")
        XCTAssertEqual(appState.audioLevel, 0.0,
            "audioLevel should be 0 after force recovery")
        XCTAssertNil(appState.errorMessage,
            "errorMessage should be nil after force recovery")
        XCTAssertEqual(mocks.audioEngine.forceResetCallCount, 1,
            "forceReset should be called on audio engine")
        XCTAssertEqual(mocks.cursorOverlay.hideCallCount, 1,
            "cursor overlay should be hidden")
    }

    @MainActor
    func testForceRecoveryFromErrorState() {
        let (appState, _) = AppState.makeTestState()

        appState.appStatus = .error
        appState.errorMessage = "Something went wrong"

        appState.forceRecovery()

        XCTAssertEqual(appState.appStatus, .idle,
            "appStatus should be idle after force recovery from error")
        XCTAssertNil(appState.errorMessage,
            "errorMessage should be cleared after force recovery")
    }

    @MainActor
    func testForceRecoveryFromProcessingState() {
        let (appState, _) = AppState.makeTestState()

        appState.appStatus = .processing
        appState.isRecording = false

        appState.forceRecovery()

        XCTAssertEqual(appState.appStatus, .idle,
            "appStatus should be idle after force recovery from processing")
    }

    @MainActor
    func testForceRecoveryWhenAlreadyIdle() {
        let (appState, _) = AppState.makeTestState()

        XCTAssertEqual(appState.appStatus, .idle)

        appState.forceRecovery()

        XCTAssertEqual(appState.appStatus, .idle,
            "appStatus should remain idle")
        XCTAssertFalse(appState.isRecording)
        XCTAssertNil(appState.errorMessage)
    }

    @MainActor
    func testForceRecoveryMultipleTimes() {
        let (appState, _) = AppState.makeTestState()
        appState.appStatus = .recording
        appState.isRecording = true

        appState.forceRecovery()
        appState.forceRecovery()
        appState.forceRecovery()

        XCTAssertEqual(appState.appStatus, .idle)
        XCTAssertFalse(appState.isRecording)
    }
}

// MARK: - AppState Recording State Guard Tests

final class AppStateRecordingGuardTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "vocamac.hasCompletedOnboarding")
        UserDefaults.standard.removeObject(forKey: "vocamac.launchAtLogin")
    }

    @MainActor
    func testStartRecordingInErrorStateForceRecovers() async {
        let (appState, _) = AppState.makeTestState()
        appState.appStatus = .error
        appState.errorMessage = "Previous error"

        await appState.startRecording()

        XCTAssertEqual(appState.appStatus, .idle,
            "startRecording in error state should force recover to idle")
        XCTAssertNil(appState.errorMessage,
            "Error message should be cleared after force recovery")
    }

    @MainActor
    func testStartRecordingInProcessingStateForceRecovers() async {
        let (appState, _) = AppState.makeTestState()
        appState.appStatus = .processing

        await appState.startRecording()

        XCTAssertEqual(appState.appStatus, .idle,
            "startRecording in processing state should force recover to idle")
    }

    @MainActor
    func testStopRecordingWhenNotRecordingIsNoop() async {
        let (appState, _) = AppState.makeTestState()
        XCTAssertEqual(appState.appStatus, .idle)
        XCTAssertFalse(appState.isRecording)

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(appState.appStatus, .idle)
        XCTAssertFalse(appState.isRecording)
    }

    @MainActor
    func testStartRecordingFailureResetsRecordingState() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.audioEngine.startRecordingResult = false

        await appState.startRecording()

        XCTAssertEqual(appState.appStatus, .error,
            "a failed audio start is reported, not silently swallowed")
        XCTAssertNotNil(appState.errorMessage,
            "the user needs to know why the hotkey appeared to do nothing")
        XCTAssertFalse(appState.isRecording,
            "failed audio start should clear recording state")
        XCTAssertEqual(appState.audioLevel, 0.0,
            "failed audio start should reset audio level")
        XCTAssertEqual(mocks.cursorOverlay.hideCallCount, 1,
            "failed audio start should hide the cursor overlay")
        XCTAssertEqual(mocks.hotKeyManager.resetKeyStateCallCount, 1,
            "failed audio start should reset hotkey state")
        XCTAssertEqual(mocks.soundManager.startSoundCallCount, 0,
            "failed audio start should not play the start sound")
    }

    @MainActor
    func testInitialStateIsIdle() {
        let (appState, _) = AppState.makeTestState()
        XCTAssertEqual(appState.appStatus, .idle)
        XCTAssertFalse(appState.isRecording)
        XCTAssertEqual(appState.audioLevel, 0.0)
        XCTAssertNil(appState.errorMessage)
    }
}
