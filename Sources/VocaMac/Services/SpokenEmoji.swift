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
/// * The longest descriptor wins, and prose before it stays prose: "so sad
///   crying emoji" becomes "so sad 😭", because speech models rarely put a
///   comma where the speaker paused. A shorter match never splits a longer
///   name, though: "smiling face with heart eyes emoji" must not become
///   "smiling face with 😍", so a match right after a word that belongs to
///   emoji names ("with", "blue", "face") leaves every word as spoken.
/// * Talking *about* an emoji is not asking for one. "send a fire emoji" and
///   "I love the heart emoji" keep their words: a determiner right before the
///   descriptor means the emoji is the subject of the sentence.
/// * "three fire emojis" and "fire emoji times three" repeat the glyph;
///   "thumbs up dark skin tone emoji" applies the skin tone.
///
/// The descriptors are English (`suggestions.tsv` is generated from the
/// English CLDR annotations), but the sentence around them need not be.
enum SpokenEmoji {
    /// The words that trigger a lookup. "emojis" is here because people
    /// pluralize it; "emoji" is not itself a key in the table, so a trigger can
    /// never match itself.
    static let triggerWords: Set<String> = ["emoji", "emojis", "emoticon", "emoticons"]

    /// Triggers that ask for more than one glyph when a count comes first:
    /// "three fire emojis".
    private static let pluralTriggers: Set<String> = ["emojis", "emoticons"]

    /// The most copies a spoken count may produce. "a hundred fire emojis" is
    /// a figure of speech, not a request.
    static let maximumRepeat = 10

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

