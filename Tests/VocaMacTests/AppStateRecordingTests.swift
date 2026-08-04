// AppStateRecordingTests.swift
// VocaMac
//
// Tests for AppState recording flow and state transitions.

import XCTest
@testable import VocaMac

// MARK: - AppState Recording State Transition Tests

@MainActor
final class AppStateRecordingTests: XCTestCase {

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

    func testSoundEffectsEnabledDefault() {
        let (appState, _) = AppState.makeTestState()

        XCTAssertTrue(appState.soundEffectsEnabled,
                     "Sound effects should be enabled by default")
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

    func testPostProcessingDisabledByDefault() {
        let (appState, _) = AppState.makeTestState()

        XCTAssertFalse(appState.postProcessingEnabled,
                      "Local AI post-processing should be disabled by default")
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
        XCTAssertEqual(appState.availableModels.count, ModelSize.allCases.count,
                      "Should have one entry per ModelSize")
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

    func testPostProcessingEnabledInjectsProcessedText() async {
        let postProcessor = MockTextPostProcessor()
        postProcessor.result = "Email Namrata about the launch."
        let whisperService = MockWhisperService()
        whisperService.mockTranscriptionResult = VocaTranscription(
            text: "um email nam rata about the launch",
            duration: 1,
            detectedLanguage: "en",
            audioLengthSeconds: 1,
            modelUsed: .tiny
        )
        let (appState, mocks) = AppState.makeTestState(
            whisperService: whisperService,
            textPostProcessor: postProcessor
        )
        appState.postProcessingEnabled = true
        appState.postProcessingRunnerPath = "/mock/llama-cli"
        appState.postProcessingModelID = "gemma-3-1b-q4"
        appState.postProcessingInstructions = "Keep it concise."
        appState.isRecording = true
        appState.appStatus = .recording
        mocks.audioEngine.stopRecordingResult = [0.1, 0.2]

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(postProcessor.improveCallCount, 1)
        XCTAssertEqual(postProcessor.lastText, "um email nam rata about the launch")
        XCTAssertEqual(postProcessor.lastConfiguration?.runnerPath, "/mock/llama-cli")
        XCTAssertEqual(postProcessor.lastConfiguration?.modelID, "gemma-3-1b-q4")
        XCTAssertEqual(postProcessor.lastConfiguration?.instructions, "Keep it concise.")
        XCTAssertEqual(mocks.textInjector.lastInjectedText, "Email Namrata about the launch.")
        XCTAssertEqual(appState.lastTranscription?.text, "Email Namrata about the launch.")
    }

    func testPreparePostProcessingModelEnablesRewrite() async {
        let postProcessor = MockTextPostProcessor()
        let (appState, _) = AppState.makeTestState(textPostProcessor: postProcessor)
        appState.postProcessingRunnerPath = LocalLLMPostProcessor.defaultRunnerPath
        appState.postProcessingModelID = "gemma-3-1b-q4"
        appState.postProcessingInstructions = "Keep it tidy."

        await appState.preparePostProcessingModel()

        XCTAssertEqual(postProcessor.prepareCallCount, 1)
        XCTAssertEqual(
            postProcessor.lastPrepareConfiguration?.runnerPath,
            LocalLLMPostProcessor.defaultRunnerPath
        )
        XCTAssertEqual(postProcessor.lastPrepareConfiguration?.modelID, "gemma-3-1b-q4")
        XCTAssertEqual(postProcessor.lastPrepareConfiguration?.instructions, "Keep it tidy.")
        XCTAssertTrue(appState.postProcessingEnabled)
        XCTAssertEqual(appState.postProcessingSetupMessage, "Gemma 3 1B ready.")
    }

    func testPostProcessingFailureInjectsRawText() async {
        let postProcessor = MockTextPostProcessor()
        postProcessor.error = TextPostProcessingError.emptyOutput
        let whisperService = MockWhisperService()
        whisperService.mockTranscriptionResult = VocaTranscription(
            text: "raw transcription",
            duration: 1,
            detectedLanguage: "en",
            audioLengthSeconds: 1,
            modelUsed: .tiny
        )
        let (appState, mocks) = AppState.makeTestState(
            whisperService: whisperService,
            textPostProcessor: postProcessor
        )
        appState.postProcessingEnabled = true
        appState.isRecording = true
        appState.appStatus = .recording
        mocks.audioEngine.stopRecordingResult = [0.1, 0.2]

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.textInjector.lastInjectedText, "raw transcription")
        XCTAssertEqual(appState.lastTranscription?.text, "raw transcription")
        XCTAssertEqual(appState.appStatus, .idle)
        XCTAssertTrue(appState.errorMessage?.contains("Post-processing failed") == true)
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

        XCTAssertEqual(appState.appStatus, .idle,
            "failed audio start should return app state to idle")
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
