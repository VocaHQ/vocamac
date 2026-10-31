// ChangeOfMindResolver.swift
// VocaMac
//
// Keeps what the speaker meant when they change their mind mid-dictation:
// "let's meet tomorrow, sorry, not actually, let's meet yesterday" →
// "let's meet yesterday".

import Foundation
import NaturalLanguage

/// Resolves self-corrections by their shape rather than their content, without
/// a model.
///
/// `SpokenCorrectionResolver` handles a value swapped for another of the same
/// kind ("tomorrow, no, Wednesday"). This handles the rest, and only when the
/// structure of the sentence proves a correction happened:
///
/// - **Restart.** After a cue, the speaker starts the clause again: the words
///   after the cue repeat the words that opened the rejected clause ("let's
///   meet tomorrow, sorry, let's meet yesterday"). The repeated opening is the
///   evidence, so the rest can be anything: a verb, a place, a whole clause.
/// - **Shared frame.** A short phrase is swapped for one built the same way:
///   the same first word ("the blue one, I mean, the red one"), the same last
///   word ("blue shirt, no, red shirt"), or a single name or noun for another
///   ("send it to John, no, Mary").
/// - **Cancellation.** "Scratch that", "strike that" and "let me start over"
///   drop the sentence they end, or the sentence before when they open one.
///
/// Without that evidence nothing changes, whatever words are present: "Sorry,
/// I missed your call", "I was actually thrilled", "I love it, actually, I
/// love all of them too" stay as spoken. A correction never crosses a line
/// break, never follows a question ("tomorrow? No, …" is an answer), and never
/// drops a negation the speaker didn't repeat.
enum ChangeOfMindResolver {

    static func resolve(_ text: String, matchesWordClasses: Bool = true) -> String {
        resolveCounting(text, matchesWordClasses: matchesWordClasses).text
    }

    /// The text with self-corrections resolved, and how many were.
    ///
    /// - Parameter matchesWordClasses: Whether a single word may be swapped for
    ///   another of the same word class ("salad, no, soup"). The tagger is
    ///   reliable in English, so the pipeline passes false for other languages.
    static func resolveCounting(_ text: String, matchesWordClasses: Bool = true) -> (text: String, count: Int) {
        var result = text
        var count = 0
        // Repeatedly: one dictation can correct itself more than once, and
        // every edit shifts what follows.
        for _ in 0..<8 {
            let words = Self.words(in: result)
            guard let edit = cancellation(in: words, text: result)
                ?? revision(in: words, text: result, matchesWordClasses: matchesWordClasses) else { break }
            result = edit.apply(to: result)
            count += 1
        }
        return (result, count)
    }

    // MARK: - Words

    /// A word, and what separates it from the word before.
    struct Word {
        let range: Range<String.Index>
        let text: String
        /// Lowercased, curly apostrophes straightened.
        let key: String
        /// The punctuation and spacing between the previous word and this one.
        var gap: Gap

        var isCapitalized: Bool { text.first?.isUppercase == true }
    }

    struct Gap: OptionSet {
        let rawValue: Int
        /// A comma, semicolon, dash, or ellipsis: a pause.
        static let pause = Gap(rawValue: 1 << 0)
        /// A full stop, exclamation mark, or question mark.
        static let sentenceEnd = Gap(rawValue: 1 << 1)
        static let question = Gap(rawValue: 1 << 2)
        static let lineBreak = Gap(rawValue: 1 << 3)
        /// Quotes, brackets, colons: structure we never cross.
        static let other = Gap(rawValue: 1 << 4)
    }

