// AppStateTests.swift
// VocaMac Tests
//
// Tests for AppState: translation toggle, onboarding, launch at login.

import XCTest
import ServiceManagement
@testable import VocaMac

// MARK: - Translation Toggle Tests

final class TranslationToggleTests: XCTestCase {

    @MainActor
    func testTranslationEnabledDefaultValue() {
        let (appState, _) = AppState.makeTestState()
        XCTAssertFalse(appState.translationEnabled)
    }

    @MainActor
    func testTranslationEnabledCanBeToggled() {
        let (appState, _) = AppState.makeTestState()
        XCTAssertFalse(appState.translationEnabled)

        appState.translationEnabled = true
        XCTAssertTrue(appState.translationEnabled)

        appState.translationEnabled = false
        XCTAssertFalse(appState.translationEnabled)
    }
}


// MARK: - OnboardingStep Tests

final class OnboardingStepTests: XCTestCase {

    func testOnboardingStepOrdering() {
        let steps = OnboardingStep.allCases
        XCTAssertEqual(steps.count, 6)
        XCTAssertEqual(steps[0], .welcome)
        XCTAssertEqual(steps[1], .permissions)
        XCTAssertEqual(steps[2], .modelSetup)
        XCTAssertEqual(steps[3], .hotkeyConfig)
        XCTAssertEqual(steps[4], .quickTest)
        XCTAssertEqual(steps[5], .complete)
    }

    func testOnboardingStepTitles() {
        for step in OnboardingStep.allCases {
            XCTAssertFalse(step.title.isEmpty)
        }
    }

    func testOnboardingStepNumbers() {
        for (index, step) in OnboardingStep.allCases.enumerated() {
            XCTAssertEqual(step.stepNumber, "Step \(index + 1) of \(OnboardingStep.allCases.count)")
        }
    }

    func testOnboardingStepIdentifiable() {
        let steps = OnboardingStep.allCases
        let ids = steps.map { $0.id }
        let uniqueIds = Set(ids)
        XCTAssertEqual(ids.count, uniqueIds.count)
    }

    func testCompletionNavigationStaysEnabledWhileBackgroundWorkFinishes() {
        XCTAssertFalse(
            OnboardingStep.complete.disablesNavigation(
                practiceBusy: true,
                isRecording: true,
                appStatus: .processing
            )
        )
        XCTAssertTrue(
            OnboardingStep.quickTest.disablesNavigation(
                practiceBusy: false,
                isRecording: false,
                appStatus: .processing
            )
        )
    }
}


// MARK: - Launch at Login Tests

final class LaunchAtLoginTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "vocamac.launchAtLogin")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "vocamac.launchAtLogin")
        super.tearDown()
    }

    @MainActor
    func testLaunchAtLoginDefaultsToFalse() {
        let (appState, _) = AppState.makeTestState()
        XCTAssertFalse(appState.launchAtLogin)
    }

    @MainActor
    func testLaunchAtLoginPersistence() {
        UserDefaults.standard.set(true, forKey: "vocamac.launchAtLogin")
        let (appState, _) = AppState.makeTestState()
        XCTAssertTrue(appState.launchAtLogin)
    }

    @MainActor
    func testSetLaunchAtLoginEnableUpdatesPreference() {
        let (appState, _) = AppState.makeTestState()
        XCTAssertFalse(appState.launchAtLogin)

        appState.setLaunchAtLogin(true)

        let expected = SMAppService.mainApp.status == .enabled
        XCTAssertEqual(appState.launchAtLogin, expected)
    }

    @MainActor
    func testSetLaunchAtLoginDisableUpdatesPreference() {
        let (appState, _) = AppState.makeTestState()
        appState.setLaunchAtLogin(true)
        appState.setLaunchAtLogin(false)

        let expected = SMAppService.mainApp.status == .enabled
        XCTAssertEqual(appState.launchAtLogin, expected)
    }

    @MainActor
    func testSetLaunchAtLoginToggleRoundTrip() {
        let (appState, _) = AppState.makeTestState()

        appState.setLaunchAtLogin(true)
        let afterEnable = appState.launchAtLogin

        appState.setLaunchAtLogin(false)
        let afterDisable = appState.launchAtLogin

        if SMAppService.mainApp.status != .enabled {
            XCTAssertFalse(afterDisable,
                "After disabling, launchAtLogin should be false")
        }
        XCTAssertNotNil(afterEnable)
        XCTAssertNotNil(afterDisable)
    }
}

