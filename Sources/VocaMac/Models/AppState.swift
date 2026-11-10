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
import os

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

    /// What the session will do with what is said.
    enum Kind: Equatable {
        /// Change the selected text.
        case edit
        /// Nothing is selected: write at the cursor, or carry on from the
        /// last edit.
        case compose
        /// The selection can't be edited: answer about it.
        case answer
    }

    var phase: Phase
    let kind: Kind
    /// The start of the selection on one line, for "Editing “…”".
    let selectionPreview: String
    let characterCount: Int
    let appName: String?
    let engineName: String
    /// The transcribed instruction, once known.
    var instruction: String?
    /// The result so far, while a model that streams is writing it.
    var preview: String?

    init(
        phase: Phase = .listening,
        kind: Kind = .edit,
        selection: String,
        appName: String?,
        engineName: String,
        instruction: String? = nil
    ) {
        self.phase = phase
        self.kind = kind
        let oneLine = selection.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        self.selectionPreview = oneLine.count > 80 ? String(oneLine.prefix(79)) + "…" : oneLine
        self.characterCount = selection.count
        self.appName = appName
        self.engineName = engineName
        self.instruction = instruction
    }

    /// The end of `preview` on one line, for the overlay: the newest words
    /// are the ones still being written.
    var previewTail: String? {
        guard let preview else { return nil }
        let oneLine = preview.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !oneLine.isEmpty else { return nil }
        return oneLine.count > 90 ? "…" + String(oneLine.suffix(89)) : oneLine
    }
}

/// What a Command Mode session acts on.
enum CommandTarget {
    /// Selected text that can be replaced.
    case selection(SelectedTextSnapshot)
    /// Selected text that can only be read: a web page, a PDF.
    case readOnly(SelectedTextSnapshot)
    /// Nothing is selected. `insertionPoint` is where the cursor was, when
    /// the app says, so text written there can be edited again.
    case cursor(insertionPoint: InsertionPoint?)

    var selectedText: String? {
        switch self {
        case .selection(let snapshot), .readOnly(let snapshot): return snapshot.text
        case .cursor: return nil
        }
    }

    var sessionKind: CommandModeSession.Kind {
        switch self {
        case .selection: return .edit
        case .readOnly: return .answer
        case .cursor: return .compose
        }
    }
}

/// When a Command Mode edit waits for approval instead of replacing the
/// selection straight away.
enum CommandReviewMode: String, CaseIterable, Identifiable {
    case never
    case longSelections
    case always

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .never: return "Never"
        case .longSelections: return "Long selections"
        case .always: return "Always"
        }
    }

    /// Selections at least this long are reviewed under `longSelections`:
    /// about a paragraph, where a bad rewrite is no longer obvious at a glance.
    static let longSelectionCharacters = 400

    func reviews(selection: String) -> Bool {
        switch self {
        case .never: return false
        case .longSelections: return selection.count >= Self.longSelectionCharacters
        case .always: return true
        }
    }
}

/// What Settings → Smart Cleanup → Try It shows.
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
    enum Kind: Equatable {
        /// The selection was replaced.
        case edit
        /// New text was written at the cursor.
        case composed
        /// An answer about text that couldn't be edited.
        case answer
        /// Something was done on the Mac; no text changed.
        case action
    }

    let instruction: String
    let original: String
    let replacement: String
    let engineName: String
    var kind: Kind = .edit
    /// Something the checks noticed about the result ("a link is missing").
    var note: String?
}

enum ScratchpadOutputDestination {
    case settingsTest
    case scratchpad
}

/// Resumes a continuation with whichever value arrives first.
final class FirstValueGate<T: Sendable>: @unchecked Sendable {
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
    @Published var appStatus: AppStatus = .idle {
        didSet {
            if oldValue != appStatus { handleAppStatusChange(from: oldValue) }
        }
    }

    /// Whether the app is actively recording audio
    var recordingGeneration = UUID()
    /// Starts, stops, and cancels in progress, nested or interleaved across
    /// awaits. The dictation flags are checked when it returns to zero.
    var dictationOperationDepth = 0
    /// What the last check found, for tests.
    var lastDictationStateViolations: [String] = []
    /// Practice sessions keep their output local even when a hotkey stops them.
    var recordingInjectsResult = true
    /// Whether the active recording belongs to an in-window practice control.
    var isPracticeRecording: Bool {
        isCapturingAudio && !recordingInjectsResult && activeCommandTarget == nil
    }

    /// Whether the practice recording is Settings › General's Test
    /// dictation (not the Scratchpad's).
    var isSettingsTestRecording: Bool {
        isPracticeRecording && nonInjectedOutputDestination == .settingsTest
    }

