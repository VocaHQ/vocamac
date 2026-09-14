// SpokenEmoji.swift
// VocaMac
//
// Turns "<descriptor> emoji" into the glyph. Ported from the VocaPhone
// clients, which are expected to produce the same text for the same
// transcript; the phrase table is the same generated `suggestions.tsv`.

import Foundation

/// Turns a dictated descriptor followed by the word "emoji" into the glyph:
/// "I'm so sad, crying emoji crying emoji" becomes "I'm so sad, 😭 😭".
///
/// Conservative, for the same reason `SpokenNumbers` is — the obvious
/// implementation produces text nobody would send:
///
/// * A trigger with no recognized descriptor in front of it is left exactly as
///   spoken. "Send me the emoji" survives untouched; this never guesses.
/// * Only a space or a hyphen joins a descriptor to its trigger. "I'm sad,
///   crying emoji" converts "crying"; "I'm sad, emoji" converts nothing,
///   because a comma ends the phrase rather than being read through.
/// * The whole descriptor or nothing. A proper suffix of what was said is
///   not enough: "smiling face with heart eyes emoji" must not become
///   "smiling face with 😍". Either the contiguous span before the trigger
///   is an exact table key (after the same with/and/of dropping the catalog
///   generator uses), or the words stay as spoken.
///
/// The descriptors are English (`suggestions.tsv` is generated from the
/// English CLDR annotations), but the sentence around them need not be.
enum SpokenEmoji {
    /// The words that trigger a lookup. "emojis" is here because people
    /// pluralize it; "emoji" is not itself a key in the table, so a trigger can
    /// never match itself.
    static let triggerWords: Set<String> = ["emoji", "emojis"]

    /// Words the catalog generator drops when it concatenates a multi-word
    /// Unicode or CLDR name into a key. Mirrored here so a spoken form that
    /// still contains them ("smiling face with heart eyes") hits the same key
    /// (`smilingfacehearteyes`) the table actually stores.
    private static let nameStop: Set<String> = [
        "with", "and", "of", "the", "a", "in", "on", "at", "to", "for", "or",
    ]

    /// Keys the table keeps but this stage must not write.
    ///
    /// `korea` in suggestions.tsv is 🇰🇵 (DPRK). Someone saying "korea emoji"
    /// almost never means that flag. `southkorea` and `northkorea` still
    /// convert.
    private static let spokenBlocklist: Set<String> = ["korea"]

    /// Replaces every `<descriptor> emoji` span with its glyph.
    ///
    /// The span replaced covers the descriptor and the trigger word and nothing
    /// else, so the punctuation and spacing around it stay where they were.
    ///
    /// - Parameters:
    ///   - language: The engine's language code, or "auto" to judge the text.
    ///     Only decides which mark counts as a sentence terminator.
    ///   - insert: What to write for each glyph. `DictationOutputPipeline`
    ///     passes a closure that masks the glyph, so neither formatting nor
    ///     the cleanup model can touch it.
    static func glyphs(
        in text: String,
        language: String = "auto",
        insert: (String) -> String = { $0 }
    ) -> String {
        // Almost every transcript has no trigger in it at all, so the "nothing
        // to do" case is the one worth being cheap. "emoji" contains a "j", so
        // text with no "j" in it cannot contain the trigger. `| 0x20` folds the
        // ASCII case, and no UTF-8 continuation byte is below 0x80, so a
        // multi-byte character cannot collide with it.
        guard !text.isEmpty,
              text.utf8.contains(where: { $0 | 0x20 == 0x6A }),
              let wordPattern,
              !EmojiTable.triggers.isEmpty
        else { return text }

        // Masked so a descriptor cannot be eaten out of an address:
        // "crying emoji.com" is a hostname, not a trigger.
        let spans = ProtectedSpans.mask(text)
        let string = spans.text as NSString
        let words = wordPattern.matches(
            in: spans.text,
            range: NSRange(location: 0, length: string.length)
        )
        guard !words.isEmpty else { return text }

        var result = ""
        var copied = 0
        var previousWasGlyph = false
        for index in words.indices {
            guard triggerWords.contains(string.substring(with: words[index].range).lowercased())
            else { continue }
            guard let match = descriptor(before: index, in: words, text: string),
                  match.start.location >= copied
            else { continue }
            let between = string.substring(with: NSRange(
                location: copied, length: match.start.location - copied
            ))
            result += previousWasGlyph ? separating(between) : between
            result += insert(match.glyph)
            copied = words[index].range.upperBound
            previousWasGlyph = true
        }
        guard copied > 0 else { return text }
        result += closing(string.substring(from: copied), language: language, source: text)
        return spans.restore(result)
    }

