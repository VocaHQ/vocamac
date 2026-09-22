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

/// What the menu bar, its icon, and the overlay show while Command Mode runs.
struct CommandModeSession: Equatable {
    enum Phase: Equatable {
        /// Recording the spoken instruction.
        case listening
        /// The model is producing the replacement.
        case rewriting
    }

    var phase: Phase
    /// The start of the selection on one line, for "Editing “…”".
    let selectionPreview: String
    let characterCount: Int
    let appName: String?
    let engineName: String
    /// The transcribed instruction, once known.
    var instruction: String?

    init(
        phase: Phase = .listening,
        selection: String,
        appName: String?,
        engineName: String,
        instruction: String? = nil
    ) {
        self.phase = phase
        let oneLine = selection.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        self.selectionPreview = oneLine.count > 80 ? String(oneLine.prefix(79)) + "…" : oneLine
        self.characterCount = selection.count
        self.appName = appName
        self.engineName = engineName
        self.instruction = instruction
    }
}

/// What Settings → Cleanup → Try It shows.
struct CleanupTryResult: Equatable {
    let input: String
    let text: String
    let summary: String
    let duration: TimeInterval

    var changedText: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) != input.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One completed Command Mode edit.
struct CommandModeEdit: Equatable {
    let instruction: String
    let original: String
    let replacement: String
    let engineName: String
}

enum ScratchpadOutputDestination {
    case settingsTest
    case scratchpad
}

