// ServiceProtocols.swift
// VocaMac
//
// Protocol abstractions for all services that AppState depends on.
// Enables dependency injection and test mocking.

import Foundation
import Combine

// MARK: - AudioRecording

protocol AudioRecording: AnyObject {
    var isCurrentlyRecording: Bool { get }
    var onAudioLevel: ((Float) -> Void)? { get set }
    var onAudioSamples: (([Float], Int) -> Void)? { get set }
    var onSilenceDetected: (() -> Void)? { get set }
    var onMaxDurationReached: (() -> Void)? { get set }
    var onAudioDeviceChanged: (() -> Void)? { get set }
    var onInputDeviceFallback: ((String) -> Void)? { get set }

    @discardableResult
    func startRecording(
        silenceThreshold: Float,
        silenceDuration: Double,
        maxDuration: TimeInterval,
        preferredInputDeviceID: String?,
        preferredInputChannel: Int,
        preferredInputChannelDeviceID: String?,
        preferredInputChannelCount: Int
    ) -> Bool
    @discardableResult func stopRecording() -> [Float]
    func cancelPendingStart()
    func forceReset()
    func checkPermissionStatus() -> PermissionStatus
    func requestPermission(completion: @escaping (Bool) -> Void)
}

extension AudioRecording {
    var onAudioSamples: (([Float], Int) -> Void)? {
        get { nil }
        set { }
    }
}

// MARK: - SoundPlaying

protocol SoundPlaying: AnyObject {
    var volume: Float { get set }
    func playStartSound()
    func playStartSoundAsync() async
    func playStopSound()
    func playStopSoundAsync() async
    func previewStartThenStop() async
}

extension SoundPlaying {
    func previewStartThenStop() async {
        await playStartSoundAsync()
        await playStopSoundAsync()
    }
}

// MARK: - AudioDucking

/// Silences other audio while a recording is open and brings it back afterwards.
protocol AudioDucking: AnyObject {
    /// Mute the default output if another app is playing and the user has not muted it already.
    func duck()
    /// Unmute what `duck` muted, if it is still muted.
    func restore()
    /// Undo a mute the previous process did not get to restore (crash, kill).
    func restoreAfterUnexpectedExit()
}

// MARK: - HotKeyMonitoring

protocol HotKeyMonitoring: AnyObject {
    var isListening: Bool { get }
    var eventTap: CFMachPort? { get }
    var onRecordingStart: (() -> Void)? { get set }
    var onRecordingStop: (() -> Void)? { get set }

    func checkAccessibilityPermission(prompt: Bool) -> Bool
    func startListening(keyCode: Int, mode: ActivationMode, doubleTapThreshold: Double, safetyTimeout: Double, modifiers: HotKeyModifiers)
    func stopListening()
    func resetKeyState()
    func _updateConfiguration(keyCode: Int?, mode: ActivationMode?, doubleTapThreshold: Double?, safetyTimeout: Double?, modifiers: HotKeyModifiers?)
}

/// Extra global shortcuts, the Escape cancel key, and the mouse trigger.
/// Separate from `HotKeyMonitoring` so existing conformances keep compiling;
/// the default implementations do nothing.
protocol HotKeyShortcutMonitoring: AnyObject {
    var onShortcut: ((HotKeyShortcutAction) -> Void)? { get set }
    var onShortcutReleased: ((HotKeyShortcutAction) -> Void)? { get set }
    var onCancel: (() -> Void)? { get set }
    func updateShortcuts(_ shortcuts: [HotKeyShortcutAction: HotKeyCombo])
    func setCancelKeyArmed(_ armed: Bool)
    func updateMouseTrigger(button: Int)
}

extension HotKeyManager: HotKeyShortcutMonitoring {}

extension HotKeyMonitoring {
    func updateConfiguration(keyCode: Int? = nil, mode: ActivationMode? = nil, doubleTapThreshold: Double? = nil, safetyTimeout: Double? = nil, modifiers: HotKeyModifiers? = nil) {
        _updateConfiguration(keyCode: keyCode, mode: mode, doubleTapThreshold: doubleTapThreshold, safetyTimeout: safetyTimeout, modifiers: modifiers)
    }
}

