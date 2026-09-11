// AppState.swift
// VocaMac
//
// Central observable state for the entire application.
// All UI and services react to changes in AppState.

import Foundation
import SwiftUI
import Combine
import AppKit
import ServiceManagement

// MARK: - Enums

/// Application status representing the current state of the transcription pipeline
enum AppStatus: String {
    case idle          // Ready for input, not recording
    case recording     // Actively capturing microphone audio
    case processing    // Transcribing audio via WhisperKit
    case error         // Something went wrong
}

/// How recording is activated by the user
enum ActivationMode: String, CaseIterable, Codable, Identifiable {
    case pushToTalk       // Hold key to record, release to stop
    case doubleTapToggle  // Double-tap key to start/stop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pushToTalk:      return "Push to Talk (Hold)"
        case .doubleTapToggle: return "Double-Tap Toggle"
        }
    }

    /// Title for the option cards, where the gesture is spelled out underneath
    /// and the parenthetical in `displayName` would only repeat it.
    var shortName: String {
        switch self {
        case .pushToTalk:      return "Push to Talk"
        case .doubleTapToggle: return "Double-Tap Toggle"
        }
    }

    var systemImage: String {
        switch self {
        case .pushToTalk:      return "hand.point.up.left.fill"
        case .doubleTapToggle: return "hand.tap.fill"
        }
    }

    var description: String {
        switch self {
        case .pushToTalk:
            return "Hold the hotkey to record. Release to stop and transcribe."
        case .doubleTapToggle:
            return "Double-tap the hotkey to start recording. Double-tap again to stop."
        }
    }
}

/// Permission status for system permissions
enum PermissionStatus: String {
    case notDetermined
    case granted
    case denied
}

