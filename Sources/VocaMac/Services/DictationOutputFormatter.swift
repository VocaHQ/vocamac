// DictationOutputFormatter.swift
// VocaMac
//
// Pure helpers that polish transcribed text before injection.
// Ports VocaLinux trailing-space (#608) and sentence capitalization (#554).

import Foundation

/// Formats completed dictation utterances for injection at the cursor.
enum DictationOutputFormatter {

    /// Capitalize the first letter of each sentence.
    ///
    /// Uppercases the first character of the string and any lowercase letter
    /// that follows sentence-ending punctuation (`.`, `!`, `?`) plus whitespace.
    /// Leaves URLs (`example.com`), decimals (`3.14`), and abbreviations without
    /// trailing space untouched. Idempotent on already-capitalized text.
    static func capitalizeSentences(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var characters = Array(text)
        characters[0] = Character(characters[0].uppercased())

        var index = 1
        while index < characters.count {
            let current = characters[index]
            if current == "." || current == "!" || current == "?" {
                var whitespaceEnd = index + 1
                while whitespaceEnd < characters.count && characters[whitespaceEnd].isWhitespace {
                    whitespaceEnd += 1
                }
                if whitespaceEnd > index + 1, whitespaceEnd < characters.count {
                    let candidate = characters[whitespaceEnd]
                    if candidate.isLetter && candidate.isLowercase {
                        characters[whitespaceEnd] = Character(candidate.uppercased())
                    }
                    index = whitespaceEnd
                    continue
                }
            }
            index += 1
        }

        return String(characters)
    }

    /// Append a trailing space so consecutive dictation sessions do not glue.
    ///
    /// Skips empty text, text that already ends with whitespace, and text that
    /// ends with a newline (paragraph breaks should not gain a trailing space).
    static func appendTrailingSpace(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        if text.last?.isWhitespace == true {
            return text
        }
        return text + " "
    }

    /// Apply capitalization and/or trailing-space polish in that order.
    ///
    /// - Parameters:
    ///   - text: Already-trimmed utterance text (caller trims before calling).
    ///   - autoCapitalize: When true, run `capitalizeSentences`.
    ///   - appendTrailingSpace: When true, run `appendTrailingSpace`.
    static func apply(
        _ text: String,
        autoCapitalize: Bool,
        appendTrailingSpace: Bool
    ) -> String {
        var result = text
        if autoCapitalize {
            result = capitalizeSentences(result)
        }
        if appendTrailingSpace {
            result = self.appendTrailingSpace(result)
        }
        return result
    }
}
