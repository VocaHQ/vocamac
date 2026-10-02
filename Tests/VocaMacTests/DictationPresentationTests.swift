import XCTest
@testable import VocaMac

final class OutputConfigurationSummaryTests: XCTestCase {
    private func summary(
        _ profile: WritingProfile, cleanup: Bool = true, rewriting: Bool = true, level: CleanupLevel = .medium
    ) -> OutputConfigurationSummary {
        OutputConfigurationSummary(profile: profile, cleanupEnabled: cleanup, rewritingEnabled: rewriting, level: level)
    }

    func testRawBypassesEveryTransformationEvenWhenGlobalFeaturesAreOn() {
        let value = summary(WritingProfile(format: .email, rules: .passthrough, intent: .professional, cleanup: .raw))
        XCTAssertEqual(value.format, "Exactly as transcribed")
        XCTAssertEqual(value.cleanup, "All text transformations bypassed")
        XCTAssertEqual(value.tone, "As spoken")
    }

    func testFormattingOnlyDoesNotPromiseToneOrCleanup() {
        let value = summary(WritingProfile(format: .email, rules: .passthrough, intent: .professional, cleanup: .off))
        XCTAssertEqual(value.cleanup, "Formatting only · AI cleanup off")
        XCTAssertEqual(value.tone, "As spoken")
    }

    func testBasicCleanupStillExplainsDeterministicRulesWhenAIIsOff() {
        let profile = WritingProfile(format: .plain, rules: .passthrough, intent: .professional)
        let value = summary(profile, cleanup: false)
        XCTAssertEqual(value.cleanup, "Basic filler/correction rules · AI cleanup off")
        XCTAssertEqual(value.tone, "As spoken")
    }

    func testPerAppLevelOverridesGlobalLevelAndNonePreventsTone() {
        let profile = WritingProfile(format: .email, rules: .passthrough, intent: .professional, cleanupLevel: CleanupLevel.none)
        let value = summary(profile, level: .grammar)
        XCTAssertEqual(value.cleanup, "Cleanup off · level None")
        XCTAssertEqual(value.tone, "As spoken")
    }

    func testToneRequiresBothSwitchesAndASupportedFormat() {
        let email = WritingProfile(format: .email, rules: .passthrough, intent: .professional)
        XCTAssertEqual(summary(email).tone, "Formal tone · English only")
        XCTAssertEqual(summary(email, rewriting: false).tone, "As spoken")
        let code = WritingProfile(format: .code, rules: .passthrough, intent: .professional)
        XCTAssertEqual(summary(code).tone, "As spoken")
    }
}

@MainActor
final class DictationPresentationTests: XCTestCase {
    private var state: AppState!
    private var mocks: TestMocks!

    override func setUp() async throws {
        (state, mocks) = AppState.makeTestState()
        mocks.permissionManager.micPermission = .granted
        mocks.permissionManager.accessibilityPermission = .granted
        mocks.permissionManager.inputMonitoringPermission = .granted
        state.selectedModelSize = ModelSize.tiny.rawValue
        state.availableModels = [model(.tiny, downloaded: true)]
    }

    override func tearDown() async throws {
        state = nil
        mocks = nil
        UserDefaults.standard.removeObject(forKey: "vocamac.modelRecommendationPriority")
    }

    private func model(_ size: ModelSize, downloaded: Bool) -> WhisperModelInfo {
        WhisperModelInfo(size: size, filePath: nil, isDownloaded: downloaded, isActive: false, isSupported: true)
    }

    func testLoadedEngineWinsOverAPendingRemotePreference() {
        state.selectedModelSize = ModelSize.customEndpoint.rawValue
        state.currentModel = model(.tiny, downloaded: true)
        XCTAssertFalse(state.speechProcessingIsRemote)
        state.currentModel = model(.customEndpoint, downloaded: true)
        XCTAssertTrue(state.speechProcessingIsRemote)
        XCTAssertEqual(state.speechProcessingDescription, "Audio sent to your endpoint")
    }

    func testRemotePreferenceIsDisclosedBeforeAnyModelHasLoaded() {
        state.currentModel = nil
        state.selectedModelSize = ModelSize.customEndpoint.rawValue
        XCTAssertTrue(state.speechProcessingIsRemote)
    }

    func testReadinessRequiresPermissionsEvenWithALoadedModel() {
        mocks.whisperService.isModelLoaded = true
        XCTAssertTrue(state.isDictationReady)
        mocks.permissionManager.micPermission = .denied
        XCTAssertEqual(state.dictationReadinessTitle, "Microphone access needed")
        XCTAssertFalse(state.isDictationReady)
        mocks.permissionManager.micPermission = .granted
        mocks.permissionManager.accessibilityPermission = .denied
        XCTAssertEqual(state.dictationReadinessTitle, "Text insertion access needed")
    }

