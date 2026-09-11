// MockServices.swift
// VocaMac Tests
//
// Mock implementations of service protocols for unit testing.
// These avoid triggering real system side effects (sounds, permissions, mic, etc.).

import Foundation
import Combine
import ApplicationServices
@testable import VocaMac

// MARK: - MockAudioEngine

final class MockAudioEngine: AudioRecording {
    var isCurrentlyRecording = false
    var onAudioLevel: ((Float) -> Void)?
    var onAudioSamples: (([Float], Int) -> Void)?
    var onSilenceDetected: (() -> Void)?
    var onMaxDurationReached: (() -> Void)?
    var onAudioDeviceChanged: (() -> Void)?
    var onInputDeviceFallback: ((String) -> Void)?

    var lastSilenceThreshold: Float?
    var lastSilenceDuration: Double?
    var lastMaxDuration: TimeInterval?
    var lastPreferredInputDeviceID: String?
    var lastPreferredInputChannel: Int?
    var lastPreferredInputChannelDeviceID: String?
    var lastPreferredInputChannelCount: Int?
    var stopRecordingResult: [Float] = []
    var forceResetCallCount = 0
    var startRecordingResult = true
    var startRecordingDelay: TimeInterval = 0
    private(set) var cancelPendingStartCallCount = 0
    /// Mirrors the real engine: a start cancelled while it is still negotiating
    /// the input route is abandoned and reports failure.
    private let cancelLock = NSLock()
    private var startCancelled = false

    private var permissionStatus: PermissionStatus = .granted

    @discardableResult
    func startRecording(
        silenceThreshold: Float,
        silenceDuration: Double,
        maxDuration: TimeInterval,
        preferredInputDeviceID: String?,
        preferredInputChannel: Int,
        preferredInputChannelDeviceID: String?,
        preferredInputChannelCount: Int
    ) -> Bool {
        cancelLock.withLock { startCancelled = false }
        if startRecordingDelay > 0 {
            Thread.sleep(forTimeInterval: startRecordingDelay)
        }
        lastSilenceThreshold = silenceThreshold
        lastSilenceDuration = silenceDuration
        lastMaxDuration = maxDuration
        lastPreferredInputDeviceID = preferredInputDeviceID
        lastPreferredInputChannel = preferredInputChannel
        lastPreferredInputChannelDeviceID = preferredInputChannelDeviceID
        lastPreferredInputChannelCount = preferredInputChannelCount

        if cancelLock.withLock({ startCancelled }) {
            isCurrentlyRecording = false
            return false
        }

        isCurrentlyRecording = startRecordingResult
        return startRecordingResult
    }

    func cancelPendingStart() {
        cancelLock.withLock {
            cancelPendingStartCallCount += 1
            startCancelled = true
        }
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
    enum PlayEvent {
        case start
        case stop
        case startAsync
        case stopAsync
    }

    var volume: Float = 0.5
    var startSoundCallCount = 0
    var stopSoundCallCount = 0
    var startSoundAsyncCallCount = 0
    var stopSoundAsyncCallCount = 0
    var playLog: [PlayEvent] = []
    /// Runs while the awaited start cue "plays", to act mid-cue.
    var whileStartSoundAsyncPlays: (() async -> Void)?

    func playStartSound() {
        startSoundCallCount += 1
        playLog.append(.start)
    }

    func playStartSoundAsync() async {
        startSoundAsyncCallCount += 1
        playLog.append(.startAsync)
        await whileStartSoundAsyncPlays?()
    }

    func playStopSound() {
        stopSoundCallCount += 1
        playLog.append(.stop)
    }

    func playStopSoundAsync() async {
        stopSoundAsyncCallCount += 1
        playLog.append(.stopAsync)
    }
}

// MARK: - MockAudioDucker

final class MockAudioDucker: AudioDucking {
    var duckCallCount = 0
    var restoreCallCount = 0
    var restoreAfterUnexpectedExitCallCount = 0
    var onDuck: (() -> Void)?