    var recordingTranscription: RecordingTranscription?
    var finishingTranscription: RecordingTranscription?
    /// Cleanups of finished pieces, run while recording ("Process while
    /// speaking"). Moves to `finishingSpeculator` at stop.
    var recordingSpeculator: CleanupSpeculator?
    var finishingSpeculator: CleanupSpeculator?
    /// Vocabulary a commit-mode Whisper session reads per piece.
    var recordingVocabulary: LiveVocabulary?
    /// The recording's live session decodes pieces while the user speaks.
    var recordingProcessesWhileSpeaking = false
    var isStoppingAudio = false
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
                recordingSpeculator?.cancelAll()
                recordingSpeculator = nil
                recordingVocabulary = nil
                recordingProcessesWhileSpeaking = false
                isHandsFreeSession = false
            }
            if oldValue && !isRecording {
                audioDucker.restore()
                spotifyPauser.resume()
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
    /// Words recognised so far in a live recording. Lives in its own object,
    /// like `audioMeter`, so partial results don't redraw every observer.
    let liveTranscriptState = LiveTranscriptState()
    var liveTranscript: String {
        get { liveTranscriptState.text }
        set { liveTranscriptState.update(newValue) }
    }
    /// The most recent Command Mode edit, so its original can be copied back.
    /// Cleared by the next dictation.
    @Published var lastCommandEdit: CommandModeEdit?
    /// The Command Mode session in progress, from capture to replacement.
    @Published var commandModeSession: CommandModeSession? {
        didSet { cursorOverlay.setCommandSession(commandModeSession) }
    }
    /// A Command Mode result waiting on the user: an edit to approve, or an
    /// answer to read.
    @Published var commandReview: CommandReview?
    /// A file or system-audio capture is being transcribed.
    @Published private(set) var isTranscribingMedia = false
    /// The microphone is recording, or the model decoding, a take of a
    /// Dictionary word being taught (`startTeachingTake`).
    @Published var isTeachingWord = false
    /// The microphone start of the current take, awaited before the take
    /// is stopped so a stop can never run ahead of it and leave it open.
    var teachingStart: Task<Bool, Never>?

    /// Optional, session-only checks for onboarding.
    @Published var onboardingVerification = OnboardingVerification()
    /// Last Settings → Test Dictation result (shown in the sidebar footer; not injected).
    @Published var settingsTestResultText: String?
    /// A Settings test dictation is still starting: its microphone may be
    /// open while the speech model loads, before `isSettingsTestRecording`
    /// turns true. Leaving the page then must still close it.
    var isStartingSettingsTest = false
    @UserDefault("vocamac.scratchpad.text") var scratchpadText: String = ""

    /// Error message to display, if any
    @Published var errorMessage: String?

    /// The last error, kept in the menu with its fix until dismissed or the
    /// next dictation starts. `errorMessage` clears itself after a few seconds.
    @Published var errorNotice: DictationErrorNotice?

    /// Processing has moved on from transcription to Smart Cleanup.
    @Published var isCleaningUp = false

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
    /// Quitting and reopening may get a permission through; see `PermissionManager.mayNeedRelaunch`.
    var permissionsMayNeedRelaunch: Bool { permissionManager.mayNeedRelaunch }
    /// A permission the user went to System Settings for is still off.
    var permissionsAwaitingGrant: Bool { permissionManager.isAwaitingGrant }
    /// Quit and reopen VocaMac; see `AppRelauncher`. `false` when the new
    /// instance couldn't be started and this one keeps running.
    @discardableResult
    func relaunch() -> Bool { AppRelauncher.relaunch() }

    /// Clear every permission grant for VocaMac, then quit so the next
    /// launch asks again.
    func resetAllPermissionsAndQuit() {
        PermissionManager.resetAllPermissions()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            NSApplication.shared.terminate(nil)
        }
    }

    /// Onboarding is open, so an Accessibility grant may bring it forward.
    func setOnboardingOpen(_ isOpen: Bool) {
        permissionManager.returnsToOnboardingAfterGrant = isOpen
    }

    /// Detected system capabilities
    @Published var systemCapabilities: SystemCapabilities?

    /// Persisted priority shared by onboarding and the model catalog.
    @UserDefault(PreferenceKey.modelRecommendationPriority) var modelRecommendationPriorityStorage = SpeechModelPriority.balanced.rawValue
    /// WhisperKit's recommended model for this device.
    @Published var deviceRecommendedModel: String?

    /// Apple Speech's languages on this Mac, once the system has been asked.
    @Published var appleSpeechLanguages: Set<String>?

    // MARK: - User Settings (persisted via UserDefaults)

    @UserDefault(PreferenceKey.onboardingCompleted) var hasCompletedOnboarding: Bool = false
    @UserDefault("vocamac.activationMode") var activationMode: ActivationMode = .pushToTalk
    @UserDefault("vocamac.hotKeyCode") var hotKeyCode: Int = 61  // Right Option
    @UserDefault("vocamac.hotKeyModifiers") var hotKeyModifiers: HotKeyModifiers = []

    /// Whether the hotkey is a regular key (⌥Space) rather than a lone
    /// modifier (Right Option). Only keyed hotkeys are hidden by Secure
    /// Event Input.
    var hotKeyIsKeyed: Bool { !KeyCodeReference.isModifierKeyCode(hotKeyCode) }
    @UserDefault("vocamac.doubleTapThreshold") var doubleTapThreshold: Double = 0.4
    @UserDefault("vocamac.silenceThreshold") var silenceThreshold: Double = 0.01
    @UserDefault("vocamac.silenceDuration") var silenceDuration: Double = SilenceDetectionSettings.defaultDuration
    @UserDefault("vocamac.maxRecordingDuration") var maxRecordingDuration: Int = 60
    @UserDefault("vocamac.selectedAudioDeviceID") var selectedAudioDeviceID: String = ""
    @UserDefault("vocamac.selectedAudioDeviceName") var selectedAudioDeviceName: String = ""
    @UserDefault("vocamac.selectedAudioChannel") var selectedAudioChannel: Int = 0
    @UserDefault("vocamac.selectedAudioChannelDeviceID") var selectedAudioChannelDeviceID: String = ""
    @UserDefault("vocamac.selectedAudioChannelCount") var selectedAudioChannelCount: Int = 0
    @UserDefault(PreferenceKey.selectedModelSize) var selectedModelSize: String = ModelSize.tiny.rawValue
    /// Whether the user picked the speech model. The startup load saves its
    /// default into `selectedModelSize` too, so a stored value proves nothing.
    @UserDefault(PreferenceKey.speechModelChosen) var speechModelChosen: Bool = false
    @UserDefault(PreferenceKey.selectedLanguage) var selectedLanguage: String = "auto"
    /// Languages the user dictates in, which steer the model picker. Nil
    /// until they choose, so the picker can start from a guess.
    @UserDefault(PreferenceKey.spokenLanguages) var spokenLanguagesStorage: String?
    @UserDefault("vocamac.launchAtLogin") var launchAtLogin: Bool = false
    @UserDefault("vocamac.preserveClipboard") var preserveClipboard: Bool = true
    @UserDefault("vocamac.soundEffectsEnabled") var soundEffectsEnabled: Bool = true
    @UserDefault(PreferenceKey.dictationTone) var dictationTone: DictationTone = .voca
    @UserDefault(PreferenceKey.duckOtherAudioEnabled) var duckOtherAudioEnabled: Bool = false
    @UserDefault(PreferenceKey.pauseSpotifyEnabled) var pauseSpotifyEnabled: Bool = false
    @UserDefault("vocamac.overlayStyle") var overlayStyle: OverlayStyle = .minimal
    @UserDefault("vocamac.overlayPosition") var overlayPosition: OverlayPosition = .bottom
    /// Legacy preference retained so existing installs that disabled the old
    /// cursor indicator continue to keep the overlay hidden after upgrading.
    @UserDefault("vocamac.showCursorIndicator") var showCursorIndicator: Bool = true
    @UserDefault("vocamac.translationEnabled") var translationEnabled: Bool = false
    @UserDefault("vocamac.customVocabulary") var customVocabulary: String = ""
    /// Set when the user removes Parakeet's vocabulary boost model, so it
    /// isn't fetched again behind their back; cleared when they download it.
    @UserDefault("vocamac.vocabularyBoostRemovedByUser") var vocabularyBoostRemovedByUser: Bool = false
    @UserDefault("vocamac.logLevel") var logLevel: String = "info"
    @UserDefault(PreferenceKey.appendTrailingSpace) var appendTrailingSpace: Bool = true
    @UserDefault(PreferenceKey.autoCapitalize) var autoCapitalize: Bool = true
    /// "twenty three" → "23" (true) or kept as words (false). Nil, what a
    /// new install has, writes numbers by style (`NumberWriting.automatic`).
    /// A stored value is a choice the user made, and stays.
    @UserDefault(PreferenceKey.numbersAsDigits) var numbersAsDigitsChoice: Bool?
    /// How dictated numbers are written; see `numbersAsDigitsChoice`.
    var numberWriting: NumberWriting {
        get { numbersAsDigitsChoice.map { $0 ? .digits : .words } ?? .automatic }
        set {
            switch newValue {
            case .automatic: numbersAsDigitsChoice = nil
            case .digits: numbersAsDigitsChoice = true
            case .words: numbersAsDigitsChoice = false
            }
        }
    }
    /// "fifty percent" → "50%", "June twenty second" → "June 22". Applies
    /// whenever numbers are written as digits; off by default, because "$5"
    /// and "21st" are a house style, not a transcription.
    @UserDefault(PreferenceKey.numberSymbols) var numberSymbols: Bool = false
    /// "crying emoji" → 😭. Off by default, so talking *about* an emoji never
    /// rewrites the sentence until the user opts in.
    @UserDefault(PreferenceKey.spokenEmoji) var spokenEmoji: Bool = false
    /// Start a new paragraph where a long dictation paused between two
    /// sentences, and give an email's greeting a line of its own. Only in
    /// styles that allow paragraphs (`WritingStyle.allowsParagraphs`).
    @UserDefault(PreferenceKey.pauseParagraphs) var pauseParagraphs: Bool = true
    @UserDefault(PreferenceKey.autoPauseEnabled) var autoPauseEnabled: Bool = false
    @UserDefault(PreferenceKey.autoPausePollInterval) var autoPausePollIntervalSeconds: Double = 5
    @UserDefault(PreferenceKey.modelKeepAliveEnabled) var modelKeepAliveEnabled: Bool = false
    @UserDefault(PreferenceKey.modelKeepAliveIdleTimeout) var modelKeepAliveIdleTimeoutSeconds: Double = 300
    @UserDefault(PreferenceKey.writingStyleEnabled) var writingStyleEnabled: Bool = true
    /// Clean up dictation into a terminal as prose when its tab in front runs
    /// a coding agent (`CodingAgentDetector`). Not in the App Store build,
    /// whose sandbox can't read another app's processes.
    @UserDefault(PreferenceKey.codingAgentsAsProse) var codingAgentsAsProse: Bool = true
    @UserDefault(PreferenceKey.writingStyleDefault) var writingStyleDefault: WritingStyle = .plain
    /// Apps VocaMac knows (Slack, Mail, code editors, terminals, note apps)
    /// get their kind's style until the user gives them a rule. On for new
    /// installs; an install that already set up styles keeps its old
    /// behaviour (`SettingsConsistency.normalizeAutomaticStyles`).
    @UserDefault(PreferenceKey.automaticWritingStyles) var automaticWritingStyles: Bool = true
    @UserDefault(PreferenceKey.writingIntent) var writingIntent: WritingIntent = .preserve
    @UserDefault(PreferenceKey.writingRewriteEnabled) var writingRewriteEnabled: Bool = false
    @UserDefault(PreferenceKey.transcriptCleanupEnabled) var transcriptCleanupEnabled: Bool = false
    @UserDefault(PreferenceKey.transcriptCleanupModel) var transcriptCleanupModel: String = CleanupModelKind.defaultKind.rawValue
    @UserDefault(PreferenceKey.transcriptCleanupPrompt) var transcriptCleanupPrompt: String = ""
    @UserDefault(PreferenceKey.transcriptCleanupLevel) var transcriptCleanupLevel: CleanupLevel = .medium
    /// Decode (and clean up) each finished sentence while recording, so long
    /// dictations paste sooner. Off by default until measured on more Macs.
    @UserDefault(PreferenceKey.processWhileSpeaking) var processWhileSpeaking: Bool = false
    /// Parakeet Unified and Nemotron Unified load their streaming export and
    /// transcribe while the user speaks, so the text is ready about two
    /// seconds after they stop. Off by default: the streaming export is a
    /// second download, and NVIDIA reports it slightly less accurate than
    /// the batch export (6.14 % against 5.91 % average WER).
    @UserDefault(PreferenceKey.parakeetLiveStreaming) var parakeetLiveStreaming: Bool = false
    @UserDefault(PreferenceKey.cleanupEndpoint) var cleanupEndpointJSON: String = ""
    @UserDefault(PreferenceKey.speechEndpoint) var speechEndpointJSON: String = ""
    @UserDefault(PreferenceKey.historyEnabled) var historyEnabled: Bool = true
    @UserDefault(PreferenceKey.historyKeepsAudio) var historyKeepsAudio: Bool = false
    @UserDefault(PreferenceKey.historyRetention) var historyRetention: HistoryRetention = .defaultRetention
    @UserDefault(PreferenceKey.escapeCancelsDictation) var escapeCancelsDictation: Bool = true
    /// `HotKeyCombo.storageString`, or empty for no shortcut.
    @UserDefault(PreferenceKey.pasteLastShortcut) var pasteLastShortcut: String = HotKeyCombo.defaultPasteLast.storageString
    /// `HotKeyCombo.storageString`, or empty for no shortcut.
    @UserDefault(PreferenceKey.handsFreeShortcut) var handsFreeShortcut: String = ""
    @UserDefault(PreferenceKey.commandModeShortcut) var commandModeShortcut: String = ""
    /// `CommandModeEngine.storageValue`, or empty to pick automatically.
    @UserDefault(PreferenceKey.commandModeEngine) var commandModeEngineStorage: String = ""
    /// Set when the user chose separate models for Smart Cleanup and Command
    /// Mode even though one model could serve both.
    @UserDefault(PreferenceKey.aiModelsKeptSeparate) var aiModelsKeptSeparate: Bool = false
    /// Opt-in: let Command Mode copy a selection an app won't share through
    /// Accessibility. Off by default; see `AccessibilitySelectedTextService`.
    @UserDefault(PreferenceKey.commandModeClipboardFallback) var commandModeClipboardFallback: Bool = false
    /// Paste a dictation without the cleanup model when the rules already
    /// left it nothing to do (see `CleanupNeed`).
    @UserDefault(PreferenceKey.cleanupSkipsCleanText) var skipCleanDictations: Bool = true
    @UserDefault(PreferenceKey.commandModeReview) var commandModeReview: CommandReviewMode = .never
    /// JSON `[SavedCommand]`; read and written through `savedCommands`.
    @UserDefault(PreferenceKey.savedCommands) var savedCommandsJSON: String = ""
    /// Opt-in: let a spoken instruction open apps and pages, search the web,
    /// run allow-listed Shortcuts, and add reminders.
    @UserDefault(PreferenceKey.voiceActionsEnabled) var voiceActionsEnabled: Bool = false
    /// Names of the Shortcuts a spoken instruction may run, one per line.
    @UserDefault(PreferenceKey.voiceActionShortcuts) var voiceActionShortcuts: String = ""
    @UserDefault(PreferenceKey.mouseTriggerButton) var mouseTriggerButton: Int = MouseTriggerButton.off.rawValue
    @UserDefault(PreferenceKey.learnCorrectionsMode) var learnCorrectionsMode: LearnCorrectionsMode = .defaultMode
    @UserDefault(PreferenceKey.useScreenContext) var useScreenContext: Bool = true
    @UserDefault(PreferenceKey.externalMicWhenLidClosed) var externalMicWhenLidClosed: Bool = false
    /// Trim silence with voice activity detection before batch decodes.
    @UserDefault(PreferenceKey.skipSilence) var skipSilence: Bool = true

    var cleanupEndpoint: CleanupEndpointConfiguration {
        get { CleanupEndpointConfiguration.decode(cleanupEndpointJSON) }
        set { cleanupEndpointJSON = newValue.encoded(); objectWillChange.send() }
    }

    var speechEndpoint: SpeechEndpointConfiguration {
        get { SpeechEndpointConfiguration.decode(speechEndpointJSON) }
        set { speechEndpointJSON = newValue.encoded(); objectWillChange.send() }
    }

    var websiteStyleBindings: [WebsiteStyleBinding] {
        get {
            // Decoded once per stored value: the Styles page reads this per row.
            let json = UserDefaults.standard.string(forKey: PreferenceKey.websiteStyleBindings)
            if let cached = calmDerived.websites, cached.json == json { return cached.bindings }
            let bindings = WebsiteStyleBindingStore.decode(json)
            calmDerived.websites = (json, bindings)
            return bindings
        }
        set {
            UserDefaults.standard.set(WebsiteStyleBindingStore.encode(newValue), forKey: PreferenceKey.websiteStyleBindings)
            objectWillChange.send()
        }
    }

    /// Apps whose dictations are never saved to History (password managers,
    /// banking, health). Same entry type and matching as the auto-pause list.
    var historyExcludedApps: [AutoPauseAppEntry] {
        get { AppListCoding.decode(UserDefaults.standard.string(forKey: PreferenceKey.historyExcludedApps)) }
        set {
            UserDefaults.standard.set(AppListCoding.encode(newValue), forKey: PreferenceKey.historyExcludedApps)
            objectWillChange.send()
        }
    }

    func addHistoryExcludedApp(_ entry: AutoPauseAppEntry) {
        var apps = historyExcludedApps
        guard !apps.contains(where: { $0.id == entry.id }) else { return }
        apps.append(entry)
        historyExcludedApps = apps
    }

    func removeHistoryExcludedApp(_ entry: AutoPauseAppEntry) {
        historyExcludedApps.removeAll { $0.id == entry.id }
    }

    /// Whether a dictation into `app` may be saved to History.
    func historyRecords(_ app: RunningAppSnapshot?) -> Bool {
        guard historyEnabled else { return false }
        return !HistoryExclusion.isExcluded(app, by: historyExcludedApps)
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
    var isStartingAudio = false

    /// How to finish a start that the user interrupted while it was still
    /// negotiating the route.
    var pendingStopDuringStart: PendingStopKind?

    /// True while `startRecording` waits for the speech model to load after
    /// an idle unload. The microphone is already open (`earlyCapture`); a
    /// stop arriving then is remembered here and applied once the model is
    /// ready. Published so the menu can say the model is loading rather than
    /// transcribing (`dictationPhase`).
    @Published var isLoadingModelForRecording = false {
        // The status is `.processing` during the load, with no transcription
        // yet: without this, Escape isn't claimed and can't cancel it.
        didSet { if oldValue != isLoadingModelForRecording { refreshCancelKeyArming() } }
    }
    var pendingStopDuringModelLoad: PendingStopKind?

    /// A dictation started while the previous one was still being transcribed
    /// or delivered. It starts as soon as that delivery finishes, unless the
    /// hotkey is released (or pressed again to stop) first.
    struct QueuedRecordingStart {
        let injectResult: Bool
        let outputDestination: ScratchpadOutputDestination
        let isHandsFree: Bool
        let verifiesShortcut: Bool
        let trigger: DictationTrigger
    }
    var queuedRecordingStart: QueuedRecordingStart?

    /// The microphone, opened at once for a push-to-talk dictation queued
    /// behind one still finishing. Waiting for the delivery before opening it
    /// lost everything said in the meantime — and all of it when the key came
    /// up first. The queued recording adopts this capture when it starts.
    var earlyCapture: EarlyCapture?

    /// Clock for early-capture release boundaries. Tests fix it, so a boundary
    /// doesn't depend on how long the test machine took between two calls.
    var captureClock: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// The speech model load in progress, if any.
    var inFlightModelLoad: Task<Void, Error>?

    /// Set while a Settings control records a new shortcut with the hotkey
    /// listener turned off, so permission recovery leaves the listener off.
    var isCapturingShortcut = false

    /// The launch-time model download and load, while it runs. The hotkey is
    /// live during it; a press waits for this instead of loading on its own.
    var startupModelPreparation: Task<Void, Never>?

    /// Frontmost app captured when recording started. Used only when the app
    /// in front at injection time is VocaMac itself (Settings has focus).
    var pendingTargetApp: RunningAppSnapshot?

    enum PendingStopKind {
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
    @Published var activeWritingStyle: ResolvedWritingStyle = .plain
    /// Name of the app `activeWritingStyle` was resolved for, whether or not
    /// it has its own rule, so the menu bar can say which app it means.
    @Published private(set) var activeWritingTargetName: String?
    @Published var nextWritingProfile: WritingProfile?
    @Published var lastOutput: DictationOutputResult?
    /// A crash report from last time, offered for reporting in the menu bar.
    @Published private(set) var pendingCrashReport: PendingCrashReport?
    let crashReportFinder: CrashReportFinder?
    /// The last dictation typed into an app kept out of History. History's
    /// newest entry is older than it, so paste-last uses this instead. Kept
    /// apart from `lastOutput`, which in-app tests and the scratchpad set too.
    var lastUnsavedDictation: String?
    @Published var heldOutput: String?

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
            numbers: numberWriting, numberSymbols: numberSymbols, spokenEmoji: spokenEmoji,
            laysOutParagraphs: pauseParagraphs
        )
    }

    /// Pipeline for Settings previews, cleanup tries and History retries.
    /// These can run while a dictation is processing, so they leave its stage
    /// alone.
    var outputPipeline: DictationOutputPipeline {
        DictationOutputPipeline(cleaner: activeCleanupService, snippets: snippetExpander)
    }

    /// Pipeline for the dictation itself: reaching the cleanup model moves the
    /// overlay, menu and footer to "Cleaning up…".
    var dictationOutputPipeline: DictationOutputPipeline {
        DictationOutputPipeline(
            cleaner: activeCleanupService, snippets: snippetExpander,
            onModelCleanup: { [weak self] in self?.dictationReachedCleanup() }
        )
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
    @Published var wordReplacements: [WordReplacement] = [] {
        // A replacement added again starts its "not said in a while"
        // clock afresh (`TermUsage.noting`).
        didSet { noteDictionaryTermsSeen() }
    }

    /// Corrections noticed in dictated text, waiting for the user to accept.
    @Published var dictionarySuggestions: [CorrectionSuggestion] = []

    /// Fillers the user always deletes ("basically"), removed from their
    /// dictations like "um". Learned from their edits; listed in Formatting.
    @Published var personalFillers: [String] = []

    /// Apps where the user starts in lowercase, learned from their edits;
    /// listed on Styles.
    @Published var learnedLowercaseApps: [LearnedLowercaseApp] = []

    /// Parakeet's optional vocabulary boost model.
    @Published var vocabularyBoostStatus: VocabularyBoostStatus =
        TranscriptionRouter.isVocabularyBoostDownloaded ? .ready : .notDownloaded

    /// History entry whose audio is being transcribed again, if any.
    @Published private(set) var retryingHistoryEntryID: UUID?

    /// Settings page to show the next time the Settings window appears.
    @Published var requestedSettingsPage: SettingsPage?

    /// A search the Speech Model page applies to its whole catalog when it
    /// next appears, then clears.
    @Published var requestedSpeechModelSearch: String?

    /// Failed dictation whose retry banner the user closed.
    @Published private(set) var dismissedRecoveryEntryID: UUID?

    /// History entry for the dictation being transcribed right now.
    var activeHistoryEntryID: UUID?

    /// Whether the current recording was started with the hands-free
    /// shortcut, so silence ends it the way it ends a double-tap recording.
    var isHandsFreeSession = false

    /// True from the end of a recording until its text is delivered. Escape
    /// cancels during this window as well as while recording.
    var isTranscribing = false {
        didSet {
            refreshCancelKeyArming()
            if oldValue && !isTranscribing {
                scheduleQueuedRecordingStart()
                runDeferredAutoPauseUnload()
            }
        }
    }

    /// Auto-pause began while a dictation was still being transcribed or
    /// delivered. Its model unload waits for that dictation to finish:
    /// unloading under it fails the dictation.
    var autoPauseUnloadDeferred = false

    /// Names and identifiers read from the screen when recording started.
    var screenContextTask: Task<[String], Never>?
    var screenDocumentURLTask: Task<URL?, Never>?
    /// The focused field and the text around its caret when recording
    /// started, to fit the dictation to it (`InsertionFit`).
    var insertionContextTask: Task<InsertionContext?, Never>?
    /// The terminal found running a coding agent when recording started, or
    /// nil (see `startCodingAgentDetection`).
    var codingAgentTask: Task<RunningAppSnapshot?, Never>?
    /// The menu's read of the target app's page address, for website rules.
    private var websiteRuleRefresh: Task<Void, Never>?

    /// What Command Mode captured before it started recording its instruction.
    var activeCommandTarget: CommandTarget?
    /// The llama.cpp slot the session's local model runs in.
    var activeCommandService: TranscriptCleaning?
    /// Where the last edit landed, so "shorter still" and "undo that" have
    /// something to act on.
    var lastCommandTarget: (snapshot: SelectedTextSnapshot, original: String, replacement: String, at: Date)?
    /// How long after an edit a follow-up still means that edit.
    static let commandFollowUpWindow: TimeInterval = 300
    /// The edit a review panel is holding until it is approved.
    var pendingReviewEdit: PendingCommandEdit?
    var commandModePressStartedAt: Date?

    /// Whether the Command Mode shortcut is still held from the press that
    /// started the session (false after a quick press, which needs a second).
    var isCommandModeKeyHeld: Bool { commandModePressStartedAt != nil }

    /// What started the dictation being set up, for the overlay's finish
    /// hint: set around a start by the dictation key or mouse button (and a
    /// queued one), `.other` otherwise.
    var dictationTrigger: DictationTrigger = .other
    /// Engine chosen when the current Command Mode session began.
    var activeCommandEngine: CommandModeEngine?
    /// App whose selection is being edited, for the history entry.
    var commandTargetApp: RunningAppSnapshot?
    /// A held shortcut came up while the selection was still being read.
    var commandModeReleasedBeforeRecording = false
    static let commandReleasedEarlyMessage = "Command Mode stopped: the shortcut was released before the microphone was ready. Hold it until you hear the double chime, or tap it once to start and again to finish."
    /// The transform in flight, so Escape can stop it.
    var activeCommandTransformer: TextTransforming?
    /// A local Command Mode model loading while the user speaks.
    var commandModelWarmup: Task<Void, Never>?
    /// Frees a Command Mode model after its last use, when "Unload model
    /// when idle" is on.
    var commandModelIdleUnload: Task<Void, Never>?
    lazy var appleIntelligenceService = AppleIntelligenceTextService()
    /// A quick press toggles Command Mode; holding past this point stops on
    /// release. Internal so flow tests can exercise both gestures instantly.
    var commandModeHoldThreshold: TimeInterval = 0.35
    var recordingVerifiesShortcut = false
    var nonInjectedOutputDestination: ScratchpadOutputDestination = .settingsTest

    /// Suggestions the user dismissed, so the same fix isn't offered again.
    var dismissedSuggestionKeys: Set<String> = []

    /// Whether a word is ordinary vocabulary in a language. Replaceable in tests.
    var isKnownWord: (String, String?) -> Bool

    // MARK: - Services

    let audioEngine: AudioRecording
    let transcriber: SpeechTranscribing
    let textInjector: TextInjecting
    let hotKeyManager: HotKeyMonitoring
    let modelManager: ModelManaging
    let soundManager: SoundPlaying
    let audioDucker: AudioDucking
    let spotifyPauser: SpotifyPausing
    let cursorOverlay: CursorOverlayManaging

    /// The Settings overlay preview. Owned here so a real dictation can end it
    /// before it starts: a preview left up while the speech model loads would
    /// look like the microphone is already listening.
    /// The one pending "Undo" offered after a Settings list removal.
    let undoCenter = UndoCenter()
    /// Stats and history summaries the v3 window shows, kept across page switches.
    let calmDerived = CalmDerivedCache()

    private(set) lazy var overlayPreview = OverlayPreviewController(
        overlay: cursorOverlay,
        isIdle: { [weak self] in
            guard let self else { return false }
            return appStatus == .idle && !isRecording
        }
    )
    let statsManager: StatsManaging
    let snippetExpander: SnippetExpanding
    let transcriptCleanup: TranscriptCleaning
    /// When each downloaded model was last in use, for Settings › Models.
    let modelUsageLog = ModelUsageLog()
    /// When `stampModelsInUseIfStale()` last wrote, so a dictation writes
    /// the usage log at most once an hour.
    var lastModelUsageStamp: Date?
    /// Bumped when a model the picker doesn't list is removed, so Settings ›
    /// Models measures its downloads again.
    @Published private(set) var unlistedModelRemovals = 0
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
    /// A second llama.cpp slot for a Command Mode model that differs from the
    /// cleanup model, on Macs with the memory for both. Nil shares one slot.
    let commandModelSlot: TranscriptCleaning?
    /// Carries out spoken actions; nil turns them off whatever the setting.
    let voiceActionPerformer: (any VoiceActionPerforming)?
    /// Shows results held for the user; nil keeps them in `commandReview` only.
    let commandReviewPresenter: (any CommandReviewPresenting)?

    /// Polls configured apps and pauses dictation while they run.
    let autoPauseMonitor = AutoPauseMonitor()
    /// Unloads the model after an idle timeout when enabled.
    let modelKeepAlive = ModelKeepAlive()
    /// Sleep/wake recovery hooks.
    let sleepWakeMonitor = SleepWakeMonitor()

    // MARK: - Private

    var cancellables = Set<AnyCancellable>()
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
    var loadGeneration: UInt64 = 0

    /// Serializes model downloads and loads at the AppState boundary. The
    /// engine router also protects its own load/transcribe lifecycle, but UI
    /// actions can otherwise start several downloads or model-management
    /// operations before they reach those lower-level services.
    let modelOperationSerializer = LoadSerializer()

    /// Invalidates an onboarding recommendation when its language or user intent changes.
    private var onboardingModelRequestGeneration: UInt64 = 0
    private var onboardingRequestedModel: ModelSize?
    /// Non-nil only while onboarding itself owns the serialized engine load.
    private var onboardingLoadingRequestGeneration: UInt64?
    /// The language setting `languageDidChange()` has already reacted to
    /// (`languageChangeKey`).
    private var handledLanguageChange: String?

    /// AudioEngine serializes its own lifecycle internally; this wrapper makes
    /// the intentional background handoff explicit for Dispatch's @Sendable API.
    struct AudioEngineWorker: @unchecked Sendable {
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
        SystemInfo.canFitModelInMemory(
            size,
            isFirstLoad: !CompiledModelRecord().hasLoaded(size),
            freeingGB: freeingGB
        )
    }
    var availableInputDevices: () -> [AudioDevice] = { AudioEngine.availableInputDevices() }
    var isLidClosed: () -> Bool = { LidStateReader.isClosed() }
    /// Low Power Mode, or a Mac hot enough to throttle. "Process while
    /// speaking" does its work during the recording, when it competes with
    /// whatever else is running; a recording that starts in these states
    /// waits for stop instead. Checked at start: dictations are short.
    var isPowerConstrained: () -> Bool = { AppState.systemIsPowerConstrained() }
    /// Seam for tests, which must not depend on the host's Apple Intelligence.
    var appleIntelligenceAvailable: () -> Bool = { AppleIntelligenceTextService.isAvailable }

    // MARK: - Initialization

    init(
        audioEngine: AudioRecording = AudioEngine(),
        transcriber: SpeechTranscribing = TranscriptionRouter(),
        textInjector: TextInjecting = TextInjector(),
        hotKeyManager: HotKeyMonitoring = HotKeyManager(),
        modelManager: ModelManaging = ModelManager(),
        soundManager: SoundPlaying = SoundManager(),
        audioDucker: AudioDucking = AudioDucker(),
        spotifyPauser: SpotifyPausing = SpotifyPauser(),
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
        commandModelSlot: TranscriptCleaning? = nil,
        voiceActionPerformer: (any VoiceActionPerforming)? = nil,
        commandReviewPresenter: (any CommandReviewPresenting)? = nil,
        crashReportFinder: CrashReportFinder? = nil,
        skipSystemIntegration: Bool = false
    ) {
        self.audioEngine = audioEngine
        self.transcriber = transcriber
        self.textInjector = textInjector
        self.hotKeyManager = hotKeyManager
        self.modelManager = modelManager
        self.soundManager = soundManager
        self.audioDucker = audioDucker
        self.spotifyPauser = spotifyPauser
        self.cursorOverlay = cursorOverlay
        self.statsManager = statsManager
        self.frontmostAppResolver = frontmostAppResolver ?? FrontmostAppResolver()
        self.snippetExpander = snippetExpander
        self.transcriptCleanup = transcriptCleanup
        self.permissionManager = permissionManager ?? PermissionManager(audioEngine: audioEngine, hotKeyManager: hotKeyManager)
        self.skipSystemIntegration = skipSystemIntegration
        // The sandbox can't read the system's crash reports folder.
        self.crashReportFinder = crashReportFinder
            ?? (skipSystemIntegration || !AppDistribution.canReadCrashReports ? nil : CrashReportFinder())
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
        self.commandModelSlot = commandModelSlot
        self.voiceActionPerformer = voiceActionPerformer ?? (skipSystemIntegration ? nil : SystemVoiceActionPerformer())
        self.commandReviewPresenter = commandReviewPresenter
            ?? (skipSystemIntegration ? nil : CommandReviewPanelController())
        self.isKnownWord = { word, language in
            MainActor.assumeIsolated { SpellingOracle.shared.isKnownWord(word, language: language) }
        }

        VocaLogger.info(.appState, "Initializing... id=\(ObjectIdentifier(self))")
        if !skipSystemIntegration {
            SettingsConsistency.normalize(defaults: .standard)
        }
        loadSnippets()
        loadDictionary()
        settleLearnModeDefault()
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

        updateChecker.isDictationBusy = { [weak self] in
            guard let self else { return false }
            return self.isRecording || self.appStatus == .recording || self.appStatus == .processing
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
        transcriptCleanup: TranscriptCleanupService(),
        commandModelSlot: TranscriptCleanupService()
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
        configureOverlayControls()
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
                guard let self = self else { return }
                // A microphone opened early (model loading, or a queued
                // dictation) is not `isRecording` yet, but its clock started
                // when it opened and the engine fires only once. End it as a
                // key release would; it's transcribed once it can start.
                if !self.isRecording, let early = self.earlyCapture, early.releasedAtSampleCount == nil {
                    VocaLogger.info(.appState, "Max recording duration (\(self.maxRecordingDuration)s) reached before the dictation could start — ending it")
                    await self.stopRecordingAndTranscribe()
                    return
                }
                guard self.isRecording else { return }
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
                await self?.startRecordingFromActivationShortcut()
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
        correctionObserver?.onEdit = { [weak self] observation in
            self?.receiveEdit(observation)
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
        // Mirror AudioDucker: core unmute/resume runs before we return from
        // willTerminate (ducker sync; Spotify sync-with-timeout so Automation
        // consent or a hung Spotify cannot stall quit forever). Only the
        // ducker's settle check is deferred. Pending-pause recovers on the
        // next launch if play does not finish before the timeout.
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.audioDucker.restore()
                self?.spotifyPauser.resumeSynchronouslyForTermination(
                    timeout: SpotifyPauser.terminationResumeTimeout
                )
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
    ///
    /// - Parameter codingAgentTerminal: The terminal found running a coding
    ///   agent; its Terminal rule then cleans up prose (see
    ///   `WritingStyleResolver.applyingCodingAgent`).
    func resolveWritingStyle(
        for target: RunningAppSnapshot?, documentURL: URL? = nil, codingAgentTerminal: RunningAppSnapshot? = nil
    ) -> ResolvedWritingStyle {
        applyingLearnedCasing(
            resolveConfiguredWritingStyle(for: target, documentURL: documentURL, codingAgentTerminal: codingAgentTerminal),
            for: target
        )
    }

    /// The style the user's rules and the presets give, before anything
    /// learned from their edits.
    private func resolveConfiguredWritingStyle(
        for target: RunningAppSnapshot?, documentURL: URL?, codingAgentTerminal: RunningAppSnapshot?
    ) -> ResolvedWritingStyle {
        let appRule = WritingStyleResolver.resolve(
            target: target,
            bindings: writingStyleBindings,
            defaultStyle: writingStyleDefault,
            isEnabled: writingStyleEnabled,
            defaultIntent: writingIntent,
            automatic: automaticWritingStyles ? { [self] app in
                WritingStyleResolver.automaticStyle(for: app) { group in
                    group == .everythingElse ? writingStyleDefault : calmStyleGroupStore.style(for: group)
                }
            } : nil
        )
        let resolved = WritingStyleResolver.applyingWebsiteRule(
            appRule, url: documentURL, bindings: websiteStyleBindings
        )
        let detected = codingAgentsAsProse && codingAgentTerminal != nil
            && Self.sameOutputTarget(codingAgentTerminal, target)
        return WritingStyleResolver.applyingCodingAgent(resolved, detected: detected)
    }

    /// Recompute `activeWritingStyle` for the app the user is working in.
    ///
    /// Called when the menu bar popover appears and after settings changes —
    /// deliberately not on a timer. Uses `styleTargetApp()` rather than the
    /// bare frontmost app: opening the popover activates VocaMac, so by the
    /// time this runs the frontmost app usually *is* VocaMac.
    ///
    /// - Parameter readingWebsite: Also read the target app's page address,
    ///   so a website rule shows as the style it will apply. Only the menu
    ///   asks for this: it costs an Accessibility read of another app.
    func refreshActiveWritingStyle(readingWebsite: Bool = false) {
        let target = frontmostAppResolver.styleTargetApp()
        // Runs on every app switch: publish only what changed, or each switch
        // redraws every view watching AppState.
        let style = resolveWritingStyle(for: target)
        if activeWritingStyle != style { activeWritingStyle = style }
        if activeWritingTargetName != target?.displayName { activeWritingTargetName = target?.displayName }
        websiteRuleRefresh?.cancel()
        websiteRuleRefresh = nil
        // The menu says when a terminal's tab runs a coding agent.
        if readingWebsite, style.style == .terminal, let target,
           let detection = codingAgentDetection(for: target) {
            websiteRuleRefresh = Task { @MainActor [weak self] in
                guard let agentTerminal = await detection.value, let self, !Task.isCancelled else { return }
                let style = resolveWritingStyle(for: target, codingAgentTerminal: agentTerminal)
                if activeWritingStyle != style { activeWritingStyle = style }
            }
            return
        }
        guard readingWebsite, !websiteStyleBindings.isEmpty,
              let target, let reader = screenContextReader else { return }
        websiteRuleRefresh = Task { @MainActor [weak self] in
            let read = Task { @MainActor in await reader.captureDocumentURL(of: target) }
            let url = await Self.value(of: read, within: Self.screenContextTimeout, otherwise: nil)
            guard let self, !Task.isCancelled, let url else { return }
            let style = resolveWritingStyle(for: target, documentURL: url)
            if activeWritingStyle != style { activeWritingStyle = style }
        }
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
        // A known app without a rule follows its kind (automatic styles), so
        // removing the rule wouldn't give it the default style: save a fresh
        // rule with the default style instead — nothing of the old rule, so
        // a Formal tone or custom prompt doesn't survive the reset.
        if automaticWritingStyles, WritingStyleCatalog.suggestion(matching: target) != nil {
            var bindings = writingStyleBindings
            bindings.removeAll { $0.matches(target) }
            bindings.append(AppStyleBinding.from(snapshot: target, style: writingStyleDefault))
            writingStyleBindings = bindings
            VocaLogger.info(.appState, "Reset \(target.displayName) to the default style")
            return target.displayName
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
        // A re-added app goes to the tab its catalog entry picks, not one it
        // was pinned to before it was removed.
        let existingIDs = Set(existing.map(\.id))
        calmResetStyleGroups(forApps: merged.map(\.id).filter { !existingIDs.contains($0) })
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

    /// Stop the decode and cleanup of a dictation that is being abandoned.
    /// Otherwise the local model keeps generating for it, and the next
    /// dictation's cleanup waits behind it.
    func cancelFinishingWork() {
        finishingTranscription?.cancel()
        finishingSpeculator?.cancelAll()
        transcriptCleanup.cancelCleanup()
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
        appleSpeechLanguages = await TranscriptionRouter.appleSpeechLanguageCodes()
    }

    // MARK: - Translation

    /// Whether dictation asks the model to translate: the setting is on and
    /// the model was trained to. The setting survives a switch to a model
    /// that can't (Whisper Turbo, Distil-Whisper), and asking one of those
    /// for the translate task degrades its output instead of translating.
    var translatesSpeech: Bool {
        guard translationEnabled,
              let model = currentModel?.size ?? ModelSize(rawValue: selectedModelSize) else { return false }
        return model.translatesToEnglish
    }

    /// Download and load the model currently recommended by onboarding.
    ///
    /// The recommendation is resolved and revalidated here so a language
    /// change during a download cannot activate the previous language's model.
    func prepareOnboardingRecommendedModel() async {
        // The same recommendation onboarding shows, so the button prepares
        // the model named on screen.
        guard let recommendation = speechModelRecommendation else { return }
        speechModelChosen = true

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

        // Still the model onboarding shows: the same recommendation the
        // download started from, so a preference or memory limit that chose
        // it cannot leave it downloaded but never loaded.
        guard generation == onboardingModelRequestGeneration,
              onboardingRequestedModel == model,
              speechModelRecommendation?.model == model,
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
            await transcriber.unloadModel()
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
    ///
    /// The spoken languages count too: with recognition on Auto, a model
    /// that binds its language at load (Nemotron Unified) is given the only
    /// spoken language, so going from one spoken language to two changes
    /// what it should load with although `selectedLanguage` stays "auto".
    func languageDidChange() async {
        let key = languageChangeKey
        guard handledLanguageChange != key else { return }
        handledLanguageChange = key

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
    /// unseen. Shown with the overlay style Off too: a failure nobody sees
    /// looks like the hotkey did nothing. Always returns true.
    @discardableResult
    func showOverlayFailure(_ message: String) -> Bool {
        cursorOverlay.showFailure(message: message)
        DictationAnnouncement.post(message)
        return true
    }

    /// End the hotkey's double-tap toggle session after a recording stopped,
    /// or failed to start, without a double-tap. Otherwise the next
    /// double-tap is read as "stop" and does nothing. Push-to-talk tracks the
    /// physical key instead, which a reset here could lose mid-press.
    func endHotKeyToggleSession() {
        guard activationMode == .doubleTapToggle else { return }
        hotKeyManager.resetKeyState()
    }

    /// Start the hotkey listener if it isn't running, and rebuild it if macOS
    /// disabled its event tap (a revoked and re-granted permission leaves the
    /// old tap disabled for good).
    func restartHotKeyListenerIfNeeded() {
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
        guard let queued = queuedRecordingStart else { return }
        guard !isTranscribing, !isRecording, !isTranscribingMedia,
              appStatus == .idle || appStatus == .error else {
            // Nothing will try again until the next key press, which would
            // then withdraw this start instead of beginning one.
            VocaLogger.warning(.appState, "Queued dictation couldn't start: \(dictationFlags)")
            if earlyCapture?.releasedAtSampleCount != nil {
                queuedRecordingStart = nil
                discardEarlyCapture()
            }
            return
        }
        queuedRecordingStart = nil
        let releasedAt = earlyCapture?.releasedAtSampleCount
        VocaLogger.info(.appState, "Previous dictation delivered — starting the queued one")
        if queued.isHandsFree { isHandsFreeSession = true }
        dictationTrigger = queued.trigger
        defer { dictationTrigger = .other }
        await startRecording(
            injectResult: queued.injectResult, outputDestination: queued.outputDestination,
            verifiesShortcut: queued.verifiesShortcut
        )
        if queued.isHandsFree && !isRecording { isHandsFreeSession = false }
        // Its key already came up: finish it now, with only the audio from
        // while the key was down.
        if let releasedAt, isCapturingAudio {
            await stopRecordingAndTranscribe(endsHotKeyToggle: true, keepingFirst: releasedAt)
        }
        // A start that never reached the microphone leaves nothing to adopt.
        discardEarlyCapture()
    }

    static let deliveryFailureMessageDuration: TimeInterval = 10

    /// Surface a short-lived error state for settings and menu UI.
    /// A deep link that couldn't do what it was asked, shown like any other
    /// passing error.
    ///
    /// Never over a dictation in progress: the error status would hide its
    /// controls and disarm Escape while the microphone kept recording. Then
    /// the message is logged and the Mac beeps.
    func showDeepLinkError(_ message: String) {
        VocaLogger.warning(.appState, message)
        guard !isRecording, appStatus != .recording, appStatus != .processing else {
            NSSound.beep()
            return
        }
        showTemporaryError(message)
    }

    func showTemporaryError(_ message: String, duration: TimeInterval = 5.0) {
        errorMessage = message
        // Set here as well as on the status change, for an error that
        // follows another before the first one cleared.
        errorNotice = DictationErrorNotice(message: message)
        appStatus = .error

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            if self?.appStatus == .error, self?.errorMessage == message {
                self?.appStatus = .idle
                self?.errorMessage = nil
            }
        }
    }

    /// Restore the model that was active before a failed switch.
    func restorePreviousModelIfNeeded(
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
            try await transcriber.loadModel(name: restoreName, folder: folderURL)
            CompiledModelRecord().recordLoad(previousSize)
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
    func clearActiveModelState() {
        currentModel = nil
        for i in availableModels.indices {
            availableModels[i].isActive = false
            availableModels[i].isLoading = false
            availableModels[i].loadingStatus = "Loading…"
        }
    }

    /// Download a model's files.
    ///
    /// Downloads take turns with each other but not with model loads: a
    /// first load can spend minutes compiling for the Neural Engine, and a
    /// download queued behind it moved no bytes and showed no progress until
    /// it finished. A load that needs a model still being downloaded waits
    /// for that download (see `performDownloadModel`).
    func downloadModel(_ size: ModelSize) async {
        await performDownloadModel(size)
    }

    /// Downloads in progress, one per model, so a second request for the
    /// same model joins the first instead of writing the same files twice.
    private var modelDownloads: [ModelSize: Task<Void, Never>] = [:]

    /// Runs downloads one at a time, apart from `modelOperationSerializer`.
    private let downloadSerializer = LoadSerializer()

    /// Download `size`, or wait for its download already in progress.
    func performDownloadModel(_ size: ModelSize) async {
        if let running = modelDownloads[size] {
            await running.value
            return
        }
        let serializer = downloadSerializer
        let download = Task<Void, Never> { @MainActor [weak self] in
            _ = try? await serializer.run { [weak self] in
                await self?.runModelDownload(size)
            }
        }
        modelDownloads[size] = download
        await download.value
        modelDownloads[size] = nil
    }

    private func runModelDownload(_ size: ModelSize) async {
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

            // Fresh files compile again on their first load.
            CompiledModelRecord().forget(size)

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
        guard let index = availableModels.firstIndex(where: { $0.size == size }) else {
            // On disk but no longer offered on this Mac (an older Whisper
            // download): Settings › Models still lists it so it can go.
            await deleteUnlistedModel(size)
            return
        }
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
            CompiledModelRecord().forget(size)
            modelUsageLog.forget(.speech(size))
            refreshModelStatuses()
            VocaLogger.info(.appState, "Deleted model \(size.displayName)")
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
            VocaLogger.error(.appState, "Delete failed for \(size.displayName): \(error.localizedDescription)")
        }
    }

    /// Delete a downloaded model the picker doesn't list, unless it is the
    /// one loaded.
    private func deleteUnlistedModel(_ size: ModelSize) async {
        guard calmLoadedSpeechModel != size, size != .tiny else { return }
        do {
            try await modelManager.deleteModel(size)
            CompiledModelRecord().forget(size)
            modelUsageLog.forget(.speech(size))
            unlistedModelRemovals += 1
            VocaLogger.info(.appState, "Deleted unlisted model \(size.displayName)")
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
            VocaLogger.error(.appState, "Delete failed for \(size.displayName): \(error.localizedDescription)")
        }
    }

    /// Refresh the download status of all models
    /// This ensures that all previously downloaded models are detected and marked correctly
    func refreshModelStatuses() {
        for i in availableModels.indices {
            let size = availableModels[i].size
            availableModels[i].isDownloaded = modelManager.isModelDownloaded(size)
            availableModels[i].downloadProgress = nil
            availableModels[i].filePath = modelManager.modelFolder(for: size)
        }
    }

    // MARK: - Startup

    func installBundledOrFallback(preferred: ModelSize) async -> Bool {
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
        // Or leave Spotify paused — same idea, farther away (Connect).
        spotifyPauser.resumeAfterUnexpectedExit()

        // 1. Hardware, detected once in `init`.
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

        // The crash-report scan reads the diagnostics folder; nothing below
        // needs it, so it runs while the models load.
        let crashReportCheck = Task<Void, Never> { @MainActor [weak self] in
            await self?.checkForCrashReport()
        }

        // What the last in-place install did, before a new check runs.
        updateChecker.reportLastInstallResult()

        // The update check is a network round trip that needs nothing below.
        // Start it now instead of after both models finish loading, which on
        // a cold CoreML compile can take minutes.
        let updateCheck = Task<Void, Never> { @MainActor [weak self] in
            await self?.updateChecker.checkOnLaunchIfNeeded()
        }

        transcriber.removeRetiredEngineState()
        transcriptCleanup.pruneUnknownModels()
        adoptRecommendedModelIfNeverChosen()

        // 4. Load the user's preferred model. The cleanup model loads with
        // llama.cpp on the GPU while the speech model loads on the Neural
        // Engine, so when memory has room for both they load together:
        // one after the other, a dictation right after launch waited for the
        // second load to start only once the first had finished.
        let cleanupLoad: Task<Void, Never>? = transcriptCleanupEnabled && startupFitsBothModels()
            ? Task<Void, Never> { @MainActor [weak self] in await self?.syncTranscriptCleanup() }
            : nil
        let preparation = Task<Void, Never> { @MainActor [weak self] in
            await self?.prepareStartupModel()
        }
        startupModelPreparation = preparation
        await preparation.value
        startupModelPreparation = nil

        if let cleanupLoad {
            await cleanupLoad.value
        } else if transcriptCleanupEnabled {
            await syncTranscriptCleanup()
        }

        await updateCheck.value
        await crashReportCheck.value

        VocaLogger.info(.appState, "Startup complete!")
    }
    /// Whether the speech model and the cleanup model can load at the same
    /// time: both downloaded, and free memory for both with room to spare.
    func startupFitsBothModels() -> Bool {
        guard cleanupEndpoint.isLocal else { return false }
        let speech = ModelSize(rawValue: selectedModelSize) ?? .tiny
        let cleanup = selectedCleanupModelKind
        guard modelManager.isModelDownloaded(speech), transcriptCleanup.isDownloaded(cleanup) else { return false }
        let speechGB = CompiledModelRecord().hasLoaded(speech) ? speech.ramRequiredGB : speech.firstLoadRAMRequiredGB
        return parallelStartupFits(speechGB + cleanup.descriptor.ramRequiredGB + Self.parallelStartupMarginGB)
    }

    /// The model onboarding recommends, when the user has never picked a
    /// speech model and that one is already on this Mac.
    ///
    /// "Set up later", or quitting before "Download & Use", leaves the
    /// bundled Tiny as an unchosen default, which the startup load then
    /// saves. Once the recommendation is on disk anyway (downloaded from
    /// Settings, or left by an earlier install) there is no reason to stay
    /// on Tiny. Only Tiny is replaced: a choice saved before
    /// `speechModelChosen` existed was recorded without it, and anything
    /// other than the default was picked by someone. Nothing is downloaded
    /// here, and Apple Speech and Custom Endpoint are never picked for the
    /// user: one may fetch system assets, the other uploads audio.
    func recommendedModelForUnchosenDefault() -> ModelSize? {
        guard !speechModelChosen,
              selectedModelSize == ModelSize.tiny.rawValue,
              let model = speechModelRecommendation?.model,
              model != .tiny,
              model.engine != .appleSpeech, model.engine != .customEndpoint,
              modelManager.isModelSupported(model), modelManager.isModelDownloaded(model) else { return nil }
        return model
    }

    /// Switch an unchosen default to the recommended model; see
    /// `recommendedModelForUnchosenDefault`.
    func adoptRecommendedModelIfNeverChosen() {
        guard let model = recommendedModelForUnchosenDefault() else { return }
        VocaLogger.info(.appState, "No speech model was ever chosen — using the recommended \(model.displayName), already downloaded")
        selectedModelSize = model.rawValue
        rebuildAvailableModels()
    }

    /// Headroom kept free when both models load together.
    static let parallelStartupMarginGB = 1.0

    /// Memory gate for loading both models at launch; a seam for tests.
    var parallelStartupFits: (_ requiredGB: Double) -> Bool = { SystemInfo.canFitInMemory(requiredGB: $0) }

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
        VocaLogger.info(.appState, "Model loaded: \(transcriber.loadedModelName ?? "none")")
    }

    func completeOnboarding() {
        syncHotKeyConfiguration()
        if !isRecording {
            hotKeyManager.resetKeyState()
        }
        hasCompletedOnboarding = true
        UserDefaults.standard.removeObject(forKey: PreferenceKey.onboardingResumeStep)
        VocaLogger.info(.appState, "Onboarding completed")
    }

    /// Where onboarding opens. Unfinished onboarding reopens on the step it
    /// was left on, so a Quit & Reopen for a permission (VocaMac's or
    /// macOS's own) lands back there; "Run setup again" starts over.
    var onboardingStartStep: OnboardingStep {
        hasCompletedOnboarding ? .welcome : OnboardingStep.resumeStep()
    }

    /// Save the step onboarding is on, for `onboardingStartStep`.
    func recordOnboardingStep(_ step: OnboardingStep) {
        UserDefaults.standard.set(step.rawValue, forKey: PreferenceKey.onboardingResumeStep)
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
            await warmCleanupModel()
        } else if !transcriptCleanupEnabled {
            transcriptCleanup.unload()
        }
        syncCommandModelSlot()
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
            await warmCleanupModel()
        }
        syncCommandModelSlot()
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
            numbers: numberWriting, numberSymbols: numberSymbols, spokenEmoji: spokenEmoji,
            skipWhenClean: skipCleanDictations, laysOutParagraphs: pauseParagraphs,
            spokenLanguages: spokenLanguages
        )
        return CleanupTryResult(
            input: text, text: output.text, summary: output.summary,
            duration: Date().timeIntervalSince(started)
        )
    }

    /// Whether a key is saved, read from the Keychain once and then kept:
    /// Settings asks on every render, and each Keychain read is a
    /// `SecItemCopyMatching` round trip. Saving or deleting a key here
    /// refreshes it.
    private var cachedCleanupEndpointHasAPIKey: Bool?
    private var cachedSpeechEndpointHasAPIKey: Bool?

    var cleanupEndpointHasAPIKey: Bool {
        if let cached = cachedCleanupEndpointHasAPIKey { return cached }
        let hasKey = KeychainCredentialStore.cleanupEndpoint.readAPIKey()?.isEmpty == false
        cachedCleanupEndpointHasAPIKey = hasKey
        return hasKey
    }

    func saveCleanupAPIKey(_ key: String) throws {
        cachedCleanupEndpointHasAPIKey = nil
        try KeychainCredentialStore.cleanupEndpoint.saveAPIKey(key)
        objectWillChange.send()
    }

    func deleteCleanupAPIKey() throws {
        cachedCleanupEndpointHasAPIKey = nil
        try KeychainCredentialStore.cleanupEndpoint.deleteAPIKey()
        objectWillChange.send()
    }

    var speechEndpointHasAPIKey: Bool {
        if let cached = cachedSpeechEndpointHasAPIKey { return cached }
        let hasKey = KeychainCredentialStore.speechEndpoint.readAPIKey()?.isEmpty == false
        cachedSpeechEndpointHasAPIKey = hasKey
        return hasKey
    }

    func saveSpeechEndpointAPIKey(_ key: String) throws {
        cachedSpeechEndpointHasAPIKey = nil
        try KeychainCredentialStore.speechEndpoint.saveAPIKey(key)
        objectWillChange.send()
    }

    func deleteSpeechEndpointAPIKey() throws {
        cachedSpeechEndpointHasAPIKey = nil
        try KeychainCredentialStore.speechEndpoint.deleteAPIKey()
        objectWillChange.send()
    }

    func reloadImportedSettings() {
        cachedCleanupEndpointHasAPIKey = nil
        cachedSpeechEndpointHasAPIKey = nil
        loadSnippets()
        loadDictionary()
        decodedBindingsCache = nil
        syncHotKeyConfiguration()
        syncShortcutConfiguration()
        syncLaunchAtLogin()
        refreshActiveWritingStyle()
        // An imported "Transcribe as you speak" only takes effect with the
        // matching encoder; a no-op when the loaded one already matches.
        Task { @MainActor [weak self] in
            await self?.reloadModelForLiveStreamingChangeIfNeeded()
        }
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
        // The models this choice may replace were in use until now.
        stampModelsInUse()
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
        syncCommandModelSlot()
        stampModelsInUse()
        if role != .commandMode { await warmCleanupModel() }
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
        await useAIModel(sharedAIModelCandidate, for: .both)
    }

    /// The model sharing would put to work: the cleanup model when it can
    /// edit text, then the local Command Mode model, then the one suggested
    /// for this Mac.
    var sharedAIModelCandidate: CleanupModelKind {
        if selectedCleanupModelKind.supportsCommandMode { return selectedCleanupModelKind }
        if case .local(let commandKind) = commandModeEngine { return commandKind }
        return cleanupModelSuggestion.commandMode
    }

    /// Whether to point out that one model can do both: cleanup is on, both
    /// features run separate models on this Mac, and the person hasn't
    /// already chosen to keep them apart.
    var suggestsSharingAIModel: Bool {
        guard transcriptCleanupEnabled, cleanupEndpoint.isLocal,
              !sharesAIModel, !aiModelsKeptSeparate,
              case .local = commandModeEngine else { return false }
        return true
    }

    /// Run Command Mode with Apple Intelligence or the cleanup endpoint.
    /// Local models go through `useAIModel`, which can download them.
    func selectCommandModeEngine(_ engine: CommandModeEngine) {
        aiModelChoiceGeneration += 1
        commandModeEngine = engine
        syncCommandModelSlot()
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
        syncCommandModelSlot()
        await warmCleanupModel()
    }

    func deleteCleanupModel(_ kind: CleanupModelKind) {
        transcriptCleanup.delete(kind)
        modelUsageLog.forget(.writing(kind))
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
        if !transcriber.isModelLoaded {
            await ensureModelLoaded()
        }
        guard transcriber.isModelLoaded else {
            throw CLIError(.modelNotDownloaded, "The selected speech model could not be loaded.")
        }
        let loaded = try await Task.detached(priority: .userInitiated) {
            try AudioFileLoader().loadAudio(at: url)
        }.value
        let language = selectedLanguage == "auto" ? nil : selectedLanguage
        let result = try await transcriber.transcribe(
            audioData: loaded.samples,
            language: language,
            translate: translatesSpeech,
            vocabulary: recognitionHintVocabulary
        )
        statsManager.recordTranscription(result, isDictation: false)
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
        if !transcriber.isModelLoaded { await ensureModelLoaded() }
        guard transcriber.isModelLoaded else { throw CLIError(.modelNotDownloaded, "The selected model could not be loaded.") }
        // Cancelled when the capture window is closed and its audio
        // discarded: stop before (or during) the decode, and never record a
        // result nobody will see.
        try Task.checkCancellation()
        let result = try await transcriber.transcribe(
            audioData: samples,
            language: selectedLanguage == "auto" ? nil : selectedLanguage,
            translate: translatesSpeech,
            vocabulary: recognitionHintVocabulary
        )
        try Task.checkCancellation()
        statsManager.recordTranscription(result, isDictation: false)
        lastTranscription = result
        return result
    }

    static let mediaTranscriptionWaitSeconds: TimeInterval = 120

    /// Nothing else is using the speech model. An error banner is only a
    /// message, so it doesn't count as busy.
    var isFreeForMediaTranscription: Bool {
        !isRecording && !isTranscribingMedia && !isTeachingWord && (appStatus == .idle || appStatus == .error)
    }

}

// MARK: - Crash reports

extension AppState {

    /// Look for a crash report macOS wrote since the last one VocaMac showed.
    func checkForCrashReport() async {
        guard let finder = crashReportFinder else { return }
        let pending = await Task.detached(priority: .utility) { finder.newestUnseenReport() }.value
        guard let pending else { return }
        VocaLogger.warning(
            .general,
            "VocaMac quit unexpectedly last time: \(pending.report.summary) (\(pending.fileURL.lastPathComponent))"
        )
        pendingCrashReport = pending
    }

    /// Open a pre-filled GitHub issue for the crash. Nothing is sent: the
    /// user reads it in the browser and decides whether to submit.
    /// Report waits for a dictation to finish: a browser error would replace
    /// its status and hide its controls.
    var canReportPendingCrash: Bool {
        pendingCrashReport != nil && !isRecording && appStatus != .recording && appStatus != .processing
    }

    func reportPendingCrash(open: (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        guard canReportPendingCrash, let pending = pendingCrashReport else { return }
        guard open(CrashIssue.url(for: pending.report)) else {
            // Keep the card so the user can try again or use Show File.
            showTemporaryError("Couldn't open your browser to report the crash. Use Show File to attach the report to an issue.")
            return
        }
        dismissPendingCrash()
    }

    /// Show the full crash report in Finder, to attach to an issue.
    func revealPendingCrashReport() {
        guard let pending = pendingCrashReport else { return }
        NSWorkspace.shared.activateFileViewerSelecting([pending.fileURL])
    }

    func dismissPendingCrash() {
        guard let pending = pendingCrashReport else { return }
        crashReportFinder?.markSeen(through: pending.modified)
        pendingCrashReport = nil
    }
}

// MARK: - History, Shortcuts, and Dictionary

extension AppState {

    // MARK: History

    /// Record a dictation in history before it is transcribed. Returns nil
    /// when history is off.
    func beginHistoryEntry(audio: [Float]) async -> UUID? {
        let target = frontmostAppResolver.currentFrontmostApp() ?? pendingTargetApp
        guard historyRecords(target) else {
            if historyEnabled {
                VocaLogger.info(.history, "Not saving this dictation: \(target?.displayName ?? "the app") is excluded from History")
            }
            return nil
        }
        historyStore.applyRetention(historyRetention)
        let modelID = currentModel?.size.rawValue ?? selectedModelSize
        // Transcription starts as soon as the entry is journaled. The audio is
        // still written (a failed or cancelled dictation needs it for Retry),
        // but in parallel rather than first.
        return await historyStore.begin(
            audio: audio,
            target: target,
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

    /// Whether a dictation in `profile` gets paragraph breaks at its pauses:
    /// only in a style that allows paragraphs, and never "Exactly as
    /// transcribed", which promises no formatting at all.
    nonisolated static func laysOutParagraphs(enabled: Bool, profile: WritingProfile) -> Bool {
        enabled && profile.format.allowsParagraphs && profile.cleanup != .raw
    }

    /// The transcript with a paragraph break at each long pause between two
    /// sentences. Reads the whole recording's loudness, so it runs off the
    /// main thread.
    nonisolated static func paragraphsAtPauses(_ result: VocaTranscription, audio: [Float]) async -> String {
        let text = result.text
        let segments = result.segments
        guard segments.contains(where: { !$0.words.isEmpty }) else { return text }
        return await Task.detached(priority: .userInitiated) {
            PauseParagraphs.apply(to: text, segments: segments, audio: audio)
        }.value
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
            guard transcriber.isModelLoaded else {
                showTemporaryError("Could not load the speech model. Open Settings → Speech Model and try again.")
                return nil
            }
            let result = try await transcriber.transcribe(
                audioData: samples,
                language: selectedLanguage == "auto" ? nil : selectedLanguage,
                translate: translatesSpeech,
                vocabulary: recognitionHintVocabulary
            )
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var output: DictationOutputResult?
            if !text.isEmpty {
                let profile = resolveWritingStyle(for: entry.targetApp).profile
                let laysOutParagraphs = Self.laysOutParagraphs(enabled: pauseParagraphs, profile: profile)
                let spoken = laysOutParagraphs
                    ? await Self.paragraphsAtPauses(result, audio: samples)
                    : result.text
                output = await outputPipeline.process(
                    spoken, profile: profile, snippetList: snippets,
                    cleanupEnabled: transcriptCleanupEnabled, rewritingEnabled: writingRewriteEnabled,
                    model: selectedCleanupModelKind, customPrompt: effectiveCleanupPrompt,
                    cleanupLevel: transcriptCleanupLevel,
                    language: result.detectedLanguage, autoCapitalize: autoCapitalize,
                    trailingSpace: appendTrailingSpace,
                    dictionary: dictionaryContext(
                        contextTerms: [], language: DictationOutputPipeline.languagePrior(
                            reported: result.detectedLanguage, spoken: spokenLanguages, text: result.text
                        ), segments: result.segments
                    ),
                    numbers: numberWriting, numberSymbols: numberSymbols, spokenEmoji: spokenEmoji,
                    skipWhenClean: skipCleanDictations, laysOutParagraphs: laysOutParagraphs,
                    spokenLanguages: spokenLanguages
                )
            }
            historyStore.recordRetry(
                id, rawText: result.text, finalText: output?.text ?? "", summary: output?.summary,
                language: result.detectedLanguage, modelID: result.modelUsed.rawValue,
                transcriptionSeconds: result.duration, segments: result.segments
            )
            guard let output else {
                showTemporaryError("The retry didn't hear any words in that recording.")
                return nil
            }
            lastOutput = output
            lastUnsavedDictation = nil
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

    /// The loaded speech model's name as the model list shows it. Engines
    /// report an identifier ("openai_whisper-tiny"), which is for logs, not
    /// for people.
    var loadedModelDisplayName: String? {
        if let model = currentModel { return CalmModelText.name(model.size) }
        guard let name = transcriber.loadedModelName else { return nil }
        let size = ModelSize(rawValue: name) ?? modelManager.modelSize(from: name)
        return size.map(CalmModelText.name) ?? name
    }

    /// Open Speech Model showing only models that translate.
    func showModelsThatTranslate() {
        requestedSpeechModelSearch = "translate"
        requestSettingsPage(.speechModel)
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
        let commandMode = HotKeyCombo(storageString: commandModeShortcut)
        if let commandMode {
            shortcuts[.commandMode] = commandMode
        }
        // Saved commands are part of Command Mode: while it is off (no
        // shortcut), their shortcuts are off too. Turning it on restores them.
        for command in savedCommands where command.isUsable && commandMode != nil {
            if let combo = HotKeyCombo(storageString: command.shortcut) {
                shortcuts[.savedCommand(command.id)] = combo
            }
        }
        monitor.updateShortcuts(shortcuts)
        monitor.updateMouseTrigger(button: MouseTriggerButton.resolved(stored: mouseTriggerButton).rawValue)
        refreshCancelKeyArming()
    }

    /// Every action that can have a shortcut: the built-in ones and each
    /// saved command.
    var shortcutActions: [HotKeyShortcutAction] {
        HotKeyShortcutAction.builtIn + savedCommands.map { .savedCommand($0.id) }
    }

    /// What `action` is called in a "that's already the … shortcut" message.
    func shortcutName(for action: HotKeyShortcutAction) -> String {
        guard case .savedCommand(let id) = action else { return action.displayName.lowercased() }
        let name = savedCommands.first { $0.id == id }?.name ?? ""
        return name.isEmpty ? "saved command" : "“\(name)”"
    }

    func shortcut(for action: HotKeyShortcutAction) -> HotKeyCombo? {
        switch action {
        case .pasteLastDictation: return HotKeyCombo(storageString: pasteLastShortcut)
        case .handsFreeToggle: return HotKeyCombo(storageString: handsFreeShortcut)
        case .commandMode: return HotKeyCombo(storageString: commandModeShortcut)
        case .savedCommand(let id):
            return savedCommands.first { $0.id == id }.flatMap { HotKeyCombo(storageString: $0.shortcut) }
        }
    }

    func setShortcut(_ combo: HotKeyCombo?, for action: HotKeyShortcutAction) {
        let stored = combo?.storageString ?? ""
        switch action {
        case .pasteLastDictation: pasteLastShortcut = stored
        case .handsFreeToggle: handsFreeShortcut = stored
        case .commandMode: commandModeShortcut = stored
        case .savedCommand(let id):
            var commands = savedCommands
            guard let index = commands.firstIndex(where: { $0.id == id }) else { return }
            commands[index].shortcut = stored
            // The setter pushes the new shortcuts to the listener.
            savedCommands = commands
            return
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
            if pendingReviewEdit != nil {
                // The edit on screen is waiting for exactly this: the same
                // keys that asked for it approve it.
                await acceptCommandReview()
            } else if activeCommandTarget != nil,
                      isCapturingAudio {
                // A second press completes a Command Mode session that was
                // started with a quick press instead of a hold.
                commandModePressStartedAt = nil
                await stopRecordingAndTranscribe()
            } else {
                commandModePressStartedAt = Date()
                commandModeReleasedBeforeRecording = false
                await beginCommandMode()
                if activeCommandTarget == nil {
                    commandModePressStartedAt = nil
                }
            }
        case .savedCommand(let id):
            await runSavedCommand(id)
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
            // The overlay said “Let go to apply”; now it takes a second press.
            cursorOverlay.setStopHint(overlayStopHint)
            return
        }

        // A hold released before the microphone was on — reading the
        // selection can take most of a second in an Electron app. Nothing the
        // user said while holding was recorded, and turning the session into
        // a press-again one would record speech they meant as done. Call it
        // off instead and say how to time it.
        guard activeCommandTarget != nil,
              isCapturingAudio else {
            commandModeReleasedBeforeRecording = true
            VocaLogger.debug(.appState, "Command Mode released before recording began — cancelling")
            return
        }
        await stopRecordingAndTranscribe()
    }

}
