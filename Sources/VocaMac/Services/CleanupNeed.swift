// CleanupNeed.swift
// VocaMac
//
// Decides whether a transcript has anything left in it for the cleanup model.

import Foundation

/// Whether the cleanup model would have anything to do.
///
/// The speech engines punctuate and capitalise on their own, and the rule
/// stages already take out "um", stutters, and spoken corrections. What is
/// left for the model is filler that needs judgement, false starts, dictated
/// punctuation, and sentences the engine ran together. Most dictations have
/// none of those, and running the model on them only delays the paste: in
/// one user's history, seven in ten model passes changed nothing.
///
/// The checks are deliberately one-sided. Anything that might be work for the
/// model — the word "like", a number spelled out, a long sentence — sends the
/// text to the model as before. Only English is judged; other languages are
/// always sent, because these word lists say nothing about them.
enum CleanupNeed {
    /// Why the model should still see `text`, or nil when it has nothing to do.
    ///
    /// - Parameters:
    ///   - text: The transcript after the rule stages. Snippet and emoji
    ///     placeholders (private-use scalars) are treated as ordinary words.
    ///   - technical: Code and Terminal text, where the model only points at
    ///     filler and punctuation is left alone.
    static func reason(
        for text: String,
        level: CleanupLevel,
        technical: Bool,
        isEnglish: Bool
    ) -> String? {
        guard isEnglish else { return "not English" }
        // Grammar repairs can't be predicted from the surface of the text.
        guard level != .grammar else { return "grammar level" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let words = Self.words(trimmed)
        guard !words.isEmpty else { return nil }

        if level != .light {
            if let filler = firstFiller(in: words) { return "possible filler (\(filler))" }
            if let opener = firstOpener(in: trimmed) { return "possible filler (\(opener))" }
            if hasRepeat(words) { return "repeated words" }
            if words.contains(where: { $0.count == 1 && $0 != "a" && $0 != "i" && $0.allSatisfy(\.isLetter) }) {
                return "stray letter"
            }
            if trimmed.contains("--") || matches(#"\p{L}-(?:\s|$)"#, trimmed) { return "cut-off word" }
        }
        if level == .high, let cue = firstMatch(correctionCues, in: words) {
            return "possible correction (\(cue))"
        }
        // Code and Terminal answers are only mined for filler.
        guard !technical else { return nil }

        if let mark = firstMatch(dictatedMarks, in: words) { return "dictated punctuation (\(mark))" }
        if hasSpelledNumber(words) { return "number spelled out" }
        if matches(#"(?:^|\s)\p{L}(?:\s+\p{L}){2,}(?:\s|$)"#, trimmed) { return "spelled-out letters" }
        if matches(#"(?:^|[\s(])i(?:[\s,.!?']|$)"#, trimmed) { return "lowercase “i”" }
        return punctuationProblem(trimmed)
    }

    // MARK: - Words

    /// Lowercased words, apostrophes kept so "don't" stays one word.
    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
    }

    /// Words and phrases that are filler often enough for the model to judge.
    /// "like" and "actually" are ordinary words most of the time; the model
    /// decides, so their presence only means it should be asked.
    private static let fillers: [[String]] = [
        ["like"], ["basically"], ["literally"], ["actually"], ["honestly"], ["obviously"],
        ["kinda"], ["sorta"], ["er"], ["erm"], ["hmm"], ["ah"], ["eh"], ["uhm"], ["mm"], ["mhm"],
        ["you", "know"], ["i", "mean"], ["you", "see"], ["sort", "of"], ["kind", "of"],
        ["or", "something"], ["and", "stuff"],
    ]

    /// Sentence openers that are usually a run-up rather than content.
    private static let openers: Set<String> = ["so", "well", "okay", "ok", "right", "yeah", "anyway", "alright"]

    private static let correctionCues: [[String]] = [
        ["no", "wait"], ["i", "mean"], ["sorry"], ["rather"], ["scratch", "that"],
        ["never", "mind"], ["start", "over"], ["no"], ["wait"], ["actually"], ["instead"],
    ]

    private static let dictatedMarks: [[String]] = [
        ["comma"], ["period"], ["full", "stop"], ["question", "mark"], ["exclamation"],
        ["semicolon"], ["colon"], ["new", "line"], ["new", "paragraph"], ["newline"],
        ["quote"], ["unquote"], ["dash"], ["hyphen"], ["ellipsis"], ["parenthesis"], ["bracket"],
    ]

    /// "one" is left out: it is a pronoun far more often than a quantity.
    private static let numberWords: Set<String> = [
        "zero", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
        "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "thousand", "million", "billion", "percent", "dollars", "o'clock",
    ]

    private static func firstMatch(_ phrases: [[String]], in words: [String]) -> String? {
        for phrase in phrases {
            guard phrase.count <= words.count else { continue }
            for start in 0...(words.count - phrase.count)
            where Array(words[start..<start + phrase.count]) == phrase {
                return phrase.joined(separator: " ")
            }
        }
        return nil
    }

    private static func firstFiller(in words: [String]) -> String? {
        firstMatch(fillers, in: words)
    }

    /// A run-up word at the start of any sentence ("So, …", "Okay.").
    private static func firstOpener(in text: String) -> String? {
        for sentence in CleanupContext.sentences(text) {
            if let first = words(sentence).first, openers.contains(first) { return first }
        }
        return nil
    }

    /// A word or pair of words said twice in a row, or a clipped start
    /// ("sn scan"): stutters and false starts the rules did not settle.
    private static func hasRepeat(_ words: [String]) -> Bool {
        for index in words.indices.dropFirst() {
            let previous = words[index - 1], word = words[index]
            if previous == word { return true }
            // A clipped start is not always a prefix of its word ("sn scan"),
            // but it is short, not a word, and begins the same way.
            if previous.count <= 3, word.count > previous.count, previous.first == word.first,
               previous.allSatisfy(\.isLetter), !shortWords.contains(previous) {
                return true
            }
            // "web website": a real word, but one the next word goes well past.
            if EditMerge.isClippedWord(previous, of: word) { return true }
        }
        guard words.count >= 4 else { return false }
        for index in 2..<(words.count - 1)
        where words[index] == words[index - 2] && words[index + 1] == words[index - 1] {
            return true
        }
        return false
    }

    /// Real words short enough to look like a clipped start of the next one
    /// ("in inside", "to today", "we went").
    private static let shortWords: Set<String> = [
        "a", "i", "an", "as", "at", "be", "by", "do", "go", "he", "if", "in", "is", "it", "me", "my",
        "no", "of", "on", "or", "so", "to", "up", "us", "we", "the", "and", "for", "but", "not", "you",
        "all", "can", "her", "was", "one", "our", "out", "has", "him", "his", "how", "its", "may",
        "new", "now", "old", "see", "two", "who", "did", "get", "let", "put", "say", "she", "too", "use",
        "any", "are", "per", "pro", "sub", "pre", "non", "re", "un", "off", "add", "end", "men", "ten",
    ]

    private static func hasSpelledNumber(_ words: [String]) -> Bool {
        words.contains { numberWords.contains($0) }
    }

    // MARK: - Punctuation

    /// Longest sentence taken as one the engine punctuated. Longer than this
    /// and it is as likely several sentences run together.
    static let longestSentenceWords = 32

    /// What an engine that did not punctuate leaves behind: no full stop at
    /// the end, a sentence that starts in lower case, or one that runs on.
    private static func punctuationProblem(_ text: String) -> String? {
        var closers = CharacterSet(charactersIn: "\"'”’)]»")
        closers.formUnion(.whitespacesAndNewlines)
        let end = text.unicodeScalars.reversed().first { !closers.contains($0) }
        guard let end else { return nil }
        let endsSentence = ".!?…:".unicodeScalars.contains(end) || isPlaceholder(end)
        guard endsSentence else { return "no closing punctuation" }
        // The sentence splitter reads "passed. then" as one sentence with an
        // abbreviation in it, so look for the lower-case start directly.
        if matches(#"[.!?]\s+\p{Ll}"#, text) { return "sentence starts in lower case" }

        for sentence in CleanupContext.sentences(text) {
            let body = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = body.unicodeScalars.first(where: { CharacterSet.alphanumerics.contains($0) || isPlaceholder($0) }) else {
                continue
            }
            if CharacterSet.lowercaseLetters.contains(first) { return "sentence starts in lower case" }
            if words(body).count > longestSentenceWords { return "long sentence" }
        }
        return nil
    }

    private static func isPlaceholder(_ scalar: Unicode.Scalar) -> Bool {
        (0xE000...0xF8FF).contains(scalar.value)
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        !RewriteValidation.matches(pattern, in: text).isEmpty
    }
}