    func duck() {
        duckCallCount += 1
        onDuck?()
    }

    func restore() {
        restoreCallCount += 1
    }

    func restoreAfterUnexpectedExit() {
        restoreAfterUnexpectedExitCallCount += 1
    }
}

// MARK: - MockHotKeyManager

final class MockHotKeyManager: HotKeyMonitoring, HotKeyShortcutMonitoring {
    var isListening = false
    var eventTap: CFMachPort? = nil
    var onRecordingStart: (() -> Void)?
    var onRecordingStop: (() -> Void)?

    var startListeningCallCount = 0
    var lastKeyCode: Int?
    var lastMode: ActivationMode?
    var lastDoubleTapThreshold: Double?
    var lastSafetyTimeout: Double?
    var lastModifiers: HotKeyModifiers?
    var resetKeyStateCallCount = 0
    var updateConfigurationCallCount = 0

    private var accessibilityPermission = false

    func checkAccessibilityPermission(prompt: Bool) -> Bool {
        accessibilityPermission
    }

    func setAccessibilityPermission(_ granted: Bool) {
        accessibilityPermission = granted
    }

    func startListening(keyCode: Int, mode: ActivationMode, doubleTapThreshold: Double, safetyTimeout: Double, modifiers: HotKeyModifiers) {
        startListeningCallCount += 1
        lastKeyCode = keyCode
        lastMode = mode
        lastDoubleTapThreshold = doubleTapThreshold
        lastSafetyTimeout = safetyTimeout
        lastModifiers = modifiers
        isListening = true
    }

    func stopListening() {
        isListening = false
    }

    func resetKeyState() {
        resetKeyStateCallCount += 1
    }

    // HotKeyShortcutMonitoring
    var onShortcut: ((HotKeyShortcutAction) -> Void)?
    var onShortcutReleased: ((HotKeyShortcutAction) -> Void)?
    var onCancel: (() -> Void)?
    var shortcuts: [HotKeyShortcutAction: HotKeyCombo] = [:]
    var isCancelKeyArmed = false
    var mouseTriggerButton = 0

    func updateShortcuts(_ shortcuts: [HotKeyShortcutAction: HotKeyCombo]) {
        self.shortcuts = shortcuts
    }

    func setCancelKeyArmed(_ armed: Bool) {
        isCancelKeyArmed = armed
    }

    func updateMouseTrigger(button: Int) {
        mouseTriggerButton = button
    }

    func _updateConfiguration(keyCode: Int?, mode: ActivationMode?, doubleTapThreshold: Double?, safetyTimeout: Double?, modifiers: HotKeyModifiers?) {
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
        if let modifiers = modifiers {
            lastModifiers = modifiers
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
    var transitionToRecordingCallCount = 0
    var lastAudioLevel: Float?
    var lastStyle: OverlayStyle?
    var lastPosition: OverlayPosition?
    var lastTranscript: String?

    func show(style: OverlayStyle, position: OverlayPosition) {
        showCallCount += 1
        lastStyle = style
        lastPosition = position
    }

    func hide() {
        hideCallCount += 1
    }

    func transitionToRecording() {
        transitionToRecordingCallCount += 1
    }

    func transitionToProcessing() {
        transitionCallCount += 1
    }

    func updateAudioLevel(_ level: Float) {
        lastAudioLevel = level
    }
    func updateTranscript(_ text: String) { lastTranscript = text }
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
    var downloadRequests: [ModelSize] = []
    var downloadDelayNanoseconds: UInt64 = 0
    private(set) var activeDownloadCount = 0
    private(set) var maxConcurrentDownloadCount = 0

    func deviceRecommendation() -> (defaultModel: String, supported: [String], disabled: [String]) {
        (
            defaultModel: defaultModel,
            supported: supportedModelNames ?? supportedModels.map(modelIdentifier(for:)),
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
            return supportedModelNames.contains(modelIdentifier(for: size))
                && !disabledModelNames.contains(modelIdentifier(for: size))
        }
        return supportedModels.contains(size)
    }

    func modelIdentifier(for size: ModelSize) -> String {
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
        case .parakeetV3, .parakeetV2, .parakeetTdtCtc110m, .appleSpeech,
             .moonshineTiny, .moonshineBase, .senseVoiceSmall, .gigaamV3, .canary180mFlash:
            return size.rawValue
        }
    }

    func modelSize(from identifier: String) -> ModelSize? {
        ModelSize.allCases.first { modelIdentifier(for: $0) == identifier }
    }

    func downloadModel(size: ModelSize, onProgress: @escaping (Double) -> Void) async throws {
        downloadRequests.append(size)
        activeDownloadCount += 1
        maxConcurrentDownloadCount = max(maxConcurrentDownloadCount, activeDownloadCount)
        defer { activeDownloadCount -= 1 }

        if downloadDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: downloadDelayNanoseconds)
        }

