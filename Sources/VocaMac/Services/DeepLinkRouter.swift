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