// MARK: - AppState Onboarding Tests

final class AppStateOnboardingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        clearPersistedSettings()
    }

    override func tearDown() {
        clearPersistedSettings()
        super.tearDown()
    }

    private func clearPersistedSettings() {
        [
            "vocamac.hasCompletedOnboarding",
            "vocamac.activationMode",
            "vocamac.hotKeyCode",
            "vocamac.hotKeyModifiers",
            "vocamac.doubleTapThreshold",
            "vocamac.maxRecordingDuration",
        ].forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    @MainActor
    func testOnboardingFlagInitiallyFalse() {
        let (appState, _) = AppState.makeTestState()
        XCTAssertFalse(appState.hasCompletedOnboarding)
    }

    @MainActor
    func testCompleteOnboardingSetsFlagTrue() {
        let (appState, _) = AppState.makeTestState()
        XCTAssertFalse(appState.hasCompletedOnboarding)

        appState.completeOnboarding()

        XCTAssertTrue(appState.hasCompletedOnboarding)
    }

    @MainActor
    func testCompleteOnboardingSyncsHotKeyConfiguration() {
        let (appState, mocks) = AppState.makeTestState()
        appState.activationMode = .doubleTapToggle
        appState.hotKeyCode = 58
        appState.doubleTapThreshold = 0.55
        appState.maxRecordingDuration = 120

        appState.completeOnboarding()

        XCTAssertEqual(mocks.hotKeyManager.updateConfigurationCallCount, 1)
        XCTAssertEqual(mocks.hotKeyManager.lastMode, .doubleTapToggle)
        XCTAssertEqual(mocks.hotKeyManager.lastKeyCode, 58)
        XCTAssertEqual(mocks.hotKeyManager.lastDoubleTapThreshold, 0.55)
        XCTAssertEqual(mocks.hotKeyManager.lastSafetyTimeout, 125.0)
        XCTAssertEqual(mocks.hotKeyManager.resetKeyStateCallCount, 1)
    }

    @MainActor
    func testCompleteOnboardingDoesNotResetHotKeyStateWhileRecording() {
        let (appState, mocks) = AppState.makeTestState()
        appState.isRecording = true

        appState.completeOnboarding()

        XCTAssertEqual(mocks.hotKeyManager.updateConfigurationCallCount, 1)
        XCTAssertEqual(mocks.hotKeyManager.resetKeyStateCallCount, 0)
        XCTAssertTrue(appState.hasCompletedOnboarding)
    }

    @MainActor
    func testSyncHotKeyConfigurationAppliesCurrentSettings() {
        let (appState, mocks) = AppState.makeTestState()
        appState.activationMode = .doubleTapToggle
        appState.hotKeyCode = 54
        appState.doubleTapThreshold = 0.3
        appState.maxRecordingDuration = 30

        appState.syncHotKeyConfiguration()

        XCTAssertEqual(mocks.hotKeyManager.updateConfigurationCallCount, 1)
        XCTAssertEqual(mocks.hotKeyManager.lastMode, .doubleTapToggle)
        XCTAssertEqual(mocks.hotKeyManager.lastKeyCode, 54)
        XCTAssertEqual(mocks.hotKeyManager.lastDoubleTapThreshold, 0.3)
        XCTAssertEqual(mocks.hotKeyManager.lastSafetyTimeout, 35.0)
    }

    @MainActor
    func testSyncHotKeyConfigurationAppliesDefaultSettings() {
        let (appState, mocks) = AppState.makeTestState()

        appState.syncHotKeyConfiguration()

        XCTAssertEqual(mocks.hotKeyManager.updateConfigurationCallCount, 1)
        XCTAssertEqual(mocks.hotKeyManager.lastMode, .pushToTalk)
        XCTAssertEqual(mocks.hotKeyManager.lastKeyCode, 61)
        XCTAssertEqual(mocks.hotKeyManager.lastDoubleTapThreshold, 0.4)
        XCTAssertEqual(mocks.hotKeyManager.lastSafetyTimeout, 65.0)
    }

    @MainActor
    func testOnboardingFlagPersistence() {
        UserDefaults.standard.set(true, forKey: PreferenceKey.onboardingCompleted)

        let (appState, _) = AppState.makeTestState()

        XCTAssertTrue(appState.hasCompletedOnboarding)
    }

    @MainActor
    func testLegacyExplicitFalseCompletionIsRepaired() {
        UserDefaults.standard.set(false, forKey: PreferenceKey.onboardingCompleted)
        let (appState, _) = AppState.makeTestState()

        appState.repairLegacyOnboardingCompletionIfNeeded()

        XCTAssertTrue(appState.hasCompletedOnboarding)
    }

    @MainActor
    func testMissingCompletionKeyStillMeansFirstLaunch() {
        let (appState, _) = AppState.makeTestState()

        appState.repairLegacyOnboardingCompletionIfNeeded()

        XCTAssertFalse(appState.hasCompletedOnboarding)
        XCTAssertNil(UserDefaults.standard.object(forKey: PreferenceKey.onboardingCompleted))
    }

    @MainActor
    func testFirstRunWaitsForUserToRequestMicrophonePermission() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.hasCompletedOnboarding = false
        mocks.permissionManager.micPermission = .notDetermined
        mocks.modelManager.bundledModels = [.tiny]
        appState.selectedModelSize = ModelSize.tiny.rawValue

        await appState.performStartup()

        XCTAssertEqual(mocks.permissionManager.requestMicPermissionCallCount, 0)
        appState.requestMicrophonePermission()
        XCTAssertEqual(mocks.permissionManager.requestMicPermissionCallCount, 1)
    }

    @MainActor
    func testPerformStartupClearsRetiredEngineStateThroughTheFacade() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.modelManager.bundledModels = [.tiny]
        appState.selectedModelSize = ModelSize.tiny.rawValue

        await appState.performStartup()

        // Asked through SpeechTranscribing, never by reaching past the router
        // into an individual engine service (AGENTS.md service-layer rule).
        XCTAssertEqual(mocks.whisperService.removeRetiredEngineStateCallCount, 1)
    }

    @MainActor
    func testPerformStartupInstallsBundledTinyModelBeforeDownload() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.modelManager.bundledModels = [.tiny]
        appState.selectedModelSize = ModelSize.tiny.rawValue

        await appState.performStartup()

        // Bundled model should have been installed
        XCTAssertEqual(mocks.modelManager.installedBundledModels, [.tiny])
        // WhisperKit handles tokenizer fetching internally — we no longer
        // pre-validate tokenizer assets before loading. Asserting that
        // ensuredTokenizerSizes is empty confirms we removed the incorrect check.
        XCTAssertEqual(mocks.modelManager.ensuredTokenizerSizes, [])
        XCTAssertEqual(mocks.whisperService.loadedModelName, "openai_whisper-tiny")
    }
}