        onProgress(1.0)
        downloadedModels.insert(size)
    }

    var deleteModelError: Error?
    var deletedModels: [ModelSize] = []

    func deleteModel(_ size: ModelSize) async throws {
        if let deleteModelError {
            throw deleteModelError
        }
        downloadedModels.remove(size)
        deletedModels.append(size)
    }

    func diskUsageDescription() -> String {
        diskUsage
    }
}

// MARK: - MockWhisperService

final class MockWhisperService: SpeechTranscribing {
    typealias LoadRequest = (name: String?, folder: URL?)

    var streamingFactory: ((String?) -> RecordingTranscription?)?
    var streamingPartialHandler: (@Sendable (String) -> Void)?
    var lastStreamingVocabulary: String?
    func startStreaming(
        language: String?, vocabulary: String,
        onPartial: (@Sendable (String) -> Void)?
    ) -> RecordingTranscription? {
        lastStreamingVocabulary = vocabulary
        streamingPartialHandler = onPartial
        return streamingFactory?(language)
    }
    var loadedModelName: String? = "openai_whisper-tiny"
    var isModelLoaded: Bool = true
    var lastTranscribedAudioData: [Float]?
    var lastLanguage: String?
    var lastTranslate: Bool?
    var lastVocabulary: String?
    var loadRequests: [LoadRequest] = []
    var loadResponses: [Result<String?, Error>] = []
    var loadDelayNanoseconds: UInt64 = 0
    private(set) var activeLoadCount = 0
    private(set) var maxConcurrentLoadCount = 0
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
        activeLoadCount += 1
        maxConcurrentLoadCount = max(maxConcurrentLoadCount, activeLoadCount)
        defer { activeLoadCount -= 1 }

        onPhaseChange?("Loading model…")

        if loadDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: loadDelayNanoseconds)
        }

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

    var unloadCallCount = 0

    func unloadModel() async {
        unloadCallCount += 1
        loadedModelName = nil
        isModelLoaded = false
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

// MARK: - MockFrontmostAppResolver

@MainActor
final class MockFrontmostAppResolver: FrontmostAppResolving {
    var frontmostApp: RunningAppSnapshot?
    /// Stands in for the app the user came from when VocaMac has focus.
    var previousApp: RunningAppSnapshot?
    var callCount = 0
    var lastActiveCallCount = 0

    init(frontmostApp: RunningAppSnapshot? = nil, previousApp: RunningAppSnapshot? = nil) {
        self.frontmostApp = frontmostApp
        self.previousApp = previousApp
    }

    func currentFrontmostApp() -> RunningAppSnapshot? {
        callCount += 1
        return frontmostApp
    }

    func lastActiveApp() -> RunningAppSnapshot? {
        lastActiveCallCount += 1
        return previousApp
    }
}

// MARK: - MockStatsManager

@MainActor
final class MockStatsManager: StatsManaging, ObservableObject {
    @Published var stats: UserStats = UserStats()

    var recordCallCount = 0
    var resetCallCount = 0
    var refreshCurrentStreakCallCount = 0
    var flushPendingSavesCallCount = 0

    var objectWillChangePublisher: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }

    func recordTranscription(_ transcription: VocaTranscription) {
        recordCallCount += 1
    }

    func refreshCurrentStreak() {
        refreshCurrentStreakCallCount += 1
    }

    func flushPendingSaves() {
        flushPendingSavesCallCount += 1
    }

    func resetStats() {
        resetCallCount += 1
    }
}

