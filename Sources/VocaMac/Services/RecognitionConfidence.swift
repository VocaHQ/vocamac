// RecognitionConfidence.swift
// VocaMac
//
// Which words the speech engine was unsure of.
//
// Whisper (token log-probabilities) and Parakeet (token confidences) report
// how sure they were of each word; Apple Speech, the ONNX models and a remote
// endpoint don't. A real word decoded with low confidence is the evidence
// `DictionaryCorrector` needs before it respells ordinary words as a term
// that sounds the same.

import Foundation

enum RecognitionConfidence {

    /// Below this a word counts as unsure. Whisper's word probability for a
    /// clearly spoken common word is usually above 0.9; misheard names and
    /// jargon fall well below this.
    static let lowThreshold = 0.6

    /// Normalized words (see `DictionaryCorrector.normalized`) decoded below
    /// `lowThreshold` every time they were heard, or nil when no word in
    /// `segments` carries a confidence, so callers can tell "sure of
    /// everything" from "doesn't say".
    ///
    /// The text the Dictionary sees has been cleaned since the decode, so a
    /// word's position there no longer matches the engine's. A word heard
    /// once unsure and once sure ("pie" twice) is therefore left out: one
    /// unsure occurrence must never vouch for respelling another the engine
    /// was sure of. A word without a confidence counts as sure.
    static func lowConfidenceWords(in segments: [TimedSegment]) -> Set<String>? {
        let words = segments.flatMap(\.words)
        guard words.contains(where: { $0.probability != nil }) else { return nil }
        var unsure = Set<String>()
        var sure = Set<String>()
        for word in words {
            let key = DictionaryCorrector.normalized(word.word)
            guard !key.isEmpty else { continue }
            if let probability = word.probability, probability < lowThreshold {
                unsure.insert(key)
            } else {
                sure.insert(key)
            }
        }
        return unsure.subtracting(sure)
    }
}