    /// Words that, right before a descriptor, mean it is not a request for a
    /// glyph: "send a fire emoji", "what's the crying emoji".
    private static let referenceWords: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "my", "your", "his",
        "her", "its", "our", "their", "any", "some", "which", "what", "what's",
        "whats", "no", "every", "each", "favorite", "favourite", "same",
        // A subject makes the descriptor a verb phrase: "I love you emoji" is
        // not "I 🤟". "you" and "it" are left out, as objects end a phrase
        // before an emoji all the time: "love you heart emoji".
        "i", "we", "they", "he", "she",
    ]

    /// Words that are part of emoji names, so a match right after one is
    /// likely the tail of a longer name the table does not have: "blue
    /// heart" is not "blue ❤️", and "face with heart eyes" is not "face with
    /// 😍".
    private static let nameWords: Set<String> = [
        "with", "of", "face", "faces", "hand", "hands", "man", "woman", "men", "women",
        "person", "people", "boy", "girl", "baby", "old", "skin", "tone",
        "red", "orange", "yellow", "green", "blue", "purple", "brown", "black",
        "white", "pink", "grey", "gray", "light", "dark", "medium", "broken",
    ]

    /// Spoken counts: "three fire emojis", "fire emoji times three".
    private static let countWords: [String: Int] = [
        "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10,
    ]

    /// Quantities that are not a count this repeats: "a hundred fire emojis"
    /// is a figure of speech.
    private static let quantityWords: Set<String> = [
        "one", "eleven", "twelve", "twenty", "thirty", "forty", "fifty", "sixty",
        "seventy", "eighty", "ninety", "hundred", "hundreds", "thousand", "thousands",
        "million", "millions", "dozen", "dozens", "many", "few", "several",
    ]

    /// Fitzpatrick modifiers, by the words CLDR names them with.
    private static let skinTones: [([String], String)] = [
        (["medium", "light"], "\u{1F3FC}"), (["medium", "dark"], "\u{1F3FE}"),
        (["light"], "\u{1F3FB}"), (["medium"], "\u{1F3FD}"), (["dark"], "\u{1F3FF}"),
    ]

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
        // text with no "j" in it cannot contain that trigger. `| 0x20` folds
        // the ASCII case, and no UTF-8 continuation byte is below 0x80, so a
        // multi-byte character cannot collide with it. "emoticon" has no "j"
        // and is checked on its own.
        guard !text.isEmpty,
              text.utf8.contains(where: { $0 | 0x20 == 0x6A })
                || text.range(of: "emoticon", options: .caseInsensitive) != nil,
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
            let trigger = string.substring(with: words[index].range).lowercased()
            guard triggerWords.contains(trigger) else { continue }
            let repeatAfter = count(after: index, in: words, text: string)
            let lastWord = repeatAfter?.lastWord ?? index
            guard var match = descriptor(
                before: index, in: words, text: string,
                plural: pluralTriggers.contains(trigger),
                endsClause: endsClause(after: lastWord, in: words, text: string)
            ), match.start.location >= copied
            else { continue }
            var end = words[index].range.upperBound
            if match.count == 1, let repeatAfter {
                match.count = repeatAfter.count
                end = words[repeatAfter.lastWord].range.upperBound
            }
            let between = string.substring(with: NSRange(
                location: copied, length: match.start.location - copied
            ))
            result += previousWasGlyph ? separating(between) : between
            result += insert(String(repeating: match.glyph, count: match.count))
            copied = end
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

    /// A descriptor found before a trigger: the glyph, where its words start,
    /// and how many copies were asked for.
    private struct Descriptor {
        var glyph: String
        var start: NSRange
        var count = 1
    }

    /// The longest table key that ends right before the trigger.
    ///
    /// Walks backwards while a space or hyphen joins, stopping at another
    /// trigger word so "crying emoji fire emoji" still finds each descriptor
    /// on its own. Each tail of that span is looked up longest first, both raw
    /// and with the generator's name-stop words removed; leading stops stay in
    /// the transcript ("and fire emoji" keeps "and").
    ///
    /// The word right before the longest match decides what happens to it:
    /// a skin tone applies, a count repeats the glyph (plural trigger only), a
    /// determiner or a word from emoji names leaves everything as spoken, and
    /// anything else is prose that stays put — but only when the trigger ends
    /// the clause. "can you check emoji support" uses "emoji" as a noun, and
    /// must not become "can you ✅ support".
    private static func descriptor(
        before trigger: Int,
        in words: [NSTextCheckingResult],
        text: NSString,
        plural: Bool,
        endsClause: Bool
    ) -> Descriptor? {
        var parts: [(word: String, range: NSRange)] = []
        var fullLength = 0
        var index = trigger - 1
        while index >= 0, isJoiner(gapAfter: index, in: words, text: text) {
            let raw = text.substring(with: words[index].range).lowercased()
            if triggerWords.contains(raw) { break }
            // The lookback is bounded by the widest key plus the words a skin
            // tone and a count can add in front of it.
            if fullLength + raw.count > EmojiTable.widestKeyLength + 24 { break }
            parts.insert((raw, words[index].range), at: 0)
            fullLength += raw.count
            index -= 1
        }
        guard !parts.isEmpty else { return nil }

        // "thumbs up dark skin tone emoji": the tone after the name.
        var trailingTone: String?
        if let tone = skinTone(endingAt: parts.count, in: parts.map(\.word)) {
            trailingTone = tone.modifier
            parts.removeLast(tone.length)
            guard !parts.isEmpty else { return nil }
        }

        for start in parts.indices {
            let tail = Array(parts[start...])
            let lookup: (glyph: String, first: Int)?
            if let glyph = glyphForSpoken(tail.map(\.word).joined()) {
                lookup = (glyph, start)
            } else if let first = tail.firstIndex(where: { !nameStop.contains($0.word) }),
                      let glyph = glyphForSpoken(tail.filter { !nameStop.contains($0.word) }.map(\.word).joined()),
                      tail.contains(where: { nameStop.contains($0.word) }) {
                lookup = (glyph, start + first)
            } else {
                lookup = nil
            }
            guard let (glyph, first) = lookup else { continue }

            var result = Descriptor(glyph: glyph, start: parts[first].range)
            var before = first
            // "dark skin tone thumbs up emoji": the tone before the name.
            var tone = trailingTone
            if tone == nil, let leading = skinTone(endingAt: before, in: parts.map(\.word)) {
                tone = leading.modifier
                before -= leading.length
                result.start = parts[before].range
            }
            if let tone {
                guard let toned = applying(tone, to: glyph) else { return nil }
                result.glyph = toned
            }
            // "fire fire fire emoji": the name said again is a count.
            let name = parts[first...].map(\.word)
            var repeats = 1
            while before >= name.count, repeats < maximumRepeat,
                  Array(parts[(before - name.count)..<before].map(\.word)) == name {
                before -= name.count
                repeats += 1
            }
            if repeats > 1 {
                result.count = repeats
                result.start = parts[before].range
            }
            // Only name-stop words before it ("and fire emoji"): the whole
            // span is the descriptor.
            guard parts[..<before].contains(where: { !nameStop.contains($0.word) }) else { return result }

            let previous = parts[before - 1].word
            if plural, let count = countWords[previous] ?? Int(previous), (2...maximumRepeat).contains(count) {
                result.count = count
                result.start = parts[before - 1].range
                return result
            }
            // "3 crying emoji" and "a fire emoji" are about the emoji.
            if Int(previous) != nil || countWords[previous] != nil || quantityWords.contains(previous)
                || referenceWords.contains(previous) || nameWords.contains(previous) {
                return nil
            }
            return endsClause ? result : nil
        }
        return nil
    }

    /// A skin tone ("medium dark skin tone") whose last word is just before
    /// `end` in `words`.
    private static func skinTone(endingAt end: Int, in words: [String]) -> (modifier: String, length: Int)? {
        guard end >= 3, words[end - 1] == "tone", words[end - 2] == "skin" else { return nil }
        for (name, modifier) in skinTones where end - 2 >= name.count {
            if Array(words[(end - 2 - name.count)..<(end - 2)]) == name {
                return (modifier, name.count + 2)
            }
        }
        return nil
    }

    /// `glyph` with a skin tone, or nil when it cannot take one: "fire dark
    /// skin tone emoji" is not a request anyone means.
    private static func applying(_ tone: String, to glyph: String) -> String? {
        var scalars = Array(glyph.unicodeScalars)
        guard let base = scalars.first, base.properties.isEmojiModifierBase else { return nil }
        // The tone replaces the presentation selector: "✌️" + tone is "✌🏿".
        if scalars.count > 1, scalars[1] == "\u{FE0F}" { scalars.remove(at: 1) }
        scalars.insert(contentsOf: tone.unicodeScalars, at: 1)
        var toned = ""
        toned.unicodeScalars.append(contentsOf: scalars)
        return toned
    }

    /// Whether the phrase ending at word `index` ends its clause: the text
    /// ends, punctuation or a line break follows, or the next few words lead
    /// straight into another trigger ("so sad crying emoji fire emoji").
    private static func endsClause(
        after index: Int,
        in words: [NSTextCheckingResult],
        text: NSString
    ) -> Bool {
        var word = index
        while word + 1 < words.count {
            // Punctuation right after the phrase ends the clause; further on,
            // it only ends the words that followed it.
            guard isJoiner(gapAfter: word, in: words, text: text) else { return word == index }
            word += 1
            if triggerWords.contains(text.substring(with: words[word].range).lowercased()) { return true }
            if word - index > 6 { return false }
        }
        return word == index
    }

    /// A count after the trigger: "fire emoji times three", "fire emoji x3".
    private static func count(
        after trigger: Int,
        in words: [NSTextCheckingResult],
        text: NSString
    ) -> (count: Int, lastWord: Int)? {
        guard trigger + 1 < words.count else { return nil }
        let gap = text.substring(with: NSRange(
            location: words[trigger].range.upperBound,
            length: words[trigger + 1].range.location - words[trigger].range.upperBound
        ))
        guard gap == " " else { return nil }
        let next = text.substring(with: words[trigger + 1].range).lowercased()
        var count: Int?
        var lastWord = trigger + 1
        if next.hasPrefix("x"), let value = Int(next.dropFirst()) {
            count = value
        } else if next == "times" || next == "x", trigger + 2 < words.count,
                  isJoiner(gapAfter: trigger + 1, in: words, text: text) {
            let word = text.substring(with: words[trigger + 2].range).lowercased()
            count = countWords[word] ?? Int(word)
            lastWord = trigger + 2
        }
        guard let count, (2...maximumRepeat).contains(count) else { return nil }
        return (count, lastWord)
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
    /// A trailing "%" stays on its number, so "100% emoji" is 💯 too.
    ///
    /// The lookbehind stops a masked span's own index being read as a word;
    /// see `ProtectedSpans`.
    private static let wordPattern = try? NSRegularExpression(
        pattern: "(?<!\(ProtectedSpans.open))[A-Za-z0-9]+(?:['’][A-Za-z0-9]+)*%?"
    )

    // MARK: - Sentence punctuation

    /// Marks that end or separate a sentence, in any script a transcript can
    /// arrive in.
    static let universalMarks = ".!?。！？।۔။។།؟" + ",;:،、၊" + "…"

    /// The full stop a script closes a sentence with, falling back to what the
    /// text itself is written in when the engine reported no language.
    static func sentenceTerminator(language: String, text: String) -> String {
        // Romanized text ("hi-Latn", from Voca Hinglish) ends sentences the
        // Latin way, whatever its language.
        if DictationOutputPipeline.isRomanized(language) { return "." }
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
///
/// `Resources/Emoji/spoken-aliases.tsv` is laid over it: the way people
/// actually say an emoji when CLDR names it differently ("fingers crossed",
/// "blue heart", "US flag"), and the few glyphs the generated table gets
/// wrong for speech ("salute" is 🫡, not 🖖). An alias replaces a table
/// entry with the same key. Mirror it in VocaPhone with the table.
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

    /// Parses a table file. The first entry for a key wins, as the generator
    /// orders entries by preference.
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

    /// The generated table with the spoken aliases laid over it.
    static func merged(table: [String: String], aliases: [String: String]) -> [String: String] {
        table.merging(aliases) { _, alias in alias }
    }

    /// The spoken aliases on their own, for tests.
    static let aliases: [String: String] = resource("spoken-aliases").map(parse) ?? [:]

    private static func load() -> [String: String] {
        guard let text = resource("suggestions") else { return [:] }
        return merged(table: parse(text), aliases: aliases)
    }

    private static func resource(_ name: String) -> String? {
        let bundle = Bundle.module
        let url = bundle.url(forResource: name, withExtension: "tsv", subdirectory: "Resources/Emoji")
            ?? bundle.url(forResource: name, withExtension: "tsv", subdirectory: "Emoji")
            ?? bundle.url(forResource: name, withExtension: "tsv")
        guard let url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
