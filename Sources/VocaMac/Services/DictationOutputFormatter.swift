// DictationOutputFormatter.swift
// VocaMac
//
// Pure helpers that polish transcribed text before injection.
// Ports VocaLinux trailing-space (#608) and sentence capitalization (#554).

import Foundation

/// Formats completed dictation utterances for injection at the cursor.
enum DictationOutputFormatter {

    /// How much context `capitalizeSentences` is allowed to take into account.
    enum CapitalizationScope {
        /// Pre-writing-styles behavior: first character of the string, then any
        /// lowercase ASCII letter after `.` `!` `?` plus whitespace.
        ///
        /// Kept so the writing-styles master toggle — and the Plain style,
        /// which promises the same thing — really are byte-for-byte the old
        /// pipeline, rather than the old pipeline plus two silent upgrades.
        case legacy
        /// Adds line starts, identifier protection, and placeholder awareness.
        /// Used by every style that actually shapes its output.
        case styleAware
    }

    /// Capitalize the first letter of each sentence.
    ///
    /// Under `.styleAware`, uppercases the first letter of the string, the
    /// first letter of every line, and any letter that follows sentence-ending
    /// punctuation (`.`, `!`, `?`) plus whitespace. Leaves URLs
    /// (`example.com`), decimals (`3.14`), and abbreviations without trailing
    /// space untouched. Idempotent on already-capitalized text.
    ///
    /// Two things are then deliberately never re-cased:
    ///
    /// - a `TextPlaceholder` scalar (a masked snippet expansion or a filename
    ///   the writing-style engine just built) — it carries the case the user
    ///   or the rule intended;
    /// - a word that already looks like an identifier (`readme.md`,
    ///   `src/utils`, `handleInput`), whether this pass built it or the speech
    ///   engine emitted it. `Readme.md` names a different file.
    ///
    /// Under `.legacy` none of that applies; see `CapitalizationScope`.
    static func capitalizeSentences(
        _ text: String,
        scope: CapitalizationScope = .styleAware
    ) -> String {
        guard !text.isEmpty else { return text }
        guard scope == .styleAware else { return capitalizeSentencesLegacy(text) }

        let characters = Array(text)
        var result = ""
        result.reserveCapacity(text.count)

        // True while looking for the letter that starts the next sentence.
        // Markup ("- ", "**") sits between the boundary and that letter, so
        // non-letter characters do not clear it.
        var awaitingCapital = true
        var afterTerminator = false

        for index in characters.indices {
            let character = characters[index]

            if awaitingCapital, character.isLetter {
                if isIdentifierLike(characters, from: index) {
                    result.append(character)
                } else {
                    result += character.uppercased()
                }
                awaitingCapital = false
                afterTerminator = false
                continue
            }

            result.append(character)

            if TextPlaceholder.isPlaceholder(character) {
                // Opaque: it supplies its own text and its own capitalization.
                awaitingCapital = false
                afterTerminator = false
            } else if character.isNumber {
                // A sentence that opens with a number has nothing to capitalize.
                awaitingCapital = false
                afterTerminator = false
            } else if character == "." || character == "!" || character == "?" {
                afterTerminator = true
            } else if character.isNewline {
                // A line break starts a new sentence even without punctuation.
                awaitingCapital = true
                afterTerminator = false
            } else if character.isWhitespace {
                if afterTerminator {
                    awaitingCapital = true
                    afterTerminator = false
                }
            } else {
                afterTerminator = false
            }
        }

        return result
    }

    /// The capitalization pass exactly as it stood before writing styles.
    ///
    /// Mirrors VocaLinux: `([.!?])(\s+)([a-z])`, ASCII lowercase only, so URLs
    /// and decimals without a space stay untouched.
    private static func capitalizeSentencesLegacy(_ text: String) -> String {
        // Capitalize the first character without assuming a single Unicode scalar.
        var result = String(text.prefix(1)).uppercased() + text.dropFirst()

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

    /// Whether the word starting at `index` reads as a filename, path, or
    /// camel-cased identifier rather than an English word.
    ///
    /// Hyphens are not a signal: "well-known" is ordinary prose.
    private static func isIdentifierLike(_ characters: [Character], from index: Int) -> Bool {
        var position = index
        var sawInteriorSeparator = false
        var sawInteriorUppercase = false

        while position < characters.count, !characters[position].isWhitespace {
            let character = characters[position]
            let isInterior = position > index && position + 1 < characters.count
                && !characters[position + 1].isWhitespace

            if character == "." || character == "/" || character == "_" {
                if isInterior, characters[position - 1].isLetter || characters[position - 1].isNumber,
                   characters[position + 1].isLetter || characters[position + 1].isNumber {
                    sawInteriorSeparator = true
                }
            } else if position > index, character.isUppercase {
                sawInteriorUppercase = true
            }
            position += 1
        }

        return sawInteriorSeparator || sawInteriorUppercase
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
    /// Skips empty text, text already ending in terminal punctuation
    /// (`.` `!` `?` `:` `;`), a closing bracket or quote, and text ending in a
    /// masked snippet expansion — a signature block ends the way the user
    /// wrote it, not with a bolted-on period.
    static func ensureTerminalPeriod(_ text: String) -> String {
        // Structural voice commands may leave one or more trailing newlines.
        // Punctuate the final content before them, then put the exact line
        // ending back instead of producing `content\n.`.
        let contentEnd = text.lastIndex(where: { $0 != "\n" && $0 != "\r" })
            .map { text.index(after: $0) }
            ?? text.startIndex
        let trailingNewlines = text[contentEnd...]
        let trimmed = text[..<contentEnd].trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return text }
        guard !TextPlaceholder.isPlaceholder(last) else { return text }
        guard !".!?:;)]}\"'".contains(last) else {
            return trimmed + trailingNewlines
        }
        return trimmed + "." + trailingNewlines
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
            // The pre-writing-styles entry point keeps the pre-writing-styles
            // capitalization; styled output goes through `WritingStyleEngine`.
            result = capitalizeSentences(result, scope: .legacy)
        }
        if appendTrailingSpace {
            result = self.appendTrailingSpace(result)
        }
        return result
    }
}
