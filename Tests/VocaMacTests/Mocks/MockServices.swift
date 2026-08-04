// MockServices.swift
// VocaMac Tests
//
// Mock implementations of service protocols for unit testing.
// These avoid triggering real system side effects (sounds, permissions, mic, etc.).

import Foundation
import Combine
@testable import VocaMac

// MARK: - MockAudioEngine

final class MockAudioEngine: AudioRecording {
    var isCurrentlyRecording = false
    var onAudioLevel: ((Float) -> Void)?
    var onSilenceDetected: (() -> Void)?
    var onMaxDurationReached: (() -> Void)?
    var onAudioDeviceChanged: (() -> Void)?

    var lastSilenceThreshold: Float?
    var lastSilenceDuration: Double?
    var lastMaxDuration: TimeInterval?
    var lastPreferredInputDeviceID: String?
    var stopRecordingResult: [Float] = []
    var forceResetCallCount = 0
    var startRecordingResult = true
    var startRecordingDelay: TimeInterval = 0

    private var permissionStatus: PermissionStatus = .granted

    @discardableResult
    func startRecording(
        silenceThreshold: Float,
        silenceDuration: Double,
        maxDuration: TimeInterval,
        preferredInputDeviceID: String?
    ) -> Bool {
        if startRecordingDelay > 0 {
            Thread.sleep(forTimeInterval: startRecordingDelay)
        }
        isCurrentlyRecording = startRecordingResult
        lastSilenceThreshold = silenceThreshold
        lastSilenceDuration = silenceDuration
        lastMaxDuration = maxDuration
        lastPreferredInputDeviceID = preferredInputDeviceID
        return startRecordingResult
    }

    @discardableResult
    func stopRecording() -> [Float] {
        isCurrentlyRecording = false
        return stopRecordingResult
    }

    func forceReset() {
        forceResetCallCount += 1
        isCurrentlyRecording = false
    }

    func checkPermissionStatus() -> PermissionStatus {
        permissionStatus
    }

    func setPermissionStatus(_ status: PermissionStatus) {
        permissionStatus = status
    }

    func requestPermission(completion: @escaping (Bool) -> Void) {
        completion(permissionStatus == .granted)
    }
}

// MARK: - MockSoundManager

final class MockSoundManager: SoundPlaying {
    var volume: Float = 0.5
    var startSoundCallCount = 0
    var stopSoundCallCount = 0
    var startSoundAsyncCallCount = 0
    var stopSoundAsyncCallCount = 0

    func playStartSound() {
        startSoundCallCount += 1
    }

    func playStartSoundAsync() async {
        startSoundAsyncCallCount += 1
    }

    func playStopSound() {
        stopSoundCallCount += 1
    }

    func playStopSoundAsync() async {
        stopSoundAsyncCallCount += 1
    }
}

// MARK: - MockHotKeyManager

final class MockHotKeyManager: HotKeyMonitoring {
    var isListening = false
    var eventTap: CFMachPort? = nil
    var onRecordingStart: (() -> Void)?
    var onRecordingStop: (() -> Void)?

    var startListeningCallCount = 0
    var lastKeyCode: Int?
    var lastMode: ActivationMode?
    var lastDoubleTapThreshold: Double?
    var lastSafetyTimeout: Double?
    var resetKeyStateCallCount = 0
    var updateConfigurationCallCount = 0

    private var accessibilityPermission = false

    func checkAccessibilityPermission(prompt: Bool) -> Bool {
        accessibilityPermission
    }

    func setAccessibilityPermission(_ granted: Bool) {
        accessibilityPermission = granted
    }

    func startListening(keyCode: Int, mode: ActivationMode, doubleTapThreshold: Double, safetyTimeout: Double) {
        startListeningCallCount += 1
        lastKeyCode = keyCode
        lastMode = mode
        lastDoubleTapThreshold = doubleTapThreshold
        lastSafetyTimeout = safetyTimeout
        isListening = true
    }

    func stopListening() {
        isListening = false
    }

    func resetKeyState() {
        resetKeyStateCallCount += 1
    }