enum ScratchpadOutputDestination {
    case settingsTest
    case scratchpad
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {

    // MARK: - Published State

    /// Current application status
    @Published var appStatus: AppStatus = .idle

    /// Whether the app is actively recording audio
    private var recordingGeneration = UUID()
    /// Practice sessions keep their output local even when a hotkey stops them.
    private var recordingInjectsResult = true
    /// Whether the active recording belongs to an in-window practice control.
    var isPracticeRecording: Bool {
        (isRecording || appStatus == .recording) && !recordingInjectsResult
    }

    private var recordingTranscription: RecordingTranscription?
    private var finishingTranscription: RecordingTranscription?
    private var isStoppingAudio = false
    /// Every way a recording ends — stop, cancel, force recovery, a failed
    /// start, an input device change, auto-pause — sets this to `false`, so
    /// this is the one place that reliably sees the microphone close. Other
    /// audio muted for the recording is restored here rather than at each
    /// of those exits; `restore()` is a no-op when nothing was muted.
    @Published var isRecording: Bool = false {
        didSet {
            if !isRecording {
                audioEngine.onAudioSamples = nil
                recordingTranscription?.cancel()
                recordingTranscription = nil
                isHandsFreeSession = false
            }
            if oldValue && !isRecording {
                audioDucker.restore()
            }
        }
    }

    /// Current audio input level (0.0 - 1.0) for visual feedback
    let audioMeter = AudioMeterState()
    var audioLevel: Float {
        get { audioMeter.level }
        set { audioMeter.update(newValue) }
    }

    /// The most recent transcription result
    @Published var lastTranscription: VocaTranscription?
    @Published private(set) var liveTranscript: String = ""

    /// Last Settings → Test Dictation result (shown in the sidebar footer; not injected).
    @Published var settingsTestResultText: String?
    @AppStorage("vocamac.scratchpad.text") var scratchpadText: String = ""

    /// Error message to display, if any
    @Published var errorMessage: String?

    /// Currently loaded/active whisper model info
    @Published var currentModel: WhisperModelInfo?

    /// All available models and their statuses
    @Published var availableModels: [WhisperModelInfo] = []

    // Permissions are managed by PermissionManager.
    // These computed properties maintain backward compatibility for views.
    var micPermission: PermissionStatus { permissionManager.micPermission }
    var accessibilityPermission: PermissionStatus { permissionManager.accessibilityPermission }
    var inputMonitoringPermission: PermissionStatus { permissionManager.inputMonitoringPermission }

    /// Detected system capabilities
    @Published var systemCapabilities: SystemCapabilities?

    /// WhisperKit's recommended model for this device
    @Published var deviceRecommendedModel: String?

    // MARK: - User Settings (persisted via UserDefaults)

    @AppStorage("vocamac.hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false
    @AppStorage("vocamac.activationMode") var activationMode: ActivationMode = .pushToTalk
    @AppStorage("vocamac.hotKeyCode") var hotKeyCode: Int = 61  // Right Option
    @AppStorage("vocamac.hotKeyModifiers") var hotKeyModifiers: HotKeyModifiers = []
    @AppStorage("vocamac.doubleTapThreshold") var doubleTapThreshold: Double = 0.4
    @AppStorage("vocamac.silenceThreshold") var silenceThreshold: Double = 0.01
    @AppStorage("vocamac.silenceDuration") var silenceDuration: Double = SilenceDetectionSettings.defaultDuration
    @AppStorage("vocamac.maxRecordingDuration") var maxRecordingDuration: Int = 60
    @AppStorage("vocamac.selectedAudioDeviceID") var selectedAudioDeviceID: String = ""
    @AppStorage("vocamac.selectedAudioDeviceName") var selectedAudioDeviceName: String = ""
    @AppStorage("vocamac.selectedAudioChannel") var selectedAudioChannel: Int = 0
    @AppStorage("vocamac.selectedAudioChannelDeviceID") var selectedAudioChannelDeviceID: String = ""
    @AppStorage("vocamac.selectedAudioChannelCount") var selectedAudioChannelCount: Int = 0
    @AppStorage(PreferenceKey.selectedModelSize) var selectedModelSize: String = ModelSize.tiny.rawValue
    @AppStorage(PreferenceKey.selectedLanguage) var selectedLanguage: String = "auto"
    @AppStorage("vocamac.launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("vocamac.preserveClipboard") var preserveClipboard: Bool = true
    @AppStorage("vocamac.soundEffectsEnabled") var soundEffectsEnabled: Bool = true
    @AppStorage(PreferenceKey.dictationTone) var dictationTone: DictationTone = .voca
    @AppStorage(PreferenceKey.duckOtherAudioEnabled) var duckOtherAudioEnabled: Bool = false
    @AppStorage("vocamac.overlayStyle") var overlayStyle: OverlayStyle = .minimal
    @AppStorage("vocamac.overlayPosition") var overlayPosition: OverlayPosition = .bottom
    /// Legacy preference retained so existing installs that disabled the old
    /// cursor indicator continue to keep the overlay hidden after upgrading.
    @AppStorage("vocamac.showCursorIndicator") var showCursorIndicator: Bool = true
    @AppStorage("vocamac.translationEnabled") var translationEnabled: Bool = false
    @AppStorage("vocamac.customVocabulary") var customVocabulary: String = ""
    @AppStorage("vocamac.logLevel") var logLevel: String = "info"
    @AppStorage(PreferenceKey.appendTrailingSpace) var appendTrailingSpace: Bool = true
    @AppStorage(PreferenceKey.autoCapitalize) var autoCapitalize: Bool = true
    @AppStorage(PreferenceKey.autoPauseEnabled) var autoPauseEnabled: Bool = false
    @AppStorage(PreferenceKey.autoPausePollInterval) var autoPausePollIntervalSeconds: Double = 5
    @AppStorage(PreferenceKey.modelKeepAliveEnabled) var modelKeepAliveEnabled: Bool = false
    @AppStorage(PreferenceKey.modelKeepAliveIdleTimeout) var modelKeepAliveIdleTimeoutSeconds: Double = 300
    @AppStorage(PreferenceKey.writingStyleEnabled) var writingStyleEnabled: Bool = true
    @AppStorage(PreferenceKey.writingStyleDefault) var writingStyleDefault: WritingStyle = .plain
    @AppStorage(PreferenceKey.writingIntent) var writingIntent: WritingIntent = .preserve
    @AppStorage(PreferenceKey.writingRewriteEnabled) var writingRewriteEnabled: Bool = false
    @AppStorage(PreferenceKey.transcriptCleanupEnabled) var transcriptCleanupEnabled: Bool = false
    @AppStorage(PreferenceKey.transcriptCleanupModel) var transcriptCleanupModel: String = CleanupModelKind.defaultKind.rawValue
    @AppStorage(PreferenceKey.transcriptCleanupPrompt) var transcriptCleanupPrompt: String = ""
    @AppStorage(PreferenceKey.transcriptCleanupLevel) var transcriptCleanupLevel: CleanupLevel = .medium
    @AppStorage(PreferenceKey.cleanupEndpoint) var cleanupEndpointJSON: String = ""
    @AppStorage(PreferenceKey.historyEnabled) var historyEnabled: Bool = true
    @AppStorage(PreferenceKey.historyKeepsAudio) var historyKeepsAudio: Bool = false
    @AppStorage(PreferenceKey.historyRetention) var historyRetention: HistoryRetention = .defaultRetention
    @AppStorage(PreferenceKey.escapeCancelsDictation) var escapeCancelsDictation: Bool = true
    /// `HotKeyCombo.storageString`, or empty for no shortcut.
    @AppStorage(PreferenceKey.pasteLastShortcut) var pasteLastShortcut: String = HotKeyCombo.defaultPasteLast.storageString
    /// `HotKeyCombo.storageString`, or empty for no shortcut.
    @AppStorage(PreferenceKey.handsFreeShortcut) var handsFreeShortcut: String = ""
    @AppStorage(PreferenceKey.commandModeShortcut) var commandModeShortcut: String = ""
    @AppStorage(PreferenceKey.mouseTriggerButton) var mouseTriggerButton: Int = MouseTriggerButton.off.rawValue
    @AppStorage(PreferenceKey.learnCorrectionsMode) var learnCorrectionsMode: LearnCorrectionsMode = .defaultMode
    @AppStorage(PreferenceKey.useScreenContext) var useScreenContext: Bool = true
    @AppStorage(PreferenceKey.externalMicWhenLidClosed) var externalMicWhenLidClosed: Bool = false

    var cleanupEndpoint: CleanupEndpointConfiguration {
        get { CleanupEndpointConfiguration.decode(cleanupEndpointJSON) }
        set { cleanupEndpointJSON = newValue.encoded(); objectWillChange.send() }
    }

    var websiteStyleBindings: [WebsiteStyleBinding] {
        get { WebsiteStyleBindingStore.decode(UserDefaults.standard.string(forKey: PreferenceKey.websiteStyleBindings)) }
        set {
            UserDefaults.standard.set(WebsiteStyleBindingStore.encode(newValue), forKey: PreferenceKey.websiteStyleBindings)
            objectWillChange.send()
        }
    }

    /// JSON-encoded `[AutoPauseAppEntry]` list (complex value not stored via `@AppStorage`).
    var autoPauseAppsJSON: String {
        get { UserDefaults.standard.string(forKey: PreferenceKey.autoPauseApps) ?? "[]" }
        set { UserDefaults.standard.set(newValue, forKey: PreferenceKey.autoPauseApps) }
    }

    /// Decoded auto-pause app list. Empty when unset or invalid JSON.
    var autoPauseApps: [AutoPauseAppEntry] {
        get {
            guard let data = autoPauseAppsJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([AutoPauseAppEntry].self, from: data) else {
                return []
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                autoPauseAppsJSON = json
            } else {
                autoPauseAppsJSON = "[]"
            }
            objectWillChange.send()
        }
    }

    /// JSON-encoded `WritingStyleBindingStore` (complex value not stored via `@AppStorage`).
    var writingStyleBindingsJSON: String {
        get { UserDefaults.standard.string(forKey: PreferenceKey.writingStyleBindings) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: PreferenceKey.writingStyleBindings)
        }
    }

    /// Last decode of `writingStyleBindingsJSON`, keyed by the JSON it came
    /// from. SwiftUI reads the binding list several times per `body`, and
    /// re-parsing the whole store on each read is pure waste; keying on the
    /// source string keeps an external write (tests, another window) honest.
    private var decodedBindingsCache: (json: String, bindings: [AppStyleBinding])?

    /// Per-app writing style rules. A corrupt payload decodes to an empty list
    /// so dictation falls back to the default style rather than failing.
    var writingStyleBindings: [AppStyleBinding] {
        get {
            let json = writingStyleBindingsJSON
            if let cache = decodedBindingsCache, cache.json == json {
                return cache.bindings
            }
            let bindings = WritingStyleBindingStore.decode(json: json).bindings
            decodedBindingsCache = (json, bindings)
            return bindings
        }
        set {
            let json = WritingStyleBindingStore(bindings: newValue).encodedJSON()
            writingStyleBindingsJSON = json
            decodedBindingsCache = (json, newValue)
            refreshActiveWritingStyle()
            objectWillChange.send()
        }
    }

    /// True while a configured auto-pause app is running and dictation is blocked.
    @Published var isAutoPaused: Bool = false

    /// Set when the last recording could not use the pinned microphone.
    /// Cleared when a recording starts on the requested device.
    @Published var inputDeviceFallbackNotice: String?

    /// True while the audio engine is negotiating its input route. Bluetooth
    /// headsets can take seconds to switch to their microphone, and a stop
    /// arriving in that window has to be deferred rather than blocked on.
    private var isStartingAudio = false

    /// How to finish a start that the user interrupted while it was still
    /// negotiating the route.
    private var pendingStopDuringStart: PendingStopKind?

    /// Frontmost app captured when recording started. Used only when the app
    /// in front at injection time is VocaMac itself (Settings has focus).
    private var pendingTargetApp: RunningAppSnapshot?

    private enum PendingStopKind {
        /// Push-to-talk released: keep whatever the engine managed to capture.
        case transcribe
        /// Overlay cancel: throw the recording away.
        case discard
    }

    /// Last reason the speech model was unloaded (nil while a model is loaded).
    @Published var lastModelUnloadReason: ModelUnloadReason?

    /// Display name of the app that triggered the current auto-pause, if any.
    @Published var autoPauseTriggerDisplayName: String?

    /// Style that would be used if the user dictated right now. Drives the
    /// menu bar indicator; refreshed when the popover appears and after every
    /// dictation, never on a timer.
    @Published private(set) var activeWritingStyle: ResolvedWritingStyle = .plain
    @Published var nextWritingProfile: WritingProfile?
    @Published private(set) var lastOutput: DictationOutputResult?
    @Published private(set) var heldOutput: String?

    /// Explicit recovery only: never paste a delayed result into a changed app.
    func copyHeldOutput() {
        guard let heldOutput else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(heldOutput, forType: .string)
        self.heldOutput = nil
    }

    func useNextWritingFormat(_ format: WritingStyle) {
        var profile = nextWritingProfile ?? resolveWritingStyle(for: writingStyleTargetApp).profile
        profile.format = format
        profile.rules = format.defaultRules
        if profile.cleanup == .raw {
            profile.cleanup = .inherit
        }
        nextWritingProfile = profile
    }

    func useNextWritingIntent(_ intent: WritingIntent) {
        var profile = nextWritingProfile ?? resolveWritingStyle(for: writingStyleTargetApp).profile
        profile.intent = intent
        // Choosing wording explicitly must override an app's Raw or
        // formatting-only policy for this utterance. The global switch and
        // local-model readiness still decide whether a rewrite can run.
        profile.cleanup = .inherit
        nextWritingProfile = profile
    }

    func useRawForNextDictation() {
        nextWritingProfile = WritingProfile(format: .plain, rules: .passthrough, cleanup: .raw)
    }

    /// Style used by the Settings preview and by Test Dictation, where the
    /// frontmost app is VocaMac's own window.
    @Published var settingsPreviewStyle: WritingStyle = .plain

    /// Optional app rule the preview targets instead of the bare preset, so a
    /// user who customized a rule can see what that rule actually does.
    @Published var settingsPreviewBindingID: String?

    /// Rules the Settings preview and Test Dictation run with.
    var settingsPreviewRules: WritingStyleRules {
        if let id = settingsPreviewBindingID,
           let binding = writingStyleBindings.first(where: { $0.id == id }) {
            return binding.effectiveRules
        }
        return settingsPreviewStyle.defaultRules
    }

    var settingsPreviewProfile: WritingProfile {
        let binding = writingStyleBindings.first { $0.id == settingsPreviewBindingID }
        return WritingProfile(
            format: binding?.style ?? settingsPreviewStyle,
            rules: settingsPreviewRules,
            intent: binding?.intent ?? writingIntent,
            cleanup: binding?.cleanup ?? .inherit,
            cleanupLevel: binding?.cleanupLevel,
            cleanupPrompt: binding?.cleanupPrompt
        )
    }

    func previewWritingProfile(_ text: String) async -> DictationOutputResult {
        await outputPipeline.process(
            text, profile: settingsPreviewProfile, snippetList: snippets,
            cleanupEnabled: transcriptCleanupEnabled, rewritingEnabled: writingRewriteEnabled,
            model: selectedCleanupModelKind, customPrompt: effectiveCleanupPrompt,
            cleanupLevel: transcriptCleanupLevel,
            language: RewriteValidation.detectedLanguage(text), autoCapitalize: autoCapitalize,
            trailingSpace: appendTrailingSpace, preview: true
        )
    }

    private var outputPipeline: DictationOutputPipeline {
        DictationOutputPipeline(cleaner: activeCleanupService, snippets: snippetExpander)
    }

    private var activeCleanupService: TranscriptCleaning {
        let endpoint = cleanupEndpoint
        guard !endpoint.isLocal else { return transcriptCleanup }
        return RemoteCleanupService(configuration: endpoint)
    }

    /// Approximate process RSS (MB) sampled just before the last unload.
    @Published var processMemoryBeforeUnloadMB: Double?

    /// Approximate process RSS (MB) sampled right after the last unload.
    @Published var processMemoryAfterUnloadMB: Double?

    private var hotKeySafetyTimeout: Double {
        Double(maxRecordingDuration) + 5.0
    }

    /// Persist the microphone VocaMac should use for future recordings.
    /// Passing nil restores the system-default input behavior.
    func selectAudioDevice(_ device: AudioDevice?) {
        let newDeviceID = device?.id ?? ""
        if selectedAudioDeviceID != newDeviceID {
            selectedAudioChannel = 0
            selectedAudioChannelDeviceID = newDeviceID
            selectedAudioChannelCount = device?.channelCount ?? 0
        }
        selectedAudioDeviceID = newDeviceID
        selectedAudioDeviceName = device?.name ?? ""

        if let device {
            syncSelectedAudioChannel(with: device)
        }
    }

    /// Persist the physical interface input selected for a specific device layout.
    func selectAudioChannel(_ channel: Int, for device: AudioDevice) {
        selectedAudioChannelDeviceID = device.id
        selectedAudioChannelCount = device.channelCount
        guard device.channelCount > 0, channel >= 0, channel < device.channelCount else {
            selectedAudioChannel = 0
            return
        }
        selectedAudioChannel = channel
    }

    /// Reset a saved channel when the active device or its channel layout changes.
    func syncSelectedAudioChannel(with device: AudioDevice) {
        let mappingIsCurrent = selectedAudioChannelDeviceID == device.id
            && selectedAudioChannelCount == device.channelCount
        let channelIsValid = selectedAudioChannel >= 0
            && selectedAudioChannel < device.channelCount
        if !mappingIsCurrent || !channelIsValid {
            selectedAudioChannel = 0
        }
        selectedAudioChannelDeviceID = device.id
        selectedAudioChannelCount = device.channelCount
    }

    /// Custom text snippets for expansion
    @Published var snippets: [Snippet] = []

    /// Spoken forms rewritten to the user's text, for every engine.
    @Published var wordReplacements: [WordReplacement] = []

    /// Corrections noticed in dictated text, waiting for the user to accept.
    @Published private(set) var dictionarySuggestions: [CorrectionSuggestion] = []

    /// History entry whose audio is being transcribed again, if any.
    @Published private(set) var retryingHistoryEntryID: UUID?

    /// Settings page to show the next time the Settings window appears.
    @Published var requestedSettingsPage: SettingsPage?

    /// Failed dictation whose retry banner the user closed.
    @Published private(set) var dismissedRecoveryEntryID: UUID?

    /// History entry for the dictation being transcribed right now.
    private var activeHistoryEntryID: UUID?

    /// Whether the current recording was started with the hands-free
    /// shortcut, so silence ends it the way it ends a double-tap recording.
    private var isHandsFreeSession = false

    /// True from the end of a recording until its text is delivered. Escape
    /// cancels during this window as well as while recording.
    private var isTranscribing = false {
        didSet { refreshCancelKeyArming() }
    }

    /// Names and identifiers read from the screen when recording started.
    private var screenContextTask: Task<[String], Never>?
    private var screenDocumentURLTask: Task<URL?, Never>?

    /// Selection captured before Command Mode starts recording its instruction.
    private var activeCommandSelection: SelectedTextSnapshot?
    private var commandModePressStartedAt: Date?
    private var commandModeShouldStopAfterStart = false
    /// A quick press toggles Command Mode; holding past this point stops on
    /// release. Internal so flow tests can exercise both gestures instantly.
    var commandModeHoldThreshold: TimeInterval = 0.35
    private var nonInjectedOutputDestination: ScratchpadOutputDestination = .settingsTest

    /// Suggestions the user dismissed, so the same fix isn't offered again.
    private var dismissedSuggestionKeys: Set<String> = []

    /// Whether a word is ordinary vocabulary in a language. Replaceable in tests.
    var isKnownWord: (String, String?) -> Bool

    // MARK: - Services

    let audioEngine: AudioRecording
    let whisperService: SpeechTranscribing
    let textInjector: TextInjecting
    let hotKeyManager: HotKeyMonitoring
    let modelManager: ModelManaging
    let soundManager: SoundPlaying
    let audioDucker: AudioDucking
    let cursorOverlay: CursorOverlayManaging
    let statsManager: StatsManaging
    let snippetExpander: SnippetExpanding
    let transcriptCleanup: TranscriptCleaning
    let updateChecker = UpdateChecker()
    let permissionManager: any PermissionManaging
    /// Identifies the app that will receive injected text.
    let frontmostAppResolver: any FrontmostAppResolving
    /// Past dictations, their text, and their audio.
    let historyStore: DictationHistoryStore
    /// Reads names and identifiers from the screen; nil when disabled.
    let screenContextReader: (any ScreenContextReading)?
    /// Notices the user fixing dictated words; nil when disabled.
    let correctionObserver: (any CorrectionObserving)?
    let selectedTextService: (any SelectedTextAccessing)?

    /// Polls configured apps and pauses dictation while they run.
    let autoPauseMonitor = AutoPauseMonitor()
    /// Unloads the model after an idle timeout when enabled.
    let modelKeepAlive = ModelKeepAlive()
    /// Sleep/wake recovery hooks.
    let sleepWakeMonitor = SleepWakeMonitor()

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private var hasStarted = false

    /// Why the model was last unloaded (for logs / UI).
    enum ModelUnloadReason: String {
        case autoPause = "auto_pause"
        case idleKeepAlive = "idle_keepalive"
        case manual = "manual"
    }

    /// Bumped when each load operation starts. Failure restores and success UI
    /// updates only apply when the generation is still current, so a stale
    /// failure cannot undo a newer successful load.
    private var loadGeneration: UInt64 = 0

    /// Serializes model downloads and loads at the AppState boundary. The
    /// engine router also protects its own load/transcribe lifecycle, but UI
    /// actions can otherwise start several downloads or model-management
    /// operations before they reach those lower-level services.
    private let modelOperationSerializer = LoadSerializer()

    /// AudioEngine serializes its own lifecycle internally; this wrapper makes
    /// the intentional background handoff explicit for Dispatch's @Sendable API.
    private struct AudioEngineWorker: @unchecked Sendable {
        let audioEngine: AudioRecording

        func startRecording(
            silenceThreshold: Float,
            silenceDuration: Double,
            maxDuration: TimeInterval,
            preferredInputDeviceID: String?,
            preferredInputChannel: Int,
            preferredInputChannelDeviceID: String?,
            preferredInputChannelCount: Int
        ) -> Bool {
            audioEngine.startRecording(
                silenceThreshold: silenceThreshold,
                silenceDuration: silenceDuration,
                maxDuration: maxDuration,
                preferredInputDeviceID: preferredInputDeviceID,
                preferredInputChannel: preferredInputChannel,
                preferredInputChannelDeviceID: preferredInputChannelDeviceID,
                preferredInputChannelCount: preferredInputChannelCount
            )
        }

        func stopRecording() -> [Float] {
            audioEngine.stopRecording()
        }
    }

    /// Process-level flag that prevents performStartup from running more than
    /// once even when SwiftUI instantiates multiple AppState objects (which it
    /// does during MenuBarExtra scene setup). Instance-level `hasStarted` guards
    /// re-entry on the same object; this static flag guards across all instances.
    ///
    /// Internal (not private) so test teardown can reset it between test cases.
    static var hasStartedGlobally = false

    /// Whether to skip system integration calls (SMAppService, etc.) during init.
    /// Set to `true` in tests to avoid side effects.
    let skipSystemIntegration: Bool

    /// Pre-load memory gate. Production defaults to SystemInfo; tests stub this
    /// so CI free+inactive pages cannot flake medium/large mock loads.
    var modelFitsInMemory: (ModelSize) -> Bool = { SystemInfo.canFitModelInMemory($0) }
    var availableInputDevices: () -> [AudioDevice] = { AudioEngine.availableInputDevices() }
    var isLidClosed: () -> Bool = { LidStateReader.isClosed() }

    // MARK: - Initialization

    init(
        audioEngine: AudioRecording = AudioEngine(),
        whisperService: SpeechTranscribing = TranscriptionRouter(),
        textInjector: TextInjecting = TextInjector(),
        hotKeyManager: HotKeyMonitoring = HotKeyManager(),
        modelManager: ModelManaging = ModelManager(),
        soundManager: SoundPlaying = SoundManager(),
        audioDucker: AudioDucking = AudioDucker(),
        cursorOverlay: CursorOverlayManaging,
        statsManager: StatsManaging,
        snippetExpander: SnippetExpanding = SnippetExpander(),
        transcriptCleanup: TranscriptCleaning,
        permissionManager: (any PermissionManaging)? = nil,
        // Not a default expression: `FrontmostAppResolver` is @MainActor and
        // default arguments are evaluated outside the initializer's isolation,
        // the same reason `cursorOverlay` has no default either.
        frontmostAppResolver: (any FrontmostAppResolving)? = nil,
        historyStore: DictationHistoryStore? = nil,
        screenContextReader: (any ScreenContextReading)? = nil,
        correctionObserver: (any CorrectionObserving)? = nil,
        selectedTextService: (any SelectedTextAccessing)? = nil,
        skipSystemIntegration: Bool = false
    ) {
        self.audioEngine = audioEngine
        self.whisperService = whisperService
        self.textInjector = textInjector
        self.hotKeyManager = hotKeyManager
        self.modelManager = modelManager
        self.soundManager = soundManager
        self.audioDucker = audioDucker
        self.cursorOverlay = cursorOverlay
        self.statsManager = statsManager
        self.frontmostAppResolver = frontmostAppResolver ?? FrontmostAppResolver()
        self.snippetExpander = snippetExpander
        self.transcriptCleanup = transcriptCleanup
        self.permissionManager = permissionManager ?? PermissionManager(audioEngine: audioEngine, hotKeyManager: hotKeyManager)
        self.skipSystemIntegration = skipSystemIntegration
        // Tests and other headless runs keep history in memory and never read
        // another app's text.
        self.historyStore = historyStore
            ?? DictationHistoryStore(directory: skipSystemIntegration ? nil : DictationHistoryStore.defaultDirectory)
        self.screenContextReader = screenContextReader ?? (skipSystemIntegration ? nil : ScreenContextReader())
        self.correctionObserver = correctionObserver ?? (skipSystemIntegration ? nil : CorrectionObserver())
        self.selectedTextService = selectedTextService
            ?? (skipSystemIntegration ? nil : AccessibilitySelectedTextService(textInjector: textInjector))
        self.isKnownWord = { word, language in
            MainActor.assumeIsolated { SpellingOracle.shared.isKnownWord(word, language: language) }
        }

        VocaLogger.info(.appState, "Initializing... id=\(ObjectIdentifier(self))")
        loadSnippets()
        loadDictionary()
        if !skipSystemIntegration {
            syncLaunchAtLogin()
        }
        setupServices()

        // Forward updateChecker changes so SwiftUI views observing AppState
        // re-render when updateState changes (nested ObservableObject fix).
        updateChecker.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Forward statsManager changes
        statsManager.objectWillChangePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        transcriptCleanup.objectWillChangePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        self.historyStore.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        self.historyStore.applyRetention(historyRetention)
    }

    /// Single production AppState instance for the process.
    ///
    /// SwiftUI can recreate the `App` value during scene setup, especially for
    /// menu bar apps. Keeping the production instance outside the `App` value's
    /// stored-property initialization prevents duplicate service graphs, event
    /// taps, audio observers, and stale SwiftUI environment objects.
    @MainActor
    private static let sharedProductionInstance = AppState(
        cursorOverlay: CursorOverlayManager(),
        statsManager: StatsManager(),
        transcriptCleanup: TranscriptCleanupService()
    )

    /// Convenience factory for creating AppState with all real services.
    /// Needed because CursorOverlayManager is @MainActor and can't be a default parameter.
    @MainActor
    static func production() -> AppState {
        VocaLogger.debug(.appState, "Using production AppState id=\(ObjectIdentifier(sharedProductionInstance))")
        return sharedProductionInstance
    }

    /// Called once from the SwiftUI lifecycle to complete initialization.
    /// Safe to call multiple times and across multiple instances — only the
    /// first call across the entire process takes effect.
    func triggerStartupIfNeeded() {
        guard !hasStarted, !AppState.hasStartedGlobally else {
            VocaLogger.debug(.appState, "triggerStartupIfNeeded called again — skipping (already started)")
            return
        }
        hasStarted = true
        AppState.hasStartedGlobally = true
        Task {
            await performStartup()
        }
    }

    // MARK: - Launch at Login

    /// Sync the persisted launchAtLogin preference with SMAppService.
    /// Called once on init to reconcile state (e.g. if the user toggled it
    /// in System Settings directly, or if the app was re-installed).
    private func syncLaunchAtLogin() {
        let currentStatus = SMAppService.mainApp.status
        let isRegistered = currentStatus == .enabled

        if launchAtLogin && !isRegistered {
            // User wants launch-at-login but it's not registered — register now
            setLaunchAtLogin(true)
        } else if !launchAtLogin && isRegistered {
            // Persisted preference says disabled but system says enabled — unregister
            setLaunchAtLogin(false)
        }
    }

    /// Register or unregister the app as a login item via SMAppService.
    /// Updates the persisted `launchAtLogin` preference to match.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                VocaLogger.info(.appState, "Registered as login item")
            } else {
                try SMAppService.mainApp.unregister()
                VocaLogger.info(.appState, "Unregistered as login item")
            }
            launchAtLogin = enabled
        } catch {
            VocaLogger.error(.appState, "Failed to \(enabled ? "register" : "unregister") login item: \(error.localizedDescription)")
            // Revert the preference to match the actual system state
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Setup

    private func setupServices() {
        textInjector.onFailure = { [weak self] message in
            Task { @MainActor in
                guard let self, !self.isRecording else { return }
                self.showTemporaryError(message)
            }
        }
        // Detect system capabilities
        systemCapabilities = SystemInfo.detect()

        // Get WhisperKit's device recommendation.
        // WhisperKit's `.default` may not be in the supported list for some
        // devices. If so, fall back to the best supported model instead.
        let recommendation = modelManager.deviceRecommendation()
        VocaLogger.info(.appState, "WhisperKit recommendation — default: \(recommendation.defaultModel), supported: [\(recommendation.supported.joined(separator: ", "))], disabled: [\(recommendation.disabled.joined(separator: ", "))]")
        let defaultIsSupported = recommendation.supported.contains(recommendation.defaultModel)
        if !defaultIsSupported, let bestSupported = recommendation.supported.last {
            deviceRecommendedModel = bestSupported
        } else {
            deviceRecommendedModel = recommendation.defaultModel
        }

        rebuildAvailableModels()

        // Validate that the recommended model maps to a supported ModelSize.
        // If the recommendation points to an unsupported model, fall back to
        // the largest supported model instead.
        if let recommended = deviceRecommendedModel {
            let recommendedSize = modelManager.modelSize(from: recommended)
            let isRecommendedSupported = recommendedSize.map { size in
                availableModels.first(where: { $0.size == size })?.isSupported == true
            } ?? false

            if !isRecommendedSupported {
                // Fall back to the largest supported WhisperKit model — the
                // recommendation badge reflects WhisperKit's per-device tuning,
                // so other engines are not candidates here.
                if let bestSupported = availableModels.last(where: { $0.isSupported && $0.size.engine == .whisperKit }) {
                    deviceRecommendedModel = modelManager.modelIdentifier(for: bestSupported.size)
                } else {
                    // No models are supported — clear the recommendation
                    deviceRecommendedModel = nil
                }
            }
        }

        // Setup audio level reporting
        audioEngine.onAudioLevel = { [weak self] level in
            Task { @MainActor in
                self?.audioLevel = level
                self?.cursorOverlay.updateAudioLevel(level)
            }
        }

        // Setup silence detection callback
        audioEngine.onSilenceDetected = { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                if (self.activationMode == .doubleTapToggle || self.isHandsFreeSession) && self.isRecording {
                    VocaLogger.info(.appState, "Silence detected — auto-stopping recording (toggle session)")
                    await self.stopRecordingAndTranscribe()
                }
            }
        }

        // Setup max recording duration callback.
        // AudioEngine fires this when the recording reaches maxRecordingDuration.
        // This is the primary duration limit — the HotKeyManager safety timer
        // (maxRecordingDuration + 5s) acts as a backstop in case this callback
        // fails or the key-up event is lost entirely.
        audioEngine.onMaxDurationReached = { [weak self] in
            Task { @MainActor in
                guard let self = self, self.isRecording else { return }
                VocaLogger.info(.appState, "Max recording duration (\(self.maxRecordingDuration)s) reached — auto-stopping")
                await self.stopRecordingAndTranscribe()
            }
        }

        // Setup audio device change callback.
        // Fires when the microphone is unplugged/replugged, Bluetooth disconnects,
        // or the default audio device changes (e.g., after sleep). AudioEngine has
        // already stopped and reset itself — we just need to recover the app state.
        audioEngine.onAudioDeviceChanged = { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                VocaLogger.warning(.appState, "Audio device changed — recovering from interrupted recording")
                self.recordingGeneration = UUID()
                self.isRecording = false
                self.audioLevel = 0.0
                self.cursorOverlay.hide()
                self.hotKeyManager.resetKeyState()
                self.appStatus = .idle
                self.errorMessage = nil
            }
        }

