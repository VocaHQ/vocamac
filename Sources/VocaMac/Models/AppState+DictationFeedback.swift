// AppState+DictationFeedback.swift
// VocaMac
//
// Keeps the menu, the overlay, and VoiceOver in step with the dictation:
// which stage it is in, the error the menu keeps until dismissed, and the
// overlay's own Stop and Cancel buttons.

import AppKit
import Foundation

extension AppState {

    // MARK: - Status Changes

    /// Runs after every change of `appStatus`.
    func handleAppStatusChange(from oldStatus: AppStatus) {
        let status = appStatus
        if status != .processing, isCleaningUp { isCleaningUp = false }
        switch status {
        case .recording:
            // A new dictation supersedes the last error.
            errorNotice = nil
            cursorOverlay.setEscapeHintVisible(escapeCancelsDictation)
        case .processing:
            cursorOverlay.setEscapeHintVisible(escapeCancelsDictation)
        case .error:
            if let errorMessage {
                errorNotice = DictationErrorNotice(message: errorMessage)
                DictationAnnouncement.post(errorMessage)
            }
        case .idle:
            break
        }
        if let message = DictationAnnouncement.message(
            from: oldStatus, to: status, isCommandMode: commandModeSession != nil
        ) {
            DictationAnnouncement.post(message)
        }
    }

    // MARK: - Processing Stage

    /// The transcript has reached the Smart Cleanup model. Only a dictation
    /// being processed moves on; Settings previews of cleanup don't.
    func dictationReachedCleanup() {
        guard appStatus == .processing, commandModeSession == nil, !isCleaningUp else { return }
        isCleaningUp = true
        cursorOverlay.transitionToCleaningUp()
    }

    /// What the menu says while a dictation is being worked on.
    var processingStatusText: String {
        if dictationPhase == .loadingModel { return "Loading speech model…" }
        return isCleaningUp ? "Cleaning up…" : "Transcribing…"
    }

    // MARK: - Error Notice

    /// Close the error the menu is showing. Also clears a stuck error status,
    /// which is what the old "Reset to Idle" button was for.
    func dismissErrorNotice() {
        errorNotice = nil
        if appStatus == .error { forceRecovery() }
    }

    /// Do what an error's fix button offers. Settings pages open through
    /// `openSettings`, which the menu owns.
    func performErrorFix(_ action: ErrorFixAction, openSettings: (SettingsPage) -> Void) {
        errorNotice = nil
        if appStatus == .error {
            appStatus = .idle
            errorMessage = nil
        }
        switch action {
        case .openSettings(let page):
            openSettings(page)
        case .openMicrophonePrivacy:
            requestMicrophonePermission()
        case .openAccessibilityPrivacy:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            startPermissionPolling()
        }
    }

    // MARK: - Overlay Controls

    /// The overlay's Stop and Cancel buttons do what the menu's do. While a
    /// Settings preview owns the overlay they only end the preview.
    func configureOverlayControls() {
        cursorOverlay.setControlActions(
            stop: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.overlayPreview.isRunning {
                        self.overlayPreview.stop()
                        return
                    }
                    await self.stopRecordingAndTranscribe()
                }
            },
            cancel: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.overlayPreview.isRunning {
                        self.overlayPreview.stop()
                        return
                    }
                    await self.cancelDictation()
                }
            }
        )
    }

    /// How the dictation being started ends, for the overlay's hint and its
    /// Hands-free label. The hands-free shortcut (and the menu) keep
    /// recording until pressed again, whatever the activation mode.
    var overlayStopHint: OverlayStopHint {
        if let silentStopHint { return silentStopHint }
        return OverlayStopHint.resolve(
            commandMode: commandModeSession == nil ? nil : (
                isKeyHeld: isCommandModeKeyHeld,
                shortcut: shortcut(for: .commandMode).map { CalmKeyCaps.compactText(for: $0) }
            ),
            isHandsFreeSession: isHandsFreeSession,
            handsFreeShortcut: shortcut(for: .handsFreeToggle).map { CalmKeyCaps.compactText(for: $0) },
            trigger: dictationTrigger,
            mode: activationMode,
            dictationKey: CalmKeyCaps.compactText(for: HotKeyCombo(keyCode: hotKeyCode, modifiers: hotKeyModifiers))
        )
    }

    // MARK: - Menu Bar

    /// What VoiceOver reads for the menu bar icon.
    var menuBarAccessibilityLabel: String {
        MenuBarAccessibility.label(
            status: appStatus, readiness: dictationReadiness,
            isCommandMode: commandModeSession != nil, isSilentMode: isSilentSession, isCleaningUp: isCleaningUp,
            isAutoPaused: isAutoPaused
        )
    }

    // MARK: - Language

    /// Set the languages the user speaks. Recognition follows: one language
    /// pins it, several or none leave detection on. Settings and onboarding
    /// both go through here, so the two never disagree.
    func setSpokenLanguages(_ languages: [String]) {
        spokenLanguages = languages
        let recognized = LanguageSync.recognitionLanguage(for: spokenLanguages)
        if selectedLanguage != recognized { selectedLanguage = recognized }
    }

    // MARK: - Sound

    /// Start and stop sounds as one choice: a tone, or Off.
    var soundCue: DictationTone {
        get { SoundPreference.displayed(enabled: soundEffectsEnabled, tone: dictationTone) }
        set {
            let stored = SoundPreference.stored(for: newValue, currentTone: dictationTone)
            if dictationTone != stored.tone { dictationTone = stored.tone }
            if soundEffectsEnabled != stored.enabled { soundEffectsEnabled = stored.enabled }
        }
    }
}
