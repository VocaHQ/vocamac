// HallucinationGuard.swift
// VocaMac
//
// Drops the stock phrases a speech model writes over audio with no speech
// in it ("Thank you.", "Thanks for watching!"), when the voice activity
// detector found no speech either.
//
// Whisper large-v3 writes text for about 40% of non-speech clips, and a
// quarter of that is "thank you"; Parakeet can invent a word on a recording
// of a single quiet one. Trimming silence (`SpeechActivityTrimmer`) removes
// most of the cause. What's left is the recording the detector was unsure
// of: speech-like frames, but no stretch of speech long enough to keep.

import Foundation

enum HallucinationGuard {

    /// Whole transcripts that are, far more often than not, a model's
    /// filler for silence or noise. Lowercased, letters and spaces only.
    static let phrases: Set<String> = [
        "thank you", "thank you very much", "thank you so much", "thanks for watching",
        "thank you for watching", "thanks for watching and see you next time", "thank you for listening",
        "please subscribe", "like and subscribe", "subscribe to my channel", "see you next time",
        "you", "bye", "bye bye", "so", "the end", "music", "applause", "silence",
        "subtitles by the amara org community", "transcribed by", "i'm sorry",
    ]

    /// Whether `text` is nothing but one of `phrases`.
    static func isStockPhrase(_ text: String) -> Bool {
        let key = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return phrases.contains(key)
    }

    /// `text`, or nothing when the detector heard no speech in the recording
    /// (`speechUnconfirmed`) and the text is a stock phrase. A recording the
    /// detector found speech in is never touched, so a real "Thank you." or
    /// "Bye." always reaches the user.
    static func filter(_ text: String, speechUnconfirmed: Bool) -> String {
        guard speechUnconfirmed, isStockPhrase(text) else { return text }
        VocaLogger.info(.general, "Dropped a likely hallucination (\(text.count) characters) from audio with no detected speech")
        return ""
    }
}