        // The pinned microphone could not be configured and recording fell back
        // to another device. Surface it so the user isn't left wondering why the
        // transcript came from the built-in mic.
        audioEngine.onInputDeviceFallback = { [weak self] notice in
            Task { @MainActor in
                guard let self else { return }
                VocaLogger.warning(.appState, notice)
                self.inputDeviceFallbackNotice = notice
            }
        }

        // Setup hotkey callbacks
        hotKeyManager.onRecordingStart = { [weak self] in
            PerformanceTrace.event("HotKeyStart")
            Task { @MainActor in
                await self?.startRecording()
            }
        }

        hotKeyManager.onRecordingStop = { [weak self] in
            PerformanceTrace.event("HotKeyStop")
            Task { @MainActor in
                await self?.stopRecordingAndTranscribe()
            }
        }

        if let shortcutMonitor = hotKeyManager as? HotKeyShortcutMonitoring {
            shortcutMonitor.onShortcut = { [weak self] action in
                Task { @MainActor in
                    await self?.handleShortcut(action)
                }
            }
            shortcutMonitor.onShortcutReleased = { [weak self] action in
                Task { @MainActor in
                    await self?.handleShortcutReleased(action)
                }
            }
            shortcutMonitor.onCancel = { [weak self] in
                Task { @MainActor in
                    await self?.cancelDictation()
                }
            }
        }
        syncShortcutConfiguration()

        // Escape is only claimed while there is a dictation to cancel.
        $appStatus
            .sink { [weak self] status in
                self?.refreshCancelKeyArming(status: status)
            }
            .store(in: &cancellables)

        correctionObserver?.onCorrections = { [weak self] corrections in
            self?.receiveCorrections(corrections)
        }

        // Wire permission manager: start hotkey listener when permissions granted
        permissionManager.onAllPermissionsGranted = { [weak self] in
            guard let self = self else { return }
            self.hotKeyManager.startListening(
                keyCode: self.hotKeyCode,
                mode: self.activationMode,
                doubleTapThreshold: self.doubleTapThreshold,
                safetyTimeout: self.hotKeySafetyTimeout,
                modifiers: self.hotKeyModifiers
            )
            VocaLogger.info(.appState, "Hotkey listener started after permission grant")
        }

