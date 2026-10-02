import XCTest
@testable import VocaMac

final class OutputConfigurationSummaryTests: XCTestCase {
    private func summary(
        _ profile: WritingProfile, cleanup: Bool = true, rewriting: Bool = true, level: CleanupLevel = .medium,
        language: String = "en"
    ) -> OutputConfigurationSummary {
        OutputConfigurationSummary(
            profile: profile, cleanupEnabled: cleanup, rewritingEnabled: rewriting, level: level,
            recognitionLanguage: language
        )
    }

    func testRawIsDescribedAloneEvenWhenGlobalFeaturesAreOn() {
        let value = summary(WritingProfile(format: .email, rules: .passthrough, intent: .professional, cleanup: .raw))
        XCTAssertEqual(value.description, "Exactly as transcribed")
    }

    func testFormattingOnlyPromisesNeitherCleanupNorTone() {
        let value = summary(WritingProfile(format: .email, rules: .passthrough, intent: .professional, cleanup: .off))
        XCTAssertEqual(value.description, "Email format · No cleanup")
    }

    func testFillersStillGoWhenSmartCleanupIsOff() {
        let profile = WritingProfile(format: .plain, rules: .passthrough, intent: .professional)
        XCTAssertEqual(summary(profile, cleanup: false).description, "Plain format · Fillers removed")
        // Light keeps every spoken sound, so without the model nothing is cleaned.
        XCTAssertEqual(summary(profile, cleanup: false, level: .light).description, "Plain format · No cleanup")
    }

    func testPerAppLevelOverridesGlobalLevelAndNonePreventsTone() {
        let profile = WritingProfile(format: .email, rules: .passthrough, intent: .professional, cleanupLevel: CleanupLevel.none)
        XCTAssertEqual(summary(profile, level: .grammar).description, "Email format · No cleanup")
    }

    func testToneRequiresBothSwitchesAndASupportedFormat() {
        let email = WritingProfile(format: .email, rules: .passthrough, intent: .professional)
        XCTAssertEqual(summary(email).description, "Email format · Medium cleanup · Formal tone")
        XCTAssertNil(summary(email, rewriting: false).tone)
        XCTAssertNil(summary(email, cleanup: false).tone)
        let code = WritingProfile(format: .code, rules: .passthrough, intent: .professional)
        XCTAssertEqual(summary(code).description, "Code format · Medium cleanup")
    }

    func testToneIsPromisedOnlyForEnglish() {
        // The pipeline rewrites English only.
        let email = WritingProfile(format: .email, rules: .passthrough, intent: .professional)
        XCTAssertEqual(summary(email, language: "en-US").tone, "Formal tone")
        XCTAssertEqual(summary(email, language: "auto").tone, "Formal tone in English")
        XCTAssertEqual(summary(email, language: "hi").description, "Email format · Medium cleanup")
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
        UserDefaults.standard.removeObject(forKey: PreferenceKey.modelRecommendationPriority)
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

    // MARK: - Recommendation, website rules, and what leaves this Mac

    func testOnboardingPreparesTheModelItShows() async {
        // English and Hindi show a multilingual model. The button used to
        // work from the recognition language alone and fetch an English one.
        state.availableModels = [.tiny, .small, .parakeetTdtCtc110m].map { model($0, downloaded: $0 == .tiny) }
        state.selectedLanguage = "en"
        state.spokenLanguages = ["en", "hi"]
        let shown = state.speechModelRecommendation?.model
        XCTAssertEqual(shown, .small)
        await state.prepareOnboardingRecommendedModel()
        XCTAssertEqual(mocks.modelManager.downloadRequests, [.small])
    }

    func testOnboardingLoadsTheShownModelUnderAnotherPreference() async {
        // Highest accuracy shows Parakeet v2 where balance would show the
        // 110M. The post-download check used the balanced pick and returned
        // with the shown model downloaded but never loaded.
        state.availableModels = [.tiny, .parakeetTdtCtc110m, .parakeetV2].map { model($0, downloaded: $0 == .tiny) }
        state.setOnboardingSpokenLanguages(["en"])
        state.modelRecommendationPriority = .accuracy
        XCTAssertEqual(state.speechModelRecommendation?.model, .parakeetV2)
        await state.prepareOnboardingRecommendedModel()
        XCTAssertEqual(mocks.modelManager.downloadRequests, [.parakeetV2])
        XCTAssertEqual(state.currentModel?.size, .parakeetV2)
    }

    func testOnboardingLanguagesSetTheRecognitionLanguage() {
        state.setOnboardingSpokenLanguages(["hi"])
        XCTAssertEqual(state.selectedLanguage, "hi")
        state.setOnboardingSpokenLanguages(["hi", "en"])
        XCTAssertEqual(state.selectedLanguage, TranscriptionLanguage.auto.code)
        XCTAssertEqual(state.spokenLanguages, ["hi", "en"])
        state.setOnboardingSpokenLanguages([])
        XCTAssertEqual(state.selectedLanguage, TranscriptionLanguage.auto.code)
    }

    func testMenuSummaryFollowsAMatchingWebsiteRule() async throws {
        let reader = MockScreenContextReader()
        reader.targetAppDocumentURL = URL(string: "https://mail.example.com/compose")
        let (state, mocks) = AppState.makeTestState(screenContextReader: reader)
        defer { state.websiteStyleBindings = [] }
        mocks.frontmostAppResolver.frontmostApp = RunningAppSnapshot(displayName: "Safari", bundleIdentifier: "com.apple.Safari")
        state.writingStyleEnabled = true
        state.transcriptCleanupEnabled = true
        state.websiteStyleBindings = [
            WebsiteStyleBinding(hostPattern: "mail.example.com", displayName: "Mail", style: .email, cleanup: .off),
        ]

        // Without the page address the summary can only know the app.
        state.refreshActiveWritingStyle()
        XCTAssertEqual(state.nextOutputSummary.format, "Plain format")

        state.refreshActiveWritingStyle(readingWebsite: true)
        for _ in 0..<200 where state.activeWritingStyle.style != .email {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(state.nextOutputSummary.description, "Email format · No cleanup")
    }

    func testRemoteNoticeNamesOnlyWhatLeavesThisMac() {
        XCTAssertNil(state.nextDictationRemoteNotice)
        state.currentModel = model(.customEndpoint, downloaded: true)
        XCTAssertEqual(state.nextDictationRemoteNotice, "Audio is sent to your endpoint")
    }
}