// MARK: - MockTranscriptCleanup

@MainActor
final class MockTranscriptCleanup: TranscriptCleaning, ObservableObject {
    @Published var modelState: CleanupModelState = .idle
    var downloadedKinds: Set<CleanupModelKind> = Set(CleanupModelKind.allCases)
    var cleanHandler: ((String) -> String)?
    var cleanCallCount = 0
    var lastCleanedText: String?
    var lastPrompt: String?
    var loadCallCount = 0
    var downloadCallCount = 0
    var downloadSucceeds = true
    var loadSucceeds = true
    var cancelDownloadCallCount = 0
    var unloadCallCount = 0
    var lastLoadedKind: CleanupModelKind?

    var isLoaded = false
    var pruneCallCount = 0

    var objectWillChangePublisher: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }

    func pruneUnknownModels() {
        pruneCallCount += 1
    }

    nonisolated func inputBudget(forPrompt prompt: String) -> Int {
        TranscriptCleanup.inputCharacterBudget(
            promptCharacters: prompt.count,
            maxTokenCount: Int(CleanupModelCatalog.recommended.maxTokenCount)
        )
    }

    func clean(_ text: String, prompt: String) async -> String {
        cleanCallCount += 1
        lastCleanedText = text
        lastPrompt = prompt
        return cleanHandler?(text) ?? text
    }

    var previewCallCount = 0

    func preview(_ text: String, prompt: String) async -> CleanupAttempt {
        previewCallCount += 1
        lastPrompt = prompt
        let output = cleanHandler?(text) ?? text
        return CleanupAttempt(
            output: output,
            outcome: output == text ? .unchanged : .cleaned,
            duration: 0
        )
    }

    func isDownloaded(_ kind: CleanupModelKind) -> Bool {
        downloadedKinds.contains(kind)
    }

    func download(_ kind: CleanupModelKind) async {
        downloadCallCount += 1
        if downloadSucceeds {
            downloadedKinds.insert(kind)
            modelState = .idle
        } else {
            modelState = .error("download failed")
        }
    }

    func cancelDownload() {
        cancelDownloadCallCount += 1
        modelState = .idle
    }

    func load(_ kind: CleanupModelKind) async {
        loadCallCount += 1
        guard loadSucceeds else {
            modelState = .error("load failed")
            return
        }
        lastLoadedKind = kind
        isLoaded = true
        modelState = .ready
    }

    func unload() {
        unloadCallCount += 1
        isLoaded = false
        modelState = .idle
    }

    func delete(_ kind: CleanupModelKind) {
        downloadedKinds.remove(kind)
        if lastLoadedKind == kind {
            modelState = .idle
        }
    }
}

// MARK: - Test Helper