        // Forward PermissionManager state changes to trigger SwiftUI updates
        permissionManager.objectWillChangePublisher
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Quit and Restart call `terminate` without setting `isRecording` to
        // false, so the didSet restore never runs. Unmute other audio here
        // directly. A second restore is a no-op when nothing is pending.
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.audioDucker.restore()
                self?.statsManager.flushPendingSaves()
                self?.historyStore.saveIfNeeded()
            }
            .store(in: &cancellables)

        // `currentStreak` is a cached, persisted value. Refresh it when the
        // local calendar context changes so an inactive streak does not stay visible.
        NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .sink { [weak self] _ in
                self?.statsManager.refreshCurrentStreak()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)
            .sink { [weak self] _ in
                self?.statsManager.refreshCurrentStreak()
            }
            .store(in: &cancellables)

        // Auto-save snippets when changed. @Published emits on willSet, so
        // persist the emitted array — reading self.snippets here would save
        // the previous state and leave the latest change unsaved.
        $snippets
            .dropFirst()  // skip the subscription replay of the just-loaded value
            .sink { [weak self] snippets in
                self?.saveSnippets(snippets)
            }
            .store(in: &cancellables)

        $wordReplacements
            .dropFirst()
            .sink { replacements in
                Self.saveJSON(replacements, forKey: PreferenceKey.wordReplacements)
            }
            .store(in: &cancellables)

        // Check permissions
        checkPermissions()

        if !skipSystemIntegration {
            setupPowerManagement()
        }
    }

    // MARK: - Power Management

    /// Wire auto-pause, idle unload, and sleep/wake monitors.
    private func setupPowerManagement() {
        autoPauseMonitor.getConfig = { [weak self] in
            guard let self else {
                return (false, [], AutoPauseMonitor.defaultPollIntervalSeconds)
            }
            return (
                self.autoPauseEnabled,
                self.autoPauseApps,
                self.autoPausePollIntervalSeconds
            )
        }
        autoPauseMonitor.onPause = { [weak self] in
            Task { @MainActor in
                await self?.handleAutoPauseEntered()
            }
        }
        autoPauseMonitor.onResume = { [weak self] in
            Task { @MainActor in
                await self?.handleAutoPauseCleared()
            }
        }

        modelKeepAlive.getConfig = { [weak self] in
            guard let self else {
                return (false, ModelKeepAlive.defaultIdleTimeoutSeconds)
            }
            return (self.modelKeepAliveEnabled, self.modelKeepAliveIdleTimeoutSeconds)
        }
        modelKeepAlive.isSafeToUnload = { [weak self] in
            guard let self else { return false }
            // The cleanup LLM holds as much RAM as a speech model, so idle
            // unload has to consider it too — otherwise enabling keep-alive
            // frees the transcriber and leaves a GGUF resident forever.
            return self.appStatus == .idle
                && !self.isAutoPaused
                && (self.whisperService.isModelLoaded || self.transcriptCleanup.isLoaded)
        }
        modelKeepAlive.onIdleUnload = { [weak self] in
            Task { @MainActor in
                await self?.unloadActiveModel(reason: .idleKeepAlive)
            }
        }

        sleepWakeMonitor.onWillSleep = { [weak self] in
            self?.modelKeepAlive.cancel()
            if self?.isRecording == true || self?.appStatus == .recording {
                self?.forceRecovery()
            }
        }
        sleepWakeMonitor.onDidWake = { [weak self] in
            guard let self else { return }
            VocaLogger.info(.appState, "Wake recovery: refreshing hotkey health")
            if self.permissionManager.allPermissionsGranted {
                self.syncHotKeyConfiguration()
                if !self.hotKeyManager.isListening {
                    self.hotKeyManager.startListening(
                        keyCode: self.hotKeyCode,
                        mode: self.activationMode,
                        doubleTapThreshold: self.doubleTapThreshold,
                        safetyTimeout: self.hotKeySafetyTimeout,
                        modifiers: self.hotKeyModifiers
                    )
                }
            }
            if !self.isAutoPaused {
                self.modelKeepAlive.bump()
            }
        }

        $appStatus
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .idle:
                    if !self.isAutoPaused {
                        self.modelKeepAlive.bump()
                    }
                case .recording, .processing, .error:
                    self.modelKeepAlive.cancel()
                }
            }
            .store(in: &cancellables)

        autoPauseMonitor.start()
        modelKeepAlive.start()
        sleepWakeMonitor.start()
        if !skipSystemIntegration {
            AudioDeviceMonitor.shared.start()
        }
    }

    /// Unload the resident model and clear active UI flags.
    func unloadActiveModel(reason: ModelUnloadReason) async {
        VocaLogger.info(.appState, "Unloading model (reason=\(reason.rawValue))")
        modelKeepAlive.cancel()
        let beforeMB = ProcessMonitor.currentResidentMemoryMB()
        processMemoryBeforeUnloadMB = beforeMB
        await whisperService.unloadModel()
        transcriptCleanup.unload()
        // Give the allocator a beat to release pages before sampling again.
        try? await Task.sleep(nanoseconds: 150_000_000)
        let afterMB = ProcessMonitor.currentResidentMemoryMB()
        processMemoryAfterUnloadMB = afterMB
        lastModelUnloadReason = reason
        for i in availableModels.indices {
            availableModels[i].isActive = false
            availableModels[i].isLoading = false
        }
        currentModel = nil
        VocaLogger.info(
            .appState,
            "Unload complete (reason=\(reason.rawValue), RSS \(String(format: "%.0f", beforeMB))→\(String(format: "%.0f", afterMB)) MB)"
        )
    }

    /// Approximate RAM freed by the last unload, when both samples exist.
    var approximateMemoryFreedMB: Double? {
        guard let before = processMemoryBeforeUnloadMB,
              let after = processMemoryAfterUnloadMB,
              before > after else {
            return nil
        }
        return before - after
    }

    /// User-facing summary of why the model is currently unloaded.
    var modelUnloadStatusMessage: String? {
        guard !whisperService.isModelLoaded else { return nil }
        if isAutoPaused {
            if let name = autoPauseTriggerDisplayName, !name.isEmpty {
                return "Paused while \(name) is running. The speech model was unloaded to free memory."
            }
            return "Paused by a listed app. The speech model was unloaded to free memory."
        }
        switch lastModelUnloadReason {
        case .idleKeepAlive:
            return "Model unloaded after idle timeout. Next dictation reloads it."
        case .autoPause:
            return "Model unloaded by auto-pause."
        case .manual:
            return "Model unloaded."
        case .none:
            return nil
        }
    }

    /// Ensure a model is loaded before dictation (lazy reload after idle unload).
    func ensureModelLoaded() async {
        guard !whisperService.isModelLoaded else { return }
        let size = ModelSize(rawValue: selectedModelSize)
            ?? currentModel?.size
            ?? .tiny
        VocaLogger.info(.appState, "Ensuring model loaded: \(size.displayName)")
        await loadModel(size)
    }

    private func handleAutoPauseEntered() async {
        isAutoPaused = true
        autoPauseTriggerDisplayName = autoPauseMonitor.activeTrigger?.displayName
        modelKeepAlive.cancel()

        if isRecording || appStatus == .recording {
            VocaLogger.warning(.appState, "Auto-pause entered while recording: stopping without inject")
            _ = await stopAudioEngine()
            isRecording = false
            audioLevel = 0
            cursorOverlay.hide()
            hotKeyManager.resetKeyState()
            appStatus = .idle
        }

        if whisperService.isModelLoaded {
            await unloadActiveModel(reason: .autoPause)
        } else {
            lastModelUnloadReason = .autoPause
        }
    }

    private func handleAutoPauseCleared() async {
        isAutoPaused = false
        autoPauseTriggerDisplayName = nil
        // Warm-reload so the next hotkey is ready (Linux behavior).
        await ensureModelLoaded()
        modelKeepAlive.bump()
    }

    /// Build the model list shown in Settings and onboarding.
    ///
    /// The base catalog is curated for M-series Macs, then extended with any
    /// exact variants WhisperKit marks supported for the current device.
    /// Models whose engine cannot run on this system at all (e.g. Apple
    /// Speech before macOS 26, Parakeet on Intel) are excluded entirely.
    private func modelCatalog() -> [ModelSize] {
        var catalog = ModelSize.standardCatalog.filter { $0.isAvailableOnThisSystem }

        for size in ModelSize.allCases
        where size.isAvailableOnThisSystem && modelManager.isModelSupported(size) {
            if !catalog.contains(size) {
                catalog.append(size)
            }
        }

        if let selected = ModelSize(rawValue: selectedModelSize),
           !catalog.contains(selected) {
            catalog.append(selected)
        }

        return catalog
    }

    /// Recreate model UI state from the latest catalog and local cache status.
    private func rebuildAvailableModels() {
        availableModels = modelCatalog().map { size in
            WhisperModelInfo(
                size: size,
                filePath: modelManager.modelFolder(for: size),
                isDownloaded: modelManager.isModelDownloaded(size),
                isActive: size.rawValue == selectedModelSize,
                isSupported: modelManager.isModelSupported(size)
            )
        }
    }

    /// Resolve WhisperKit's recommended exact model variant into app metadata.
    private func recommendedModelSize() -> ModelSize? {
        guard let recommended = deviceRecommendedModel,
              let size = modelManager.modelSize(from: recommended),
              modelManager.isModelSupported(size) else {
            return nil
        }
        return size
    }

    /// Pick a supported startup model when the stored preference is no longer valid.
    private func startupFallbackModel(for preferred: ModelSize) -> ModelSize {
        guard !modelManager.isModelSupported(preferred) else {
            return preferred
        }

        // Stay on the engine the user was already using where possible.
        // Without this, the catalog order alone decides the fallback, and a
        // Whisper user could land on a different engine — notably Apple
        // Speech, which always counts as downloaded because macOS owns it.
        if let sameEngine = availableModels.last(where: {
            $0.size.engine == preferred.engine && $0.isSupported && $0.isDownloaded
        })?.size {
            return sameEngine
        }

        if let downloadedSupported = availableModels.last(where: { $0.isSupported && $0.isDownloaded })?.size {
            return downloadedSupported
        }

        if let recommended = recommendedModelSize() {
            return recommended
        }

        return .tiny
    }

    // MARK: - Permission Handling (delegated to PermissionManager)

    func checkPermissions() { permissionManager.checkPermissions() }
    func startPermissionPolling() { permissionManager.startPermissionPolling() }
    func stopPermissionPolling() { permissionManager.stopPermissionPolling() }
    var allPermissionsGranted: Bool { permissionManager.allPermissionsGranted }
    func requestMicrophonePermission() { permissionManager.requestMicrophonePermission() }
    func openMicrophoneSettings() { permissionManager.openMicrophoneSettings() }
    func requestAccessibilityPermission() { permissionManager.requestAccessibilityPermission() }
    func requestInputMonitoringPermission() { permissionManager.requestInputMonitoringPermission() }

    // MARK: - Hotkey Configuration

    /// Apply persisted hotkey settings to the active listener.
    /// `@AppStorage` updates save preferences immediately, but an already-running
    /// event tap also needs its in-memory configuration refreshed.
    func syncHotKeyConfiguration() {
        hotKeyManager.updateConfiguration(
            keyCode: hotKeyCode,
            mode: activationMode,
            doubleTapThreshold: doubleTapThreshold,
            safetyTimeout: hotKeySafetyTimeout,
            modifiers: hotKeyModifiers
        )
        VocaLogger.debug(.appState, "Hotkey configuration synced (keyCode=\(hotKeyCode), modifiers=\(hotKeyModifiers.rawValue), mode=\(activationMode.rawValue))")
    }

    // MARK: - Writing Styles

    /// Resolve the style for a target app using the current preferences.
    func resolveWritingStyle(for target: RunningAppSnapshot?, documentURL: URL? = nil) -> ResolvedWritingStyle {
        let appRule = WritingStyleResolver.resolve(
            target: target,
            bindings: writingStyleBindings,
            defaultStyle: writingStyleDefault,
            isEnabled: writingStyleEnabled,
            defaultIntent: writingIntent
        )
        return WritingStyleResolver.applyingWebsiteRule(
            appRule, url: documentURL, bindings: websiteStyleBindings
        )
    }

    /// Recompute `activeWritingStyle` for the app the user is working in.
    ///
    /// Called when the menu bar popover appears and after settings changes —
    /// deliberately not on a timer. Uses `styleTargetApp()` rather than the
    /// bare frontmost app: opening the popover activates VocaMac, so by the
    /// time this runs the frontmost app usually *is* VocaMac.
    func refreshActiveWritingStyle() {
        activeWritingStyle = resolveWritingStyle(for: frontmostAppResolver.styleTargetApp())
    }

    /// The app a menu bar action should apply to: whatever is in front, or the
    /// app the user came from when VocaMac's own window has focus.
    var writingStyleTargetApp: RunningAppSnapshot? {
        frontmostAppResolver.styleTargetApp()
    }

    /// Bind the target app to a style, replacing any existing rule for it.
    ///
    /// This is the menu bar's one-tap fix for "that came out wrong".
    @discardableResult
    func bindFrontmostApp(to style: WritingStyle) -> String? {
        guard let target = writingStyleTargetApp else {
            VocaLogger.warning(.appState, "Cannot bind writing style: no target app")
            showTemporaryError("No app to bind — switch to the app you want to style, then try again.")
            return nil
        }
        var bindings = writingStyleBindings
        let existing = bindings.last { $0.matches(target) }
        bindings.removeAll { $0.matches(target) }
        var binding = AppStyleBinding.from(snapshot: target, style: style)
        binding.intent = existing?.intent ?? .preserve
        binding.cleanup = existing?.cleanup ?? .inherit
        binding.cleanupLevel = existing?.cleanupLevel
        binding.cleanupPrompt = existing?.cleanupPrompt
        bindings.append(binding)
        writingStyleBindings = bindings
        VocaLogger.info(.appState, "Bound \(target.displayName) to writing style '\(style.rawValue)'")
        return target.displayName
    }

    /// Remove the target app's rule so it falls back to the default style.
    @discardableResult
    func unbindFrontmostApp() -> String? {
        guard let target = writingStyleTargetApp else {
            VocaLogger.warning(.appState, "Cannot clear writing style: no target app")
            showTemporaryError("No app to clear — switch to the app you want to reset, then try again.")
            return nil
        }
        let bindings = writingStyleBindings
        let remaining = bindings.filter { !$0.matches(target) }
        guard remaining.count != bindings.count else { return target.displayName }
        writingStyleBindings = remaining
        VocaLogger.info(.appState, "Cleared writing style rule for \(target.displayName)")
        return target.displayName
    }

    /// Delete every app rule, leaving the default style in charge.
    func removeAllWritingStyleBindings() {
        guard !writingStyleBindings.isEmpty else { return }
        writingStyleBindings = []
        VocaLogger.info(.appState, "Removed all writing style rules")
    }

    /// Add every suggestion for an installed app that is not already bound.
    ///
    /// Discovery is one LaunchServices lookup per catalog entry — a few dozen
    /// disk-backed queries — so it runs off the main actor and the caller shows
    /// a loading state while it does. Nothing is created without this being
    /// asked for: writing styles ship inert, because an app rule changes the
    /// shape of an existing user's dictation and an upgrade does not get to
    /// decide that for them.
    ///
    /// Returns how many rules were added. Bindings are re-read after the
    /// lookup so a rule the user added while it ran is preserved. Rules they
    /// removed (or cleared via Remove All) while discovery was pending are
    /// snapshotted at start and passed as merge exclusions so the append-only
    /// catalog merge cannot silently restore them.
    @discardableResult
    func addSuggestedWritingStyles() async -> Int {
        let running = AppIdentityMatching.workspaceRunningApps()
        let bindingsAtStart = writingStyleBindings
        let suggestions = await Task.detached(priority: .userInitiated) {
            WritingStyleCatalog.suggestionsForInstalledApps(running: running)
        }.value
        return applySuggestedWritingStyles(suggestions, bindingsAtStart: bindingsAtStart)
    }

    /// Finish a discovery pass: merge `suggestions` into the current bindings
    /// while excluding anything present in `bindingsAtStart` that the user has
    /// since removed. Exposed for tests so the mid-flight removal contract does
    /// not depend on MainActor scheduling of the LaunchServices await.
    @discardableResult
    func applySuggestedWritingStyles(
        _ suggestions: [WritingStyleCatalog.Suggestion],
        bindingsAtStart: [AppStyleBinding]
    ) -> Int {
        let existing = writingStyleBindings
        let removedDuringFlight = Self.writingStyleBindingsRemoved(
            from: bindingsAtStart,
            to: existing
        )
        let merged = WritingStyleCatalog.merging(
            existing,
            with: suggestions,
            excluding: removedDuringFlight
        )
        guard merged.count != existing.count else {
            VocaLogger.info(.appState, "No new writing style suggestions matched installed apps")
            return 0
        }
        writingStyleBindings = merged
        let added = merged.count - existing.count
        VocaLogger.info(.appState, "Added \(added) suggested writing style rule(s)")
        return added
    }

    /// Bindings present in `before` but gone from `after` under the same merge
    /// identity (id, bundle ID, or process name). Used so in-flight discovery
    /// does not treat a deliberate removal as an unbound installed app.
    private static func writingStyleBindingsRemoved(
        from before: [AppStyleBinding],
        to after: [AppStyleBinding]
    ) -> [AppStyleBinding] {
        before.filter { start in
            !after.contains { current in
                if current.id == start.id { return true }
                if let left = current.bundleIdentifier?.lowercased(),
                   let right = start.bundleIdentifier?.lowercased(),
                   left == right {
                    return true
                }
                let leftProcess = AppIdentityMatching.normalizeProcessName(
                    current.processName ?? current.id
                )
                let rightProcess = AppIdentityMatching.normalizeProcessName(
                    start.processName ?? start.id
                )
                return !leftProcess.isEmpty && leftProcess == rightProcess
            }
        }
    }

    /// Format sample text the way the given style would, for the Settings
    /// preview. Uses the same engine as the real pipeline.
    func writingStylePreview(_ sample: String, style: WritingStyle) -> String {
        writingStylePreview(sample, rules: style.defaultRules)
    }

    /// Preview a specific rule set — a preset, or one app rule's overrides.
    func writingStylePreview(_ sample: String, rules: WritingStyleRules) -> String {
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        let masked = snippetExpander.expandMasked(in: trimmed, using: snippets)
        let styled = WritingStyleEngine.format(
            masked.text,
            rules: rules,
            globalAutoCapitalize: autoCapitalize,
            globalTrailingSpace: appendTrailingSpace
        )
        return masked.restore(in: styled)
    }

    // MARK: - Force Recovery

    /// Forcibly reset the entire recording pipeline to idle state.
    /// This is a last-resort recovery mechanism callable from the menu bar UI.
    /// It unconditionally resets the audio engine, hotkey state, cursor overlay,
    /// and all published state back to idle.
    func forceRecovery() {
        recordingGeneration = UUID()
        finishingTranscription?.cancel()
        VocaLogger.warning(.appState, "Force recovery: resetting all state to idle (was appStatus=\(appStatus.rawValue), isRecording=\(isRecording))")

        // Reset audio engine unconditionally
        audioEngine.forceReset()

        // Reset hotkey tracking state
        hotKeyManager.resetKeyState()

        // Reset UI state
        isRecording = false
        audioLevel = 0.0
        cursorOverlay.hide()
        appStatus = .idle
        errorMessage = nil
        isTranscribing = false
        activeCommandSelection = nil
        commandModePressStartedAt = nil
        commandModeShouldStopAfterStart = false
        liveTranscript = ""
        screenContextTask?.cancel()
        screenContextTask = nil
        if let id = activeHistoryEntryID {
            historyStore.markCancelled(id)
            activeHistoryEntryID = nil
        }
    }

    /// Play start, then stop, for the tone currently selected in Settings.
    /// Off is silence. Preview is not gated by the sound-effects switch.
    func previewDictationTone() async {
        await soundManager.previewStartThenStop()
    }

    // MARK: - Recording Flow

    func startRecording(
        injectResult: Bool = true,
        outputDestination: ScratchpadOutputDestination = .settingsTest
    ) async {
        let interval = PerformanceTrace.begin("RecordingStart")
        defer { PerformanceTrace.end(interval) }
        // If we're already recording, this is a recovery attempt — the user
        // pressed the hotkey again because a previous key-up was missed.
        // Stop the current recording and transcribe what we have.
        if appStatus == .recording || isRecording {
            VocaLogger.warning(.appState, "startRecording called while already recording — treating as stop (recovery)")
            await stopRecordingAndTranscribe()
            return
        }

        if isAutoPaused {
            let message = "Dictation is paused while a listed app is running."
            VocaLogger.info(.appState, message)
            showTemporaryError(message)
            return
        }

        // Snapshot the target app now. Injection re-reads the frontmost app —
        // that is what actually receives the text — and only falls back to this
        // when VocaMac itself is in front at that point.
        pendingTargetApp = frontmostAppResolver.currentFrontmostApp()

        // Starting another dictation means the user is done fixing the last one.
        correctionObserver?.flush()

        guard appStatus == .idle else {
            // If stuck in .processing or .error for too long, force recovery
            // so the user can start a fresh recording.
            if appStatus == .error || appStatus == .processing {
                VocaLogger.warning(.appState, "startRecording called in \(appStatus.rawValue) state — force recovering to allow new recording")
                forceRecovery()
                // Don't start recording in the same call — let the user press again
                return
            }
            VocaLogger.warning(.appState, "startRecording called in non-idle state: \(appStatus.rawValue) — ignoring")
            return
        }
        guard micPermission == .granted else {
            errorMessage = "Microphone permission is required. Please grant access in System Settings."
            appStatus = .error
            return
        }

        // Lazy-reload after idle unload (or any other cold start).
        if !whisperService.isModelLoaded {
            appStatus = .processing
            await ensureModelLoaded()
            guard whisperService.isModelLoaded else {
                showTemporaryError("Could not load the speech model. Open Settings → Speech Model and try again.")
                return
            }
            appStatus = .idle
        }

        recordingGeneration = UUID()
        let generation = recordingGeneration
        recordingInjectsResult = injectResult
        nonInjectedOutputDestination = outputDestination
        startScreenContextCapture(injectResult: injectResult)
        appStatus = .recording
        liveTranscript = ""
        isRecording = true
        errorMessage = nil
        inputDeviceFallbackNotice = nil

        // Show the overlay in its connecting state. It only claims to be
        // listening once the audio engine confirms the route is live — on
        // Bluetooth that can be seconds later, and anything said before then is
        // not captured by anyone.
        if showCursorIndicator && overlayStyle != .off {
            cursorOverlay.show(style: overlayStyle, position: overlayPosition)
        }

        // Start recording immediately for instant responsiveness.
        // The start sound is played concurrently — any brief bleed into the
        // mic buffer is negligible and handled well by WhisperKit's noise model.
        isStartingAudio = true
        pendingStopDuringStart = nil
        let partialHandler: (@Sendable (String) -> Void)?
        if overlayStyle == .live {
            partialHandler = { [weak self] text in
                _ = Task<Void, Never> { @MainActor [weak self] in
                    guard let self, self.isRecording else { return }
                    self.liveTranscript = text
                    self.cursorOverlay.updateTranscript(text)
                }
            }
        } else {
            partialHandler = nil
        }
        let session = whisperService.startStreaming(
            language: selectedLanguage == "auto" ? nil : selectedLanguage,
            vocabulary: customVocabulary,
            onPartial: partialHandler
        )
        recordingTranscription = session
        audioEngine.onAudioSamples = session.map { session in
            { samples, offset in session.append(samples, at: offset) }
        }
        let automaticExternal = automaticExternalInputIfNeeded()
        let didStartRecording = await startAudioEngine(
            silenceThreshold: Float(silenceThreshold),
            silenceDuration: silenceDuration,
            maxDuration: TimeInterval(maxRecordingDuration),
            preferredInputDeviceID: automaticExternal?.id
                ?? (selectedAudioDeviceID.isEmpty ? nil : selectedAudioDeviceID),
            preferredInputChannel: automaticExternal == nil ? selectedAudioChannel : 0,
            preferredInputChannelDeviceID: automaticExternal?.id
                ?? (selectedAudioChannelDeviceID.isEmpty ? nil : selectedAudioChannelDeviceID),
            preferredInputChannelCount: automaticExternal?.channelCount ?? selectedAudioChannelCount
        )
        isStartingAudio = false

        // The hotkey was released (or the overlay cancelled) while the route was
        // still coming up. That stop was deferred so it wouldn't block behind the
        // Bluetooth settle; finish it now.
        if let pendingStop = pendingStopDuringStart {
            pendingStopDuringStart = nil
            await finishStartInterruptedByStop(pendingStop, didStartRecording: didStartRecording)
            return
        }

        guard didStartRecording else {
            VocaLogger.warning(.appState, "Audio engine failed to start — resetting recording state")
            isRecording = false
            audioLevel = 0.0
            activeCommandSelection = nil
            liveTranscript = ""
            cursorOverlay.hide()
            hotKeyManager.resetKeyState()
            // Silently dropping back to idle looks like the hotkey did nothing.
            // Tell the user which microphone we tried and where to change it.
            let deviceDescription = selectedAudioDeviceName.isEmpty
                ? "the system default microphone"
                : selectedAudioDeviceName
            showTemporaryError("Could not start \(deviceDescription). Pick a different input in Settings → Audio, or reconnect the device.")
            return
        }

        cursorOverlay.transitionToRecording()

        // Play start sound after mic is active (fire-and-forget).
        // Off is a stored tone and stays silent even when this switch is on.
        // Muting other audio would silence the cue too, so when that is on,
        // let the cue finish first.
        if soundEffectsEnabled && isRecording && appStatus == .recording {
            if duckOtherAudioEnabled {
                await soundManager.playStartSoundAsync()
            } else {
                soundManager.playStartSound()
            }
        }

        // Mute other audio once the microphone is live, so a start that never
        // gets a route leaves playback alone. Undone from `isRecording`'s
        // observer on every exit. The recording may have ended, or a new one
        // begun, while the cue played.
        if duckOtherAudioEnabled && isRecording && appStatus == .recording
            && recordingGeneration == generation {
            audioDucker.duck()
        }
    }

    private func automaticExternalInputIfNeeded() -> AudioDevice? {
        guard externalMicWhenLidClosed, isLidClosed() else { return nil }
        let devices = availableInputDevices()
        if let selected = devices.first(where: { $0.id == selectedAudioDeviceID }), !selected.isBuiltIn {
            return nil
        }
        let external = devices.filter { !$0.isBuiltIn }
            .sorted { lhs, rhs in lhs.isDefault && !rhs.isDefault }
            .first
        if let external {
            inputDeviceFallbackNotice = "MacBook lid is closed — recording from \(external.name)."
        }
        return external
    }

    func stopRecordingAndTranscribe(injectResult: Bool = true) async {
        // Start-time recordingInjectsResult alone decides injection. The parameter is kept
        // for source compatibility but ignored so practice/settings UIs cannot demote an ordinary hotkey session.
        let injectResult = recordingInjectsResult
        let interval = PerformanceTrace.begin("StopToResultQueued")
        defer { PerformanceTrace.end(interval) }
        // Accept stop if we're recording OR if the audio engine thinks
        // it's recording (covers stuck-state recovery scenarios where
        // isRecording and appStatus may be out of sync).
        guard isRecording || appStatus == .recording else { return }

        // A start that is still negotiating its input route holds the audio
        // engine's lifecycle queue. Calling stopRecording() here would block the
        // hotkey path for the whole Bluetooth settle and then hand back an empty
        // buffer — the "No microphone audio detected" report. Ask the engine to
        // abandon the start instead and let startRecording() finish up.
        if isStartingAudio {
            pendingStopDuringStart = .transcribe
            audioEngine.cancelPendingStart()
            return
        }

        guard !isStoppingAudio else { return }
        isStoppingAudio = true
        let generation = recordingGeneration
        let audioData = await stopAudioEngine()
        isStoppingAudio = false
        guard generation == recordingGeneration else { return }
        let session = recordingTranscription
        recordingTranscription = nil
        finishingTranscription = session
        defer {
            session?.cancel()
            if finishingTranscription === session { finishingTranscription = nil }
        }
        isRecording = false
        audioLevel = 0.0

        // Play stop sound
        if soundEffectsEnabled {
            soundManager.playStopSound()
        }

        // Transition cursor indicator to processing state (red -> purple)
        // Keeps the overlay visible so the user knows text is on its way
        cursorOverlay.transitionToProcessing()

        guard !audioData.isEmpty else {
            activeCommandSelection = nil
            liveTranscript = ""
            cursorOverlay.hide()
            appStatus = .idle
            return
        }

        guard audioData.contains(where: { abs($0) >= 0.0001 }) else {
            activeCommandSelection = nil
            cursorOverlay.hide()
            // Don't keep a route warm when it produced only silence.
            audioEngine.forceReset()
            let message = "No microphone audio detected. Check that the selected microphone is connected and available in Settings → Audio."
            VocaLogger.warning(.appState, message)
            showTemporaryError(message)
            return
        }

        appStatus = .processing
        isTranscribing = true
        defer {
            if generation == recordingGeneration { isTranscribing = false }
        }

        let contextTask = screenContextTask
        screenContextTask = nil
        let documentURLTask = screenDocumentURLTask
        screenDocumentURLTask = nil
        // Saved before transcribing, so a crash or failure can't lose it.
        let historyID = injectResult ? await beginHistoryEntry(audio: audioData) : nil
        activeHistoryEntryID = historyID
        guard generation == recordingGeneration else {
            // Escape arrived while the audio was being saved.
            if let historyID { historyStore.markCancelled(historyID) }
            return
        }

        do {
            let language = selectedLanguage == "auto" ? nil : selectedLanguage
            let contextTerms = await Self.awaitContextTerms(contextTask)
            let capturedDocumentURL = await Self.awaitDocumentURL(documentURLTask)
            let recognitionVocabulary = Self.recognitionVocabulary(
                customVocabulary, contextTerms: contextTerms
            )
            let result: VocaTranscription
            let selectedEngine = ModelSize(rawValue: selectedModelSize)?.engine
            let contextNeedsWhisperBatch = selectedEngine == .whisperKit
                && (!contextTerms.isEmpty || translationEnabled)
            if let session, session.language == language, !contextNeedsWhisperBatch {
                do {
                    result = try await session.finish(expectedSampleCount: audioData.count)
                } catch {
                    guard generation == recordingGeneration else { return }
                    try Task.checkCancellation()
                    PerformanceTrace.event("StreamingBatchFallback")
                    VocaLogger.warning(.appState, "Live transcription unavailable; decoding the complete recording")
                    result = try await whisperService.transcribe(
                        audioData: audioData, language: language,
                        translate: translationEnabled, vocabulary: recognitionVocabulary
                    )
                }
            } else {
                session?.cancel()
                result = try await whisperService.transcribe(
                    audioData: audioData, language: language,
                    translate: translationEnabled, vocabulary: recognitionVocabulary
                )
            }

            guard generation == recordingGeneration else {
                if let historyID { historyStore.markCancelled(historyID) }
                return
            }
            lastTranscription = result
            liveTranscript = ""

            // Update stats
            statsManager.recordTranscription(result)

            if let selection = activeCommandSelection {
                activeCommandSelection = nil
                await finishCommandMode(instruction: result.text, selection: selection)
                return
            }

            let trimmedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty {
                let target = frontmostAppResolver.currentFrontmostApp()
                    ?? pendingTargetApp ?? frontmostAppResolver.lastActiveApp()
                let documentURL = await revalidatedDocumentURL(capturedDocumentURL)
                let resolved = resolveWritingStyle(for: target, documentURL: documentURL)
                let profile = injectResult ? (nextWritingProfile ?? resolved.profile) : settingsPreviewProfile
                if injectResult {
                    nextWritingProfile = nil
                    activeWritingStyle = resolved
                }
                let output = await outputPipeline.process(
                    result.text, profile: profile, snippetList: snippets,
                    cleanupEnabled: transcriptCleanupEnabled, rewritingEnabled: writingRewriteEnabled,
                    model: selectedCleanupModelKind, customPrompt: effectiveCleanupPrompt,
                    cleanupLevel: transcriptCleanupLevel,
                    language: result.detectedLanguage, autoCapitalize: autoCapitalize,
                    trailingSpace: appendTrailingSpace, preview: !injectResult,
                    dictionary: dictionaryContext(contextTerms: contextTerms, language: result.detectedLanguage)
                )
                guard generation == recordingGeneration, !Task.isCancelled else {
                    if let historyID { historyStore.markCancelled(historyID) }
                    return
                }
                lastOutput = output
                if let historyID {
                    historyStore.complete(
                        historyID, rawText: result.text, finalText: output.text, summary: output.summary,
                        language: result.detectedLanguage, transcriptionSeconds: result.duration,
                        keepAudio: historyKeepsAudio
                    )
                }
                if injectResult {
                    let current = frontmostAppResolver.currentFrontmostApp()
                        ?? frontmostAppResolver.lastActiveApp() ?? pendingTargetApp
                    guard Self.sameOutputTarget(target, current) else {
                        heldOutput = output.text
                        cursorOverlay.hide()
                        errorMessage = "The destination app changed. Your dictation is saved in the menu bar; copy it to paste where you want."
                        appStatus = .error
                        return
                    }
                    textInjector.inject(text: output.text, preserveClipboard: preserveClipboard)
                    observeCorrections(to: output.text)
                } else {
                    if nonInjectedOutputDestination == .scratchpad {
                        if !scratchpadText.isEmpty, !scratchpadText.hasSuffix("\n") { scratchpadText += "\n" }
                        scratchpadText += output.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        settingsTestResultText = output.text
                    }
                }
            } else {
                VocaLogger.info(.appState, "Transcription produced no usable text (silence or blank audio)")
                if let historyID {
                    historyStore.complete(
                        historyID, rawText: result.text, finalText: "", summary: nil,
                        language: result.detectedLanguage, transcriptionSeconds: result.duration,
                        keepAudio: historyKeepsAudio
                    )
                }
                if !injectResult {
                    settingsTestResultText = nil
                }
            }

            cursorOverlay.hide()
            appStatus = .idle
        } catch {
            guard generation == recordingGeneration else {
                if let historyID { historyStore.markCancelled(historyID) }
                return
            }
            cursorOverlay.hide()
            activeCommandSelection = nil
            liveTranscript = ""
            var message = "Transcription failed: \(error.localizedDescription)"
            if let historyID {
                historyStore.markFailed(historyID, message: error.localizedDescription)
                if historyStore.entry(id: historyID)?.hasAudio == true {
                    message += " Your audio is saved — retry it from the menu bar."
                }
            }
            errorMessage = message
            appStatus = .error

            // Auto-recover after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                if self?.appStatus == .error {
                    self?.appStatus = .idle
                    self?.errorMessage = nil
                }
            }
        }
    }

    func toggleScratchpadRecording() async {
        if isRecording || appStatus == .recording {
            await stopRecordingAndTranscribe()
        } else {
            await startRecording(injectResult: false, outputDestination: .scratchpad)
        }
    }

    /// Cancels the active recording without sending its audio to a transcription
    /// engine. This is used by the overlay's cancel button.
    func cancelRecording() async {
        guard isRecording || appStatus == .recording else { return }

        if isStartingAudio {
            pendingStopDuringStart = .discard
            audioEngine.cancelPendingStart()
            return
        }

        _ = await stopAudioEngine()
        isRecording = false
        audioLevel = 0.0
        screenContextTask?.cancel()
        screenContextTask = nil
        screenDocumentURLTask?.cancel()
        screenDocumentURLTask = nil
        activeCommandSelection = nil
        commandModePressStartedAt = nil
        commandModeShouldStopAfterStart = false
        liveTranscript = ""
        cursorOverlay.hide()
        hotKeyManager.resetKeyState()
        appStatus = .idle
        errorMessage = nil
        VocaLogger.info(.appState, "Recording cancelled")
    }

    /// Escape: throw away a recording, or drop a dictation still being
    /// transcribed. A dictation cancelled mid-transcription keeps its audio in
    /// history, so an accidental Escape can be undone with Retry.
    func cancelDictation() async {
        if isRecording || appStatus == .recording {
            await cancelRecording()
            return
        }
        guard isTranscribing else { return }
        recordingGeneration = UUID()
        finishingTranscription?.cancel()
        activeCommandSelection = nil
        commandModePressStartedAt = nil
        commandModeShouldStopAfterStart = false
        liveTranscript = ""
        isTranscribing = false
        if let id = activeHistoryEntryID {
            historyStore.markCancelled(id)
            activeHistoryEntryID = nil
        }
        cursorOverlay.hide()
        hotKeyManager.resetKeyState()
        appStatus = .idle
        errorMessage = nil
        VocaLogger.info(.appState, "Dictation cancelled while transcribing")
    }

    /// Completes a recording the user ended while the microphone was still
    /// connecting. If the engine never reached the capture stage there is
    /// nothing to transcribe — no audio existed before the route came up — so
    /// say so plainly instead of reporting a mysterious silent recording.
    private func finishStartInterruptedByStop(
        _ kind: PendingStopKind,
        didStartRecording: Bool
    ) async {
        guard didStartRecording else {
            VocaLogger.info(.appState, "Recording ended while the microphone was still connecting")
            isRecording = false
            audioLevel = 0.0
            cursorOverlay.hide()
            hotKeyManager.resetKeyState()

            switch kind {
            case .discard:
                appStatus = .idle
                errorMessage = nil
            case .transcribe:
                showTemporaryError("The microphone was still connecting, so nothing was recorded. Bluetooth headsets need a moment — hold the hotkey until the start sound, then speak.")
            }
            return
        }

        // The route came up just as the user let go; treat it as a normal end.
        switch kind {
        case .transcribe:
            await stopRecordingAndTranscribe()
        case .discard:
            await cancelRecording()
        }
    }

    private func startAudioEngine(
        silenceThreshold: Float,
        silenceDuration: Double,
        maxDuration: TimeInterval,
        preferredInputDeviceID: String?,
        preferredInputChannel: Int,
        preferredInputChannelDeviceID: String?,
        preferredInputChannelCount: Int
    ) async -> Bool {
        let worker = AudioEngineWorker(audioEngine: audioEngine)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let didStart = worker.startRecording(
                    silenceThreshold: silenceThreshold,
                    silenceDuration: silenceDuration,
                    maxDuration: maxDuration,
                    preferredInputDeviceID: preferredInputDeviceID,
                    preferredInputChannel: preferredInputChannel,
                    preferredInputChannelDeviceID: preferredInputChannelDeviceID,
                    preferredInputChannelCount: preferredInputChannelCount
                )
                continuation.resume(returning: didStart)
            }
        }
    }

    private func stopAudioEngine() async -> [Float] {
        let worker = AudioEngineWorker(audioEngine: audioEngine)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: worker.stopRecording())
            }
        }
    }

    // MARK: - Model Management

    func loadModel(_ size: ModelSize? = nil) async {
        _ = try? await modelOperationSerializer.run { [self] in
            await performLoadModel(size)
        }
    }

    /// Perform one model load after earlier model operations have completed.
    private func performLoadModel(_ size: ModelSize? = nil) async {
        loadGeneration += 1
        let generation = loadGeneration

        let previousLoadedModelName = whisperService.loadedModelName
        let previousModelSize = currentModel?.size
            ?? previousLoadedModelName.flatMap { modelManager.modelSize(from: $0) }
            ?? ModelSize(rawValue: selectedModelSize)
        let hadLoadedModel = whisperService.isModelLoaded

        let modelName: String?
        if let size = size {
            modelName = modelManager.modelIdentifier(for: size)
        } else {
            modelName = nil  // Let WhisperKit auto-select
        }

        // Resolve which ModelSize we're loading. When size is nil (auto-select),
        // we don't know yet — we'll detect it after loading completes.
        let targetSize = size

        // Refuse known-too-large loads before WhisperKit/CoreML can hang the
        // UI spinner under memory pressure (vocamac#250). Leave any already
        // loaded model alone — we never started a load, so do not restore/clear.
        if let targetSize,
           !modelFitsInMemory(targetSize) {
            let needed = String(format: "%.1f", targetSize.ramRequiredGB)
            let failureMessage =
                "Not enough free memory to load \(targetSize.displayName) "
                + "(~\(needed) GB needed). Free RAM or choose a smaller model."
            showTemporaryError(failureMessage)
            VocaLogger.error(.appState, failureMessage)
            return
        }

        // Mark the model as loading in the UI
        if let targetSize = targetSize, let idx = availableModels.firstIndex(where: { $0.size == targetSize }) {
            availableModels[idx].isLoading = true
            availableModels[idx].loadingStatus = "Preparing…"
        }

        do {
            // If model is downloaded locally, pass the folder URL so WhisperKit
            // loads from disk instead of downloading again. WhisperKit handles
            // tokenizer fetching itself — we don't pre-validate those files.
            let folderURL: URL?
            if let targetSize = targetSize, modelManager.isModelDownloaded(targetSize) {
                folderURL = modelManager.modelFolder(for: targetSize)
            } else {
                folderURL = nil
            }

            // Update status: unpacking
            if let targetSize = targetSize, let idx = availableModels.firstIndex(where: { $0.size == targetSize }) {
                availableModels[idx].loadingStatus = "Unpacking model…"
            }

            // Load model with status callback
            try await whisperService.loadModel(name: modelName, folder: folderURL) { [weak self] phase in
                Task { @MainActor in
                    guard let self = self else { return }
                    if let targetSize = targetSize,
                       let idx = self.availableModels.firstIndex(where: { $0.size == targetSize }) {
                        self.availableModels[idx].loadingStatus = phase
                    }
                }
            }

            // Determine which ModelSize was actually loaded.
            // When auto-selecting, WhisperKit chooses the model and we need
            // to detect which one it picked by inspecting the loaded model name.
            let resolvedSize: ModelSize
            if let targetSize = targetSize {
                resolvedSize = targetSize
            } else {
                let loadedName = (whisperService.loadedModelName ?? "").lowercased()
                if let loadedSize = modelManager.modelSize(from: whisperService.loadedModelName ?? "") {
                    resolvedSize = loadedSize
                } else if loadedName.contains("v20240930_turbo") {
                    resolvedSize = .largeV3LatestTurbo
                } else if loadedName.contains("v20240930") {
                    resolvedSize = .largeV3Latest
                } else if loadedName.contains("distil") && loadedName.contains("turbo") {
                    resolvedSize = .distilLargeV3TurboCompact
                } else if loadedName.contains("distil") {
                    resolvedSize = .distilLargeV3Compact
                } else if loadedName.contains("large") && loadedName.contains("turbo") {
                    resolvedSize = .largeV3Turbo
                } else if loadedName.contains("large") {
                    resolvedSize = .largeV3
                } else if loadedName.contains("medium") {
                    resolvedSize = .medium
                } else if loadedName.contains("small") {
                    resolvedSize = .small
                } else if loadedName.contains("base") {
                    resolvedSize = .base
                } else {
                    resolvedSize = .tiny
                }
                VocaLogger.info(.appState, "Auto-selected model resolved to: \(resolvedSize.displayName) (from '\(whisperService.loadedModelName ?? "unknown")')")
            }

            // A newer loadModel started while we were waiting; leave UI to it.
            guard generation == loadGeneration else {
                clearLoadingFlag(for: targetSize)
                return
            }

            // Persist the resolved model as the user's preference
            selectedModelSize = resolvedSize.rawValue

            // Update model states — clear all, then mark the loaded one as active
            for i in availableModels.indices {
                let matches = availableModels[i].size == resolvedSize
                availableModels[i].isActive = matches
                availableModels[i].isLoading = false
                availableModels[i].loadingStatus = "Loading…"
                if matches {
                    // Refresh download status in case the auto-select downloaded it
                    availableModels[i].isDownloaded = modelManager.isModelDownloaded(resolvedSize)
                    currentModel = availableModels[i]
                }
            }

            lastModelUnloadReason = nil
            processMemoryBeforeUnloadMB = nil
            processMemoryAfterUnloadMB = nil
            VocaLogger.info(.appState, "Model ready: \(resolvedSize.displayName)")
        } catch {
            // A newer load superseded this one; do not restore over it.
            guard generation == loadGeneration else {
                clearLoadingFlag(for: targetSize)
                return
            }

            // Clear loading state on error for all models (covers auto-select case)
            for i in availableModels.indices {
                availableModels[i].isLoading = false
                availableModels[i].loadingStatus = "Loading…"
            }

            let modelDisplayName = targetSize?.displayName ?? "model"
            let failureMessage = "Failed to load \(modelDisplayName): \(error.localizedDescription)"
            showTemporaryError(failureMessage)
            VocaLogger.error(.appState, failureMessage)

            await restorePreviousModelIfNeeded(
                afterFailedLoadFor: targetSize,
                previousSize: previousModelSize,
                previousName: previousLoadedModelName,
                hadLoadedModel: hadLoadedModel,
                originalFailureMessage: failureMessage
            )
        }
    }

    /// Clear the loading spinner on a superseded load without touching others.
    private func clearLoadingFlag(for size: ModelSize?) {
        guard let size,
              let idx = availableModels.firstIndex(where: { $0.size == size }) else {
            return
        }
        availableModels[idx].isLoading = false
        availableModels[idx].loadingStatus = "Loading…"
    }

    /// Reload the active model when the transcription language changes and
    /// the engine bakes that language into the loaded model (sherpa-onnx).
    /// Other engines take the language per transcription and need no reload.
    func reloadModelForLanguageChangeIfNeeded() async {
        guard let size = currentModel?.size,
              size.bindsLanguageAtLoadTime,
              whisperService.isModelLoaded else {
            return
        }

        VocaLogger.info(.appState, "Language changed to \(selectedLanguage) — reloading \(size.displayName)")
        await loadModel(size)
    }

    /// Surface a short-lived error state for settings and menu UI.
    private func showTemporaryError(_ message: String) {
        errorMessage = message
        appStatus = .error

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            if self?.appStatus == .error, self?.errorMessage == message {
                self?.appStatus = .idle
                self?.errorMessage = nil
            }
        }
    }

    /// Restore the model that was active before a failed switch.
    private func restorePreviousModelIfNeeded(
        afterFailedLoadFor failedSize: ModelSize?,
        previousSize: ModelSize?,
        previousName: String?,
        hadLoadedModel: Bool,
        originalFailureMessage: String
    ) async {
        guard hadLoadedModel,
              let previousSize,
              failedSize != previousSize else {
            clearActiveModelState()
            return
        }

        do {
            VocaLogger.info(.appState, "Restoring previous model: \(previousSize.displayName)")
            let folderURL = modelManager.isModelDownloaded(previousSize)
                ? modelManager.modelFolder(for: previousSize)
                : nil
            let restoreName = previousName ?? modelManager.modelIdentifier(for: previousSize)
            try await whisperService.loadModel(name: restoreName, folder: folderURL)
            markModelActive(previousSize)
            VocaLogger.info(.appState, "Restored previous model: \(previousSize.displayName)")
        } catch {
            clearActiveModelState()
            let restoreFailure = "Previous model could not be restored: \(error.localizedDescription)"
            errorMessage = "\(originalFailureMessage) \(restoreFailure)"
            VocaLogger.error(.appState, restoreFailure)
        }
    }

    /// Synchronize AppState's model metadata after a successful load.
    private func markModelActive(_ size: ModelSize) {
        currentModel = nil
        for i in availableModels.indices {
            let matches = availableModels[i].size == size
            availableModels[i].isActive = matches
            availableModels[i].isLoading = false
            availableModels[i].loadingStatus = "Loading…"
            if matches {
                availableModels[i].isDownloaded = modelManager.isModelDownloaded(size)
                currentModel = availableModels[i]
            }
        }
    }

    /// Clear active model metadata when no model is loaded in WhisperService.
    private func clearActiveModelState() {
        currentModel = nil
        for i in availableModels.indices {
            availableModels[i].isActive = false
            availableModels[i].isLoading = false
            availableModels[i].loadingStatus = "Loading…"
        }
    }

    func downloadModel(_ size: ModelSize) async {
        _ = try? await modelOperationSerializer.run { [self] in
            await performDownloadModel(size)
        }
    }

    /// Perform one model download after earlier model operations have
    /// completed. Keeping the UI updates inside the serialized operation
    /// prevents multiple progress indicators from representing concurrent
    /// writes to the model cache.
    private func performDownloadModel(_ size: ModelSize) async {
        guard let index = availableModels.firstIndex(where: { $0.size == size }) else { return }

        availableModels[index].downloadProgress = 0.0

        do {
            try await modelManager.downloadModel(size: size) { [weak self] progress in
                Task { @MainActor in
                    guard let self = self else { return }
                    if let idx = self.availableModels.firstIndex(where: { $0.size == size }) {
                        // Only update progress if we haven't already completed (1.0)
                        // This prevents race conditions with the simulated progress task
                        if progress >= 1.0 || self.availableModels[idx].downloadProgress != nil {
                            self.availableModels[idx].downloadProgress = progress
                        }
                    }
                }
            }

            // Small delay to let the final progress (1.0) callback settle on MainActor
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

            // Refresh all model statuses to ensure previously downloaded models are preserved
            refreshModelStatuses()
            VocaLogger.info(.appState, "Download complete for \(size.displayName), isDownloaded=\(modelManager.isModelDownloaded(size))")
        } catch {
            if let idx = availableModels.firstIndex(where: { $0.size == size }) {
                availableModels[idx].downloadProgress = nil
            }
            errorMessage = "Download failed: \(error.localizedDescription)"
            VocaLogger.error(.appState, "Download failed for \(size.displayName): \(error.localizedDescription)")
        }
    }

    /// Delete a downloaded model's local files, freeing disk space.
    /// Refuses to delete the currently active model — the user must load a
    /// different model first so the app is never left without a loaded model —
    /// and refuses a model that's mid-download or mid-load, so its files
    /// aren't yanked out from under an in-flight read.
    func deleteModel(_ size: ModelSize) async {
        guard let index = availableModels.firstIndex(where: { $0.size == size }) else { return }
        guard !availableModels[index].isActive else {
            errorMessage = "Can't delete the active model. Load a different model first."
            return
        }
        guard !availableModels[index].isLoading, availableModels[index].downloadProgress == nil else {
            errorMessage = "Can't delete a model that's loading or downloading."
            return
        }

        do {
            try await modelManager.deleteModel(size)
            refreshModelStatuses()
            VocaLogger.info(.appState, "Deleted model \(size.displayName)")
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
            VocaLogger.error(.appState, "Delete failed for \(size.displayName): \(error.localizedDescription)")
        }
    }

    /// Refresh the download status of all models
    /// This ensures that all previously downloaded models are detected and marked correctly
    private func refreshModelStatuses() {
        for i in availableModels.indices {
            let size = availableModels[i].size
            availableModels[i].isDownloaded = modelManager.isModelDownloaded(size)
            availableModels[i].downloadProgress = nil
            availableModels[i].filePath = modelManager.modelFolder(for: size)
        }
    }

    // MARK: - Startup

    private func installBundledOrFallback(preferred: ModelSize) async -> Bool {
        do {
            return try modelManager.installBundledModelIfAvailable(for: preferred)
        } catch {
            VocaLogger.warning(.appState, "Bundled model install failed for \(preferred.displayName): \(error.localizedDescription)")
            return false
        }
    }

    func performStartup() async {
        // `vocamac.logLevel` was stored but never applied, so the level was
        // pinned at .info and every VocaLogger.debug call — including the
        // input-route tracing that explains a failed start — was discarded.
        if let level = LogLevel(rawValue: logLevel.uppercased()) {
            VocaLogger.setLogLevel(level)
        }
        VocaLogger.info(.appState, "performStartup beginning...")

        // A crash while dictating would otherwise leave the Mac quiet.
        audioDucker.restoreAfterUnexpectedExit()

        // 1. Detect hardware
        systemCapabilities = SystemInfo.detect()
        let sysInfo = systemCapabilities
        VocaLogger.info(.appState, "System: \(sysInfo?.processorName ?? "unknown") | \(sysInfo?.physicalMemoryGB ?? 0) GB RAM | \(sysInfo?.coreCount ?? 0) cores")

        // 2. Check/request permissions
        checkPermissions()
        VocaLogger.info(.appState, "Mic permission: \(micPermission.rawValue) | Accessibility: \(accessibilityPermission.rawValue) | Input Monitoring: \(inputMonitoringPermission.rawValue)")

        // First-run setup explains microphone access before the user requests it.
        if hasCompletedOnboarding && micPermission == .notDetermined {
            VocaLogger.info(.appState, "Mic permission not determined — requesting...")
            requestMicrophonePermission()
        }

        // Start polling if any permission is still missing
        startPermissionPolling()

        // 3. Load the user's preferred model.
        // On first launch the preferred model (tiny by default) won't be
        // downloaded yet. We download it explicitly so the UI can show real
        // progress, rather than delegating to WhisperKit's opaque auto-select
        // which provides no progress callbacks and may pick a different model.
        let preferredModel = ModelSize(rawValue: selectedModelSize) ?? .tiny
        var modelToLoad = startupFallbackModel(for: preferredModel)
        if modelToLoad != preferredModel {
            VocaLogger.warning(.appState, "Preferred model \(preferredModel.displayName) is not supported on this device — falling back to \(modelToLoad.displayName)")
            selectedModelSize = modelToLoad.rawValue
            rebuildAvailableModels()
        }

        if !modelManager.isModelDownloaded(modelToLoad) {
            // Try bundled model for the preferred size first
            let installedPreferred = await installBundledOrFallback(preferred: modelToLoad)
            if installedPreferred {
                refreshModelStatuses()
            } else {
                VocaLogger.info(.appState, "Preferred model \(modelToLoad.displayName) not downloaded — downloading now...")
                await downloadModel(modelToLoad)
            }

            // If preferred model still isn't ready, try bundled tiny as a last resort
            if !modelManager.isModelDownloaded(modelToLoad), modelToLoad != .tiny {
                let installedTiny = await installBundledOrFallback(preferred: .tiny)
                if installedTiny {
                    modelToLoad = .tiny
                    refreshModelStatuses()
                    VocaLogger.info(.appState, "Falling back to bundled Tiny model")
                }
            }
        }

        VocaLogger.info(.appState, "Loading model: \(modelToLoad.displayName)...")
        await loadModel(modelToLoad)
        VocaLogger.info(.appState, "Model loaded: \(whisperService.loadedModelName ?? "none")")

        transcriptCleanup.pruneUnknownModels()
        if transcriptCleanupEnabled {
            await syncTranscriptCleanup()
        }

        // 4. Always attempt to start hotkey listener
        // The event tap creation itself will fail if permissions aren't granted,
        // and we handle that gracefully in HotKeyManager.
        VocaLogger.info(.appState, "Attempting to start hotkey listener...")
        hotKeyManager.startListening(
            keyCode: hotKeyCode,
            mode: activationMode,
            doubleTapThreshold: doubleTapThreshold,
            safetyTimeout: hotKeySafetyTimeout,
            modifiers: hotKeyModifiers
        )
        if hotKeyManager.isListening {
            VocaLogger.info(.appState, "Hotkey listener active (keyCode=\(hotKeyCode), mode=\(activationMode.rawValue))")
        } else {
            VocaLogger.warning(.appState, "Hotkey listener failed to start. Check Accessibility & Input Monitoring permissions.")
        }

        await updateChecker.checkOnLaunchIfNeeded()

        VocaLogger.info(.appState, "Startup complete!")
    }
    func completeOnboarding() {
        syncHotKeyConfiguration()
        if !isRecording {
            hotKeyManager.resetKeyState()
        }
        hasCompletedOnboarding = true
        VocaLogger.info(.appState, "Onboarding completed")
    }

    // MARK: - Snippets Management

    private func loadSnippets() {
        if let data = UserDefaults.standard.data(forKey: "vocamac.snippets") {
            do {
                snippets = try JSONDecoder().decode([Snippet].self, from: data)
            } catch {
                VocaLogger.error(.appState, "Failed to decode snippets: \(error)")
            }
        }
    }

    func saveSnippets() {
        saveSnippets(snippets)
    }

    private func saveSnippets(_ snippets: [Snippet]) {
        do {
            let encoded = try JSONEncoder().encode(snippets)
            UserDefaults.standard.set(encoded, forKey: "vocamac.snippets")
        } catch {
            VocaLogger.error(.appState, "Failed to encode snippets: \(error)")
        }
    }

    func expandSnippets(in text: String) -> String {
        return snippetExpander.expand(in: text, using: snippets)
    }

    var selectedCleanupModelKind: CleanupModelKind {
        get { CleanupModelKind.resolved(stored: transcriptCleanupModel) }
        set { transcriptCleanupModel = newValue.rawValue }
    }

    var effectiveCleanupPrompt: String {
        let stored = transcriptCleanupPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? TranscriptCleanup.defaultPrompt : stored
    }

    func syncTranscriptCleanup() async {
        if !cleanupEndpoint.isLocal {
            transcriptCleanup.unload()
            return
        }
        let kind = selectedCleanupModelKind
        if transcriptCleanupEnabled, transcriptCleanup.isDownloaded(kind) {
            await transcriptCleanup.load(kind)
        } else if !transcriptCleanupEnabled {
            transcriptCleanup.unload()
        }
    }

    func downloadCleanupModel(_ kind: CleanupModelKind) async {
        await transcriptCleanup.download(kind)
        // Only adopt the selection once the bytes are on disk: a failed or
        // cancelled download must not leave the preference pointing at a model
        // that isn't there.
        guard transcriptCleanup.isDownloaded(kind) else { return }
        transcriptCleanupModel = kind.rawValue
        if transcriptCleanupEnabled {
            await transcriptCleanup.load(kind)
        }
    }

    /// Run one cleanup pass on text the user typed into Settings, so they can
    /// see what the model does before trusting it with a dictation. Loads the
    /// model on demand — testing should not require enabling the feature first.
    func previewCleanup(_ text: String, prompt: String) async -> CleanupAttempt {
        let cleaner = activeCleanupService
        if !cleanupEndpoint.isLocal {
            return await cleaner.preview(
                text,
                prompt: transcriptCleanupLevel.prompt(custom: prompt)
            )
        }
        let kind = selectedCleanupModelKind
        guard transcriptCleanup.isDownloaded(kind) else {
            return CleanupAttempt(
                output: text,
                outcome: .skipped("\(kind.descriptor.displayName) is not downloaded yet"),
                duration: 0
            )
        }
        await transcriptCleanup.load(kind)
        return await transcriptCleanup.preview(
            text,
            prompt: transcriptCleanupLevel.prompt(custom: prompt)
        )
    }

    var cleanupEndpointHasAPIKey: Bool {
        CleanupCredentialStore().readAPIKey()?.isEmpty == false
    }

    func saveCleanupAPIKey(_ key: String) throws {
        try CleanupCredentialStore().saveAPIKey(key)
        objectWillChange.send()
    }

    func deleteCleanupAPIKey() throws {
        try CleanupCredentialStore().deleteAPIKey()
        objectWillChange.send()
    }

    func reloadImportedSettings() {
        loadSnippets()
        loadDictionary()
        decodedBindingsCache = nil
        syncHotKeyConfiguration()
        syncShortcutConfiguration()
        syncLaunchAtLogin()
        refreshActiveWritingStyle()
        objectWillChange.send()
    }

    /// Turn cleanup on from onboarding and fetch the model in the background.
    ///
    /// Deliberately returns immediately: onboarding must never wait on a
    /// several-hundred-megabyte download, and the user has to be able to
    /// finish setup and start dictating while it runs.
    func startCleanupSetupInBackground() {
        transcriptCleanupEnabled = true
        let kind = selectedCleanupModelKind
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.downloadCleanupModel(kind)
        }
    }

    func cancelCleanupDownload() {
        transcriptCleanup.cancelDownload()
    }

    func loadCleanupModel(_ kind: CleanupModelKind) async {
        await transcriptCleanup.load(kind)
        // Same rule as downloading: adopt the selection only once the model is
        // actually resident. A load refused for memory would otherwise point
        // the preference at a model that never loads, while the previously
        // working one stays in RAM unselected.
        guard transcriptCleanup.isLoaded else { return }
        transcriptCleanupModel = kind.rawValue
    }

    func deleteCleanupModel(_ kind: CleanupModelKind) {
        transcriptCleanup.delete(kind)
    }

    /// Transcribe a user-chosen media file without injecting it into another
    /// app. The GUI shares the same router and model choice as the CLI.
    func transcribeFile(at url: URL) async throws -> VocaTranscription {
        guard !isRecording, appStatus == .idle else {
            throw CLIError(.transcriptionFailed, "Finish the active dictation before transcribing a file.")
        }
        appStatus = .processing
        defer { if appStatus == .processing { appStatus = .idle } }
        if !whisperService.isModelLoaded {
            await ensureModelLoaded()
        }
        guard whisperService.isModelLoaded else {
            throw CLIError(.modelNotDownloaded, "The selected speech model could not be loaded.")
        }
        let loaded = try await Task.detached(priority: .userInitiated) {
            try AudioFileLoader().loadAudio(at: url)
        }.value
        let language = selectedLanguage == "auto" ? nil : selectedLanguage
        let result = try await whisperService.transcribe(
            audioData: loaded.samples,
            language: language,
            translate: translationEnabled,
            vocabulary: customVocabulary
        )
        statsManager.recordTranscription(result)
        lastTranscription = result
        return result
    }

    func transcribeCapturedAudio(_ samples: [Float]) async throws -> VocaTranscription {
        guard !samples.isEmpty else { throw CLIError(.invalidAudio, "No audio was captured.") }
        guard !isRecording, appStatus == .idle else {
            throw CLIError(.transcriptionFailed, "Finish the active dictation first.")
        }
        appStatus = .processing
        defer { if appStatus == .processing { appStatus = .idle } }
        if !whisperService.isModelLoaded { await ensureModelLoaded() }
        guard whisperService.isModelLoaded else { throw CLIError(.modelNotDownloaded, "The selected model could not be loaded.") }
        let result = try await whisperService.transcribe(
            audioData: samples,
            language: selectedLanguage == "auto" ? nil : selectedLanguage,
            translate: translationEnabled,
            vocabulary: customVocabulary
        )
        statsManager.recordTranscription(result)
        lastTranscription = result
        return result
    }

    private static func sameOutputTarget(_ first: RunningAppSnapshot?, _ second: RunningAppSnapshot?) -> Bool {
        switch (first, second) {
        case (nil, nil): return true
        case let (first?, second?):
            return AppIdentityMatching.matches(
                configuredBundleIdentifier: first.bundleIdentifier,
                configuredProcessName: first.processName,
                configuredID: first.bundleIdentifier ?? first.processName ?? first.displayName,
                snapshot: second
            )
        default: return false
        }
    }
}