    /// The text after the final glyph, with a sentence terminator that is all
    /// it consists of dropped.
    ///
    /// An emoji *is* the end: people write "I'm so sad 😭" and "💯", not
    /// "I'm so sad 😭." Only the full stop goes, never "!" or "?", which carry
    /// meaning that was in what the user said. And only when the terminator is
    /// the *whole* tail: "crying emoji is how I feel." keeps its full stop.
    private static func closing(_ tail: String, language: String, source: String) -> String {
        let terminator = sentenceTerminator(language: language, text: source)
        // Thai and Lao end a sentence with nothing at all, so there is no mark
        // to drop and an empty terminator would match every tail.
        guard !terminator.isEmpty,
              tail.trimmingCharacters(in: .whitespacesAndNewlines) == terminator
        else { return tail }
        return ""
    }

    /// What to put between two glyphs this stage produced, given the text that
    /// was between their phrases.
    ///
    /// A speech model writes a pause down as a comma: "crying emoji, crying
    /// emoji" substituted in place leaves "😭, 😭". Nobody punctuates a run of
    /// emoji, so when nothing but marks and space separates two of them, that
    /// collapses to a single space. Deliberately narrow: "fire emoji, then
    /// home" keeps its comma.
    private static func separating(_ between: String) -> String {
        guard !between.isEmpty,
              between.allSatisfy({ $0.isWhitespace || universalMarks.contains($0) })
        else { return between }
        return " "
    }

    /// The contiguous joiner-connected words immediately before the trigger,
    /// converted only when that whole span is an exact table key.
    ///
    /// Walks backwards while a space or hyphen joins, stopping at another
    /// trigger word so "crying emoji fire emoji" still finds each descriptor
    /// on its own. No suffix fallback. The span is looked up both raw and with
    /// the generator's name-stop words removed; leading stops stay in the
    /// transcript ("and fire emoji" keeps "and").
    private static func descriptor(
        before trigger: Int,
        in words: [NSTextCheckingResult],
        text: NSString
    ) -> (glyph: String, start: NSRange)? {
        var parts: [(word: String, range: NSRange)] = []
        var fullLength = 0
        var index = trigger - 1
        while index >= 0, isJoiner(gapAfter: index, in: words, text: text) {
            let raw = text.substring(with: words[index].range).lowercased()
            if triggerWords.contains(raw) { break }
            if fullLength + raw.count > EmojiTable.widestKeyLength { break }
            parts.insert((raw, words[index].range), at: 0)
            fullLength += raw.count
            index -= 1
        }
        guard !parts.isEmpty else { return nil }

        let fullKey = parts.map(\.word).joined()
        if let glyph = glyphForSpoken(fullKey) {
            return (glyph, parts[0].range)
        }

        let significant = parts.filter { !nameStop.contains($0.word) }
        guard !significant.isEmpty else { return nil }
        let strippedKey = significant.map(\.word).joined()
        guard strippedKey != fullKey else { return nil }
        guard let glyph = glyphForSpoken(strippedKey) else { return nil }
        return (glyph, significant[0].range)
    }

    private static func glyphForSpoken(_ key: String) -> String? {
        if spokenBlocklist.contains(key) { return nil }
        return EmojiTable.glyph(forKey: key)
    }

    /// Whether the gap between this word and the next one is nothing but a
    /// space or a hyphen. Any punctuation — or a masked span — in between ends
    /// the phrase.
    private static func isJoiner(
        gapAfter index: Int,
        in words: [NSTextCheckingResult],
        text: NSString
    ) -> Bool {
        let gap = text.substring(with: NSRange(
            location: words[index].range.upperBound,
            length: words[index + 1].range.location - words[index].range.upperBound
        ))
        return gap == " " || gap == "-" || gap == "‑"
    }

    /// Letters and digits: "100 emoji" is 💯, and a speech model writes
    /// someone saying "hundred" as "100" about as often as it writes the word.
    ///
    /// The lookbehind stops a masked span's own index being read as a word;
    /// see `ProtectedSpans`.
    private static let wordPattern = try? NSRegularExpression(
        pattern: "(?<!\(ProtectedSpans.open))[A-Za-z0-9]+(?:['’][A-Za-z0-9]+)*"
    )

    // MARK: - Sentence punctuation

    /// Marks that end or separate a sentence, in any script a transcript can
    /// arrive in.
    static let universalMarks = ".!?。！？।۔။។།؟" + ",;:،、၊" + "…"

    /// The full stop a script closes a sentence with, falling back to what the
    /// text itself is written in when the engine reported no language.
    static func sentenceTerminator(language: String, text: String) -> String {
        let code = language.lowercased().split(separator: "-").first.map(String.init) ?? ""
        switch code {
        case "ja", "zh", "yue": return "。"
        case "ur", "sd", "ks": return "۔"
        case "hi", "mr", "ne", "bn", "as", "pa": return "।"
        case "th", "lo": return ""
        case "my": return "။"
        case "km": return "។"
        case "bo": return "།"
        case "ar", "fa", "ps", "ta", "te", "kn", "ml", "gu", "si": return "."
        default:
            if text.contains(where: { "。、！？".contains($0) }) { return "。" }
            if text.contains(where: { "،؟".contains($0) }) { return "." }
            if text.contains("۔") { return "۔" }
            if text.contains("।") || containsDandaScript(text) { return "।" }
            return "."
        }
    }

