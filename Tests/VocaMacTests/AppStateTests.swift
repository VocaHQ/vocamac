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
        XCTAssertEqual(steps.count, 5)
        XCTAssertEqual(steps[0], .welcome)
        XCTAssertEqual(steps[1], .permissions)
        XCTAssertEqual(steps[2], .hotkeyConfig)
        XCTAssertEqual(steps[3], .quickTest)
        XCTAssertEqual(steps[4], .complete)
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
        UserDefaults.standard.set(true, forKey: "vocamac.hasCompletedOnboarding")

        let (appState, _) = AppState.makeTestState()

        XCTAssertTrue(appState.hasCompletedOnboarding)
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

        appState.modelFitsInMemory = { $0 != .medium }
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
}