    func _updateConfiguration(keyCode: Int?, mode: ActivationMode?, doubleTapThreshold: Double?, safetyTimeout: Double?) {
        updateConfigurationCallCount += 1
        if let keyCode = keyCode {
            lastKeyCode = keyCode
        }
        if let mode = mode {
            lastMode = mode
        }
        if let doubleTapThreshold = doubleTapThreshold {
            lastDoubleTapThreshold = doubleTapThreshold
        }
        if let safetyTimeout = safetyTimeout {
            lastSafetyTimeout = safetyTimeout
        }
    }
}

// MARK: - MockPermissionManager

@MainActor
final class MockPermissionManager: ObservableObject, PermissionManaging {
    @Published var micPermission: PermissionStatus = .granted
    @Published var accessibilityPermission: PermissionStatus = .granted
    @Published var inputMonitoringPermission: PermissionStatus = .granted
    var onAllPermissionsGranted: (() -> Void)?

    var checkPermissionsCallCount = 0
    var startPollingCallCount = 0
    var stopPollingCallCount = 0
    var requestMicPermissionCallCount = 0
    var openMicSettingsCallCount = 0
    var requestAccessibilityCallCount = 0
    var requestInputMonitoringCallCount = 0

    var objectWillChangePublisher: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }

    var allPermissionsGranted: Bool {
        micPermission == .granted &&
        accessibilityPermission == .granted &&
        inputMonitoringPermission == .granted
    }

    func checkPermissions() {
        checkPermissionsCallCount += 1
    }

    func startPermissionPolling() {
        startPollingCallCount += 1
    }

    func stopPermissionPolling() {
        stopPollingCallCount += 1
    }

    func requestMicrophonePermission() {
        requestMicPermissionCallCount += 1
    }

    func openMicrophoneSettings() {
        openMicSettingsCallCount += 1
    }

    func requestAccessibilityPermission() {
        requestAccessibilityCallCount += 1
    }

    func requestInputMonitoringPermission() {
        requestInputMonitoringCallCount += 1
    }
}

// MARK: - MockCursorOverlay

@MainActor
final class MockCursorOverlay: CursorOverlayManaging {
    var showCallCount = 0
    var hideCallCount = 0
    var transitionCallCount = 0
    var lastAudioLevel: Float?

    func show() {
        showCallCount += 1
    }

    func hide() {
        hideCallCount += 1
    }

    func transitionToProcessing() {
        transitionCallCount += 1
    }

    func updateAudioLevel(_ level: Float) {
        lastAudioLevel = level
    }
}

// MARK: - MockModelManager

final class MockModelManager: ModelManaging {
    var supportedModels: [ModelSize] = ModelSize.allCases
    var defaultModel: String = "openai_whisper-tiny"
    var supportedModelNames: [String]?
    var disabledModelNames: [String] = []
    var downloadedModels: Set<ModelSize> = []
    var diskUsage: String = "100 MB"
    var bundledModels: Set<ModelSize> = []
    var installedBundledModels: [ModelSize] = []
    var ensuredTokenizerSizes: [ModelSize] = []
    var installBundledModelError: Error?

    func deviceRecommendation() -> (defaultModel: String, supported: [String], disabled: [String]) {
        (
            defaultModel: defaultModel,
            supported: supportedModelNames ?? supportedModels.map(whisperKitModelName(for:)),
            disabled: disabledModelNames
        )
    }

    func modelFolder(for size: ModelSize) -> URL? {
        downloadedModels.contains(size) ? URL(fileURLWithPath: "/mock/path/\(size.rawValue)") : nil
    }

    func bundledModelFolder(for size: ModelSize) -> URL? {
        bundledModels.contains(size) ? URL(fileURLWithPath: "/mock/bundled/\(size.rawValue)") : nil
    }

    func installBundledModelIfAvailable(for size: ModelSize) throws -> Bool {
        if let installBundledModelError {
            throw installBundledModelError
        }
        guard bundledModels.contains(size) else { return false }
        installedBundledModels.append(size)
        downloadedModels.insert(size)
        return true
    }