// MARK: - History, Shortcuts, and Dictionary

extension AppState {

    // MARK: History

    /// Record a dictation in history before it is transcribed. Returns nil
    /// when history is off.
    fileprivate func beginHistoryEntry(audio: [Float]) async -> UUID? {
        guard historyEnabled else { return nil }
        historyStore.applyRetention(historyRetention)
        let modelID = currentModel?.size.rawValue ?? selectedModelSize
        return await historyStore.begin(
            audio: audio,
            target: frontmostAppResolver.currentFrontmostApp() ?? pendingTargetApp,
            modelID: modelID,
            language: selectedLanguage == "auto" ? nil : selectedLanguage,
            audioSeconds: Double(audio.count) / 16_000
        )
    }

    /// The newest dictation, when it failed or was interrupted and can be
    /// retried, unless the user dismissed the banner for it.
    var recoverableHistoryEntry: DictationHistoryEntry? {
        guard historyEnabled, let entry = historyStore.latestRecoverableEntry,
              entry.id != dismissedRecoveryEntryID else { return nil }
        return entry
    }

    /// Hide the retry banner for an entry; it stays in History.
    func dismissRecovery(_ id: UUID) {
        dismissedRecoveryEntryID = id
    }

    /// Transcribe a history entry's audio again with the current model and
    /// settings, and copy the result. Never pastes: VocaMac's own window is
    /// in front when this runs, so the paste-last shortcut puts it in place.
    @discardableResult
    func retryHistoryEntry(_ id: UUID) async -> String? {
        guard retryingHistoryEntryID == nil,
              let entry = historyStore.entry(id: id), entry.hasAudio else { return nil }
        retryingHistoryEntryID = id
        defer { retryingHistoryEntryID = nil }

        do {
            let samples = try await historyStore.loadAudio(for: entry)
            await ensureModelLoaded()
            guard whisperService.isModelLoaded else {
                showTemporaryError("Could not load the speech model. Open Settings → Speech Model and try again.")
                return nil
            }
            let result = try await whisperService.transcribe(
                audioData: samples,
                language: selectedLanguage == "auto" ? nil : selectedLanguage,
                translate: translationEnabled,
                vocabulary: customVocabulary
            )
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var output: DictationOutputResult?
            if !text.isEmpty {
                let profile = resolveWritingStyle(for: entry.targetApp).profile
                output = await outputPipeline.process(
                    result.text, profile: profile, snippetList: snippets,
                    cleanupEnabled: transcriptCleanupEnabled, rewritingEnabled: writingRewriteEnabled,
                    model: selectedCleanupModelKind, customPrompt: effectiveCleanupPrompt,
                    cleanupLevel: transcriptCleanupLevel,
                    language: result.detectedLanguage, autoCapitalize: autoCapitalize,
                    trailingSpace: appendTrailingSpace,
                    dictionary: dictionaryContext(contextTerms: [], language: result.detectedLanguage)
                )
            }
            historyStore.recordRetry(
                id, rawText: result.text, finalText: output?.text ?? "", summary: output?.summary,
                language: result.detectedLanguage, modelID: result.modelUsed.rawValue,
                transcriptionSeconds: result.duration
            )
            guard let output else {
                showTemporaryError("The retry didn't hear any words in that recording.")
                return nil
            }
            lastOutput = output
            copyToClipboard(output.text)
            VocaLogger.info(.appState, "Retried dictation \(id) with \(result.modelUsed.displayName)")
            return output.text
        } catch {
            showTemporaryError("Retry failed: \(error.localizedDescription)")
            return nil
        }
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func deleteHistoryEntry(_ id: UUID) {
        if !historyStore.delete(id) {
            showTemporaryError("Couldn't delete that dictation because the history file couldn't be saved. Nothing was removed.")
        }
    }

    func clearHistory() {
        if !historyStore.deleteAll() {
            showTemporaryError("Couldn't delete your history because the history file couldn't be saved. Nothing was removed.")
        }
    }

    func deleteAllHistoryAudio() {
        if !historyStore.deleteAllAudio() {
            showTemporaryError("Couldn't delete the recordings because the history file couldn't be saved. Nothing was removed.")
        }
    }

    /// Apply a retention change right away rather than at the next dictation.
    func applyHistoryRetention() {
        historyStore.applyRetention(historyRetention)
    }

    /// Open Settings on a specific page (e.g. History from the menu bar).
    func requestSettingsPage(_ page: SettingsPage) {
        requestedSettingsPage = page
    }

    // MARK: Shortcuts

    /// Push the extra shortcuts and the mouse trigger to the hotkey listener.
    func syncShortcutConfiguration() {
        guard let monitor = hotKeyManager as? HotKeyShortcutMonitoring else { return }
        var shortcuts: [HotKeyShortcutAction: HotKeyCombo] = [:]
        if let combo = HotKeyCombo(storageString: pasteLastShortcut) {
            shortcuts[.pasteLastDictation] = combo
        }
        if let combo = HotKeyCombo(storageString: handsFreeShortcut) {
            shortcuts[.handsFreeToggle] = combo
        }
        if let combo = HotKeyCombo(storageString: commandModeShortcut) {
            shortcuts[.commandMode] = combo
        }
        monitor.updateShortcuts(shortcuts)
        monitor.updateMouseTrigger(button: MouseTriggerButton.resolved(stored: mouseTriggerButton).rawValue)
        refreshCancelKeyArming()
    }

    func shortcut(for action: HotKeyShortcutAction) -> HotKeyCombo? {
        switch action {
        case .pasteLastDictation: return HotKeyCombo(storageString: pasteLastShortcut)
        case .handsFreeToggle: return HotKeyCombo(storageString: handsFreeShortcut)
        case .commandMode: return HotKeyCombo(storageString: commandModeShortcut)
        }
    }

    func setShortcut(_ combo: HotKeyCombo?, for action: HotKeyShortcutAction) {
        let stored = combo?.storageString ?? ""
        switch action {
        case .pasteLastDictation: pasteLastShortcut = stored
        case .handsFreeToggle: handsFreeShortcut = stored
        case .commandMode: commandModeShortcut = stored
        }
        syncShortcutConfiguration()
    }

    func handleShortcut(_ action: HotKeyShortcutAction) async {
        switch action {
        case .pasteLastDictation:
            pasteLastDictation()
        case .handsFreeToggle:
            await toggleHandsFreeDictation()
        case .commandMode:
            if activeCommandSelection != nil,
               isRecording || appStatus == .recording {
                // A second press completes a Command Mode session that was
                // started with a quick press instead of a hold.
                commandModePressStartedAt = nil
                commandModeShouldStopAfterStart = false
                await stopRecordingAndTranscribe()
            } else {
                commandModePressStartedAt = Date()
                commandModeShouldStopAfterStart = false
                await beginCommandMode()
                if activeCommandSelection == nil {
                    commandModePressStartedAt = nil
                    commandModeShouldStopAfterStart = false
                }
            }
        }
    }

    func handleShortcutReleased(_ action: HotKeyShortcutAction) async {
        guard action == .commandMode,
              let startedAt = commandModePressStartedAt else { return }
        commandModePressStartedAt = nil

        // Quick taps are treated as toggle-on. This is especially important
        // while a microphone route or cleanup model is still warming up: the
        // old hold-only behavior interpreted the key-up as an immediate stop
        // and ended the command before any audio could exist.
        guard Date().timeIntervalSince(startedAt) >= commandModeHoldThreshold else {
            VocaLogger.debug(.appState, "Command Mode quick press — waiting for a second press")
            return
        }

        commandModeShouldStopAfterStart = true
        guard activeCommandSelection != nil,
              isRecording || appStatus == .recording else { return }
        commandModeShouldStopAfterStart = false
        await stopRecordingAndTranscribe()
    }

    /// Capture the current selection before recording the spoken edit command.
    func beginCommandMode() async {
        guard appStatus == .idle, !isRecording else { return }
        guard transcriptCleanupEnabled else {
            showTemporaryError("Command Mode needs Smart Cleanup. Enable it in Settings → Cleanup.")
            return
        }
        guard cleanupEndpoint.validationProblem() == nil else {
            showTemporaryError(cleanupEndpoint.validationProblem() ?? "The cleanup endpoint is not configured.")
            return
        }
        if cleanupEndpoint.isLocal,
           selectedCleanupModelKind.descriptor.recommendation != .quality {
            showTemporaryError("Command Mode needs the Qwen 2.5 1.5B model, or a configured remote endpoint. Choose it in Settings → Cleanup.")
            return
        }
        if cleanupEndpoint.isLocal,
           !transcriptCleanup.isDownloaded(selectedCleanupModelKind) {
            showTemporaryError("Download the selected Command Mode model in Settings → Cleanup first.")
            return
        }
        guard let selectedTextService,
              let selection = await selectedTextService.captureSelection() else {
            commandModeShouldStopAfterStart = false
            showTemporaryError("Select editable text in another app, then use the Command Mode shortcut.")
            return
        }
        activeCommandSelection = selection
        VocaLogger.info(
            .appState,
            "Command Mode captured a " + String(selection.text.count) + "-character selection"
        )
        await startRecording(injectResult: false)
        if commandModeShouldStopAfterStart, isRecording || appStatus == .recording {
            commandModeShouldStopAfterStart = false
            await stopRecordingAndTranscribe()
        }
        if !isRecording {
            activeCommandSelection = nil
            commandModeShouldStopAfterStart = false
        }
    }

    private func finishCommandMode(instruction: String, selection: SelectedTextSnapshot) async {
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else {
            cursorOverlay.hide()
            showTemporaryError("No editing command was detected. Your selection was not changed.")
            return
        }
        let cleaner = activeCleanupService
        if cleanupEndpoint.isLocal {
            let kind = selectedCleanupModelKind
            guard cleaner.isDownloaded(kind) else {
                cursorOverlay.hide()
                showTemporaryError("Download a cleanup model, or configure a remote endpoint, before using Command Mode.")
                return
            }
            await cleaner.load(kind)
        }
        let attempt = await cleaner.transform(
            selection.text,
            prompt: CommandModePrompt.make(instruction: instruction)
        )
        guard case .cleaned = attempt.outcome,
              let selectedTextService,
              await selectedTextService.replaceSelection(selection, with: attempt.output) else {
            cursorOverlay.hide()
            let reason: String
            switch attempt.outcome {
            case .rejected(let why), .skipped(let why): reason = why
            case .unchanged: reason = "the model returned the selection unchanged"
            case .cleaned: reason = "the original selection is no longer editable"
            }
            showTemporaryError("Command Mode did not change the text: \(reason).")
            return
        }
        lastOutput = DictationOutputResult(
            original: selection.text,
            text: attempt.output,
            summary: "Command Mode: \(instruction)"
        )
        VocaLogger.info(
            .appState,
            "Command Mode queued a " + String(attempt.output.count) + "-character replacement"
        )
        cursorOverlay.hide()
        appStatus = .idle
        errorMessage = nil
    }

    /// Start a dictation that runs until the shortcut is pressed again (or
    /// silence ends it), whatever the activation mode is.
    func toggleHandsFreeDictation() async {
        if isRecording || appStatus == .recording {
            await stopRecordingAndTranscribe()
            return
        }
        isHandsFreeSession = true
        await startRecording()
        if !isRecording {
            isHandsFreeSession = false
        }
    }

    /// Type the most recent dictation again at the cursor.
    func pasteLastDictation() {
        guard !isRecording, appStatus != .recording else { return }
        let fromHistory = historyEnabled ? historyStore.latestDeliveredText : nil
        guard let text = fromHistory ?? lastOutput?.text ?? heldOutput,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showTemporaryError("There's no dictation to paste yet.")
            return
        }
        VocaLogger.info(.appState, "Pasting the last dictation again (\(text.count) chars)")
        textInjector.inject(text: text, preserveClipboard: preserveClipboard)
    }