extension AppState {
    @MainActor
    static func makeTestState(
        modelManager: MockModelManager = MockModelManager(),
        whisperService: MockWhisperService = MockWhisperService(),
        transcriptCleanup: MockTranscriptCleanup? = nil,
        historyStore: DictationHistoryStore? = nil,
        screenContextReader: (any ScreenContextReading)? = nil,
        correctionObserver: (any CorrectionObserving)? = nil,
        selectedTextService: (any SelectedTextAccessing)? = nil
    ) -> (appState: AppState, mocks: TestMocks) {
        UserDefaults.standard.removeObject(forKey: "vocamac.selectedAudioDeviceID")
        UserDefaults.standard.removeObject(forKey: "vocamac.selectedAudioDeviceName")
        UserDefaults.standard.removeObject(forKey: "vocamac.selectedAudioChannel")
        UserDefaults.standard.removeObject(forKey: "vocamac.selectedAudioChannelDeviceID")
        UserDefaults.standard.removeObject(forKey: "vocamac.selectedAudioChannelCount")
        UserDefaults.standard.removeObject(forKey: "vocamac.soundEffectsEnabled")
        UserDefaults.standard.removeObject(forKey: "vocamac.translationEnabled")
        // Output polish defaults leak between test *processes* via
        // UserDefaults, so reset them here rather than in each test.
        UserDefaults.standard.removeObject(forKey: PreferenceKey.appendTrailingSpace)
        UserDefaults.standard.removeObject(forKey: PreferenceKey.autoCapitalize)
        UserDefaults.standard.removeObject(forKey: PreferenceKey.autoPauseEnabled)
        UserDefaults.standard.removeObject(forKey: PreferenceKey.modelKeepAliveEnabled)
        UserDefaults.standard.removeObject(forKey: PreferenceKey.writingStyleEnabled)
        UserDefaults.standard.removeObject(forKey: PreferenceKey.writingStyleDefault)
        UserDefaults.standard.removeObject(forKey: PreferenceKey.writingStyleBindings)
        UserDefaults.standard.removeObject(forKey: PreferenceKey.writingIntent)
        UserDefaults.standard.removeObject(forKey: PreferenceKey.writingRewriteEnabled)
        UserDefaults.standard.removeObject(forKey: PreferenceKey.duckOtherAudioEnabled)
        UserDefaults.standard.removeObject(forKey: PreferenceKey.transcriptCleanupEnabled)
        UserDefaults.standard.removeObject(forKey: PreferenceKey.transcriptCleanupModel)
        UserDefaults.standard.removeObject(forKey: PreferenceKey.transcriptCleanupPrompt)
        for key in [
            PreferenceKey.historyEnabled, PreferenceKey.historyKeepsAudio, PreferenceKey.historyRetention,
            PreferenceKey.escapeCancelsDictation, PreferenceKey.pasteLastShortcut, PreferenceKey.handsFreeShortcut,
            PreferenceKey.mouseTriggerButton, PreferenceKey.wordReplacements, PreferenceKey.dictionarySuggestions,
            PreferenceKey.dismissedDictionarySuggestions, PreferenceKey.learnCorrectionsMode,
            PreferenceKey.useScreenContext, "vocamac.customVocabulary",
            PreferenceKey.transcriptCleanupLevel, PreferenceKey.cleanupEndpoint,
            PreferenceKey.commandModeShortcut, PreferenceKey.websiteStyleBindings,
            PreferenceKey.externalMicWhenLidClosed, "vocamac.scratchpad.text",
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }

        let audioEngine = MockAudioEngine()
        let soundManager = MockSoundManager()
        let audioDucker = MockAudioDucker()
        let hotKeyManager = MockHotKeyManager()
        let permissionManager = MockPermissionManager()
        let cursorOverlay = MockCursorOverlay()
        let textInjector = MockTextInjector()
        let statsManager = MockStatsManager()
        let frontmostAppResolver = MockFrontmostAppResolver()
        let cleanup = transcriptCleanup ?? MockTranscriptCleanup()

        let mocks = TestMocks(
            audioEngine: audioEngine,
            soundManager: soundManager,
            audioDucker: audioDucker,
            hotKeyManager: hotKeyManager,
            permissionManager: permissionManager,
            cursorOverlay: cursorOverlay,
            modelManager: modelManager,
            whisperService: whisperService,
            textInjector: textInjector,
            statsManager: statsManager,
            frontmostAppResolver: frontmostAppResolver,
            transcriptCleanup: cleanup
        )
        let appState = AppState(
            audioEngine: audioEngine,
            whisperService: whisperService,
            textInjector: textInjector,
            hotKeyManager: hotKeyManager,
            modelManager: modelManager,
            soundManager: soundManager,
            audioDucker: audioDucker,
            cursorOverlay: cursorOverlay,
            statsManager: statsManager,
            snippetExpander: SnippetExpander(),
            transcriptCleanup: cleanup,
            permissionManager: permissionManager,
            frontmostAppResolver: frontmostAppResolver,
            historyStore: historyStore,
            screenContextReader: screenContextReader,
            correctionObserver: correctionObserver,
            selectedTextService: selectedTextService,
            skipSystemIntegration: true
        )
        // Spell checking depends on the machine's dictionaries; tests use a
        // small fixed word list instead.
        appState.isKnownWord = { word, _ in TestWords.common.contains(word.lowercased()) }
        // Bypass host free-RAM probe so mock loads are not refused on CI.
        appState.modelFitsInMemory = { _ in true }
        return (appState, mocks)
    }
}

