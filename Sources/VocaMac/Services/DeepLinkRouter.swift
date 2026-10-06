// DeepLinkRouter.swift
// VocaMac

import Foundation

enum VocaDeepLink: Equatable {
    case startDictation
    case stopDictation
    case toggleDictation
    case pasteLast
    case history
    case settings
    case transcribeFile
    case scratchpad

    /// Recording and text injection are privileged side effects when invoked
    /// by another process through the custom URL scheme. App Intents are an
    /// explicit Shortcuts surface and do not use this gate.
    var requiresExternalConfirmation: Bool {
        switch self {
        case .startDictation, .stopDictation, .toggleDictation, .pasteLast:
            return true
        case .history, .settings, .transcribeFile, .scratchpad:
            return false
        }
    }

    var confirmationDescription: String {
        switch self {
        case .startDictation: return "start microphone recording"
        case .stopDictation: return "stop recording and type the transcript"
        case .toggleDictation: return "start or stop microphone recording"
        case .pasteLast: return "type your last saved dictation"
        case .history, .settings, .transcribeFile, .scratchpad: return "open VocaMac"
        }
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == "vocamac" else { return nil }
        let command = [url.host, url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "/").lowercased()
        switch command {
        case "dictate/start", "start": self = .startDictation
        case "dictate/stop", "stop": self = .stopDictation
        case "dictate/toggle", "toggle": self = .toggleDictation
        case "paste-last": self = .pasteLast
        case "history": self = .history
        case "settings": self = .settings
        case "transcribe-file": self = .transcribeFile
        case "scratchpad": self = .scratchpad
        default: return nil
        }
    }
}

@MainActor
extension AppState {
    func handleDeepLink(_ link: VocaDeepLink) async {
        switch link {
        case .startDictation:
            if !isRecording { await startRecording() }
        case .stopDictation:
            if isRecording { await stopRecordingAndTranscribe() }
        case .toggleDictation:
            if isRecording { await stopRecordingAndTranscribe() }
            else { await startRecording() }
        case .pasteLast:
            pasteLastDictation()
        case .history:
            requestSettingsPage(.history)
        case .settings, .transcribeFile, .scratchpad:
            // Window-opening links are handled by the app's window managers.
            break
        }
    }
}

/// Which app a confirmed deep link should act on.
enum DeepLinkReturnTarget {

    /// The bundle ID to put back in front once the user allows a link.
    ///
    /// macOS brings VocaMac forward to deliver a `vocamac://` URL, so by the
    /// time the link is handled the frontmost app is usually VocaMac itself.
    /// The app the user came from is then the last other app to be activated.
    static func bundleIdentifier(
        frontmost: String?,
        lastActive: String?,
        ownBundleIdentifier: String?
    ) -> String? {
        for candidate in [frontmost, lastActive] {
            guard let candidate, !candidate.isEmpty, candidate != ownBundleIdentifier else { continue }
            return candidate
        }
        return nil
    }
}
