// RecognitionHints.swift
// VocaMac
//
// Shapes Dictionary vocabulary into the recognition hint each engine accepts.
//
// Whisper takes the terms as prompt tokens (see `WhisperService`), Apple
// Speech as `AnalysisContext` contextual strings, and Parakeet as a CTC
// vocabulary boost. The specialized ONNX models take no hint; every engine
// still gets `DictionaryCorrector` after transcription.

import Foundation

enum RecognitionHints {

    /// Apple Speech treats contextual strings as a bias list; a short list
    /// of the user's own words works better than a whole glossary.
    static let maximumContextualStrings = 100

    /// FluidAudio's CTC word spotter is tuned for up to about 100 terms, and
    /// false positives rise quickly for very short ones ("or" → "VR").
    static let maximumBoostTerms = 100
    static let minimumBoostTermLength = 4

    /// Words FluidAudio's rescorer would happily "find" everywhere.
    private static let boostStopwords: Set<String> = [
        "about", "after", "again", "also", "because", "been", "being", "could",
        "does", "each", "from", "have", "here", "into", "just", "like", "made",
        "make", "more", "most", "much", "only", "other", "over", "said", "same",
        "some", "such", "than", "that", "their", "them", "then", "there", "these",
        "they", "this", "those", "very", "want", "well", "were", "what", "when",
        "where", "which", "while", "will", "with", "would", "your",
    ]

    /// Terms in a comma/newline vocabulary string, first spelling wins.
    static func terms(from vocabulary: String) -> [String] {
        var seen = Set<String>()
        return WhisperService.vocabularyTerms(from: vocabulary)
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// Contextual strings for Apple Speech, in the order the user gave them.
    static func contextualStrings(from vocabulary: String) -> [String] {
        Array(terms(from: vocabulary).suffix(maximumContextualStrings))
    }

    /// Terms worth a CTC boost pass on Parakeet.
    ///
    /// `recognitionVocabulary` puts the user's own words last, so keep the
    /// tail when trimming to the cap.
    static func boostTerms(from vocabulary: String) -> [String] {
        let usable = terms(from: vocabulary).filter { term in
            let letters = term.filter { $0.isLetter || $0.isNumber }
            return letters.count >= minimumBoostTermLength
                && !boostStopwords.contains(term.lowercased())
        }
        return Array(usable.suffix(maximumBoostTerms))
    }

    /// Replacement targets that read like a term rather than a snippet.
    ///
    /// "get hub" → "GitHub" makes GitHub a good hint; a replacement that
    /// types an email address or a sentence is not something to listen for.
    static func isHintableReplacement(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...32).contains(trimmed.count),
              trimmed.contains(where: \.isLetter),
              !trimmed.contains("@"), !trimmed.contains("/"), !trimmed.contains(":") else { return false }
        return trimmed.split(whereSeparator: \.isWhitespace).count <= 3
    }
}

/// Download state of Parakeet's vocabulary boost model.
enum VocabularyBoostStatus: Equatable {
    case notDownloaded
    case downloading
    case ready
    case failed(String)
}