// MARK: - PermissionManaging

@MainActor
protocol PermissionManaging: AnyObject {
    var micPermission: PermissionStatus { get set }
    var accessibilityPermission: PermissionStatus { get set }
    var inputMonitoringPermission: PermissionStatus { get set }
    var allPermissionsGranted: Bool { get }
    var onAllPermissionsGranted: (() -> Void)? { get set }

    var objectWillChangePublisher: AnyPublisher<Void, Never> { get }

    func checkPermissions()
    func startPermissionPolling()
    func stopPermissionPolling()
    func requestMicrophonePermission()
    func openMicrophoneSettings()
    func requestAccessibilityPermission()
    func requestInputMonitoringPermission()
}

// MARK: - CursorOverlayManaging

@MainActor
protocol CursorOverlayManaging: AnyObject {
    /// Shows the overlay in its connecting state: visible, but explicit that
    /// the microphone is not capturing yet.
    func show(style: OverlayStyle, position: OverlayPosition)
    func hide()
    func transitionToRecording()
    func transitionToProcessing()
    func updateAudioLevel(_ level: Float)
    func updateTranscript(_ text: String)
}

// MARK: - ModelManaging

protocol ModelManaging: AnyObject {
    func deviceRecommendation() -> (defaultModel: String, supported: [String], disabled: [String])
    func modelFolder(for size: ModelSize) -> URL?
    func bundledModelFolder(for size: ModelSize) -> URL?
    func installBundledModelIfAvailable(for size: ModelSize) throws -> Bool
    func ensureTokenizerAssets(for size: ModelSize) throws -> URL
    func isModelDownloaded(_ size: ModelSize) -> Bool
    func isModelSupported(_ size: ModelSize) -> Bool
    func modelIdentifier(for size: ModelSize) -> String
    func modelSize(from identifier: String) -> ModelSize?
    func downloadModel(size: ModelSize, onProgress: @escaping (Double) -> Void) async throws
    func deleteModel(_ size: ModelSize) async throws
    func diskUsageDescription() -> String
}

extension ModelManaging {
    func bundledModelFolder(for size: ModelSize) -> URL? { nil }
}

extension ModelManaging {
    func installBundledModelIfAvailable(for size: ModelSize) throws -> Bool { false }
}

extension ModelManaging {
    func ensureTokenizerAssets(for size: ModelSize) throws -> URL {
        guard let folder = modelFolder(for: size) else {
            throw NSError(domain: "VocaMac.ModelManaging", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model folder unavailable for \(size.rawValue)"])
        }
        return folder
    }
}

// MARK: - SpeechTranscribing

protocol SpeechTranscribing: AnyObject {
    var loadedModelName: String? { get }
    var isModelLoaded: Bool { get }
    func startStreaming(
        language: String?,
        vocabulary: String,
        onPartial: (@Sendable (String) -> Void)?
    ) -> RecordingTranscription?
    func transcribe(audioData: [Float], language: String?, translate: Bool, vocabulary: String) async throws -> VocaTranscription
    func _loadModel(name: String?, folder: URL?, onPhaseChange: ((String) -> Void)?) async throws
    /// Release the currently loaded model (and any sibling engines) to free memory.
    func unloadModel() async
}

extension SpeechTranscribing {
    func startStreaming(
        language: String?,
        vocabulary: String = "",
        onPartial: (@Sendable (String) -> Void)? = nil
    ) -> RecordingTranscription? { nil }

