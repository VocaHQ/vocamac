// WordTeaching.swift
// VocaMac
//
// Teaching a Dictionary word by saying it: the user says the word a few
// times, each take is decoded without recognition hints, and the ways the
// engine misheard it become spoken forms of a replacement for that word,
// the same entry `AppState.learn` makes from a correction.
//
// A replacement fires on every later match, so this keeps the rules the
// rest of the Dictionary follows: a single ordinary word ("cloud" heard for
// Claude) never becomes a replacement — the word stays a recognition hint,
// and the Dictionary and cleanup respell it only where the engine was unsure
// (`DictionaryCorrector`, `EditMerge`). Pure, so it is tested without a
// microphone.

import Foundation

enum WordTeaching {
    /// Takes per word: enough to catch the usual mishearings.
    static let maximumTakes = 3
    /// A take ends on its own after this long; a word takes a second or two.
    static let takeSeconds: TimeInterval = 4

    /// One way a take was heard, and what can be done with it.
    struct Heard: Equatable, Identifiable {
        enum Verdict: Equatable {
            /// Heard as the word itself (any case or spacing): nothing to learn.
            case matches
            /// Can become a spoken form of the word.
            case learnable
            /// One everyday word: a replacement would rewrite ordinary speech.
            case ordinaryWord
            /// Already a spoken form of this word.
            case alreadyLearned
            /// Already a spoken form of another replacement, which would win.
            case taken(by: String)
            /// Far longer than the word: background speech, not the word.
            case unlikely
        }

        /// As it would be stored: lowercased, punctuation removed.
        let form: String
        let verdict: Verdict
        /// Takes it was heard in.
        var count: Int = 1

        var id: String { form }
        var isLearnable: Bool { verdict == .learnable }
    }

    /// A take's transcript as a spoken form: lowercased, without
    /// punctuation (a full stop, quotes), spaces collapsed. Apostrophes and
    /// hyphens inside words stay.
    static func spokenForm(of transcript: String) -> String {
        let kept = transcript.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber || character == "'" || character == "’" || character == "-" {
                return character
            }
            return " "
        }
        return String(kept)
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-'’")) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The distinct ways `transcripts` heard `term`, in the order first heard.
    /// Empty takes are left out.
    static func review(
        term: String,
        transcripts: [String],
        replacements: [WordReplacement],
        isKnownWord: (String) -> Bool
    ) -> [Heard] {
        var heard: [Heard] = []
        for transcript in transcripts {
            let form = spokenForm(of: transcript)
            guard !form.isEmpty else { continue }
            if let index = heard.firstIndex(where: { $0.form == form }) {
                heard[index].count += 1
                continue
            }
            heard.append(Heard(form: form, verdict: verdict(
                for: form, term: term, replacements: replacements, isKnownWord: isKnownWord
            )))
        }
        return heard
    }

    static func verdict(
        for form: String,
        term: String,
        replacements: [WordReplacement],
        isKnownWord: (String) -> Bool
    ) -> Heard.Verdict {
        if DictionaryCorrector.normalized(form) == DictionaryCorrector.normalized(term) {
            return .matches
        }
        if let existing = replacements.first(where: { replacement in
            replacement.heardForms.contains { $0.lowercased() == form }
        }) {
            return existing.replacement == term ? .alreadyLearned : .taken(by: existing.replacement)
        }
        let termWords = term.split(whereSeparator: \.isWhitespace).count
        if form.split(separator: " ").count > max(3, termWords * 2 + 1) {
            return .unlikely
        }
        if AppState.isOrdinaryWord(form, isKnownWord: isKnownWord) {
            return .ordinaryWord
        }
        return .learnable
    }
}