    fileprivate func refreshCancelKeyArming(status: AppStatus? = nil) {
        guard let monitor = hotKeyManager as? HotKeyShortcutMonitoring else { return }
        let current = status ?? appStatus
        monitor.setCancelKeyArmed(escapeCancelsDictation && (current == .recording || isTranscribing))
    }

    // MARK: Dictionary

    /// Vocabulary terms, one per entry. Stored in `customVocabulary` so the
    /// Whisper recognition hint keeps working.
    var vocabularyTerms: [String] {
        WhisperService.vocabularyTerms(from: customVocabulary)
    }

    func setVocabularyTerms(_ terms: [String]) {
        var seen = Set<String>()
        let cleaned = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        customVocabulary = cleaned.joined(separator: "\n")
    }

    /// Add a term, replacing a differently-cased copy of it.
    func addVocabularyTerm(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var terms = vocabularyTerms.filter { $0.lowercased() != trimmed.lowercased() }
        terms.append(trimmed)
        setVocabularyTerms(terms)
    }

    func removeVocabularyTerm(_ term: String) {
        setVocabularyTerms(vocabularyTerms.filter { $0 != term })
    }

    /// Add a replacement, merging into an existing one that already writes
    /// the same text.
    func addWordReplacement(heard: String, replacement: String) {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !replacement.isEmpty else { return }
        if let index = wordReplacements.firstIndex(where: { $0.replacement == replacement }) {
            let forms = wordReplacements[index].heardForms
            guard !forms.contains(where: { $0.lowercased() == heard.lowercased() }) else { return }
            wordReplacements[index].heard = (forms + [heard]).joined(separator: ", ")
        } else {
            wordReplacements.append(WordReplacement(heard: heard, replacement: replacement))
        }
    }