    func ensureTokenizerAssets(for size: ModelSize) throws -> URL {
        ensuredTokenizerSizes.append(size)
        return URL(fileURLWithPath: "/mock/path/\(size.rawValue)")
    }

    func isModelDownloaded(_ size: ModelSize) -> Bool {
        downloadedModels.contains(size)
    }

    func isModelSupported(_ size: ModelSize) -> Bool {
        if let supportedModelNames {
            return supportedModelNames.contains(whisperKitModelName(for: size))
                && !disabledModelNames.contains(whisperKitModelName(for: size))
        }
        return supportedModels.contains(size)
    }

    func whisperKitModelName(for size: ModelSize) -> String {
        switch size {
        case .tiny:
            return "openai_whisper-tiny"
        case .base:
            return "openai_whisper-base"
        case .small:
            return "openai_whisper-small"
        case .largeV3LatestTurboCompact:
            return "openai_whisper-large-v3-v20240930_turbo_632MB"
        case .distilLargeV3Compact:
            return "distil-whisper_distil-large-v3_594MB"
        case .distilLargeV3TurboCompact:
            return "distil-whisper_distil-large-v3_turbo_600MB"
        case .largeV3LatestCompact:
            return "openai_whisper-large-v3-v20240930_626MB"
        case .largeV3Latest:
            return "openai_whisper-large-v3-v20240930"
        case .largeV3LatestTurbo:
            return "openai_whisper-large-v3-v20240930_turbo"
        case .largeV3:
            return "openai_whisper-large-v3"
        case .largeV3Turbo:
            return "openai_whisper-large-v3_turbo"
        case .medium:
            return "openai_whisper-medium"
        }
    }

    func modelSize(from whisperKitName: String) -> ModelSize? {
        ModelSize.allCases.first { whisperKitModelName(for: $0) == whisperKitName }
    }

    func downloadModel(size: ModelSize, onProgress: @escaping (Double) -> Void) async throws {
        downloadedModels.insert(size)
    }

    func diskUsageDescription() -> String {
        diskUsage
    }
}

// MARK: - MockWhisperService

final class MockWhisperService: SpeechTranscribing {
    typealias LoadRequest = (name: String?, folder: URL?)

    var loadedModelName: String? = "openai_whisper-tiny"
    var isModelLoaded: Bool = true
    var lastTranscribedAudioData: [Float]?
    var lastLanguage: String?
    var lastTranslate: Bool?
    var lastVocabulary: String?
    var loadRequests: [LoadRequest] = []
    var loadResponses: [Result<String?, Error>] = []
    var mockTranscriptionResult: VocaTranscription = VocaTranscription(text: "mock transcription", duration: 1.0, detectedLanguage: "en", audioLengthSeconds: 1.0, modelUsed: .tiny)
    var shouldThrow = false

    func transcribe(audioData: [Float], language: String?, translate: Bool, vocabulary: String) async throws -> VocaTranscription {
        lastTranscribedAudioData = audioData
        lastLanguage = language
        lastTranslate = translate
        lastVocabulary = vocabulary
        if shouldThrow {
            throw WhisperError.transcriptionFailed(reason: "mock error")
        }
        return mockTranscriptionResult
    }

    func _loadModel(name: String?, folder: URL?, onPhaseChange: ((String) -> Void)?) async throws {
        loadRequests.append((name: name, folder: folder))
        onPhaseChange?("Loading model…")

        if !loadResponses.isEmpty {
            let response = loadResponses.removeFirst()
            switch response {
            case .success(let loadedName):
                loadedModelName = loadedName ?? name ?? "mock-model"
                isModelLoaded = true
                return
            case .failure(let error):
                loadedModelName = nil
                isModelLoaded = false
                throw error
            }
        }

        loadedModelName = name ?? "mock-model"
        isModelLoaded = true
    }
}

// MARK: - MockTextInjector

final class MockTextInjector: TextInjecting {
    var injectCallCount = 0
    var lastInjectedText: String?
    var lastPreserveClipboard: Bool?