    /// Devanagari, Bengali/Assamese, and Gurmukhi conventionally use the danda.
    private static func containsDandaScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0900...0x097F, 0x0980...0x09FF, 0x0A00...0x0A7F: true
            default: false
            }
        }
    }

    // MARK: - Protected spans

    /// URLs, email addresses, bare domains, decimals and times, ordinals, and
    /// dotted initialisms, masked so no descriptor is taken out of one.
    ///
    /// The placeholders sit at the top of the Private Use Area, away from the
    /// snippet lane `DictationOutputPipeline` has already masked the text
    /// with, and they are always restored before `glyphs(in:)` returns.
    private struct ProtectedSpans {
        static let open: Character = "\u{F8FE}"
        static let close: Character = "\u{F8FF}"

        let text: String
        let tokens: [String]

        /// A bare hostname, recognized by the case of its last label: a
        /// top-level domain is written in lowercase (or all caps), while a full
        /// stop that ended a sentence is followed by a capital — `report.Then`
        /// stays out.
        private static let hostname = "\\b(?:[\\w-]+\\.)+(?:[a-z]{2,24}|[A-Z]{2,24})\\b"

        /// A path may contain dots; it may not end on the full stop that ends
        /// the sentence the address is sitting in.
        private static let path = "(?:/[^\\s]*[^\\s.,;:!?\\\"“”'\\)\\]])?"

        private static let expression = try? NSRegularExpression(
            pattern: "((?i:https?)://[^\\s]+[^\\s.,;:!?\\\"“”'\\)\\]]"
                + "|[\\w.+-]+@(?:[\\w-]+\\.)+[A-Za-z]{2,}"
                + "|" + hostname + path
                + "|\\d+(?:[.,:/]\\d+)+"
                + "|\\d+(?i:st|nd|rd|th)\\b"
                + "|(?:[A-Za-z]\\.){2,})"
        )
        private static let placeholder = try? NSRegularExpression(
            pattern: "\(open)(\\d+)\(close)"
        )

        static func mask(_ text: String) -> ProtectedSpans {
            guard let expression else { return ProtectedSpans(text: text, tokens: []) }
            let string = text as NSString
            let matches = expression.matches(
                in: text, range: NSRange(location: 0, length: string.length)
            )
            let result = NSMutableString(string: text)
            for index in matches.indices.reversed() {
                result.replaceCharacters(
                    in: matches[index].range,
                    with: "\(open)\(index)\(close)"
                )
            }
            return ProtectedSpans(
                text: String(result),
                tokens: matches.map { string.substring(with: $0.range) }
            )
        }

        /// Puts the original spans back into text rewritten around them.
        func restore(_ masked: String) -> String {
            guard let placeholder = Self.placeholder, !tokens.isEmpty else { return masked }
            let string = masked as NSString
            let matches = placeholder.matches(
                in: masked, range: NSRange(location: 0, length: string.length)
            )
            let result = NSMutableString(string: masked)
            for match in matches.reversed() {
                let index = Int(string.substring(with: match.range(at: 1))) ?? -1
                guard tokens.indices.contains(index) else { continue }
                result.replaceCharacters(in: match.range, with: tokens[index])
            }
            return String(result)
        }
    }
}

// MARK: - Emoji table

/// The word-to-glyph table in `Resources/Emoji/suggestions.tsv`.
///
/// Copied verbatim from VocaPhone's `assets/keyboard/emoji/suggestions.tsv`,
/// generated there from Unicode names, CLDR spoken names, and curated spoken
/// forms. Keys are lower-cased with the spaces removed: "thumbs up" is
/// `thumbsup`. Update it by copying the file again, never by hand, so the
/// clients keep answering the same phrase with the same glyph.
enum EmojiTable {
    /// The shortest key worth matching. Two letters are mostly initials,
    /// particles and typos.
    static let minimumLength = 2

    /// Word → glyph, loaded once on first use.
    static let triggers: [String: String] = load()

    /// The longest key in the table, in characters: the lookback bound for a
    /// descriptor, read off the data rather than guessed as a word count.
    static let widestKeyLength: Int = triggers.keys.reduce(0) { max($0, $1.count) }

    static func glyph(forKey key: String) -> String? {
        guard key.count >= minimumLength else { return nil }
        return triggers[key]
    }

    static func parse(_ text: String) -> [String: String] {
        var table: [String: String] = [:]
        table.reserveCapacity(4_000)
        for line in text.split(whereSeparator: \.isNewline) {
            if line.isEmpty || line.first == "#" { continue }
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let word = parts[0].lowercased()
            let glyph = String(parts[1])
            guard !word.isEmpty, !glyph.isEmpty, table[word] == nil else { continue }
            table[word] = glyph
        }
        return table
    }

    private static func load() -> [String: String] {
        let bundle = Bundle.module
        let url = bundle.url(forResource: "suggestions", withExtension: "tsv", subdirectory: "Resources/Emoji")
            ?? bundle.url(forResource: "suggestions", withExtension: "tsv", subdirectory: "Emoji")
            ?? bundle.url(forResource: "suggestions", withExtension: "tsv")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parse(text)
    }
}