/// Resumes a continuation with whichever value arrives first.
private final class FirstValueGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    func install(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(with value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
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
        (isRecording || appStatus == .recording) && !recordingInjectsResult && activeCommandSelection == nil
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
    /// The most recent Command Mode edit, so its original can be copied back.
    /// Cleared by the next dictation.
    @Published private(set) var lastCommandEdit: CommandModeEdit?
    /// The Command Mode session in progress, from capture to replacement.
    @Published private(set) var commandModeSession: CommandModeSession? {
        didSet { cursorOverlay.setCommandSession(commandModeSession) }
    }
    /// A file or system-audio capture is being transcribed.
    @Published private(set) var isTranscribingMedia = false

    /// Last Settings → Test Dictation result (shown in the sidebar footer; not injected).
    @Published var settingsTestResultText: String?
    @AppStorage("vocamac.scratchpad.text") var scratchpadText: String = ""

    /// Error message to display, if any
    @Published var errorMessage: String?

    /// Currently loaded/active whisper model info
    @Published var currentModel: WhisperModelInfo?

    /// All available models and their statuses
    @Published var availableModels: [WhisperModelInfo] = []

    /// Whether onboarding is downloading or loading its current recommendation.
    @Published private(set) var isPreparingOnboardingModel = false

    // Permissions are managed by PermissionManager.
    // These computed properties maintain backward compatibility for views.
    var micPermission: PermissionStatus { permissionManager.micPermission }
    var accessibilityPermission: PermissionStatus { permissionManager.accessibilityPermission }
    var inputMonitoringPermission: PermissionStatus { permissionManager.inputMonitoringPermission }

    /// Detected system capabilities
    @Published var systemCapabilities: SystemCapabilities?

    /// WhisperKit's recommended model for this device
    @Published var deviceRecommendedModel: String?

    /// Apple Speech's languages on this Mac, once the system has been asked.
    @Published var appleSpeechLanguages: Set<String>?

    // MARK: - User Settings (persisted via UserDefaults)

    @AppStorage(PreferenceKey.onboardingCompleted) var hasCompletedOnboarding: Bool = false
    @AppStorage("vocamac.activationMode") var activationMode: ActivationMode = .pushToTalk
    @AppStorage("vocamac.hotKeyCode") var hotKeyCode: Int = 61  // Right Option
    @AppStorage("vocamac.hotKeyModifiers") var hotKeyModifiers: HotKeyModifiers = []

    /// Whether the hotkey is a regular key (⌥Space) rather than a lone
    /// modifier (Right Option). Only keyed hotkeys are hidden by Secure
    /// Event Input.
    var hotKeyIsKeyed: Bool { !KeyCodeReference.isModifierKeyCode(hotKeyCode) }
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
    /// Languages the user dictates in, which steer the model picker. Nil
    /// until they choose, so the picker can start from a guess.
    @AppStorage(PreferenceKey.spokenLanguages) var spokenLanguagesStorage: String?
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
    /// "twenty three" → "23". Off by default: talking about numbers in prose
    /// often wants the words.
    @AppStorage(PreferenceKey.numbersAsDigits) var numbersAsDigits: Bool = false
    /// "fifty percent" → "50%", "June twenty second" → "June 22". Only applies
    /// with `numbersAsDigits`; off by default, because "$5" and "21st" are a
    /// house style, not a transcription.
    @AppStorage(PreferenceKey.numberSymbols) var numberSymbols: Bool = false
    /// "crying emoji" → 😭. Off by default, so talking *about* an emoji never
    /// rewrites the sentence until the user opts in.
    @AppStorage(PreferenceKey.spokenEmoji) var spokenEmoji: Bool = false
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
    /// `CommandModeEngine.storageValue`, or empty to pick automatically.
    @AppStorage(PreferenceKey.commandModeEngine) var commandModeEngineStorage: String = ""
    /// Set when the user chose separate models for Smart Cleanup and Command
    /// Mode even though one model could serve both.
    @AppStorage(PreferenceKey.aiModelsKeptSeparate) var aiModelsKeptSeparate: Bool = false
    /// Opt-in: let Command Mode copy a selection an app won't share through
    /// Accessibility. Off by default; see `AccessibilitySelectedTextService`.
    @AppStorage(PreferenceKey.commandModeClipboardFallback) var commandModeClipboardFallback: Bool = false
    @AppStorage(PreferenceKey.mouseTriggerButton) var mouseTriggerButton: Int = MouseTriggerButton.off.rawValue
    @AppStorage(PreferenceKey.learnCorrectionsMode) var learnCorrectionsMode: LearnCorrectionsMode = .defaultMode
    @AppStorage(PreferenceKey.useScreenContext) var useScreenContext: Bool = true
    @AppStorage(PreferenceKey.externalMicWhenLidClosed) var externalMicWhenLidClosed: Bool = false
    /// Trim silence with voice activity detection before batch decodes.
    @AppStorage(PreferenceKey.skipSilence) var skipSilence: Bool = true

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

    /// Secure Event Input is on (a password field or Terminal's Secure
    /// Keyboard Entry), so keyed shortcuts run through a fallback.
    @Published private(set) var isSecureInputActive = false

    /// True while the audio engine is negotiating its input route. Bluetooth
    /// headsets can take seconds to switch to their microphone, and a stop
    /// arriving in that window has to be deferred rather than blocked on.
    private var isStartingAudio = false

    /// How to finish a start that the user interrupted while it was still
    /// negotiating the route.
    private var pendingStopDuringStart: PendingStopKind?

    /// True while `startRecording` waits for the speech model to load after
    /// an idle unload. A stop arriving then can't stop anything yet, so it is
    /// remembered here and the recording is never started.
    private var isLoadingModelForRecording = false
    private var pendingStopDuringModelLoad: PendingStopKind?

    /// A dictation started while the previous one was still being transcribed
    /// or delivered. It starts as soon as that delivery finishes, unless the
    /// hotkey is released (or pressed again to stop) first.
    private struct QueuedRecordingStart {
        let injectResult: Bool
        let outputDestination: ScratchpadOutputDestination
        let isHandsFree: Bool
    }
    private var queuedRecordingStart: QueuedRecordingStart?

    /// Set while a Settings control records a new shortcut with the hotkey
    /// listener turned off, so permission recovery leaves the listener off.
    var isCapturingShortcut = false

    /// The launch-time model download and load, while it runs. The hotkey is
    /// live during it; a press waits for this instead of loading on its own.
    private var startupModelPreparation: Task<Void, Never>?

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
    /// menu bar indicator; refreshed when the popover appears, when another
    /// app is activated, and after every dictation, never on a timer.
    @Published private(set) var activeWritingStyle: ResolvedWritingStyle = .plain
    /// Name of the app `activeWritingStyle` was resolved for, whether or not
    /// it has its own rule, so the menu bar can say which app it means.
    @Published private(set) var activeWritingTargetName: String?
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
            trailingSpace: appendTrailingSpace, preview: true,
            numbersAsDigits: numbersAsDigits, numberSymbols: numberSymbols, spokenEmoji: spokenEmoji
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

    /// Parakeet's optional vocabulary boost model.
    @Published private(set) var vocabularyBoostStatus: VocabularyBoostStatus =
        TranscriptionRouter.isVocabularyBoostDownloaded ? .ready : .notDownloaded

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
        didSet {
            refreshCancelKeyArming()
            if oldValue && !isTranscribing {
                scheduleQueuedRecordingStart()
            }
        }
    }

    /// Names and identifiers read from the screen when recording started.
    private var screenContextTask: Task<[String], Never>?
    private var screenDocumentURLTask: Task<URL?, Never>?

    /// Selection captured before Command Mode starts recording its instruction.
    private var activeCommandSelection: SelectedTextSnapshot?
    private var commandModePressStartedAt: Date?
    /// Engine chosen when the current Command Mode session began.
    private var activeCommandEngine: CommandModeEngine?
    /// App whose selection is being edited, for the history entry.
    private var commandTargetApp: RunningAppSnapshot?
    /// A held shortcut came up while the selection was still being read.
    private var commandModeReleasedBeforeRecording = false
    static let commandReleasedEarlyMessage = "Command Mode stopped: the shortcut was released before the microphone was ready. Hold it until you hear the double chime, or tap it once to start and again to finish."
    /// The transform in flight, so Escape can stop it.
    private var activeCommandTransformer: TextTransforming?
    /// A local Command Mode model loading while the user speaks.
    private var commandModelWarmup: Task<Void, Never>?
    /// Frees a large Command Mode model a while after its last use.
    private var commandModelIdleUnload: Task<Void, Never>?
    static let commandModelIdleSeconds: TimeInterval = 300
    private lazy var appleIntelligenceService = AppleIntelligenceTextService()
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

    /// Invalidates an onboarding recommendation when its language or user intent changes.
    private var onboardingModelRequestGeneration: UInt64 = 0
    private var onboardingRequestedModel: ModelSize?
    /// Non-nil only while onboarding itself owns the serialized engine load.
    private var onboardingLoadingRequestGeneration: UInt64?
    /// The language whose change `languageDidChange()` has already reacted to.
    private var handledLanguageChange: String?

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
    ///
    /// `freeingGB` is the RAM the outgoing model releases as part of this
    /// load, which must not count against the incoming one.
    var modelFitsInMemory: (_ size: ModelSize, _ freeingGB: Double) -> Bool = { size, freeingGB in
        SystemInfo.canFitModelInMemory(size, freeingGB: freeingGB)
    }
    var availableInputDevices: () -> [AudioDevice] = { AudioEngine.availableInputDevices() }
    var isLidClosed: () -> Bool = { LidStateReader.isClosed() }
    /// Seam for tests, which must not depend on the host's Apple Intelligence.
    var appleIntelligenceAvailable: () -> Bool = { AppleIntelligenceTextService.isAvailable }

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
        // Launch reads, replays, and compacts history off the main thread.
        self.historyStore = historyStore
            ?? DictationHistoryStore(
                directory: skipSystemIntegration ? nil : DictationHistoryStore.defaultDirectory,
                loadInBackground: !skipSystemIntegration
            )
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

        // Keep the menu bar's style row on the app the user is actually in.
        // The popover's onAppear alone left it showing the previous app, so
        // resolve once per app switch as well. Event-driven, no polling.
        if !skipSystemIntegration {
            NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didActivateApplicationNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshActiveWritingStyle() }
                .store(in: &cancellables)
        }

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
                // "Copied, press ⌘V" has to stay up long enough to act on.
                self.showOverlayFailure(message)
                self.showTemporaryError(message, duration: Self.deliveryFailureMessageDuration)
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
                self.discardRecordingState()
                // The new generation abandons any transcription that had
                // already begun, and its own cleanup is skipped for it.
                self.isTranscribing = false
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
        if let manager = hotKeyManager as? HotKeyManager {
            manager.onSecureInputChange = { [weak self] active in
                self?.isSecureInputActive = active
            }
        }

        hotKeyManager.onRecordingStart = { [weak self] in
            PerformanceTrace.event("HotKeyStart")
            Task { @MainActor in
                await self?.startRecording()
            }
        }

        hotKeyManager.onRecordingStop = { [weak self] in
            PerformanceTrace.event("HotKeyStop")
            Task { @MainActor in
                await self?.stopRecordingAndTranscribe(endsHotKeyToggle: false)
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
                if status == .idle || status == .error {
                    self?.scheduleQueuedRecordingStart()
                }
            }
            .store(in: &cancellables)

        correctionObserver?.onCorrections = { [weak self] corrections in
            self?.receiveCorrections(corrections)
        }

        // Start the hotkey listener when permissions are granted, and rebuild
        // it when a revoke-and-grant left macOS's tap disabled.
        permissionManager.onAllPermissionsGranted = { [weak self] in
            guard let self = self else { return }
            self.restartHotKeyListenerIfNeeded()
            VocaLogger.info(.appState, "Hotkey listener checked after permission grant")
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
            self.checkPermissions()
            if self.permissionManager.allPermissionsGranted {
                self.syncHotKeyConfiguration()
                self.restartHotKeyListenerIfNeeded()
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
        // Checked again once earlier model operations finish: a load queued
        // ahead of this one may already have loaded a model.
        _ = try? await modelOperationSerializer.run { @MainActor [self] in
            guard !whisperService.isModelLoaded else { return }
            await performLoadModel(size)
        }
    }

    private var autoPausedMessage: String {
        if let name = autoPauseTriggerDisplayName ?? autoPauseMonitor.activeTrigger?.displayName, !name.isEmpty {
            return "Dictation is paused while \(name) is running."
        }
        return "Dictation is paused while a listed app is running."
    }

    private func handleAutoPauseEntered() async {
        isAutoPaused = true
        autoPauseTriggerDisplayName = autoPauseMonitor.activeTrigger?.displayName
        modelKeepAlive.cancel()

        queuedRecordingStart = nil
        if isRecording || appStatus == .recording {
            VocaLogger.warning(.appState, "Auto-pause entered while recording: stopping without inject")
            recordingGeneration = UUID()
            _ = await stopAudioEngine()
            showOverlayFailure(autoPausedMessage)
            discardRecordingState()
            isTranscribing = false
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

    /// The model a load with no explicit size should use: the stored
    /// preference, corrected to something this Mac supports, else whatever
    /// this device is recommended. Nil only when the catalog offers nothing.
    private func resolvedDefaultModel() -> ModelSize? {
        if let stored = ModelSize(rawValue: selectedModelSize) {
            return startupFallbackModel(for: stored)
        }
        return currentModel?.size ?? recommendedModelSize()
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
        let target = frontmostAppResolver.styleTargetApp()
        activeWritingStyle = resolveWritingStyle(for: target)
        activeWritingTargetName = target?.displayName
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
        // Re-picking the style an app already has must not wipe its custom
        // rules; a different style brings its own rules.
        if existing?.style == style {
            binding.ruleOverrides = existing?.ruleOverrides
        }
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
        queuedRecordingStart = nil
        finishingTranscription?.cancel()
        // Otherwise the local model keeps generating for the abandoned
        // dictation, and the next dictation's cleanup waits behind it.
        transcriptCleanup.cancelCleanup()
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
        resetCommandModeState()
        liveTranscript = ""
        screenContextTask?.cancel()
        screenContextTask = nil
        screenDocumentURLTask?.cancel()
        screenDocumentURLTask = nil
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
            let message = autoPausedMessage
            VocaLogger.info(.appState, message)
            endHotKeyToggleSession()
            showOverlayFailure(message)
            showTemporaryError(message)
            return
        }

        // A file or system-audio transcription owns the speech model and shows
        // as processing. Treating that as a stuck state would force-recover
        // mid-job and run two decodes on one model.
        if isTranscribingMedia {
            VocaLogger.info(.appState, "Dictation ignored while a file or system-audio transcription is running")
            endHotKeyToggleSession()
            errorMessage = "VocaMac is transcribing audio. Dictation is available when it finishes."
            let message = errorMessage
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                if self?.errorMessage == message { self?.errorMessage = nil }
            }
            return
        }

        if isLoadingModelForRecording {
            VocaLogger.info(.appState, "Dictation already starting while the speech model loads — ignoring")
            return
        }

        // The previous dictation is still being transcribed, cleaned up, or
        // delivered. Never throw it away: start this one when it's done.
        if isTranscribing {
            if queuedRecordingStart != nil {
                // Toggle-style triggers (hands-free, menu) press again to stop.
                queuedRecordingStart = nil
                VocaLogger.info(.appState, "Queued dictation withdrawn before it started")
            } else {
                queuedRecordingStart = QueuedRecordingStart(
                    injectResult: injectResult,
                    outputDestination: outputDestination,
                    isHandsFree: isHandsFreeSession
                )
                VocaLogger.info(.appState, "Dictation requested while the previous one is still finishing — starting when it's delivered")
            }
            return
        }

        switch appStatus {
        case .idle, .recording:
            break
        case .error:
            // An error only reports something that already happened. Clear it
            // and start, rather than making the user press twice.
            errorMessage = nil
            appStatus = .idle
        case .processing:
            // Processing with no transcription, model load, or media job
            // behind it is a stuck status. Clear it and start in one press
            // (not `forceRecovery`, which would forget the key being held).
            VocaLogger.warning(.appState, "startRecording found a stale processing state — clearing it and starting")
            errorMessage = nil
            appStatus = .idle
        }

        // Snapshot the target app now. Injection re-reads the frontmost app —
        // that is what actually receives the text — and only falls back to this
        // when VocaMac itself is in front at that point.
        pendingTargetApp = frontmostAppResolver.currentFrontmostApp()

        // Starting another dictation means the user is done fixing the last one.
        correctionObserver?.flush()

        guard micPermission == .granted else {
            endHotKeyToggleSession()
            showOverlayFailure("Microphone access is off.")
            errorMessage = "Microphone permission is required. Please grant access in System Settings."
            appStatus = .error
            return
        }

        // Lazy-reload after idle unload (or any other cold start).
        if !whisperService.isModelLoaded {
            // The first download can take minutes. Say so instead of leaving
            // the hotkey looking stuck on "processing" until it finishes.
            if startupModelPreparation != nil,
               availableModels.contains(where: { $0.downloadProgress != nil }) {
                let message = "The speech model is still downloading. Dictation will work as soon as it finishes."
                VocaLogger.info(.appState, message)
                endHotKeyToggleSession()
                showOverlayFailure("The speech model is still downloading.")
                showTemporaryError(message)
                return
            }
            appStatus = .processing
            isLoadingModelForRecording = true
            pendingStopDuringModelLoad = nil
            if let startupModelPreparation {
                await startupModelPreparation.value
            }
            await ensureModelLoaded()
            isLoadingModelForRecording = false
            let pendingStop = pendingStopDuringModelLoad
            pendingStopDuringModelLoad = nil
            guard whisperService.isModelLoaded else {
                endHotKeyToggleSession()
                showOverlayFailure("Couldn't load the speech model.")
                showTemporaryError("Could not load the speech model. Open Settings → Speech Model and try again.")
                return
            }
            appStatus = .idle
            // The hotkey was released (or Escape pressed) while the model
            // loaded. Starting now would leave the microphone recording with
            // nobody holding the key.
            if let pendingStop {
                VocaLogger.info(.appState, "Dictation ended while the speech model was loading — not starting a recording")
                hotKeyManager.resetKeyState()
                if pendingStop == .transcribe {
                    showTemporaryError("The speech model was still loading, so nothing was recorded. It's ready now — try again.")
                }
                return
            }
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
            cursorOverlay.recordingLimit = maxRecordingDuration > 0 ? TimeInterval(maxRecordingDuration) : nil
            cursorOverlay.show(style: overlayStyle, position: overlayPosition)
            cursorOverlay.setCommandSession(commandModeSession)
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
            vocabulary: recognitionHintVocabulary,
            onPartial: partialHandler
        )
        // Only promise live words when an engine will actually send them:
        // Whisper and Parakeet decode partial snapshots; the Apple Speech
        // session streams audio but reports text only when it finishes.
        let engineSendsPartials = [.whisperKit, .parakeet].contains(ModelSize(rawValue: selectedModelSize)?.engine)
        cursorOverlay.setLiveWordsAvailable(session != nil && partialHandler != nil && engineSendsPartials)
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
            showOverlayFailure("Couldn't start the microphone.")
            discardRecordingState()
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
            let isCommand = activeCommandSelection != nil
            if duckOtherAudioEnabled {
                if isCommand { await soundManager.playCommandStartSoundAsync() }
                else { await soundManager.playStartSoundAsync() }
            } else {
                if isCommand { soundManager.playCommandStartSound() }
                else { soundManager.playStartSound() }
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
        await stopRecordingAndTranscribe(endsHotKeyToggle: true)
    }

    /// - Parameter endsHotKeyToggle: False only when the hotkey itself asked
    ///   for the stop. Any other stop (silence, the time limit, the menu or
    ///   overlay) must also end the hotkey's double-tap session, or the next
    ///   double-tap would be taken as a stop and do nothing.
    private func stopRecordingAndTranscribe(endsHotKeyToggle: Bool) async {
        // Start-time recordingInjectsResult alone decides injection.
        // Practice/settings UIs cannot demote an ordinary hotkey session.
        let injectResult = recordingInjectsResult
        let interval = PerformanceTrace.begin("StopToResultQueued")
        defer { PerformanceTrace.end(interval) }
        // Accept stop if we're recording OR if the audio engine thinks
        // it's recording (covers stuck-state recovery scenarios where
        // isRecording and appStatus may be out of sync).
        guard isRecording || appStatus == .recording else {
            if isLoadingModelForRecording { pendingStopDuringModelLoad = .transcribe }
            if queuedRecordingStart != nil {
                // Released (or toggled off) before the previous dictation
                // finished, so this one never started.
                queuedRecordingStart = nil
                VocaLogger.info(.appState, "Queued dictation ended before it could start")
            }
            return
        }
        if endsHotKeyToggle {
            endHotKeyToggleSession()
        }

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
            resetCommandModeState()
            liveTranscript = ""
            cursorOverlay.hide()
            appStatus = .idle
            return
        }

        guard audioData.contains(where: { abs($0) >= 0.0001 }) else {
            resetCommandModeState()
            showOverlayFailure("No audio from the microphone.")
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
        // Journaled before transcribing; the audio is written alongside the
        // transcription, so a failure can still be retried from history.
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
                customVocabulary, replacementTargets: replacementTargets, contextTerms: contextTerms
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
            liveTranscript = ""

            // A spoken edit command isn't a dictation: it stays out of the
            // last-dictation card and the dictated-words stats.
            if let selection = activeCommandSelection {
                activeCommandSelection = nil
                commandModeSession?.phase = .rewriting
                commandModeSession?.instruction = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                await finishCommandMode(
                    instruction: result.text,
                    transcription: result,
                    selection: selection,
                    engine: activeCommandEngine ?? commandModeEngine,
                    generation: generation
                )
                return
            }

            lastTranscription = result
            lastCommandEdit = nil
            statsManager.recordTranscription(result)

            let trimmedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Set when nothing was heard and no overlay could say so.
            var heardNothing = false
            if !trimmedText.isEmpty {
                let target = frontmostAppResolver.currentFrontmostApp()
                    ?? pendingTargetApp ?? frontmostAppResolver.lastActiveApp()
                let documentURL = await revalidatedDocumentURL(capturedDocumentURL)
                let resolved = resolveWritingStyle(for: target, documentURL: documentURL)
                // The scratchpad is plain notes: format it with the default
                // style, not whichever app the Settings preview was left on.
                let profile: WritingProfile
                if injectResult {
                    profile = nextWritingProfile ?? resolved.profile
                } else if nonInjectedOutputDestination == .scratchpad {
                    profile = resolveWritingStyle(for: nil).profile
                } else {
                    profile = settingsPreviewProfile
                }
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
                    dictionary: dictionaryContext(contextTerms: contextTerms, language: result.detectedLanguage),
                    numbersAsDigits: numbersAsDigits, numberSymbols: numberSymbols, spokenEmoji: spokenEmoji
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
                        showOverlayFailure("The app changed. Your text is saved in the menu bar.")
                        cursorOverlay.hide()
                        // The held text stays in the menu bar; the error
                        // itself clears so the app doesn't stay in .error.
                        showTemporaryError("The destination app changed. Your dictation is saved in the menu bar; copy it to paste where you want.")
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
                if injectResult {
                    heardNothing = !showOverlayFailure("Didn't catch that.")
                } else {
                    settingsTestResultText = nil
                }
            }

            cursorOverlay.hide()
            appStatus = .idle
            if heardNothing {
                showTemporaryError("Didn't catch that. Nothing was typed.")
            }
        } catch {
            guard generation == recordingGeneration else {
                if let historyID { historyStore.markCancelled(historyID) }
                return
            }
            resetCommandModeState()
            liveTranscript = ""
            var message = "Transcription failed: \(error.localizedDescription)"
            var overlayMessage = "Transcription failed."
            if let historyID {
                historyStore.markFailed(historyID, message: error.localizedDescription)
                if historyStore.entry(id: historyID)?.hasAudio == true {
                    message += " Your audio is saved — retry it from the menu bar."
                    overlayMessage = "Transcription failed. Retry it from the menu bar."
                }
            }
            showOverlayFailure(overlayMessage)
            cursorOverlay.hide()
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
        guard isRecording || appStatus == .recording else {
            if isLoadingModelForRecording { pendingStopDuringModelLoad = .discard }
            queuedRecordingStart = nil
            return
        }

        if isStartingAudio {
            pendingStopDuringStart = .discard
            audioEngine.cancelPendingStart()
            return
        }

        // A stop already waiting on the audio engine (the hotkey released a
        // moment before Escape) must not go on to transcribe and paste.
        recordingGeneration = UUID()
        _ = await stopAudioEngine()
        discardRecordingState()
        appStatus = .idle
        errorMessage = nil
        VocaLogger.info(.appState, "Recording cancelled")
    }

    /// Tear down a recording that ends without a transcript: a cancel, a
    /// failed start, a lost input device, or auto-pause. Every such exit
    /// must also drop a Command Mode session, or the next ordinary dictation
    /// would be taken as an editing command for the stale selection.
    private func discardRecordingState() {
        isRecording = false
        audioLevel = 0.0
        screenContextTask?.cancel()
        screenContextTask = nil
        screenDocumentURLTask?.cancel()
        screenDocumentURLTask = nil
        resetCommandModeState()
        liveTranscript = ""
        cursorOverlay.hide()
        hotKeyManager.resetKeyState()
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
        // Escape cancels everything, including a dictation waiting to start.
        queuedRecordingStart = nil
        finishingTranscription?.cancel()
        transcriptCleanup.cancelCleanup()
        resetCommandModeState()
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

        // Decide the model here rather than passing nil and letting WhisperKit
        // auto-select. Its choice arrives with no progress reporting and lands
        // in its own cache, and it is only a WhisperKit choice, so it can
        // never reach the other three engines. Resolving first means the
        // download and memory paths below always know what they are handling.
        guard let targetSize = size ?? resolvedDefaultModel() else {
            let failureMessage = "No speech model is available for this Mac."
            showTemporaryError(failureMessage)
            VocaLogger.error(.appState, failureMessage)
            clearActiveModelState()
            return
        }
        let modelName = modelManager.modelIdentifier(for: targetSize)

        // Refuse known-too-large loads before WhisperKit/CoreML can hang the
        // UI spinner under memory pressure (vocamac#250). Leave any already
        // loaded model alone — we never started a load, so do not restore/clear.
        //
        // The resident model is still in memory at this point: the router only
        // unloads it once the load is under way. Credit what it will release,
        // or switching away from a large engine (Parakeet especially) is
        // measured against memory that model is about to give back.
        let reclaimableGB = hadLoadedModel ? (previousModelSize?.ramRequiredGB ?? 0) : 0
        if !modelFitsInMemory(targetSize, reclaimableGB) {
            let needed = String(format: "%.1f", targetSize.ramRequiredGB)
            let failureMessage =
                "Not enough free memory to load \(targetSize.displayName) "
                + "(~\(needed) GB needed). Free RAM or choose a smaller model."
            showTemporaryError(failureMessage)
            VocaLogger.error(.appState, failureMessage)
            return
        }

        // Fetch the weights ourselves when they are missing, so the wait shows
        // real download progress. Left to the engine it is a silent multi-GB
        // transfer behind a spinner that only ever says "Loading model…" —
        // and for WhisperKit the files land in its own cache rather than ours.
        // Settings' "Download & Load" already does this; every other entry
        // point (a hotkey reloading after the files were deleted, a language
        // change, an intent) arrives here instead.
        //
        // `performDownloadModel` rather than `downloadModel`: we already hold
        // `modelOperationSerializer`, and re-entering it would deadlock this
        // load behind itself.
        if !modelManager.isModelDownloaded(targetSize) {
            VocaLogger.info(
                .appState,
                "\(targetSize.displayName) is not downloaded — fetching it before loading"
            )
            // A bundled copy costs a file move instead of a transfer.
            if await installBundledOrFallback(preferred: targetSize) {
                refreshModelStatuses()
            }
            if !modelManager.isModelDownloaded(targetSize) {
                await performDownloadModel(targetSize)
            }
            guard generation == loadGeneration else {
                clearLoadingFlag(for: targetSize)
                return
            }
            guard modelManager.isModelDownloaded(targetSize) else {
                // The download path owns its own messaging, including staying
                // quiet when the user cancelled, so do not invent one here.
                clearLoadingFlag(for: targetSize)
                return
            }
        }

        // Mark the model as loading in the UI
        if let idx = availableModels.firstIndex(where: { $0.size == targetSize }) {
            availableModels[idx].isLoading = true
            availableModels[idx].loadingStatus = "Preparing…"
        }

        do {
            // The files are present by now, so the engine loads from our own
            // cache instead of fetching its own copy. WhisperKit handles
            // tokenizer fetching itself — we don't pre-validate those files.
            let folderURL = modelManager.modelFolder(for: targetSize)

            // Update status: unpacking
            if let idx = availableModels.firstIndex(where: { $0.size == targetSize }) {
                availableModels[idx].loadingStatus = "Unpacking model…"
            }

            // Load model with status callback
            try await whisperService.loadModel(name: modelName, folder: folderURL) { [weak self] phase in
                Task { @MainActor in
                    guard let self = self else { return }
                    if let idx = self.availableModels.firstIndex(where: { $0.size == targetSize }) {
                        self.availableModels[idx].loadingStatus = phase
                    }
                }
            }

            // A newer loadModel started while we were waiting; leave UI to it.
            guard generation == loadGeneration else {
                clearLoadingFlag(for: targetSize)
                return
            }

            // Persist the resolved model as the user's preference
            selectedModelSize = targetSize.rawValue

            // Update model states — clear all, then mark the loaded one as active
            for i in availableModels.indices {
                let matches = availableModels[i].size == targetSize
                availableModels[i].isActive = matches
                availableModels[i].isLoading = false
                availableModels[i].loadingStatus = "Loading…"
                if matches {
                    availableModels[i].isDownloaded = modelManager.isModelDownloaded(targetSize)
                    currentModel = availableModels[i]
                }
            }

            lastModelUnloadReason = nil
            processMemoryBeforeUnloadMB = nil
            processMemoryAfterUnloadMB = nil
            VocaLogger.info(.appState, "Model ready: \(targetSize.displayName)")
        } catch {
            // A newer load superseded this one; do not restore over it.
            guard generation == loadGeneration else {
                clearLoadingFlag(for: targetSize)
                return
            }

            for i in availableModels.indices {
                availableModels[i].isLoading = false
                availableModels[i].loadingStatus = "Loading…"
            }

            let failureMessage = "Failed to load \(targetSize.displayName): \(error.localizedDescription)"
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

    // MARK: - Spoken Languages

    /// The languages the user dictates in: their saved choice, or a guess
    /// from the pinned transcription language and the Mac's languages.
    var spokenLanguages: [String] {
        get { SpokenLanguages.resolve(stored: spokenLanguagesStorage, selectedLanguage: selectedLanguage) }
        set { spokenLanguagesStorage = SpokenLanguages.encode(newValue) }
    }

    /// Ask the system which languages Apple Speech covers, once per launch.
    func refreshAppleSpeechLanguages() async {
        guard appleSpeechLanguages == nil,
              availableModels.contains(where: { $0.size == .appleSpeech }) else { return }
        appleSpeechLanguages = await AppleSpeechService.supportedLanguageCodes()
    }

    /// Download and load the model currently recommended by onboarding.
    ///
    /// The recommendation is resolved and revalidated here so a language
    /// change during a download cannot activate the previous language's model.
    func prepareOnboardingRecommendedModel() async {
        guard let recommendation = OnboardingModelGuidance.recommendation(
            for: selectedLanguage,
            availableModels: availableModels
        ) else {
            return
        }

        onboardingModelRequestGeneration &+= 1
        let generation = onboardingModelRequestGeneration
        let model = recommendation.model
        onboardingRequestedModel = model
        isPreparingOnboardingModel = true
        errorMessage = nil

        defer {
            if generation == onboardingModelRequestGeneration {
                onboardingRequestedModel = nil
                isPreparingOnboardingModel = false
            }
        }

        do {
            try await modelOperationSerializer.run { [self] in
                await performOnboardingModelPreparation(model, generation: generation)
            }
        } catch is CancellationError {
            VocaLogger.info(.appState, "Onboarding model preparation cancelled for \(model.displayName)")
        } catch {
            let message = "Could not prepare \(model.displayName): \(error.localizedDescription)"
            showTemporaryError(message)
            VocaLogger.error(.appState, message)
        }
    }

    /// Perform onboarding's model operation while holding the shared model lock.
    private func performOnboardingModelPreparation(
        _ model: ModelSize,
        generation: UInt64
    ) async {
        guard generation == onboardingModelRequestGeneration else { return }
        if !modelManager.isModelDownloaded(model) {
            await performDownloadModel(model)
        }

        guard generation == onboardingModelRequestGeneration,
              onboardingRequestedModel == model,
              OnboardingModelGuidance.recommendation(
                for: selectedLanguage,
                availableModels: availableModels
              )?.model == model,
              modelManager.isModelDownloaded(model) else {
            return
        }

        let previouslyActiveModel = currentModel?.size
        onboardingLoadingRequestGeneration = generation
        defer {
            if onboardingLoadingRequestGeneration == generation {
                onboardingLoadingRequestGeneration = nil
            }
        }
        await performLoadModel(model)

        guard generation == onboardingModelRequestGeneration else {
            // Onboarding no longer owns the shared load; the restore below is
            // not its work to cancel.
            onboardingLoadingRequestGeneration = nil

            // The engine may have completed after cancellation even though
            // performLoadModel correctly declined to publish the stale model.
            // Keep service and AppState readiness aligned.
            await whisperService.unloadModel()
            clearActiveModelState()

            // A language change queues a replacement preparation that will
            // load the new recommendation. A plain Cancel does not, so put
            // back the model the user was already dictating with rather than
            // leaving the app with nothing loaded.
            if !isPreparingOnboardingModel, let previouslyActiveModel {
                VocaLogger.info(
                    .appState,
                    "Onboarding load cancelled — restoring \(previouslyActiveModel.displayName)"
                )
                await performLoadModel(previouslyActiveModel)
            }
            return
        }
    }

    /// Invalidate onboarding's recommendation and stop its download, if any.
    func cancelOnboardingModelPreparation() {
        onboardingModelRequestGeneration &+= 1
        if let onboardingRequestedModel {
            modelManager.cancelDownload(for: onboardingRequestedModel)
        }
        if onboardingLoadingRequestGeneration != nil {
            // Safe to invalidate the global load only here: this marker is set
            // after onboarding acquires the serializer, so no unrelated model
            // operation can be running at the same time.
            loadGeneration &+= 1
        }
        onboardingRequestedModel = nil
        isPreparingOnboardingModel = false
    }

    /// Apply a changed transcription language and invalidate stale model work.
    ///
    /// Settings and the onboarding wizard both watch `selectedLanguage`, and
    /// the wizard is launched from Settings, so a single change routinely
    /// arrives twice. Handling it twice would cancel and restart the download
    /// the first call just started, so later calls for the same language are
    /// dropped.
    func languageDidChange() async {
        guard handledLanguageChange != selectedLanguage else { return }
        handledLanguageChange = selectedLanguage

        let shouldPrepareUpdatedRecommendation = isPreparingOnboardingModel
        cancelOnboardingModelPreparation()
        if shouldPrepareUpdatedRecommendation {
            await prepareOnboardingRecommendedModel()
            return
        }
        await reloadModelForLanguageChangeIfNeeded()
    }

    /// Say near the caret why a dictation produced nothing. The menu bar
    /// popover is closed while dictating, so an error only shown there goes
    /// unseen. Returns false when overlays are off; the caller then relies on
    /// its temporary error instead.
    @discardableResult
    private func showOverlayFailure(_ message: String) -> Bool {
        guard showCursorIndicator, overlayStyle != .off else { return false }
        cursorOverlay.showFailure(message: message)
        return true
    }

    /// End the hotkey's double-tap toggle session after a recording stopped,
    /// or failed to start, without a double-tap. Otherwise the next
    /// double-tap is read as "stop" and does nothing. Push-to-talk tracks the
    /// physical key instead, which a reset here could lose mid-press.
    private func endHotKeyToggleSession() {
        guard activationMode == .doubleTapToggle else { return }
        hotKeyManager.resetKeyState()
    }

    /// Start the hotkey listener if it isn't running, and rebuild it if macOS
    /// disabled its event tap (a revoked and re-granted permission leaves the
    /// old tap disabled for good).
    private func restartHotKeyListenerIfNeeded() {
        // Settings turns the listener off while it records a new shortcut;
        // turning it back on would swallow the key being recorded.
        guard !isCapturingShortcut else { return }
        if hotKeyManager.isListening, let tap = hotKeyManager.eventTap,
           !CGEvent.tapIsEnabled(tap: tap) {
            VocaLogger.warning(.appState, "Hotkey event tap was disabled — recreating it")
            hotKeyManager.stopListening()
        }
        guard !hotKeyManager.isListening else { return }
        hotKeyManager.startListening(
            keyCode: hotKeyCode,
            mode: activationMode,
            doubleTapThreshold: doubleTapThreshold,
            safetyTimeout: hotKeySafetyTimeout,
            modifiers: hotKeyModifiers
        )
    }

    /// Start a dictation queued behind the previous one, once that one is
    /// delivered. Runs on a later turn so the delivery finishes unwinding.
    private func scheduleQueuedRecordingStart() {
        guard queuedRecordingStart != nil else { return }
        Task { @MainActor [weak self] in
            await self?.startQueuedRecordingIfReady()
        }
    }

    /// Clearing the queue and marking the recording as started happen in one
    /// main-actor turn, so a key release can't slip between them and leave a
    /// push-to-talk recording running with nobody holding the key.
    private func startQueuedRecordingIfReady() async {
        guard let queued = queuedRecordingStart,
              !isTranscribing, !isRecording, !isTranscribingMedia,
              appStatus == .idle || appStatus == .error else { return }
        queuedRecordingStart = nil
        VocaLogger.info(.appState, "Previous dictation delivered — starting the queued one")
        if queued.isHandsFree { isHandsFreeSession = true }
        await startRecording(injectResult: queued.injectResult, outputDestination: queued.outputDestination)
        if queued.isHandsFree && !isRecording { isHandsFreeSession = false }
    }

    static let deliveryFailureMessageDuration: TimeInterval = 10

    /// Surface a short-lived error state for settings and menu UI.
    private func showTemporaryError(_ message: String, duration: TimeInterval = 5.0) {
        errorMessage = message
        appStatus = .error

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
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
        guard let index = availableModels.firstIndex(where: { $0.size == size }) else {
            // No row to report progress against. Callers check the files
            // afterwards rather than assume success, so say why here.
            VocaLogger.warning(
                .appState,
                "Not downloading \(size.displayName): it is not in this device's model list"
            )
            return
        }

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
            if error is CancellationError {
                // The user pressed Cancel; that isn't a failure to report.
                VocaLogger.info(.appState, "Download cancelled for \(size.displayName)")
                return
            }
            if case ModelManagerError.insufficientDiskSpace = error {
                // Already a complete sentence saying what to do.
                errorMessage = error.localizedDescription
            } else {
                errorMessage = "Download failed: \(error.localizedDescription)"
            }
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

        // 3. Start the hotkey listener before any model work. Loading a model
        // (and the cleanup model after it) takes seconds, and a login launch
        // with a dead hotkey looks broken. A press while the model is still
        // loading waits for it (see `startRecording`).
        // The event tap creation itself will fail if permissions aren't granted,
        // and we handle that gracefully in HotKeyManager.
        VocaLogger.info(.appState, "Attempting to start hotkey listener...")
        restartHotKeyListenerIfNeeded()
        if hotKeyManager.isListening {
            VocaLogger.info(.appState, "Hotkey listener active (keyCode=\(hotKeyCode), mode=\(activationMode.rawValue))")
        } else {
            VocaLogger.warning(.appState, "Hotkey listener failed to start. Check Accessibility & Input Monitoring permissions.")
        }

        // 4. Load the user's preferred model.
        let preparation = Task<Void, Never> { @MainActor [weak self] in
            await self?.prepareStartupModel()
        }
        startupModelPreparation = preparation
        await preparation.value
        startupModelPreparation = nil

        whisperService.removeRetiredEngineState()
        transcriptCleanup.pruneUnknownModels()
        if transcriptCleanupEnabled {
            await syncTranscriptCleanup()
        }

        await updateChecker.checkOnLaunchIfNeeded()

        VocaLogger.info(.appState, "Startup complete!")
    }
    /// Download (if needed) and load the preferred speech model at launch.
    ///
    /// On first launch the preferred model (tiny by default) won't be
    /// downloaded yet. We download it explicitly so the UI can show real
    /// progress, rather than delegating to WhisperKit's opaque auto-select
    /// which provides no progress callbacks and may pick a different model.
    private func prepareStartupModel() async {
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
    }

    func completeOnboarding() {
        syncHotKeyConfiguration()
        if !isRecording {
            hotKeyManager.resetKeyState()
        }
        hasCompletedOnboarding = true
        VocaLogger.info(.appState, "Onboarding completed")
    }

    /// Repair completion state corrupted by the old manual "Set Up VocaMac"
    /// action. A genuine first launch has no stored value; the old action was
    /// the only production path that explicitly persisted `false`.
    func repairLegacyOnboardingCompletionIfNeeded(defaults: UserDefaults = .standard) {
        guard !hasCompletedOnboarding,
              defaults.object(forKey: PreferenceKey.onboardingCompleted) != nil else {
            return
        }

        hasCompletedOnboarding = true
        VocaLogger.info(.appState, "Repaired onboarding completion state from the legacy setup action")
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

    /// The downloaded on-device Command Mode model, when cleanup is on and
    /// runs a different local model. Both share one model slot, so two
    /// different models swap in and out around every edit; pointing cleanup
    /// at the Command Mode model keeps a single model resident.
    var commandModelAvailableForCleanup: CleanupModelKind? {
        guard transcriptCleanupEnabled, cleanupEndpoint.isLocal,
              case .local(let kind) = commandModeEngine,
              kind != selectedCleanupModelKind,
              kind.supportsCleanup,
              transcriptCleanup.isDownloaded(kind) else { return nil }
        return kind
    }

    /// Run dictation cleanup with the Command Mode model.
    func useCommandModelForCleanup() async {
        guard let kind = commandModelAvailableForCleanup else { return }
        await loadCleanupModel(kind)
    }

    /// Cleanup and Command Mode models suggested for this Mac's memory.
    var cleanupModelSuggestion: CleanupModelSuggestion {
        CleanupModelCatalog.suggestion(
            memoryGB: systemCapabilities?.physicalMemoryGB ?? SystemInfo.physicalMemoryGB
        )
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

    /// Run text the user typed into Settings through the same cleanup a
    /// dictation gets — "um" removal, the model, and the safety checks — so
    /// "Try It" shows what would actually be typed, not the model's raw
    /// answer. Uses the default writing style, loads the model on demand, and
    /// works before cleanup is switched on.
    func tryCleanup(_ text: String, prompt: String) async -> CleanupTryResult {
        let started = Date()
        let output = await outputPipeline.process(
            text, profile: resolveWritingStyle(for: nil).profile, snippetList: snippets,
            cleanupEnabled: true, rewritingEnabled: writingRewriteEnabled,
            model: selectedCleanupModelKind, customPrompt: prompt,
            cleanupLevel: transcriptCleanupLevel,
            // Like an engine that reports no language: the pipeline judges it.
            language: selectedLanguage == "auto" ? nil : selectedLanguage, autoCapitalize: autoCapitalize,
            trailingSpace: false, preview: true,
            numbersAsDigits: numbersAsDigits, numberSymbols: numberSymbols, spokenEmoji: spokenEmoji
        )
        return CleanupTryResult(
            input: text, text: output.text, summary: output.summary,
            duration: Date().timeIntervalSince(started)
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

    /// Download a Command Mode model and select it for Command Mode only. The
    /// dictation cleanup model stays as it was.
    func downloadCommandModeModel(_ kind: CleanupModelKind) async {
        await transcriptCleanup.download(kind)
        guard transcriptCleanup.isDownloaded(kind) else { return }
        commandModeEngine = .local(kind)
    }

    // MARK: Models for Cleanup and Command Mode

    /// Bumped by every model choice. A choice that resumes after a download or
    /// load checks it, so an older request can't overwrite a newer one.
    private var aiModelChoiceGeneration = 0

    /// Whether one on-device model is running both Smart Cleanup and Command
    /// Mode. Choosing a different model for either one ends it; so does
    /// switching it off, which is remembered.
    var sharesAIModel: Bool {
        !aiModelsKeptSeparate && cleanupEndpoint.isLocal
            && commandModeEngine == .local(selectedCleanupModelKind)
    }

    /// Put `kind` to work for `role`, downloading it first if needed. While
    /// the two features share a model, a model that can do both is used for
    /// both, so picking one in either place never leaves them out of step.
    /// Nothing changes if the download fails or cleanup can't load the model:
    /// a request is applied whole or not at all.
    func useAIModel(_ kind: CleanupModelKind, for role: AIModelRole) async {
        var role = role
        if sharesAIModel, kind.supportsCommandMode { role = .both }
        if !kind.supportsCommandMode {
            guard role != .commandMode else { return }
            role = .cleanup
        }
        aiModelChoiceGeneration += 1
        let generation = aiModelChoiceGeneration
        if !transcriptCleanup.isDownloaded(kind) {
            await transcriptCleanup.download(kind)
            guard generation == aiModelChoiceGeneration,
                  transcriptCleanup.isDownloaded(kind) else { return }
        }
        if role != .commandMode {
            if transcriptCleanupEnabled && cleanupEndpoint.isLocal {
                await transcriptCleanup.load(kind)
                // A newer choice wins. A refused load keeps the previous
                // cleanup model, so Command Mode and sharing don't move either.
                guard generation == aiModelChoiceGeneration,
                      transcriptCleanup.loadedKind == kind else { return }
                transcriptCleanupModel = kind.rawValue
            } else {
                // Nothing to load while cleanup is off; remember the choice.
                transcriptCleanupModel = kind.rawValue
            }
        }
        // Asking for one model to do both is asking to share again.
        if role == .both { aiModelsKeptSeparate = false }
        if role != .cleanup {
            commandModeEngine = .local(kind)
        }
    }

    /// Turn sharing on or off. On adopts the cleanup model when it can edit
    /// text, then the local Command Mode model, then the one suggested for
    /// this Mac.
    func setSharesAIModel(_ shared: Bool) async {
        guard shared else {
            // Supersedes a sharing request still downloading or loading.
            aiModelChoiceGeneration += 1
            aiModelsKeptSeparate = true
            return
        }
        // useAIModel clears the separate flag only once the model is in place.
        let kind: CleanupModelKind
        if selectedCleanupModelKind.supportsCommandMode {
            kind = selectedCleanupModelKind
        } else if case .local(let commandKind) = commandModeEngine {
            kind = commandKind
        } else {
            kind = cleanupModelSuggestion.commandMode
        }
        await useAIModel(kind, for: .both)
    }

    /// Run Command Mode with Apple Intelligence or the cleanup endpoint.
    /// Local models go through `useAIModel`, which can download them.
    func selectCommandModeEngine(_ engine: CommandModeEngine) {
        aiModelChoiceGeneration += 1
        commandModeEngine = engine
    }

    func downloadAIModel(_ kind: CleanupModelKind) async {
        await transcriptCleanup.download(kind)
    }

    /// Optional cleanup must not make the speech engine appear unavailable.
    var cleanupReadinessLabel: String? {
        guard transcriptCleanupEnabled else { return nil }
        guard cleanupEndpoint.isLocal else {
            return cleanupEndpoint.validationProblem() == nil ? nil : "Cleanup needs setup"
        }
        return transcriptCleanup.modelState.readinessLabel
    }

    /// Offer the smallest downloaded alternative; the service rechecks free
    /// memory when the user chooses it, so this never promises a successful load.
    var smallerDownloadedCleanupModel: CleanupModelKind? {
        CleanupModelKind.cleanupChoices
            .filter {
                $0.descriptor.ramRequiredGB < selectedCleanupModelKind.descriptor.ramRequiredGB
                    && transcriptCleanup.isDownloaded($0)
            }
            .min { $0.descriptor.ramRequiredGB < $1.descriptor.ramRequiredGB }
    }

    func loadCleanupModel(_ kind: CleanupModelKind) async {
        await transcriptCleanup.load(kind)
        // Same rule as downloading: adopt the selection only once the model is
        // actually resident. A load refused for memory would otherwise point
        // the preference at a model that never loads, while the previously
        // working one stays in RAM unselected.
        guard transcriptCleanup.loadedKind == kind else { return }
        transcriptCleanupModel = kind.rawValue
    }

    func deleteCleanupModel(_ kind: CleanupModelKind) {
        transcriptCleanup.delete(kind)
    }

    /// Transcribe a user-chosen media file without injecting it into another
    /// app. The GUI shares the same router and model choice as the CLI.
    func transcribeFile(at url: URL) async throws -> VocaTranscription {
        guard isFreeForMediaTranscription else {
            throw CLIError(.transcriptionFailed, "Finish the active dictation before transcribing a file.")
        }
        errorMessage = nil
        appStatus = .processing
        isTranscribingMedia = true
        defer {
            isTranscribingMedia = false
            if appStatus == .processing { appStatus = .idle }
        }
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
            vocabulary: recognitionHintVocabulary
        )
        statsManager.recordTranscription(result)
        lastTranscription = result
        return result
    }

    func transcribeCapturedAudio(_ samples: [Float]) async throws -> VocaTranscription {
        guard !samples.isEmpty else { throw CLIError(.invalidAudio, "No audio was captured.") }
        // A capture can end on its own (the duration limit) mid-dictation.
        // Wait for the dictation rather than refuse and lose the capture.
        let deadline = Date().addingTimeInterval(Self.mediaTranscriptionWaitSeconds)
        while !isFreeForMediaTranscription {
            guard Date() < deadline else {
                throw CLIError(.transcriptionFailed, "VocaMac is still busy with a dictation. Try again when it finishes.")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        errorMessage = nil
        appStatus = .processing
        isTranscribingMedia = true
        defer {
            isTranscribingMedia = false
            if appStatus == .processing { appStatus = .idle }
        }
        if !whisperService.isModelLoaded { await ensureModelLoaded() }
        guard whisperService.isModelLoaded else { throw CLIError(.modelNotDownloaded, "The selected model could not be loaded.") }
        // Cancelled when the capture window is closed and its audio
        // discarded: stop before (or during) the decode, and never record a
        // result nobody will see.
        try Task.checkCancellation()
        let result = try await whisperService.transcribe(
            audioData: samples,
            language: selectedLanguage == "auto" ? nil : selectedLanguage,
            translate: translationEnabled,
            vocabulary: recognitionHintVocabulary
        )
        try Task.checkCancellation()
        statsManager.recordTranscription(result)
        lastTranscription = result
        return result
    }

    static let mediaTranscriptionWaitSeconds: TimeInterval = 120

    /// Nothing else is using the speech model. An error banner is only a
    /// message, so it doesn't count as busy.
    private var isFreeForMediaTranscription: Bool {
        !isRecording && !isTranscribingMedia && (appStatus == .idle || appStatus == .error)
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
        // Transcription starts as soon as the entry is journaled. The audio is
        // still written (a failed or cancelled dictation needs it for Retry),
        // but in parallel rather than first.
        return await historyStore.begin(
            audio: audio,
            target: frontmostAppResolver.currentFrontmostApp() ?? pendingTargetApp,
            modelID: modelID,
            language: selectedLanguage == "auto" ? nil : selectedLanguage,
            audioSeconds: Double(audio.count) / 16_000,
            waitForAudio: false
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
                vocabulary: recognitionHintVocabulary
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
                    dictionary: dictionaryContext(contextTerms: [], language: result.detectedLanguage),
                    numbersAsDigits: numbersAsDigits, numberSymbols: numberSymbols, spokenEmoji: spokenEmoji
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

    // History loads in the background at launch, and the store refuses
    // deletions until it has. Each of these waits for the load first.

    @discardableResult
    func deleteHistoryEntry(_ id: UUID) -> Task<Void, Never> {
        Task { @MainActor [self] in
            await historyStore.waitUntilLoaded()
            if !historyStore.delete(id) {
                showTemporaryError("Couldn't delete that dictation because the history file couldn't be saved. Nothing was removed.")
            }
        }
    }

    @discardableResult
    func clearHistory() -> Task<Void, Never> {
        Task { @MainActor [self] in
            await historyStore.waitUntilLoaded()
            if !historyStore.deleteAll() {
                showTemporaryError("Couldn't delete your history because the history file couldn't be saved. Nothing was removed.")
            }
        }
    }

    @discardableResult
    func deleteAllHistoryAudio() -> Task<Void, Never> {
        Task { @MainActor [self] in
            await historyStore.waitUntilLoaded()
            if !historyStore.deleteAllAudio() {
                showTemporaryError("Couldn't delete the recordings because the history file couldn't be saved. Nothing was removed.")
            }
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
                await stopRecordingAndTranscribe()
            } else {
                commandModePressStartedAt = Date()
                commandModeReleasedBeforeRecording = false
                await beginCommandMode()
                if activeCommandSelection == nil {
                    commandModePressStartedAt = nil
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

        // A hold released before the microphone was on — reading the
        // selection can take most of a second in an Electron app. Nothing the
        // user said while holding was recorded, and turning the session into
        // a press-again one would record speech they meant as done. Call it
        // off instead and say how to time it.
        guard activeCommandSelection != nil,
              isRecording || appStatus == .recording else {
            commandModeReleasedBeforeRecording = true
            VocaLogger.debug(.appState, "Command Mode released before recording began — cancelling")
            return
        }
        await stopRecordingAndTranscribe()
    }

    // MARK: Command Mode

    /// The engine Command Mode will use, after falling back from choices that
    /// can no longer work (an endpoint that was switched off).
    var commandModeEngine: CommandModeEngine {
        get {
            CommandModeEngine.resolve(
                stored: commandModeEngineStorage,
                endpointIsConfigured: !cleanupEndpoint.isLocal && cleanupEndpoint.validationProblem() == nil,
                appleIntelligenceAvailable: appleIntelligenceAvailable()
            )
        }
        set { commandModeEngineStorage = newValue.storageValue }
    }

    /// Why `engine` can't run an edit right now, worded for the error banner.
    func commandModeProblem(for engine: CommandModeEngine) -> String? {
        switch engine {
        case .appleIntelligence:
            guard !appleIntelligenceAvailable() else { return nil }
            return AppleIntelligenceTextService.availabilityProblem()
                ?? "Apple Intelligence is unavailable. Choose another Command Mode model in Settings → Cleanup."
        case .endpoint:
            if cleanupEndpoint.isLocal {
                return "Command Mode is set to use the cleanup endpoint, but none is configured. Choose a model in Settings → Cleanup."
            }
            return cleanupEndpoint.validationProblem()
        case .local(let kind):
            guard transcriptCleanup.isDownloaded(kind) else {
                return "Download \(kind.descriptor.displayName) in Settings → Cleanup → Command Mode first."
            }
            return nil
        }
    }

    private func commandTransformer(for engine: CommandModeEngine) -> TextTransforming {
        switch engine {
        case .appleIntelligence: return appleIntelligenceService
        case .endpoint: return RemoteCleanupService(configuration: cleanupEndpoint)
        case .local: return transcriptCleanup
        }
    }

    /// Capture the current selection before recording the spoken edit command.
    func beginCommandMode() async {
        guard appStatus == .idle, !isRecording else { return }
        let engine = commandModeEngine
        if let problem = commandModeProblem(for: engine) {
            showTemporaryError(problem)
            return
        }
        guard let selectedTextService else {
            showTemporaryError(SelectionCaptureFailure.noFocusedApp.message)
            return
        }
        let selection: SelectedTextSnapshot
        switch await selectedTextService.captureSelection() {
        case .success(let captured):
            selection = captured
        case .failure(let failure):
            showTemporaryError(failure.message)
            return
        }
        if commandModeReleasedBeforeRecording {
            commandModeReleasedBeforeRecording = false
            showTemporaryError(Self.commandReleasedEarlyMessage)
            return
        }
        activeCommandSelection = selection
        activeCommandEngine = engine
        commandTargetApp = frontmostAppResolver.currentFrontmostApp()
        commandModeSession = CommandModeSession(
            selection: selection.text,
            appName: commandTargetApp?.displayName,
            engineName: engine.displayName
        )
        VocaLogger.info(
            .appState,
            "Command Mode captured a " + String(selection.text.count) + "-character selection"
                + (selection.source == .clipboard ? " via the clipboard" : "")
        )
        // Load a local model while the user speaks, so its load time isn't
        // added to the wait after they stop.
        commandModelIdleUnload?.cancel()
        if case .local(let kind) = engine {
            let cleanup = transcriptCleanup
            commandModelWarmup = Task { await cleanup.load(kind) }
        }
        await startRecording(injectResult: false)
        // Released while the speech model was still loading for this session.
        if commandModeReleasedBeforeRecording {
            commandModeReleasedBeforeRecording = false
            if isRecording || appStatus == .recording { await cancelRecording() }
            resetCommandModeState()
            showTemporaryError(Self.commandReleasedEarlyMessage)
            return
        }
        if !isRecording, activeCommandSelection != nil, !isTranscribing {
            // The microphone never started; nothing will finish this session.
            resetCommandModeState()
        }
    }

    private func finishCommandMode(
        instruction: String,
        transcription: VocaTranscription,
        selection: SelectedTextSnapshot,
        engine: CommandModeEngine,
        generation: UUID
    ) async {
        defer {
            commandModeSession = nil
            finishCommandModelUse(engine)
        }
        var instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        // "um, make this shorter" — the model doesn't need the hesitation, and
        // History and the Last Edit card shouldn't show it.
        if DictationOutputPipeline.knownLanguage(transcription.detectedLanguage).map(DictationOutputPipeline.isEnglish)
            ?? RewriteValidation.likelyEnglish(instruction) {
            instruction = WritingStyleEngine.removeHesitations(instruction).text
        }
        guard !instruction.isEmpty else {
            cursorOverlay.hide()
            showTemporaryError("No editing command was detected. Your selection was not changed.")
            return
        }
        if case .local(let kind) = engine {
            await commandModelWarmup?.value
            commandModelWarmup = nil
            guard generation == recordingGeneration else { return }
            // Joins or no-ops when the warm-up already loaded it.
            await transcriptCleanup.load(kind)
            // Check the kind, not just "something is loaded": a load refused
            // before it starts leaves the cleanup model resident, and a 0.5B
            // cleanup model must not be handed an editing command.
            guard transcriptCleanup.loadedKind == kind else {
                cursorOverlay.hide()
                let detail: String
                if case .error(let message) = transcriptCleanup.modelState { detail = message }
                else { detail = "\(kind.descriptor.displayName) could not be loaded." }
                showTemporaryError("Command Mode did not change the text: \(detail)")
                return
            }
        }
        guard generation == recordingGeneration else { return }

        let transformer = commandTransformer(for: engine)
        activeCommandTransformer = transformer
        let attempt = await transformer.transform(
            selection.text,
            prompt: CommandModePrompt.make(instruction: instruction)
        )
        activeCommandTransformer = nil
        // Escape while the model was running: the user no longer wants this
        // edit, even if the model finished anyway.
        guard generation == recordingGeneration else {
            VocaLogger.info(.appState, "Command Mode cancelled; selection left unchanged")
            return
        }

        let replacement = TranscriptCleanup.preservingOuterWhitespace(
            of: selection.text, in: attempt.output
        )
        guard case .cleaned = attempt.outcome,
              let selectedTextService,
              await selectedTextService.replaceSelection(selection, with: replacement) else {
            cursorOverlay.hide()
            let reason: String
            switch attempt.outcome {
            case .rejected(let why), .skipped(let why): reason = why
            case .unchanged: reason = "the model returned the selection unchanged"
            case .cleaned: reason = "the selection changed or its app is no longer in front"
            }
            showTemporaryError("Command Mode did not change the text: \(reason).")
            return
        }
        lastCommandEdit = CommandModeEdit(
            instruction: instruction,
            original: selection.text,
            replacement: replacement,
            engineName: engine.displayName
        )
        if historyEnabled {
            // Same retention as dictations, applied now rather than at the
            // next dictation, so a run of edits can't outlive the setting.
            defer { historyStore.applyRetention(historyRetention) }
            historyStore.recordCommandEdit(
                instruction: instruction,
                original: selection.text,
                replacement: replacement,
                summary: "Command Mode · \(engine.displayName)",
                target: commandTargetApp,
                modelID: selectedModelSize,
                language: transcription.detectedLanguage,
                audioSeconds: transcription.audioLengthSeconds
            )
        }
        VocaLogger.info(
            .appState,
            "Command Mode queued a " + String(replacement.count) + "-character replacement"
        )
        cursorOverlay.hide()
        appStatus = .idle
        errorMessage = nil
    }

    /// Drop a Command Mode session that ended without an edit: stop its
    /// model, and hand the llama.cpp slot back to cleanup.
    private func resetCommandModeState() {
        activeCommandSelection = nil
        commandModeSession = nil
        commandModePressStartedAt = nil
        activeCommandTransformer?.cancelTransform()
        activeCommandTransformer = nil
        if let engine = activeCommandEngine { finishCommandModelUse(engine) }
    }

    /// Give the cleanup model back after a Command Mode model borrowed the
    /// shared llama.cpp slot, or free a large model that nothing else needs.
    private func finishCommandModelUse(_ engine: CommandModeEngine) {
        activeCommandEngine = nil
        guard case .local(let kind) = engine else { return }
        commandModelIdleUnload?.cancel()
        if cleanupUsesLocalModel {
            // The next dictation needs its cleanup model resident.
            if kind != selectedCleanupModelKind {
                Task { await releaseCommandModelSlot() }
            }
            return
        }
        // Nothing else needs the slot: keep the model warm for a follow-up
        // edit, then free its memory.
        commandModelIdleUnload = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.commandModelIdleSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled, self.activeCommandEngine == nil else { return }
            await self.releaseCommandModelSlot()
        }
    }

    private var cleanupUsesLocalModel: Bool {
        transcriptCleanupEnabled && cleanupEndpoint.isLocal
            && transcriptCleanup.isDownloaded(selectedCleanupModelKind)
    }

    /// Put the cleanup model back in the shared slot, or empty it.
    private func releaseCommandModelSlot() async {
        if cleanupUsesLocalModel {
            await transcriptCleanup.load(selectedCleanupModelKind)
        } else if transcriptCleanup.isLoaded {
            transcriptCleanup.unload()
        }
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

    /// Replacement targets offered to engines as recognition hints.
    private var replacementTargets: [String] {
        wordReplacements.filter(\.isValid).map(\.replacement)
    }

    /// Vocabulary and replacement targets as a recognition hint, for decodes
    /// with no screen context (live sessions, files, history retries).
    var recognitionHintVocabulary: String {
        Self.recognitionVocabulary(customVocabulary, replacementTargets: replacementTargets, contextTerms: [])
    }

    // MARK: - Vocabulary Boost

    /// Download Parakeet's vocabulary boost model.
    func downloadVocabularyBoost() {
        guard vocabularyBoostStatus != .downloading else { return }
        vocabularyBoostStatus = .downloading
        Task { @MainActor [weak self] in
            do {
                try await TranscriptionRouter.downloadVocabularyBoost()
                self?.vocabularyBoostStatus = .ready
                VocaLogger.info(.appState, "Parakeet vocabulary boost downloaded")
            } catch {
                VocaLogger.error(.appState, "Vocabulary boost download failed: \(error.localizedDescription)")
                self?.vocabularyBoostStatus = .failed(error.localizedDescription)
            }
        }
    }

    /// Delete Parakeet's vocabulary boost model.
    func removeVocabularyBoost() {
        do {
            try TranscriptionRouter.removeVocabularyBoost()
            vocabularyBoostStatus = .notDownloaded
        } catch {
            VocaLogger.error(.appState, "Could not remove vocabulary boost: \(error.localizedDescription)")
            vocabularyBoostStatus = .failed(error.localizedDescription)
        }
    }

    /// Vocabulary terms, one per entry. Stored in `customVocabulary` so the
    /// Whisper recognition hint keeps working.
    var vocabularyTerms: [String] {
        RecognitionHints.vocabularyTerms(from: customVocabulary)
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
        // "auto" from Parakeet or Apple Speech isn't a language; passed on, it
        // made every word count as known and switched off name fixes.
        let language = DictationOutputPipeline.knownLanguage(language)
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
        await value(of: task, within: screenContextTimeout, otherwise: [])
    }

    fileprivate static func awaitDocumentURL(_ task: Task<URL?, Never>?) async -> URL? {
        await value(of: task, within: screenContextTimeout, otherwise: nil)
    }

    static let screenContextTimeout: TimeInterval = 0.3

    /// A task's value if it arrives within `timeout`, otherwise `fallback`.
    ///
    /// Returns at the deadline even when the task ignores cancellation: a
    /// task group would wait for every child, and `Task.value` does not stop
    /// waiting when cancelled, so a slow Accessibility read would hold up the
    /// dictation for as long as it took. The task is left to finish on its own.
    static func value<T: Sendable>(
        of task: Task<T, Never>?,
        within timeout: TimeInterval,
        otherwise fallback: T
    ) async -> T {
        guard let task else { return fallback }
        let gate = FirstValueGate<T>()
        return await withCheckedContinuation { continuation in
            gate.install(continuation)
            Task.detached {
                gate.resume(with: await task.value)
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                gate.resume(with: fallback)
            }
        }
    }

    /// A browser can navigate while transcription runs. Apply a website rule
    /// only when the output is still going to the host captured at recording
    /// start; a failed refresh is safer than formatting for a stale page.
    private func revalidatedDocumentURL(_ capturedURL: URL?) async -> URL? {
        guard !websiteStyleBindings.isEmpty,
              let capturedURL,
              let reader = screenContextReader else { return nil }
        let refresh = Task { @MainActor in await reader.captureFrontmostDocumentURL() }
        guard let currentURL = await Self.value(of: refresh, within: Self.screenContextTimeout, otherwise: nil) else {
            VocaLogger.warning(.appState, "Couldn't re-read the website before dictation output; skipping the captured website rule")
            return nil
        }
        guard capturedURL.host?.lowercased() == currentURL.host?.lowercased() else {
            VocaLogger.warning(.appState, "Website changed before dictation output; skipping the captured website rule")
            return nil
        }
        return currentURL
    }

    /// Whisper gets the same ephemeral screen terms as the post-corrector.
    ///
    /// WhisperKit keeps only the last ~220 prompt tokens and trims from the
    /// front, so the user's own vocabulary goes last and screen terms fill a
    /// small budget ahead of it: a page full of identifiers is what gets cut,
    /// never the user's words. A long glossary also makes Whisper more likely
    /// to echo it back as a transcript.
    static func recognitionVocabulary(
        _ vocabulary: String,
        replacementTargets: [String] = [],
        contextTerms: [String]
    ) -> String {
        // Replacement targets ("GitHub" for "get hub") are words the user
        // wants heard, so they join the vocabulary ahead of the user's terms.
        var userTerms = RecognitionHints.vocabularyTerms(from: vocabulary)
        let listed = Set(userTerms.map { $0.lowercased() })
        var targetSeen = Set<String>()
        let targets = replacementTargets.filter {
            RecognitionHints.isHintableReplacement($0)
                && !listed.contains($0.lowercased())
                && targetSeen.insert($0.lowercased()).inserted
        }
        userTerms = targets + userTerms
        let known = Set(userTerms.map { $0.lowercased() })
        let characterBudget = max(0, recognitionPromptCharacterBudget - userTerms.joined(separator: ", ").count)
        var screenTerms: [String] = []
        var used = 0
        var seen = Set<String>()
        for term in contextTerms where !known.contains(term.lowercased()) && seen.insert(term.lowercased()).inserted {
            guard screenTerms.count < maximumRecognitionContextTerms,
                  used + term.count + 2 <= characterBudget else { break }
            screenTerms.append(term)
            used += term.count + 2
        }
        return (screenTerms + userTerms).joined(separator: ", ")
    }

    /// About 200 tokens of glossary at roughly three characters per token.
    static let recognitionPromptCharacterBudget = 600
    static let maximumRecognitionContextTerms = 40

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