    func loadModel(name: String? = nil, folder: URL? = nil, onPhaseChange: ((String) -> Void)? = nil) async throws {
        try await _loadModel(name: name, folder: folder, onPhaseChange: onPhaseChange)
    }
}

// MARK: - TextInjecting

protocol TextInjecting: AnyObject {
    var onFailure: ((String) -> Void)? { get set }
    func inject(text: String, preserveClipboard: Bool)
}

// MARK: - FrontmostAppResolving

/// Identifies the app that will receive injected text, so writing styles can
/// be chosen for it. Injectable so style resolution is testable without a
/// window server.
///
/// Main-actor bound, like `StatsManaging`: the concrete resolver caches the
/// last activated app from an `NSWorkspace` notification delivered on the main
/// queue, and every caller reads it from `AppState`, which is `@MainActor`.
/// Stating that here is what keeps it true once strict concurrency is on.
@MainActor
protocol FrontmostAppResolving: AnyObject {
    /// The frontmost application, or `nil` when it cannot be determined or is
    /// VocaMac itself.
    func currentFrontmostApp() -> RunningAppSnapshot?

    /// The last application other than VocaMac to be activated.
    ///
    /// Needed because VocaMac's own popover and Settings window take focus:
    /// while either is open the frontmost app *is* VocaMac, and "which style
    /// applies here" has to be answered about the app the user came from.
    func lastActiveApp() -> RunningAppSnapshot?
}

extension FrontmostAppResolving {
    /// The app a dictation should be styled for: whatever is in front, falling
    /// back to the last app that was.
    @MainActor
    func styleTargetApp() -> RunningAppSnapshot? {
        currentFrontmostApp() ?? lastActiveApp()
    }
}

extension TextInjecting {
    var onFailure: ((String) -> Void)? {
        get { nil }
        set { }
    }
}

// MARK: - StatsManaging

@MainActor
protocol StatsManaging: AnyObject {
    var stats: UserStats { get }
    var objectWillChangePublisher: AnyPublisher<Void, Never> { get }
    func recordTranscription(_ transcription: VocaTranscription)
    func refreshCurrentStreak()
    func flushPendingSaves()
    func resetStats()
}

extension StatsManaging {
    func refreshCurrentStreak() {}
    func flushPendingSaves() {}
}

// MARK: - SnippetExpanding

protocol SnippetExpanding: AnyObject {
    func expand(in text: String, using snippets: [Snippet]) -> String

    /// Expand triggers, but leave each expansion masked as a single opaque
    /// character so later formatting cannot reshape user-authored text.
    func expandMasked(in text: String, using snippets: [Snippet]) -> MaskedText
}

extension SnippetExpanding {
    /// Conformances that only implement `expand` still work; their expansions
    /// are simply not protected from formatting.
    func expandMasked(in text: String, using snippets: [Snippet]) -> MaskedText {
        MaskedText(text: expand(in: text, using: snippets))
    }
}

// MARK: - TranscriptCleaning

@MainActor
protocol TranscriptCleaning: AnyObject {
    var modelState: CleanupModelState { get }
    var isLoaded: Bool { get }
    nonisolated func inputBudget(forPrompt prompt: String) -> Int
    var objectWillChangePublisher: AnyPublisher<Void, Never> { get }

    func clean(_ text: String, prompt: String) async -> String
    func attempt(_ text: String, prompt: String) async -> CleanupAttempt
    func preview(_ text: String, prompt: String) async -> CleanupAttempt
    /// Transform selected text for Command Mode. Unlike transcript cleanup,
    /// this may intentionally translate, expand, or substantially shorten it.
    func transform(_ text: String, prompt: String) async -> CleanupAttempt
    func availabilityProblem(for kind: CleanupModelKind) -> String?
    func isDownloaded(_ kind: CleanupModelKind) -> Bool
    func pruneUnknownModels()
    func download(_ kind: CleanupModelKind) async
    func cancelDownload()
    func load(_ kind: CleanupModelKind) async
    func unload()
    func delete(_ kind: CleanupModelKind)
}

extension TranscriptCleaning {
    func availabilityProblem(for kind: CleanupModelKind) -> String? {
        isDownloaded(kind) ? nil : "download a local cleanup model in Settings"
    }

    func attempt(_ text: String, prompt: String) async -> CleanupAttempt {
        let output = await clean(text, prompt: prompt)
        return CleanupAttempt(output: output, outcome: output == text ? .unchanged : .cleaned, duration: 0)
    }

    func transform(_ text: String, prompt: String) async -> CleanupAttempt {
        await preview(text, prompt: prompt)
    }
}