    func dictionaryContext(contextTerms: [String], language: String?) -> DictionaryContext {
        let isKnownWord = self.isKnownWord
        return DictionaryContext(
            vocabulary: vocabularyTerms,
            replacements: wordReplacements,
            contextTerms: contextTerms,
            isKnownWord: { isKnownWord($0, language) }
        )
    }

    /// Accept a noticed correction: the corrected spelling becomes a
    /// vocabulary term, plus a replacement when the engine heard different
    /// letters (not just different casing or spacing).
    func acceptDictionarySuggestion(_ suggestion: CorrectionSuggestion) {
        learn(heard: suggestion.heard, corrected: suggestion.corrected)
        dictionarySuggestions.removeAll { $0.id == suggestion.id }
        saveSuggestions()
    }

    func dismissDictionarySuggestion(_ suggestion: CorrectionSuggestion) {
        dictionarySuggestions.removeAll { $0.id == suggestion.id }
        dismissedSuggestionKeys.insert(suggestion.id)
        saveSuggestions()
    }

    private func learn(heard: String, corrected: String) {
        addVocabularyTerm(corrected)
        if DictionaryCorrector.normalized(heard) != DictionaryCorrector.normalized(corrected) {
            addWordReplacement(heard: heard, replacement: corrected)
        }
        VocaLogger.info(.dictionary, "Learned a spelling from a correction")
    }