    func testIdleUnloadedDownloadedModelRemainsReady() {
        mocks.whisperService.isModelLoaded = false
        XCTAssertEqual(state.dictationReadinessTitle, "Ready")
        state.availableModels = [model(.tiny, downloaded: false)]
        XCTAssertEqual(state.dictationReadinessTitle, "Choose a speech model")
    }

    func testUninitializedCatalogIsNotReportedAsReady() {
        mocks.whisperService.isModelLoaded = false
        state.availableModels = []
        XCTAssertFalse(state.isDictationReady)
        XCTAssertEqual(state.dictationReadinessTitle, "Preparing speech model…")
    }

    func testInsertionCannotBeConfirmedBeforeAnAttempt() {
        state.armOnboardingVerification(.insertion)
        state.confirmOnboardingInsertion()
        XCTAssertFalse(state.onboardingVerification.insertionConfirmed)
        state.onboardingVerification.insertionAttempted = true
        state.confirmOnboardingInsertion()
        XCTAssertTrue(state.onboardingVerification.insertionConfirmed)
        XCTAssertNil(state.onboardingVerification.mode)
    }

    func testShortcutPracticeUsesRealRecordingFlowWithoutInjection() async {
        state.armOnboardingVerification(.shortcut)
        mocks.audioEngine.stopRecordingResult = Array(repeating: 0.1, count: 16_000)
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "This is a shortcut test", duration: 0.1, detectedLanguage: "en", audioLengthSeconds: 1, modelUsed: .tiny
        )
        await state.startRecordingFromActivationShortcut()
        XCTAssertTrue(state.onboardingVerification.shortcutDetected)
        XCTAssertTrue(state.isPracticeRecording)
        XCTAssertFalse(state.onboardingVerification.shortcutDictationWorks)
        await state.stopRecordingAndTranscribe()
        XCTAssertTrue(state.onboardingVerification.microphoneWorks)
        XCTAssertTrue(state.onboardingVerification.shortcutDictationWorks)
        XCTAssertNotNil(state.settingsTestResultText)
        XCTAssertEqual(mocks.textInjector.injectCallCount, 0)
    }

    func testInsertionAttemptDoesNotAutomaticallyClaimSuccess() async {
        state.armOnboardingVerification(.insertion)
        mocks.audioEngine.stopRecordingResult = Array(repeating: 0.1, count: 16_000)
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "Insert these words", duration: 0.1, detectedLanguage: "en", audioLengthSeconds: 1, modelUsed: .tiny
        )
        await state.startRecordingFromActivationShortcut()
        XCTAssertFalse(state.isPracticeRecording)
        await state.stopRecordingAndTranscribe()
        XCTAssertEqual(mocks.textInjector.injectCallCount, 1)
        XCTAssertTrue(state.onboardingVerification.insertionAttempted)
        XCTAssertTrue(state.onboardingVerification.microphoneWorks)
        XCTAssertTrue(state.onboardingVerification.shortcutDictationWorks)
        XCTAssertFalse(state.onboardingVerification.insertionConfirmed)
        state.confirmOnboardingInsertion()
        XCTAssertTrue(state.onboardingVerification.insertionConfirmed)
    }

    func testButtonPracticeDoesNotClaimShortcutVerificationEvenWhenArmed() async {
        state.armOnboardingVerification(.shortcut)
        mocks.audioEngine.stopRecordingResult = Array(repeating: 0.1, count: 16_000)
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "Button practice", duration: 0.1, detectedLanguage: "en", audioLengthSeconds: 1, modelUsed: .tiny
        )
        await state.startRecording(injectResult: false)
        await state.stopRecordingAndTranscribe()
        XCTAssertTrue(state.onboardingVerification.microphoneWorks)
        XCTAssertFalse(state.onboardingVerification.shortcutDetected)
        XCTAssertFalse(state.onboardingVerification.shortcutDictationWorks)
    }

    func testEmptyShortcutRecordingIsNotVerified() async {
        state.armOnboardingVerification(.shortcut)
        mocks.audioEngine.stopRecordingResult = []
        await state.startRecordingFromActivationShortcut()
        await state.stopRecordingAndTranscribe()
        XCTAssertTrue(state.onboardingVerification.shortcutDetected)
        XCTAssertFalse(state.onboardingVerification.shortcutDictationWorks)
        XCTAssertFalse(state.onboardingVerification.microphoneWorks)
    }
}
