// DictationFeedback.swift
// VocaMac
//
// What VocaMac tells the user about a dictation that is running or went
// wrong: the fix an error points to, the menu bar icon's state and spoken
// label, and what VoiceOver announces.

import AppKit
import Foundation

// MARK: - Error Fixes

/// One thing the user can do about an error, offered as a button beside it.
enum ErrorFixAction: Equatable {
    case openSettings(SettingsPage)
    case openMicrophonePrivacy
    case openAccessibilityPrivacy

    var title: String {
        switch self {
        case .openSettings(let page): return "Open \(page.title)"
        case .openMicrophonePrivacy: return "Allow Microphone…"
        case .openAccessibilityPrivacy: return "Allow Accessibility…"
        }
    }

    var systemImage: String {
        switch self {
        case .openSettings(let page): return page.systemImage
        case .openMicrophonePrivacy: return "mic"
        case .openAccessibilityPrivacy: return "hand.raised"
        }
    }

    /// The fix an error message points to, if any. Messages name the place
    /// to go in words ("Settings → Audio"); this turns that into a button.
    static func suggested(for message: String) -> ErrorFixAction? {
        let text = message.lowercased()
        if text.contains("microphone permission") || text.contains("microphone access") {
            return .openMicrophonePrivacy
        }
        if text.contains("accessibility is off") {
            return .openAccessibilityPrivacy
        }
        if text.contains("settings → audio") {
            return .openSettings(.audio)
        }
        if text.contains("settings → speech model") || text.contains("speech model is still downloading") {
            return .openSettings(.speechModel)
        }
        return nil
    }
}

/// An error the menu keeps showing until it is dismissed or the next
/// dictation starts, with the fix it points to.
struct DictationErrorNotice: Equatable {
    let message: String
    let action: ErrorFixAction?

    init(message: String, action: ErrorFixAction? = nil) {
        self.message = message
        self.action = action ?? ErrorFixAction.suggested(for: message)
    }
}

// MARK: - Menu Bar Status

/// How ready the idle menu bar icon should look.
enum MenuBarReadiness: Equatable {
    case ready
    /// A model is downloading or loading; dictation will work soon.
    case preparing
    /// A permission or a speech model is missing; dictation can't start.
    case blocked

    init(_ readiness: DictationReadiness) {
        switch readiness {
        case .ready: self = .ready
        case .preparingModel: self = .preparing
        case .needsMicrophone, .needsInputMonitoring, .needsAccessibility, .needsModel: self = .blocked
        }
    }
}

/// What VoiceOver reads for the menu bar icon: the app, then what it is doing
/// or what it needs.
enum MenuBarAccessibility {
    static func label(
        status: AppStatus,
        readiness: DictationReadiness,
        isCommandMode: Bool = false,
        isSilentMode: Bool = false,
        isCleaningUp: Bool = false,
        isAutoPaused: Bool = false
    ) -> String {
        if isSilentMode, status == .recording { return "VocaMac, Silent Mode reading your lips" }
        guard let state = stateDescription(
            status: status, readiness: readiness, isCommandMode: isCommandMode,
            isCleaningUp: isCleaningUp, isAutoPaused: isAutoPaused
        ) else { return "VocaMac" }
        return "VocaMac, \(state)"
    }

    private static func stateDescription(
        status: AppStatus,
        readiness: DictationReadiness,
        isCommandMode: Bool,
        isCleaningUp: Bool,
        isAutoPaused: Bool
    ) -> String? {
        switch status {
        case .recording:
            return isCommandMode ? "Command Mode listening" : "recording"
        case .processing:
            if isCommandMode { return "editing selection" }
            return isCleaningUp ? "cleaning up" : "transcribing"
        case .error:
            return "error"
        case .idle:
            if isAutoPaused { return "paused" }
            switch readiness {
            case .needsMicrophone, .needsInputMonitoring, .needsAccessibility: return "needs permission"
            case .needsModel: return "needs a speech model"
            case .preparingModel: return "preparing speech model"
            case .ready: return nil
            }
        }
    }
}

// MARK: - VoiceOver Announcements

/// What VoiceOver says as a dictation moves along, so someone who can't see
/// the overlay knows the microphone is on and when it went off.
enum DictationAnnouncement {
    /// What VoiceOver hears once the microphone is live. The status turns to
    /// `.recording` earlier, while the input is still connecting, so the
    /// status change itself isn't announced.
    static func recordingStarted(isCommandMode: Bool) -> String {
        isCommandMode ? "Command Mode listening" : "Recording"
    }

    static func message(from oldStatus: AppStatus, to newStatus: AppStatus, isCommandMode: Bool) -> String? {
        guard oldStatus != newStatus else { return nil }
        switch (oldStatus, newStatus) {
        case (.recording, .processing):
            return isCommandMode ? "Editing selection" : "Recording stopped, transcribing"
        case (.recording, .idle):
            return "Recording stopped"
        default:
            return nil
        }
    }

    /// Ask VoiceOver to read `message` now. Does nothing when VoiceOver is
    /// off or before the app has finished launching.
    @MainActor
    static func post(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, NSWorkspace.shared.isVoiceOverEnabled else { return }
        // NSApp is nil while AppState is first built.
        guard let app = NSApp as NSApplication? else { return }
        NSAccessibility.post(
            element: app,
            notification: .announcementRequested,
            userInfo: [
                .announcement: trimmed,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
