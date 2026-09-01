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
        /// which promises the same thing — reproduce the old pipeline rather
        /// than the old pipeline plus two silent upgrades.
        ///
        /// One deliberate exception remains, and it is not this rule's: the old
        /// pipeline polished *before* expanding snippets, so an expansion
        /// ending in whitespace could pick up a second space or a stray column
        /// of indent. Expanding first and masking the expansion fixes that, and
        /// the fix is wanted, so a whitespace-ending snippet is the one place
        /// where output legitimately differs from the previous release.
        /// `SnippetWritingStyleInteractionTests` pins both halves.
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

    /// Sentence-ending marks, across the scripts a dictation can arrive in.
    ///
    /// A speech engine transcribing Hindi emits a danda, and one transcribing
    /// Chinese emits an ideographic full stop. Recognising only ASCII made
    /// `ensureTerminalPeriod` treat those sentences as unpunctuated and bolt a
    /// second, wrong mark onto them ("धन्यवाद।." / "谢谢。.").
    private static let terminalPunctuation: Set<Character> = [
        // Latin and shared.
        ".", "!", "?", ":", ";", "\u{2026}",
        // Devanagari and the Indic scripts that share the danda.
        "\u{0964}", "\u{0965}",
        // Arabic.
        "\u{06D4}", "\u{061F}", "\u{061B}",
        // Armenian, Ethiopic, Thai-adjacent, Tibetan.
        "\u{0589}", "\u{055C}", "\u{055E}", "\u{1362}", "\u{0F0D}",
        // CJK and full-width forms.
        "\u{3002}", "\u{FF01}", "\u{FF1F}", "\u{FF0E}", "\u{FF1A}", "\u{FF1B}"
    ]

    /// Closing marks that end a sentence when they follow one.
    private static let closingMarks: Set<Character> = [
        ")", "]", "}", "\"", "'",
        // Curly quotes a speech engine or a snippet can produce.
        "\u{2019}", "\u{201D}", "\u{00BB}", "\u{203A}",
        // CJK brackets and quotes.
        "\u{3001}", "\u{300D}", "\u{300F}", "\u{FF09}", "\u{3011}", "\u{3009}"
    ]

    /// Remove a single trailing period.
    ///
    /// Editors and shells almost never want the sentence period a speech
    /// engine adds. Only one `.` is removed, and only when it ends the
    /// content, so an ellipsis or a filename keeps its dots.
    ///
    /// Trailing newlines are preserved exactly, mirroring
    /// `ensureTerminalPeriod`: a structural command leaves "run tests.\n", and
    /// the period is still the thing to remove.
    static func stripTrailingPeriod(_ text: String) -> String {
        let (content, lineEnding) = splitTrailingLineEndings(text)
        guard content.count > 1, content.hasSuffix(".") else { return text }
        // Leave "..." and decimals like "3." alone.
        let withoutPeriod = content.dropLast()
        guard let last = withoutPeriod.last, last != "." else { return text }
        return withoutPeriod + lineEnding
    }

    /// Append `.` when the text does not already end in terminal punctuation.
    ///
    /// Skips empty text, text already ending in terminal punctuation or a
    /// closing bracket or quote in any script, and text ending in a masked
    /// snippet expansion — a signature block ends the way the user wrote it,
    /// not with a bolted-on period.
    ///
    /// It also declines to punctuate a script whose full stop is not `.`.
    /// Guessing that a Hindi or Chinese sentence wants an ASCII period is a
    /// visible error, and this rule has no language signal to do better with —
    /// leaving the sentence as dictated is the recoverable answer.
    static func ensureTerminalPeriod(_ text: String) -> String {
        // Structural voice commands may leave one or more trailing newlines.
        // Punctuate the final content before them, then put the exact line
        // ending back instead of producing `content\n.`.
        let (content, lineEnding) = splitTrailingLineEndings(text)
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return text }
        guard !TextPlaceholder.isPlaceholder(last) else { return text }
        guard !terminalPunctuation.contains(last), !closingMarks.contains(last) else {
            return trimmed + lineEnding
        }
        guard usesFullStop(trimmed) else { return text }
        return trimmed + "." + lineEnding
    }

    /// Split trailing CR/LF off the content, so a rule can rewrite the content
    /// and put the exact line ending back.
    private static func splitTrailingLineEndings(_ text: String) -> (content: String, lineEnding: String) {
        // `isNewline`, not a comparison against "\n" and "\r": Swift treats
        // CRLF as one Character, so testing the two separately reads a "\r\n"
        // ending as ordinary content and leaves the rule with nothing to do.
        let contentEnd = text.lastIndex(where: { !$0.isNewline })
            .map { text.index(after: $0) }
            ?? text.startIndex
        return (String(text[..<contentEnd]), String(text[contentEnd...]))
    }

    /// Whether this text is written in a script that ends sentences with `.`.
    ///
    /// Decided from the last letter, which is the one the mark would follow.
    /// True for Latin, Greek and Cyrillic; false for Devanagari, Arabic, CJK
    /// and everything else, which either use their own mark or none.
    private static func usesFullStop(_ text: String) -> Bool {
        guard let lastLetter = text.last(where: { $0.isLetter || $0.isNumber }) else {
            // Digits and symbols only — "." is as good an answer as any.
            return true
        }
        guard let scalar = lastLetter.unicodeScalars.first else { return true }
        let value = scalar.value
        // Everything below Armenian is Latin, Greek or Cyrillic, plus the
        // Latin extended blocks that carry accented and Vietnamese letters.
        return value < 0x0530
            || (0x1E00...0x1EFF).contains(value)
            || (0x2C60...0x2C7F).contains(value)
            || (0xA720...0xA7FF).contains(value)
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
