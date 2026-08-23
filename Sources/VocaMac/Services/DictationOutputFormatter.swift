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
    /// Uppercases the first letter of the string and any lowercase letter
    /// that follows sentence-ending punctuation (`.`, `!`, `?`) plus whitespace.
    /// Leaves URLs (`example.com`), decimals (`3.14`), and abbreviations without
    /// trailing space untouched. Idempotent on already-capitalized text.
    static func capitalizeSentences(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        // Capitalize the first *letter*, not the first character. A style may
        // have prefixed the text with markup ("- ", "**"), and uppercasing a
        // marker would silently leave the sentence lowercase.
        var result = text
        if let firstLetter = result.firstIndex(where: { $0.isLetter }) {
            result.replaceSubrange(firstLetter...firstLetter, with: result[firstLetter].uppercased())
        }

        // Capitalize after sentence-ending punctuation + whitespace.
        // Mirrors VocaLinux: ([.!?])(\s+)([a-z]). ASCII lowercase only so
        // URLs and decimals without a space stay untouched.
        let pattern = #"([.!?])(\s+)([a-z])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return result
        }

        let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
        let matches = regex.matches(in: result, range: nsRange)
        // Apply from the end so earlier ranges stay valid.
        for match in matches.reversed() {
            guard let letterRange = Range(match.range(at: 3), in: result) else { continue }
            result.replaceSubrange(letterRange, with: result[letterRange].uppercased())
        }

        return result
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

    /// Remove a single trailing period.
    ///
    /// Editors and shells almost never want the sentence period a speech
    /// engine adds. Only one `.` is removed, and only when it is the last
    /// character, so an ellipsis or a filename keeps its dots.
    static func stripTrailingPeriod(_ text: String) -> String {
        guard text.count > 1, text.hasSuffix(".") else { return text }
        // Leave "..." and decimals like "3." alone.
        let withoutPeriod = String(text.dropLast())
        guard let last = withoutPeriod.last, last != "." else { return text }
        return withoutPeriod
    }

    /// Append `.` when the text does not already end in terminal punctuation.
    ///
    /// Skips empty text and text already ending in `.` `!` `?` `:` or a
    /// closing bracket, so lists and quoted fragments are left alone.
    static func ensureTerminalPeriod(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return text }
        guard !".!?:;)]}\"'".contains(last) else { return text }
        return trimmed + "."
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