// MARK: - AppState Model Loading Tests

final class AppStateModelLoadingTests: XCTestCase {

    private static let ownedDefaultsKeys = [
        "vocamac.selectedModelSize",
        "vocamac.selectedLanguage",
    ]

    override func setUp() {
        super.setUp()
        Self.ownedDefaultsKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        Self.ownedDefaultsKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    @MainActor
    func testSetupKeepsLargeSupportedWhenMediumIsNotRecommended() {
        let modelManager = MockModelManager()
        modelManager.defaultModel = "openai_whisper-large-v3-v20240930"
        modelManager.supportedModelNames = [
            "openai_whisper-tiny",
            "openai_whisper-base",
            "openai_whisper-small",
            "openai_whisper-large-v3-v20240930",
            "openai_whisper-large-v3-v20240930_626MB",
        ]

        let (appState, _) = AppState.makeTestState(modelManager: modelManager)

        XCTAssertEqual(appState.deviceRecommendedModel, "openai_whisper-large-v3-v20240930")
        XCTAssertNil(appState.availableModels.first(where: { $0.size == .medium }))
        XCTAssertEqual(
            appState.availableModels.first(where: { $0.size == .largeV3Latest })?.isSupported,
            true
        )
    }

    @MainActor
    func testFailedModelSwitchShowsErrorAndRestoresPreviousModel() async {
        UserDefaults.standard.set(ModelSize.small.rawValue, forKey: "vocamac.selectedModelSize")

        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.small, .medium]

        let whisperService = MockWhisperService()
        whisperService.loadedModelName = "openai_whisper-small"
        whisperService.isModelLoaded = true
        let loadError = NSError(
            domain: "VocaMacTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "CoreML rejected model"]
        )
        whisperService.loadResponses = [
            .failure(loadError),
            .success("openai_whisper-small"),
        ]

        let (appState, mocks) = AppState.makeTestState(
            modelManager: modelManager,
            whisperService: whisperService
        )

        await appState.loadModel(.medium)

        XCTAssertEqual(
            mocks.whisperService.loadRequests.map { $0.name },
            ["openai_whisper-medium", "openai_whisper-small"]
        )
        XCTAssertEqual(appState.appStatus, .error)
        XCTAssertTrue(appState.errorMessage?.contains("Failed to load Medium") == true)
        XCTAssertEqual(appState.currentModel?.size, .small)
        XCTAssertEqual(appState.selectedModelSize, ModelSize.small.rawValue)
        XCTAssertEqual(
            appState.availableModels.first(where: { $0.size == .small })?.isActive,
            true
        )
        XCTAssertEqual(
            appState.availableModels.first(where: { $0.size == .medium })?.isLoading,
            false
        )
    }

