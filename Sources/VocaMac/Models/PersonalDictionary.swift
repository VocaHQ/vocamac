// PersonalDictionary.swift
// VocaMac
//
// The user's own words: vocabulary terms that must be spelled their way,
// replacements for words an engine keeps getting wrong, and corrections
// VocaMac noticed the user making.

import Foundation

/// Rewrite what an engine heard into what the user meant, e.g.
/// "get hub" → "GitHub". Applied to every engine's output.
struct WordReplacement: Identifiable, Codable, Equatable {
    var id: UUID
    /// One or more spoken forms, comma-separated. Matching ignores case.
    var heard: String
    /// Exactly what to type instead.
    var replacement: String

    init(id: UUID = UUID(), heard: String, replacement: String) {
        self.id = id
        self.heard = heard
        self.replacement = replacement
    }

    /// Each non-empty spoken form in `heard`.
    var heardForms: [String] {
        heard.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var isValid: Bool {
        !heardForms.isEmpty && !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A correction VocaMac saw the user make to dictated text.
struct CorrectionSuggestion: Identifiable, Codable, Equatable {
    /// What was typed.
    var heard: String
    /// What the user changed it to.
    var corrected: String
    var occurrences: Int
    var lastSeen: Date

    var id: String { Self.key(heard: heard, corrected: corrected) }

    static func key(heard: String, corrected: String) -> String {
        "\(heard.lowercased())→\(corrected)"
    }
}

/// What VocaMac does when it sees the user correct a dictated word.
enum LearnCorrectionsMode: String, CaseIterable, Identifiable, Codable {
    case off
    case suggest
    case automatic

    var id: String { rawValue }

    static let defaultMode: LearnCorrectionsMode = .suggest

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .suggest: return "Suggest words"
        case .automatic: return "Add automatically"
        }
    }

    var description: String {
        switch self {
        case .off:
            return "VocaMac doesn't look at text after typing it."
        case .suggest:
            return "When you fix a word VocaMac typed, it suggests adding your spelling to the dictionary."
        case .automatic:
            return "When you fix a word VocaMac typed, your spelling is added to the dictionary right away."
        }
    }
}

/// Everything the output pipeline needs to apply the personal dictionary to
/// one dictation.
struct DictionaryContext {
    var vocabulary: [String]
    var replacements: [WordReplacement]
    /// Names and identifiers read from the screen when recording started.
    var contextTerms: [String]
    /// Whether a word is ordinary vocabulary in the dictation's language.
    var isKnownWord: (String) -> Bool

    var isEmpty: Bool {
        vocabulary.isEmpty && replacements.isEmpty && contextTerms.isEmpty
    }
}