    fileprivate func receiveCorrections(_ corrections: [CorrectionLearner.Correction]) {
        let mode = learnCorrectionsMode
        guard mode != .off else { return }
        let known = Set(vocabularyTerms)
        for correction in corrections where !known.contains(correction.corrected) {
            let key = CorrectionSuggestion.key(heard: correction.heard, corrected: correction.corrected)
            guard !dismissedSuggestionKeys.contains(key) else { continue }
            if mode == .automatic {
                learn(heard: correction.heard, corrected: correction.corrected)
                continue
            }
            if let index = dictionarySuggestions.firstIndex(where: { $0.id == key }) {
                dictionarySuggestions[index].occurrences += 1
                dictionarySuggestions[index].lastSeen = Date()
            } else {
                dictionarySuggestions.insert(
                    CorrectionSuggestion(heard: correction.heard, corrected: correction.corrected,
                                         occurrences: 1, lastSeen: Date()),
                    at: 0
                )
            }
        }
        dictionarySuggestions = Array(dictionarySuggestions.prefix(50))
        saveSuggestions()
    }

    /// Feed corrections through the same path the observer uses. Tests only.
    func _receiveCorrectionsForTesting(_ corrections: [CorrectionLearner.Correction]) {
        receiveCorrections(corrections)
    }

    fileprivate func observeCorrections(to text: String) {
        guard learnCorrectionsMode != .off, let correctionObserver,
              let processID = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let isKnownWord = self.isKnownWord
        correctionObserver.observe(insertedText: text, processID: processID) { isKnownWord($0, "en") }
    }

    /// Start reading names and identifiers from the screen while the user speaks.
    fileprivate func startScreenContextCapture(injectResult: Bool) {
        screenContextTask?.cancel()
        screenContextTask = nil
        screenDocumentURLTask?.cancel()
        screenDocumentURLTask = nil
        guard injectResult, let reader = screenContextReader else { return }
        if useScreenContext {
            let isKnownWord = self.isKnownWord
            screenContextTask = Task { @MainActor in
                guard let text = await reader.captureFrontmostContext(), !Task.isCancelled else { return [] }
                return ScreenContextTerms.extract(from: text) { isKnownWord($0, "en") }
            }
        }
        if !websiteStyleBindings.isEmpty {
            screenDocumentURLTask = Task { @MainActor in
                await reader.captureFrontmostDocumentURL()
            }
        }
    }

    /// The screen terms, if they arrive in time. Never holds up a dictation
    /// for more than a moment on a slow app.
    fileprivate static func awaitContextTerms(_ task: Task<[String], Never>?) async -> [String] {
        guard let task else { return [] }
        return await withTaskGroup(of: [String]?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: 300_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    fileprivate static func awaitDocumentURL(_ task: Task<URL?, Never>?) async -> URL? {
        guard let task else { return nil }
        return await withTaskGroup(of: URL?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: 300_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// A browser can navigate while transcription runs. Apply a website rule
    /// only when the output is still going to the host captured at recording
    /// start; a failed refresh is safer than formatting for a stale page.
    private func revalidatedDocumentURL(_ capturedURL: URL?) async -> URL? {
        guard !websiteStyleBindings.isEmpty,
              let capturedURL,
              let reader = screenContextReader,
              let currentURL = await reader.captureFrontmostDocumentURL(),
              capturedURL.host?.lowercased() == currentURL.host?.lowercased() else {
            if capturedURL != nil {
                VocaLogger.warning(.appState, "Website changed before dictation output; skipping the captured website rule")
            }
            return nil
        }
        return currentURL
    }

    /// Whisper gets the same ephemeral screen terms as the post-corrector.
    /// The combined prompt is bounded so a page full of identifiers cannot
    /// crowd the user's own vocabulary out of the decoder context.
    static func recognitionVocabulary(_ vocabulary: String, contextTerms: [String]) -> String {
        let terms = contextTerms.prefix(100).joined(separator: ", ")
        if vocabulary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return terms }
        if terms.isEmpty { return vocabulary }
        return String((vocabulary + "\n" + terms).prefix(4_000))
    }

    fileprivate func loadDictionary() {
        wordReplacements = Self.loadJSON([WordReplacement].self, forKey: PreferenceKey.wordReplacements) ?? []
        dictionarySuggestions = Self.loadJSON([CorrectionSuggestion].self, forKey: PreferenceKey.dictionarySuggestions) ?? []
        dismissedSuggestionKeys = Set(
            UserDefaults.standard.stringArray(forKey: PreferenceKey.dismissedDictionarySuggestions) ?? []
        )
    }

    private func saveSuggestions() {
        Self.saveJSON(dictionarySuggestions, forKey: PreferenceKey.dictionarySuggestions)
        UserDefaults.standard.set(Array(dismissedSuggestionKeys), forKey: PreferenceKey.dismissedDictionarySuggestions)
    }

    fileprivate static func loadJSON<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            VocaLogger.error(.dictionary, "Could not read \(key): \(error)")
            return nil
        }
    }

    fileprivate static func saveJSON<T: Encodable>(_ value: T, forKey key: String) {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            VocaLogger.error(.dictionary, "Could not save \(key): \(error)")
        }
    }
}