struct TestMocks {
    let audioEngine: MockAudioEngine
    let soundManager: MockSoundManager
    let audioDucker: MockAudioDucker
    let hotKeyManager: MockHotKeyManager
    let permissionManager: MockPermissionManager
    let cursorOverlay: MockCursorOverlay
    let modelManager: MockModelManager
    let whisperService: MockWhisperService
    let textInjector: MockTextInjector
    let statsManager: MockStatsManager
    let frontmostAppResolver: MockFrontmostAppResolver
    let transcriptCleanup: MockTranscriptCleanup
}


// MARK: - Test Words

enum TestWords {
    /// Stand-in for the system spell checker in tests.
    static let common: Set<String> = [
        "the", "a", "an", "and", "i", "to", "is", "it", "in", "on", "of", "for", "with", "my", "me",
        "open", "file", "hello", "world", "cloud", "there", "their", "big", "large", "meet", "at",
        "send", "email", "call", "please", "user", "id", "service", "super", "base", "post", "apple",
        "notes", "mail", "check", "this", "that", "we", "should", "use", "set", "value", "ask",
        "about", "project", "today", "tomorrow", "update", "code", "run", "tests", "get", "hub",
    ]
}

// MARK: - Mock Screen Context and Correction Observer

@MainActor
final class MockScreenContextReader: ScreenContextReading {
    var text: String?
    var documentURL: URL?
    var documentURLs: [URL?] = []
    var captureCallCount = 0
    var documentURLCallCount = 0

    func captureFrontmostContext() async -> String? {
        captureCallCount += 1
        return text
    }

    func captureFrontmostDocumentURL() async -> URL? {
        documentURLCallCount += 1
        if !documentURLs.isEmpty { return documentURLs.removeFirst() }
        return documentURL
    }
}

@MainActor
final class MockSelectedTextService: SelectedTextAccessing {
    var selectedText = ""
    var replacement: String?
    var captureCallCount = 0
    var replaceCallCount = 0

    func captureSelection() async -> SelectedTextSnapshot? {
        captureCallCount += 1
        guard !selectedText.isEmpty else { return nil }
        return SelectedTextSnapshot(
            element: AXElementBox(element: AXUIElementCreateSystemWide()),
            processID: 42,
            text: selectedText,
            range: CFRange(location: 0, length: selectedText.utf16.count)
        )
    }

    func replaceSelection(_ snapshot: SelectedTextSnapshot, with text: String) async -> Bool {
        replaceCallCount += 1
        replacement = text
        return true
    }
}

@MainActor
final class MockCorrectionObserver: CorrectionObserving {
    var onCorrections: (([CorrectionLearner.Correction]) -> Void)?
    var observedTexts: [String] = []
    var flushCallCount = 0

    func observe(insertedText text: String, processID: pid_t, isKnownWord: @escaping (String) -> Bool) {
        observedTexts.append(text)
    }

    func flush() {
        flushCallCount += 1
    }

    func cancel() {}
}