    func inject(text: String, preserveClipboard: Bool) {
        injectCallCount += 1
        lastInjectedText = text
        lastPreserveClipboard = preserveClipboard
    }
}

// MARK: - MockTextPostProcessor

final class MockTextPostProcessor: TextPostProcessing {
    var prepareCallCount = 0
    var improveCallCount = 0
    var lastPrepareConfiguration: TextPostProcessingConfiguration?
    var lastText: String?
    var lastConfiguration: TextPostProcessingConfiguration?
    var result = "processed text"
    var error: Error?
    var prepareError: Error?

    func prepare(configuration: TextPostProcessingConfiguration) async throws {
        prepareCallCount += 1
        lastPrepareConfiguration = configuration
        if let prepareError {
            throw prepareError
        }
    }

    func improve(_ text: String, configuration: TextPostProcessingConfiguration) async throws -> String {
        improveCallCount += 1
        lastText = text
        lastConfiguration = configuration
        if let error {
            throw error
        }
        return result
    }
}

// MARK: - MockStatsManager

@MainActor
final class MockStatsManager: StatsManaging, ObservableObject {
    @Published var stats: UserStats = UserStats()

    var recordCallCount = 0
    var resetCallCount = 0

    var objectWillChangePublisher: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }

    func recordTranscription(_ transcription: VocaTranscription) {
        recordCallCount += 1
    }

    func resetStats() {
        resetCallCount += 1
    }
}

// MARK: - Test Helper

extension AppState {
    @MainActor
    static func makeTestState(
        modelManager: MockModelManager = MockModelManager(),
        whisperService: MockWhisperService = MockWhisperService(),
        textPostProcessor: MockTextPostProcessor = MockTextPostProcessor()
    ) -> (appState: AppState, mocks: TestMocks) {
        UserDefaults.standard.removeObject(forKey: "vocamac.selectedAudioDeviceID")
        UserDefaults.standard.removeObject(forKey: "vocamac.selectedAudioDeviceName")
        UserDefaults.standard.removeObject(forKey: "vocamac.postProcessingEnabled")
        UserDefaults.standard.removeObject(forKey: "vocamac.postProcessingRunnerPath")
        UserDefaults.standard.removeObject(forKey: "vocamac.postProcessingModelID")
        UserDefaults.standard.removeObject(forKey: "vocamac.postProcessingModelPath")
        UserDefaults.standard.removeObject(forKey: "vocamac.postProcessingInstructions")

        let audioEngine = MockAudioEngine()
        let soundManager = MockSoundManager()
        let hotKeyManager = MockHotKeyManager()
        let permissionManager = MockPermissionManager()
        let cursorOverlay = MockCursorOverlay()
        let textInjector = MockTextInjector()
        let statsManager = MockStatsManager()

        let mocks = TestMocks(
            audioEngine: audioEngine,
            soundManager: soundManager,
            hotKeyManager: hotKeyManager,
            permissionManager: permissionManager,
            cursorOverlay: cursorOverlay,
            modelManager: modelManager,
            whisperService: whisperService,
            textInjector: textInjector,
            textPostProcessor: textPostProcessor,
            statsManager: statsManager
        )
        let appState = AppState(
            audioEngine: audioEngine,
            whisperService: whisperService,
            textInjector: textInjector,
            textPostProcessor: textPostProcessor,
            hotKeyManager: hotKeyManager,
            modelManager: modelManager,
            soundManager: soundManager,
            cursorOverlay: cursorOverlay,
            statsManager: statsManager,
            permissionManager: permissionManager,
            skipSystemIntegration: true
        )
        return (appState, mocks)
    }
}

struct TestMocks {
    let audioEngine: MockAudioEngine
    let soundManager: MockSoundManager
    let hotKeyManager: MockHotKeyManager
    let permissionManager: MockPermissionManager
    let cursorOverlay: MockCursorOverlay
    let modelManager: MockModelManager
    let whisperService: MockWhisperService
    let textInjector: MockTextInjector
    let textPostProcessor: MockTextPostProcessor
    let statsManager: MockStatsManager
}
