// TranscriptionLanguage.swift
// VocaMac
//
// Selectable transcription language catalog (ISO 639-1 codes WhisperKit accepts).

import Foundation

/// A language the user can pin for recognition (or auto-detect).
struct TranscriptionLanguage: Identifiable, Hashable {
    /// ISO 639-1 code, or `"auto"` for detection.
    let code: String
    let displayName: String

    var id: String { code }

    static let auto = TranscriptionLanguage(code: "auto", displayName: "Auto-detect")

    /// Expanded catalog aligned with VocaLinux speech language choices.
    /// Codes are ISO 639-1 so WhisperKit / Apple Speech / sherpa routing stay valid.
    static let catalog: [TranscriptionLanguage] = [
        .auto,
        TranscriptionLanguage(code: "en", displayName: "English"),
        TranscriptionLanguage(code: "es", displayName: "Spanish"),
        TranscriptionLanguage(code: "fr", displayName: "French"),
        TranscriptionLanguage(code: "de", displayName: "German"),
        TranscriptionLanguage(code: "it", displayName: "Italian"),
        TranscriptionLanguage(code: "pt", displayName: "Portuguese"),
        TranscriptionLanguage(code: "nl", displayName: "Dutch"),
        TranscriptionLanguage(code: "pl", displayName: "Polish"),
        TranscriptionLanguage(code: "ru", displayName: "Russian"),
        TranscriptionLanguage(code: "uk", displayName: "Ukrainian"),
        TranscriptionLanguage(code: "cs", displayName: "Czech"),
        TranscriptionLanguage(code: "sk", displayName: "Slovak"),
        TranscriptionLanguage(code: "hu", displayName: "Hungarian"),
        TranscriptionLanguage(code: "ro", displayName: "Romanian"),
        TranscriptionLanguage(code: "bg", displayName: "Bulgarian"),
        TranscriptionLanguage(code: "hr", displayName: "Croatian"),
        TranscriptionLanguage(code: "sr", displayName: "Serbian"),
        TranscriptionLanguage(code: "sv", displayName: "Swedish"),
        TranscriptionLanguage(code: "da", displayName: "Danish"),
        TranscriptionLanguage(code: "no", displayName: "Norwegian"),
        TranscriptionLanguage(code: "fi", displayName: "Finnish"),
        TranscriptionLanguage(code: "el", displayName: "Greek"),
        TranscriptionLanguage(code: "tr", displayName: "Turkish"),
        TranscriptionLanguage(code: "ar", displayName: "Arabic"),
        TranscriptionLanguage(code: "he", displayName: "Hebrew"),
        TranscriptionLanguage(code: "fa", displayName: "Persian"),
        TranscriptionLanguage(code: "hi", displayName: "Hindi"),
        TranscriptionLanguage(code: "bn", displayName: "Bengali"),
        TranscriptionLanguage(code: "ta", displayName: "Tamil"),
        TranscriptionLanguage(code: "th", displayName: "Thai"),
        TranscriptionLanguage(code: "vi", displayName: "Vietnamese"),
        TranscriptionLanguage(code: "id", displayName: "Indonesian"),
        TranscriptionLanguage(code: "ms", displayName: "Malay"),
        TranscriptionLanguage(code: "zh", displayName: "Chinese"),
        TranscriptionLanguage(code: "ja", displayName: "Japanese"),
        TranscriptionLanguage(code: "ko", displayName: "Korean"),
        TranscriptionLanguage(code: "ca", displayName: "Catalan"),
    ]

    /// Languages excluding auto-detect, sorted by display name.
    static var selectable: [TranscriptionLanguage] {
        catalog.filter { $0.code != "auto" }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Filter the catalog by display name or code.
    static func filtered(search: String) -> [TranscriptionLanguage] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return catalog }
        return catalog.filter {
            $0.displayName.lowercased().contains(needle) || $0.code.lowercased().contains(needle)
        }
    }
}