    @MainActor
    func testLoadingWithNoSizeUsesTheStoredPreferenceNotEngineAutoSelect() async {
        UserDefaults.standard.set(ModelSize.small.rawValue, forKey: "vocamac.selectedModelSize")

        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.small]

        let whisperService = MockWhisperService()
        whisperService.loadResponses = [.success("openai_whisper-small")]

        let (appState, mocks) = AppState.makeTestState(
            modelManager: modelManager,
            whisperService: whisperService
        )

        await appState.loadModel()

        // A concrete model and folder, rather than nil to let the engine pick
        // and fetch its own copy with no progress reporting.
        XCTAssertEqual(mocks.whisperService.loadRequests.count, 1)
        XCTAssertEqual(mocks.whisperService.loadRequests.first?.name, "openai_whisper-small")
        XCTAssertNotNil(mocks.whisperService.loadRequests.first?.folder)
        XCTAssertEqual(appState.currentModel?.size, .small)
    }

    @MainActor
    func testLoadingAMissingModelDownloadsItFirst() async {
        let modelManager = MockModelManager()
        modelManager.downloadedModels = []

        let whisperService = MockWhisperService()
        whisperService.loadResponses = [.success("openai_whisper-small")]

        let (appState, mocks) = AppState.makeTestState(
            modelManager: modelManager,
            whisperService: whisperService
        )

        await appState.loadModel(.small)

        // Fetched with real progress rather than left to the engine to pull
        // down silently, and loaded from our own cache afterwards.
        XCTAssertEqual(modelManager.downloadRequests, [.small])
        XCTAssertEqual(mocks.whisperService.loadRequests.count, 1)
        XCTAssertNotNil(mocks.whisperService.loadRequests.first?.folder)
        XCTAssertEqual(appState.currentModel?.size, .small)
    }

    @MainActor
    func testLoadingAMissingModelPrefersTheBundledCopyOverDownloading() async {
        let modelManager = MockModelManager()
        modelManager.downloadedModels = []
        modelManager.bundledModels = [.small]

        let whisperService = MockWhisperService()
        whisperService.loadResponses = [.success("openai_whisper-small")]

        let (appState, _) = AppState.makeTestState(
            modelManager: modelManager,
            whisperService: whisperService
        )

        await appState.loadModel(.small)

        XCTAssertEqual(modelManager.installedBundledModels, [.small])
        XCTAssertTrue(modelManager.downloadRequests.isEmpty)
        XCTAssertEqual(appState.currentModel?.size, .small)
    }

    @MainActor
    func testAFailedDownloadStopsTheLoadInsteadOfLoadingNothing() async {
        struct Boom: LocalizedError {
            var errorDescription: String? { "network went away" }
        }

        let modelManager = MockModelManager()
        modelManager.downloadedModels = []
        modelManager.downloadError = Boom()

        let whisperService = MockWhisperService()

        let (appState, mocks) = AppState.makeTestState(
            modelManager: modelManager,
            whisperService: whisperService
        )

        await appState.loadModel(.small)

        XCTAssertEqual(modelManager.downloadRequests, [.small])
        // The engine is never asked to load a model whose files are absent.
        XCTAssertTrue(mocks.whisperService.loadRequests.isEmpty)
        XCTAssertEqual(appState.errorMessage?.contains("network went away"), true)
        XCTAssertEqual(
            appState.availableModels.first(where: { $0.size == .small })?.isLoading,
            false
        )
    }

    @MainActor
    func testLowMemoryGateRefusesMediumBeforeWhisperWithoutTouchingLoadedModel() async {
        UserDefaults.standard.set(ModelSize.small.rawValue, forKey: "vocamac.selectedModelSize")

        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.small, .medium]

        let whisperService = MockWhisperService()
        whisperService.loadResponses = [
            .success("openai_whisper-small"),
        ]

        let (appState, mocks) = AppState.makeTestState(
            modelManager: modelManager,
            whisperService: whisperService
        )

        await appState.loadModel(.small)
        let loadsAfterSmall = mocks.whisperService.loadRequests.count
        XCTAssertEqual(appState.currentModel?.size, .small)
        XCTAssertTrue(mocks.whisperService.isModelLoaded)

        appState.modelFitsInMemory = { size, _ in size != .medium }
        await appState.loadModel(.medium)

        XCTAssertTrue(
            appState.errorMessage?.contains("Not enough") == true
                || appState.errorMessage?.localizedCaseInsensitiveContains("free memory") == true
        )
        XCTAssertEqual(mocks.whisperService.loadRequests.count, loadsAfterSmall)
        XCTAssertFalse(
            mocks.whisperService.loadRequests.map { $0.name }.contains("openai_whisper-medium")
        )
        XCTAssertEqual(appState.currentModel?.size, .small)
        XCTAssertEqual(appState.selectedModelSize, ModelSize.small.rawValue)
        XCTAssertTrue(mocks.whisperService.isModelLoaded)
        XCTAssertEqual(mocks.whisperService.loadedModelName, "openai_whisper-small")
    }

    @MainActor
    func testDeleteModelRemovesDownloadedModel() async {
        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.small, .medium]
        let (appState, _) = AppState.makeTestState(modelManager: modelManager)

        await appState.deleteModel(.medium)

        XCTAssertEqual(modelManager.deletedModels, [.medium])
        XCTAssertEqual(appState.availableModels.first(where: { $0.size == .medium })?.isDownloaded, false)
        XCTAssertNil(appState.errorMessage)
    }

    @MainActor
    func testDeleteModelRefusesToDeleteTheActiveModel() async {
        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.small]
        let (appState, _) = AppState.makeTestState(modelManager: modelManager)

        await appState.loadModel(.small)
        await appState.deleteModel(.small)

        XCTAssertTrue(modelManager.deletedModels.isEmpty)
        XCTAssertEqual(appState.availableModels.first(where: { $0.size == .small })?.isDownloaded, true)
        XCTAssertTrue(appState.errorMessage?.contains("active model") == true)
    }

    @MainActor
    func testDeleteModelRefusesToDeleteAModelThatIsLoading() async {
        // A model mid-load or mid-download must not have its files pulled out
        // from under the in-flight read.
        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.small]
        let (appState, _) = AppState.makeTestState(modelManager: modelManager)
        let index = appState.availableModels.firstIndex(where: { $0.size == .small })!
        appState.availableModels[index].isLoading = true

        await appState.deleteModel(.small)

        XCTAssertTrue(modelManager.deletedModels.isEmpty)
        XCTAssertTrue(appState.errorMessage?.contains("loading") == true)
    }

    @MainActor
    func testDeleteModelSurfacesUnderlyingError() async {
        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.small]
        modelManager.deleteModelError = NSError(
            domain: "VocaMacTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Permission denied"]
        )
        let (appState, _) = AppState.makeTestState(modelManager: modelManager)

        await appState.deleteModel(.small)

        XCTAssertTrue(appState.errorMessage?.contains("Permission denied") == true)
        XCTAssertEqual(appState.availableModels.first(where: { $0.size == .small })?.isDownloaded, true)
    }

    @MainActor
    func testConcurrentModelDownloadsAreSerialized() async throws {
        let modelManager = MockModelManager()
        modelManager.downloadDelayNanoseconds = 50_000_000
        let (appState, _) = AppState.makeTestState(modelManager: modelManager)

        async let firstDownload: Void = appState.downloadModel(.small)
        try await Task.sleep(nanoseconds: 5_000_000)
        async let secondDownload: Void = appState.downloadModel(.medium)

        await firstDownload
        await secondDownload

        XCTAssertEqual(modelManager.downloadRequests, [.small, .medium])
        XCTAssertEqual(modelManager.maxConcurrentDownloadCount, 1)
        XCTAssertEqual(modelManager.downloadedModels, [.small, .medium])
    }

    @MainActor
    func testConcurrentModelLoadsAreSerialized() async throws {
        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.small, .medium]
        let whisperService = MockWhisperService()
        whisperService.loadDelayNanoseconds = 50_000_000
        let (appState, _) = AppState.makeTestState(
            modelManager: modelManager,
            whisperService: whisperService
        )

        async let firstLoad: Void = appState.loadModel(.small)
        try await Task.sleep(nanoseconds: 5_000_000)
        async let secondLoad: Void = appState.loadModel(.medium)

        await firstLoad
        await secondLoad

        XCTAssertEqual(
            whisperService.loadRequests.map { $0.name },
            ["openai_whisper-small", "openai_whisper-medium"]
        )
        XCTAssertEqual(whisperService.maxConcurrentLoadCount, 1)
        XCTAssertEqual(appState.currentModel?.size, .medium)
    }

    @MainActor
    func testStartupFallsBackFromUnsupportedMediumPreference() async {
        UserDefaults.standard.set(ModelSize.medium.rawValue, forKey: "vocamac.selectedModelSize")

        let modelManager = MockModelManager()
        modelManager.defaultModel = "openai_whisper-large-v3-v20240930"
        modelManager.supportedModelNames = [
            "openai_whisper-tiny",
            "openai_whisper-base",
            "openai_whisper-small",
            "openai_whisper-large-v3-v20240930",
        ]
        modelManager.downloadedModels = [.small, .medium]

        let whisperService = MockWhisperService()
        whisperService.loadedModelName = nil
        whisperService.isModelLoaded = false

        let (appState, mocks) = AppState.makeTestState(
            modelManager: modelManager,
            whisperService: whisperService
        )

        await appState.performStartup()

        XCTAssertEqual(mocks.whisperService.loadRequests.first?.name, "openai_whisper-small")
        XCTAssertEqual(appState.selectedModelSize, ModelSize.small.rawValue)
        XCTAssertEqual(appState.currentModel?.size, .small)
    }

    @MainActor
    func testStartupFallbackStaysOnTheSameEngine() async {
        UserDefaults.standard.set(ModelSize.medium.rawValue, forKey: "vocamac.selectedModelSize")

        // Apple Speech is supported and always counts as downloaded, and it
        // sits after the Whisper models in the catalog. A Whisper user whose
        // preference became unsupported should still land on Whisper.
        let modelManager = MockModelManager()
        modelManager.supportedModelNames = [
            "openai_whisper-tiny",
            "openai_whisper-small",
            "apple-speech",
        ]
        modelManager.downloadedModels = [.tiny, .small, .medium, .appleSpeech]

        let whisperService = MockWhisperService()
        whisperService.loadedModelName = nil
        whisperService.isModelLoaded = false

        let (appState, mocks) = AppState.makeTestState(
            modelManager: modelManager,
            whisperService: whisperService
        )

        await appState.performStartup()

        XCTAssertEqual(appState.currentModel?.size, .small)
        XCTAssertEqual(mocks.whisperService.loadRequests.first?.name, "openai_whisper-small")
    }

    // MARK: - Language-bound model reloading

    @MainActor
    func testLanguageChangeReloadsALanguageBoundModel() async {
        // SenseVoice takes its recognition language when the recognizer is
        // built, so the change only lands on reload.
        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.senseVoiceSmall]
        let (appState, mocks) = AppState.makeTestState(modelManager: modelManager)

        await appState.loadModel(.senseVoiceSmall)
        XCTAssertEqual(appState.currentModel?.size, .senseVoiceSmall)
        let loadsAfterInitial = mocks.whisperService.loadRequests.count

        appState.selectedLanguage = "zh"
        await appState.reloadModelForLanguageChangeIfNeeded()

        XCTAssertEqual(mocks.whisperService.loadRequests.count, loadsAfterInitial + 1)
        XCTAssertEqual(mocks.whisperService.loadRequests.last?.name, "sense-voice-small")
    }

    @MainActor
    func testLanguageChangeDoesNotReloadAMonolingualONNXModel() async {
        // Moonshine is English-only, so it has no language to rebind and
        // should not pay for a reload.
        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.moonshineTiny]
        let (appState, mocks) = AppState.makeTestState(modelManager: modelManager)

        await appState.loadModel(.moonshineTiny)
        let loadsAfterInitial = mocks.whisperService.loadRequests.count

        appState.selectedLanguage = "ru"
        await appState.reloadModelForLanguageChangeIfNeeded()

        XCTAssertEqual(mocks.whisperService.loadRequests.count, loadsAfterInitial)
    }

    @MainActor
    func testLanguageChangeDoesNotReloadWhisperModel() async {
        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.tiny]
        let (appState, mocks) = AppState.makeTestState(modelManager: modelManager)

        await appState.loadModel(.tiny)
        let loadsAfterInitial = mocks.whisperService.loadRequests.count

        appState.selectedLanguage = "ru"
        await appState.reloadModelForLanguageChangeIfNeeded()

        // Whisper takes the language per transcription — no reload needed.
        XCTAssertEqual(mocks.whisperService.loadRequests.count, loadsAfterInitial)
    }

    @MainActor
    func testOnboardingLanguageChangeDoesNotLoadStaleRecommendation() async throws {
        let modelManager = MockModelManager()
        modelManager.downloadDelayNanoseconds = 100_000_000
        let (appState, mocks) = AppState.makeTestState(modelManager: modelManager)
        appState.selectedLanguage = "en"

        let englishPreparation = Task { @MainActor in
            await appState.prepareOnboardingRecommendedModel()
        }
        for _ in 0..<100 where modelManager.downloadRequests.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(modelManager.downloadRequests.first, .parakeetTdtCtc110m)

        appState.selectedLanguage = "ru"
        await appState.languageDidChange()
        await englishPreparation.value

        XCTAssertEqual(modelManager.downloadRequests, [.parakeetTdtCtc110m, .gigaamV3])
        XCTAssertEqual(modelManager.cancelledDownloads, [.parakeetTdtCtc110m])
        XCTAssertEqual(mocks.whisperService.loadRequests.map(\.name), ["gigaam-v3-russian"])
        XCTAssertEqual(appState.currentModel?.size, .gigaamV3)
    }

    @MainActor
    func testCancellingQueuedOnboardingPreparationDoesNotInvalidateActiveLoad() async throws {
        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.medium, .parakeetTdtCtc110m]
        let whisperService = MockWhisperService()
        whisperService.loadDelayNanoseconds = 100_000_000
        let (appState, _) = AppState.makeTestState(
            modelManager: modelManager,
            whisperService: whisperService
        )
        appState.selectedLanguage = "en"

        let unrelatedLoad = Task { @MainActor in await appState.loadModel(.medium) }
        for _ in 0..<100 where whisperService.loadRequests.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let onboardingPreparation = Task { @MainActor in
            await appState.prepareOnboardingRecommendedModel()
        }
        for _ in 0..<100 where !appState.isPreparingOnboardingModel {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        appState.cancelOnboardingModelPreparation()
        await unrelatedLoad.value
        await onboardingPreparation.value

        XCTAssertEqual(appState.currentModel?.size, .medium)
        XCTAssertEqual(whisperService.loadRequests.map(\.name), ["openai_whisper-medium"])
        XCTAssertFalse(appState.isPreparingOnboardingModel)
    }

    @MainActor
    func testCancelledQueuedOnboardingTaskClearsPreparationState() async throws {
        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.medium, .parakeetTdtCtc110m]
        let whisperService = MockWhisperService()
        whisperService.loadDelayNanoseconds = 100_000_000
        let (appState, _) = AppState.makeTestState(
            modelManager: modelManager,
            whisperService: whisperService
        )
        appState.selectedLanguage = "en"

        let unrelatedLoad = Task { @MainActor in await appState.loadModel(.medium) }
        for _ in 0..<100 where whisperService.loadRequests.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let onboardingPreparation = Task { @MainActor in
            await appState.prepareOnboardingRecommendedModel()
        }
        for _ in 0..<100 where !appState.isPreparingOnboardingModel {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        onboardingPreparation.cancel()
        await onboardingPreparation.value
        await unrelatedLoad.value

        XCTAssertFalse(appState.isPreparingOnboardingModel)
        XCTAssertEqual(appState.currentModel?.size, .medium)
        XCTAssertEqual(whisperService.loadRequests.map(\.name), ["openai_whisper-medium"])
    }

    @MainActor
    func testDuplicateLanguageChangeNotificationsReloadOnlyOnce() async {
        // Settings and the onboarding wizard both watch selectedLanguage, and
        // the wizard is opened from Settings, so one change fires both.
        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.senseVoiceSmall]
        let (appState, mocks) = AppState.makeTestState(modelManager: modelManager)

        await appState.loadModel(.senseVoiceSmall)
        let loadsAfterInitial = mocks.whisperService.loadRequests.count

        appState.selectedLanguage = "zh"
        await appState.languageDidChange()
        await appState.languageDidChange()

        XCTAssertEqual(mocks.whisperService.loadRequests.count, loadsAfterInitial + 1)

        // A genuinely new language is still handled.
        appState.selectedLanguage = "ja"
        await appState.languageDidChange()

        XCTAssertEqual(mocks.whisperService.loadRequests.count, loadsAfterInitial + 2)
    }

    @MainActor
    func testCancellingAnActiveOnboardingLoadRestoresThePreviousModel() async throws {
        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.medium, .parakeetTdtCtc110m]
        let whisperService = MockWhisperService()
        let (appState, _) = AppState.makeTestState(
            modelManager: modelManager,
            whisperService: whisperService
        )
        appState.selectedLanguage = "en"

        await appState.loadModel(.medium)
        XCTAssertEqual(appState.currentModel?.size, .medium)

        whisperService.loadDelayNanoseconds = 100_000_000
        let loadsBeforeOnboarding = whisperService.loadRequests.count
        let preparation = Task { @MainActor in
            await appState.prepareOnboardingRecommendedModel()
        }
        for _ in 0..<100 where whisperService.loadRequests.count == loadsBeforeOnboarding {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        appState.cancelOnboardingModelPreparation()
        await preparation.value

        // Cancelling must not leave the app with nothing loaded.
        XCTAssertEqual(appState.currentModel?.size, .medium)
        XCTAssertTrue(whisperService.isModelLoaded)
        XCTAssertEqual(whisperService.loadRequests.last?.name, "openai_whisper-medium")
        XCTAssertFalse(appState.isPreparingOnboardingModel)
    }

    @MainActor
    func testCancellingAnActiveOnboardingLoadDoesNotPublishStaleModel() async throws {
        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.parakeetTdtCtc110m]
        let whisperService = MockWhisperService()
        whisperService.loadDelayNanoseconds = 100_000_000
        let (appState, _) = AppState.makeTestState(
            modelManager: modelManager,
            whisperService: whisperService
        )
        appState.selectedLanguage = "en"

        let preparation = Task { @MainActor in
            await appState.prepareOnboardingRecommendedModel()
        }
        for _ in 0..<100 where whisperService.loadRequests.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        appState.cancelOnboardingModelPreparation()
        await preparation.value

        XCTAssertNil(appState.currentModel)
        XCTAssertFalse(whisperService.isModelLoaded)
        XCTAssertFalse(appState.isPreparingOnboardingModel)
    }
}