    static func words(in text: String) -> [Word] {
        var words: [Word] = []
        var gap: Gap = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if isWordCharacter(character) {
                var end = text.index(after: index)
                while end < text.endIndex {
                    let next = text[end]
                    if isWordCharacter(next) {
                        end = text.index(after: end)
                        continue
                    }
                    // "let's", "twenty-five", "3:30", "3.5", "p.m": joined
                    // only when a word character follows.
                    let after = text.index(after: end)
                    if "'’-.:".contains(next), after < text.endIndex, isWordCharacter(text[after]) {
                        end = after
                        continue
                    }
                    break
                }
                let word = String(text[index..<end])
                words.append(Word(range: index..<end, text: word, key: key(word), gap: gap))
                gap = []
                index = end
                continue
            }
            switch character {
            case ",", ";", "—", "–", "-", "…": gap.insert(.pause)
            case ".":
                // Two or more dots are an ellipsis: a hesitation, not an end.
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "." {
                    gap.insert(.pause)
                    var skip = next
                    while skip < text.endIndex, text[skip] == "." { skip = text.index(after: skip) }
                    index = skip
                    continue
                }
                gap.insert(.sentenceEnd)
            case "!": gap.insert(.sentenceEnd)
            case "?": gap.formUnion([.sentenceEnd, .question])
            default:
                if character.isNewline {
                    gap.insert(.lineBreak)
                } else if !character.isWhitespace {
                    gap.insert(.other)
                }
            }
            index = text.index(after: index)
        }
        return words
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    static func key(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "’", with: "'")
    }

    // MARK: - Edits

    struct Edit {
        /// The text removed; what follows it stays.
        let removed: Range<String.Index>
        /// Capitalise the first letter after the removed span: it now opens
        /// the sentence the removed words opened.
        let capitalizesNext: Bool

        func apply(to text: String) -> String {
            var result = text
            let tail = String(text[removed.upperBound...])
            var replacement = tail
            if capitalizesNext, let first = tail.first, first.isLowercase {
                replacement = first.uppercased() + tail.dropFirst()
            }
            result.replaceSubrange(removed.lowerBound..<text.endIndex, with: replacement)
            // Removing a trailing span leaves the space before it.
            if tail.allSatisfy(\.isWhitespace) {
                while let last = result.last, last.isWhitespace { result.removeLast() }
            }
            return result
        }
    }

    /// The edit that removes words `from..<to`, keeping the gap before `from`,
    /// or nil when that would split a quote or bracket: "Send it to [John],
    /// no wait, Mary" must not leave "[Mary".
    private static func removing(
        _ words: [Word], from: Int, to: Int, text: String, capitalizes: Bool
    ) -> Edit? {
        let start = words[from].range.lowerBound
        let end = to < words.count ? words[to].range.lowerBound : text.endIndex
        guard !text[start..<end].contains(where: { enclosingMarks.contains($0) }) else { return nil }
        return Edit(removed: start..<end, capitalizesNext: capitalizes)
    }

    /// Quotes and brackets, which come in pairs. Straight and curly single
    /// quotes are left out: they are apostrophes inside words.
    private static let enclosingMarks: Set<Character> = ["\"", "“", "”", "(", ")", "[", "]", "{", "}", "«", "»"]

    /// Whether word `index` opens a sentence or line.
    private static func opensSentence(_ words: [Word], _ index: Int) -> Bool {
        index == 0 || !words[index].gap.isDisjoint(with: [.sentenceEnd, .lineBreak])
    }

    /// The first word of the sentence that holds word `index`.
    private static func sentenceStart(_ words: [Word], containing index: Int) -> Int {
        var start = index
        while start > 0, !opensSentence(words, start) { start -= 1 }
        return start
    }

    // MARK: - Cancellation

    /// "Scratch that" drops the sentence it ends, or the one before when it
    /// opens a sentence.
    private static func cancellation(in words: [Word], text: String) -> Edit? {
        for index in words.indices {
            guard let length = match(cancelPhrases, in: words, at: index) else { continue }
            let end = index + length
            // "scratch that itch": a phrase that runs on into the sentence
            // without a pause on either side is just words.
            // "Strike that pose" runs on as ordinary words; a cancellation
            // ends at a pause, a full stop, or the end of the dictation.
            let pauseAfter = end == words.count || !words[end].gap.isDisjoint(with: [.pause, .sentenceEnd])
            guard pauseAfter else { continue }
            guard end == words.count || !words[end].gap.contains(.lineBreak) else { continue }

            // Cue words before it ("no, scratch that") go with it.
            let start = sentenceStart(words, containing: index)
            let spoken = words[start..<index].contains { !isCueWord($0.key) }
            if spoken {
                if let edit = removing(words, from: start, to: end, text: text, capitalizes: true) { return edit }
                continue
            }
            // It opens a sentence: the previous sentence on the same line goes.
            guard start > 0, !words[start].gap.contains(.lineBreak) else { continue }
            let previous = sentenceStart(words, containing: start - 1)
            if let edit = removing(words, from: previous, to: end, text: text, capitalizes: true) { return edit }
        }
        return nil
    }

    // MARK: - Restarts and swaps

    private struct Chain {
        let start: Int
        let end: Int
        /// Two cues, or a cue of several words: "no, wait", "sorry, sorry",
        /// "I mean", "not actually".
        let isStrong: Bool
        /// Set off by punctuation on at least one side.
        let isPunctuated: Bool
        /// Set off by punctuation on both sides.
        let isEnclosed: Bool
        /// A sentence of its own: "Sorry, sorry, not actually."
        let isStandaloneSentence: Bool
        /// The chain is one word that also apologises or hedges ("sorry",
        /// "actually"): "I'll be late, sorry, I'll be there at ten" is an
        /// apology and new news, not a correction.
        let isDiscourseMarker: Bool
    }

    private static func revision(in words: [Word], text: String, matchesWordClasses: Bool) -> Edit? {
        var index = 0
        while index < words.count {
            guard let chain = chain(in: words, at: index) else {
                index += 1
                continue
            }
            if chain.start > 0, chain.end < words.count,
               !words[chain.start].gap.contains(.question),
               !words[chain.start].gap.contains(.lineBreak), !words[chain.end].gap.contains(.lineBreak),
               let edit = restart(chain, in: words, text: text)
                ?? sharedFrame(chain, in: words, text: text, matchesWordClasses: matchesWordClasses) {
                return edit
            }
            index = chain.end
        }
        return nil
    }

    private static func chain(in words: [Word], at start: Int) -> Chain? {
        var end = start
        var cues = 0
        var chainOnly = 0
        var hasPhrase = false
        var lastCue = ""
        while end < words.count {
            if end > start, words[end].gap.contains(.lineBreak) || words[end].gap.contains(.other) { break }
            if let length = match(cuePhrases, in: words, at: end) {
                // "not actually" denies on its own ("Monday, not actually
                // Tuesday"); it only joins a chain another cue starts.
                if chainOnlyPhrases.contains(Array(words[end..<(end + length)].map(\.key))) {
                    chainOnly += 1
                } else {
                    cues += 1
                    lastCue = words[end].key
                    if length > 1 { hasPhrase = true }
                }
                end += length
            } else if interjections.contains(words[end].key) {
                end += 1
            } else {
                break
            }
        }
        guard cues > 0 else { return nil }
        let before = words[start].gap
        let after: Gap = end < words.count ? words[end].gap : [.sentenceEnd]
        let punctuatedBefore = start > 0 && !before.isDisjoint(with: [.pause, .sentenceEnd])
        let punctuatedAfter = !after.isDisjoint(with: [.pause, .sentenceEnd])
        return Chain(
            start: start, end: end,
            isStrong: cues + chainOnly >= 2 || hasPhrase,
            isPunctuated: punctuatedBefore || punctuatedAfter,
            isEnclosed: punctuatedBefore && punctuatedAfter,
            isStandaloneSentence: start > 0 && before.contains(.sentenceEnd) && after.contains(.sentenceEnd),
            isDiscourseMarker: cues == 1 && chainOnly == 0 && !hasPhrase && discourseMarkers.contains(lastCue)
        )
    }

    /// "let's meet tomorrow, sorry, let's meet yesterday": the words after the
    /// cue repeat the opening of the clause before it.
    private static func restart(_ chain: Chain, in words: [Word], text: String) -> Edit? {
        // A single everyday cue ("no", "wait") needs a pause beside it, and a
        // lone "sorry" or "actually" never starts a restart.
        if !chain.isStrong, !chain.isPunctuated || chain.isDiscourseMarker { return nil }
        let clauseEnd = chain.start
        // Engines write the pause before a cue as a full stop ("Let's meet
        // tomorrow. Sorry, let's meet Friday."), so a cue that opens a
        // sentence corrects the sentence before it; otherwise the clause is
        // in the cue's own sentence. The repeated opening is the evidence
        // either way. Only the last 16 words are searched: a restart corrects
        // a clause, not a paragraph.
        let clauseStart = max(sentenceStart(words, containing: clauseEnd - 1), clauseEnd - 16)
        let restartStart = chain.end
        let sentenceAfter = words[(restartStart + 1)...].firstIndex(where: {
            !$0.gap.isDisjoint(with: [.sentenceEnd, .lineBreak])
        }) ?? words.count
        let restartWords = words[restartStart..<sentenceAfter]
        // "…, actually, let's meet Friday too": the speaker added, not replaced.
        if restartWords.prefix(14).contains(where: { additions.contains($0.key) }) { return nil }

        // The nearest opening the restart repeats, so the least is removed.
        for opening in stride(from: clauseEnd - 1, through: clauseStart, by: -1)
        where words[opening].key == words[restartStart].key {
            var shared = 0
            while opening + shared < clauseEnd, restartStart + shared < sentenceAfter,
                  words[opening + shared].key == words[restartStart + shared].key {
                shared += 1
            }
            let rejected = words[(opening + shared)..<clauseEnd]
            guard !rejected.isEmpty, rejected.count <= 12 else { continue }
            // "That's great, I mean, that's really great": every word is
            // said again, so the speaker elaborated rather than corrected.
            let restated = Set(restartWords.prefix(rejected.count + shared + 4).map(\.key))
            guard !rejected.allSatisfy({ restated.contains($0.key) }) else { continue }
            let sharesEnough = shared >= 2 || (chain.isStrong && !functionWords.contains(words[opening].key))
            guard sharesEnough else { continue }
            // A negation the speaker dropped changes the meaning: "I can't do
            // Monday, no, I can do Tuesday" stays.
            let restartKeys = Set(restartWords.prefix(rejected.count + shared + 3).map(\.key))
            if rejected.contains(where: { isNegation($0.key) && !restartKeys.contains($0.key) }) { continue }
            if let edit = removing(words, from: opening, to: restartStart, text: text,
                                   capitalizes: opensSentence(words, opening) && words[opening].isCapitalized) {
                return edit
            }
        }
        return nil
    }

    /// "the blue one, I mean, the red one", "blue shirt, no, red shirt",
    /// "send it to John, no, Mary".
    private static func sharedFrame(
        _ chain: Chain, in words: [Word], text: String, matchesWordClasses: Bool
    ) -> Edit? {
        guard !chain.isStandaloneSentence, chain.isStrong || chain.isEnclosed else { return nil }
        guard !words[(chain.start + 1)..<chain.end].contains(where: { $0.gap.contains(.sentenceEnd) }),
              !words[chain.end].gap.contains(.sentenceEnd) else { return nil }
        let first = chain.start
        let replacement = chain.end
        let clauseStart = sentenceStart(words, containing: first - 1)
        let clause = words[clauseStart..<first]
        guard !clause.contains(where: { isNegation($0.key) }) else { return nil }
        // "the blue one, I mean, the red one too": the speaker added.
        let replacementSentence = words[replacement...].prefix { word in
            word.range.lowerBound == words[replacement].range.lowerBound
                || word.gap.isDisjoint(with: [.sentenceEnd, .lineBreak])
        }
        guard !replacementSentence.prefix(14).contains(where: { additions.contains($0.key) }) else { return nil }
        // Where the replacement ends: the next pause, sentence end, or text end.
        let replacementEnd = words[(replacement + 1)...].firstIndex(where: { !$0.gap.isEmpty }) ?? words.count
        let replacementLength = replacementEnd - replacement
        // "Send it to John. No, wait, Mary.": after a full stop the
        // replacement must be a fragment that ends its own sentence.
        if words[first].gap.contains(.sentenceEnd) {
            let endsSentence = replacementEnd == words.count
                || !words[replacementEnd].gap.isDisjoint(with: [.sentenceEnd, .lineBreak])
            guard endsSentence else { return nil }
        }

        // Same opening article or preposition, same length give or take one,
        // ending at a pause, and something actually swapped.
        for length in 2...4 where first - length >= clauseStart {
            let start = first - length
            let replacementKeys = Set(words[replacement..<replacementEnd].map(\.key))
            guard words[start].key == words[replacement].key, frameWords.contains(words[start].key),
                  abs(replacementLength - length) <= 1,
                  !words[(start + 1)..<first].contains(where: { !$0.gap.isEmpty }),
                  !words[start..<first].allSatisfy({ replacementKeys.contains($0.key) }) else { continue }
            if let edit = removing(words, from: start, to: replacement, text: text,
                                   capitalizes: opensSentence(words, start) && words[start].isCapitalized) {
                return edit
            }
        }
        // Same last word, a content word, phrases of equal length.
        for length in 2...4 where first - length >= clauseStart && replacement + length <= words.count {
            let start = first - length
            let replacementKeys = Set(words[replacement..<(replacement + length)].map(\.key))
            guard words[first - 1].key == words[replacement + length - 1].key,
                  !functionWords.contains(words[first - 1].key),
                  !words[start..<first].allSatisfy({ replacementKeys.contains($0.key) }),
                  !words[(start + 1)..<first].contains(where: { !$0.gap.isEmpty }),
                  !words[(replacement + 1)..<(replacement + length)].contains(where: { !$0.gap.isEmpty })
            else { continue }
            if let edit = removing(words, from: start, to: replacement, text: text,
                                   capitalizes: opensSentence(words, start) && words[start].isCapitalized) {
                return edit
            }
        }
        // One word for another of the same kind, the replacement standing
        // alone before a pause or the end: "to John, no, Mary".
        guard replacementLength == 1, first - 1 > clauseStart else { return nil }
        let rejected = words[first - 1]
        let corrected = words[replacement]
        guard rejected.key != corrected.key, sameKind(rejected, corrected, before: words[first - 2],
                                                     previousOpensSentence: opensSentence(words, first - 2), in: text,
                                                     matchesWordClasses: matchesWordClasses) else { return nil }
        return removing(words, from: first - 1, to: replacement, text: text, capitalizes: false)
    }

    /// Two names, or (in English) two nouns or two adjectives — and the
    /// rejected word a whole phrase, not the end of one: "to John, no, Mary",
    /// never "the team lead, no, Mary".
    private static func sameKind(
        _ lhs: Word, _ rhs: Word, before previous: Word, previousOpensSentence: Bool,
        in text: String, matchesWordClasses: Bool
    ) -> Bool {
        // A capital that only opens the sentence says nothing about a name.
        let previousIsName = previous.isCapitalized && !previousOpensSentence
        let isName = { (word: Word) in
            word.isCapitalized && word.text != "I" && !functionWords.contains(word.key)
                && !isCueWord(word.key) && !word.text.contains(where: \.isNumber)
        }
        if isName(lhs), isName(rhs) {
            // "John Smith, no, Mary" would leave "John Mary".
            return !previousIsName
        }
        guard matchesWordClasses else { return false }
        // The tagger reads a capitalised first word as a noun ("Call mom"),
        // so it sees the sentence's opening word in lower case.
        var tagged = text
        let lowered = previous.text.lowercased()
        if previousOpensSentence, lowered.count == previous.text.count {
            tagged.replaceSubrange(previous.range, with: lowered)
        }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = tagged
        let classOf = { (word: Word) -> NLTag? in
            let offset = text.distance(from: text.startIndex, to: word.range.lowerBound)
            let index = tagged.index(tagged.startIndex, offsetBy: offset)
            return tagger.tag(at: index, unit: .word, scheme: .lexicalClass).0
        }
        guard let lhsClass = classOf(lhs), lhsClass == classOf(rhs) else { return false }
        switch lhsClass {
        case .noun:
            // A noun after a noun or adjective ends a longer phrase.
            let previousClass = classOf(previous)
            return previousClass != .noun && previousClass != .adjective && !previousIsName
        case .adjective:
            return true
        default:
            return false
        }
    }

    // MARK: - Vocabulary

    private static func match(_ phrases: [[String]], in words: [Word], at index: Int) -> Int? {
        for phrase in phrases where index + phrase.count <= words.count {
            var matches = true
            for (offset, part) in phrase.enumerated() {
                let word = words[index + offset]
                // A phrase is said in one breath; a sentence end splits it.
                if offset > 0, word.gap.contains(.sentenceEnd) || word.gap.contains(.lineBreak) {
                    matches = false
                    break
                }
                if word.key != part {
                    matches = false
                    break
                }
            }
            if matches { return phrase.count }
        }
        return nil
    }

    private static func isCueWord(_ key: String) -> Bool {
        interjections.contains(key) || cueWords.contains(key)
    }

    private static func isNegation(_ key: String) -> Bool {
        SpokenCorrectionResolver.negations.contains(key) || key.hasSuffix("n't")
    }

    /// The correction cues, longest first so "no wait" wins over "no".
    static let cuePhrases: [[String]] = (SpokenCorrectionResolver.cues + SpokenCorrectionResolver.chainOnlyCues + [
        "sorry no", "sorry actually", "i meant", "i mean to say", "let me rephrase", "what i meant",
    ])
    .map { $0.split(separator: " ").map(String.init) }
    .sorted { $0.count > $1.count }

    private static let cueWords: Set<String> = Set(cuePhrases.flatMap { $0 })

    private static let chainOnlyPhrases: Set<[String]> = Set(
        SpokenCorrectionResolver.chainOnlyCues.map { $0.split(separator: " ").map(String.init) }
    )

    static let interjections: Set<String> = ["oh", "uh", "um", "uhm", "ah", "er", "erm", "hmm", "oops", "whoops"]

    /// Cues that, alone, more often apologise or hedge than correct.
    private static let discourseMarkers: Set<String> = [
        "sorry", "actually", "perdón", "perdon", "pardon", "desculpa", "scusa", "enfin",
    ]

    /// Phrases that cancel what came before. "Never mind" and "forget that"
    /// are left to the model: in a message they are usually meant ("never
    /// mind, I found it").
    private static let cancelPhrases: [[String]] = [
        "scratch that", "strike that", "let me start over", "let me start again",
        "borra eso", "efface ça", "streich das", "apaga isso",
    ]
    .map { $0.split(separator: " ").map(String.init) }
    .sorted { $0.count > $1.count }

    /// Words that open a phrase built the same way twice: "the blue one" /
    /// "the red one", "on the left" / "on the right".
    private static let frameWords: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "my", "your", "our", "their", "his", "her",
        "its", "to", "at", "in", "on", "for", "with", "from", "by", "into", "onto",
    ]

    /// Words that add to what was said rather than replace it.
    private static let additions: Set<String> = [
        "too", "also", "either", "additionally", "plus", "another", "even",
        "también", "aussi", "auch", "anche", "bhi",
    ]

    /// Words too common for one shared word to prove a restart.
    private static let functionWords: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "some", "any", "my", "your", "our", "their",
        "his", "her", "its", "i", "you", "he", "she", "it", "we", "they", "me", "him", "us", "them",
        "i'm", "i'll", "i've", "i'd", "you're", "you'll", "we're", "we'll", "they're", "it's", "that's",
        "there's", "let's", "to", "of", "in", "on", "at", "for", "with", "by", "from", "about", "and",
        "or", "but", "so", "if", "is", "are", "was", "were", "be", "been", "am", "do", "does", "did",
        "have", "has", "had", "will", "would", "can", "could", "should", "shall", "may", "might", "must",
        "there", "here", "then", "just", "not", "one", "what", "which", "who", "when", "where", "how",
        "el", "la", "los", "las", "un", "una", "le", "les", "der", "die", "das", "ein", "eine", "o",
        "il", "lo", "de", "du", "des", "en", "y", "et", "und", "e", "que", "qui",
    ]
}
