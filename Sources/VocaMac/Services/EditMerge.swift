// EditMerge.swift
// VocaMac
//
// Applies a cleanup model's answer one edit at a time: every safe edit is
// kept, every risky one is put back as spoken. A cleanup is never thrown
// away whole.

import Foundation

/// A small model's cleanup is usually right in most places and wrong in one:
/// it removes the fillers, fixes a spelling, punctuates — and changes "15" to
/// "10" or drops a sentence. Judging the answer as a whole forces a choice
/// between keeping the damage and losing every good edit.
///
/// This lines the answer up against the original and decides each difference
/// on its own. Kept:
///
/// - punctuation, including a spoken "comma" / "period" written as a mark
/// - a capital at the start of a sentence, and "i" → "I"
/// - a misspelling corrected to a real word ("expender" → "expander")
/// - "do not" ↔ "don't" and other contractions
/// - hesitations, fillers, stutters ("if if", "diff different"), and
///   restarts the speaker abandoned; "scratch that" at the High level
///
/// Everything else — a changed number, name, or word, an added word, a dropped
/// sentence, a dropped question mark — stays as the user said it. The Light
/// level keeps every spoken word and takes punctuation and capitals only.
enum EditMerge {

    struct Result: Equatable {
        let text: String
        /// Edits taken from the model.
        let applied: Int
        /// Edits the model made that were left as spoken.
        let skipped: Int
    }

    static func merge(
        original: String,
        candidate: String,
        level: CleanupLevel,
        isKnownWord: (String) -> Bool
    ) -> Result {
        let source = tokens(in: original)
        let target = tokens(in: candidate)
        guard !source.isEmpty, source.count * max(target.count, 1) <= 4_000_000 else {
            return Result(text: original, applied: 0, skipped: 0)
        }
        let operations = align(source, target)
        // An answer that adds more new words than a cleanup ever would, or
        // adds words while keeping under half of the user's, isn't an edit —
        // the model answered or rewrote — so take nothing from it, not even
        // punctuation. An answer that only removes words can't be an answer;
        // the per-edit rules below decide which removals are safe.
        let sourceWords = source.filter(\.isWord).count
        let keptWords = operations.filter {
            if case .match(let o, _) = $0 { return source[o].isWord } else { return false }
        }.count
        let newWords = operations.filter {
            if case .insert(let c) = $0 { return target[c].isWord } else { return false }
        }.count
        guard sourceWords == 0 || (newWords <= max(3, sourceWords / 2)
                                   && (newWords <= 1 || Double(keptWords) / Double(sourceWords) >= minimumSharedWords)) else {
            return Result(text: original, applied: 0, skipped: 1)
        }

        var output: [Emitted] = []
        var applied = 0
        var skipped = 0
        var index = 0
        while index < operations.count {
            if case .match(let o, let c) = operations[index] {
                output.append(Emitted(token: matchedCase(source[o], target[c], sentenceStart: endsSentence(output)),
                                      leading: source[o].leading))
                if source[o].text != output[output.count - 1].token.text { applied += 1 }
                index += 1
                continue
            }
            // A hunk: everything up to the next match.
            var removed: [Int] = []
            var added: [Int] = []
            while index < operations.count {
                switch operations[index] {
                case .delete(let o): removed.append(o)
                case .insert(let c): added.append(c)
                case .match: break
                }
                if case .match = operations[index] { break }
                index += 1
            }
            let nextMatch = operations[index...].first { if case .match = $0 { return true } else { return false } }
            var following: [Token] = []
            var next: Token?
            if case .match(let o, _) = nextMatch {
                following = source[o...].filter(\.isWord)
                next = source[o]
            }
            let sentence = output.reversed().prefix { ![".", "!", "?"].contains($0.token.text) }.reversed().map(\.token)
            let hunk = Hunk(
                removed: removed.map { source[$0] }, added: added.map { target[$0] },
                preceding: output.map(\.token).filter(\.isWord),
                precedingInSentence: sentence.filter(\.isWord),
                following: following, sentenceStart: endsSentence(output),
                previous: output.last?.token, next: next
            )
            if isSafe(hunk, level: level, isKnownWord: isKnownWord) {
                for token in hunk.added {
                    output.append(Emitted(token: token, leading: token.leading))
                }
                applied += 1
            } else {
                for token in hunk.removed { output.append(Emitted(token: token, leading: token.leading)) }
                skipped += 1
            }
        }
        return Result(text: render(output), applied: applied, skipped: skipped)
    }

    /// Share of the user's words the answer must keep to count as an edit.
    static let minimumSharedWords = 0.5

    // MARK: - Deciding one edit

    private struct Hunk {
        let removed: [Token]
        let added: [Token]
        let preceding: [Token]
        /// Words already written in the current sentence.
        let precedingInSentence: [Token]
        let following: [Token]
        let sentenceStart: Bool
        /// The token written just before the edit, and the one right after.
        let previous: Token?
        let next: Token?

        var removedWords: [Token] { removed.filter(\.isWord) }
        var addedWords: [Token] { added.filter(\.isWord) }
    }

    private static func isSafe(_ hunk: Hunk, level: CleanupLevel, isKnownWord: (String) -> Bool) -> Bool {
        // A protected technical span or snippet is never edited.
        guard !hunk.removed.contains(where: \.isProtected), !hunk.added.contains(where: \.isProtected) else {
            return false
        }
        // A question stays a question.
        let questionsBefore = hunk.removed.filter { $0.text == "?" }.count
        guard hunk.added.filter({ $0.text == "?" }).count >= questionsBefore else { return false }

        let removedWords = hunk.removedWords
        let addedWords = hunk.addedWords

        // Punctuation only.
        if removedWords.isEmpty, addedWords.isEmpty {
            return hunk.added.allSatisfy { allowedPunctuation.contains($0.text) }
        }
        // New words are new content.
        if removedWords.isEmpty { return false }

        if addedWords.isEmpty {
            // "comma" → "," — also when the mark is already written beside it.
            let spoken = removedWords.map(\.key).joined(separator: " ")
            if let mark = spokenPunctuation[spoken],
               hunk.added.contains(where: { $0.text == mark }) || hunk.previous?.text == mark || hunk.next?.text == mark {
                return true
            }
            return level != .light && isSafeDeletion(hunk, level: level)
        }

        // One word for one word: a spelling fix.
        if removedWords.count == 1, addedWords.count == 1 {
            let before = removedWords[0].key, after = addedWords[0].key
            if isSpellingFix(before, after, isKnownWord: isKnownWord) { return true }
        }
        // "do not" ↔ "don't"
        if expandContractions(removedWords.map(\.key)) == expandContractions(addedWords.map(\.key)) {
            return true
        }
        return false
    }

    private static func isSafeDeletion(_ hunk: Hunk, level: CleanupLevel) -> Bool {
        let words = hunk.removedWords.filter { !WritingStyleEngine.isHesitationWord($0.key) }
        guard let first = words.first else { return true }
        let keys = words.map(\.key)
        let phrase = keys.joined(separator: " ")
        let commaNearby = hunk.removed.contains { $0.text == "," }
            || hunk.previous?.text == "," || hunk.next?.text == ","

        if CleanupSalvage.openingFillers.contains(phrase) || phrase == "like", hunk.sentenceStart {
            return true
        }
        if CleanupSalvage.commaFillers.contains(phrase), commaNearby {
            return true
        }
        // "if if", "the the": the same words sit right beside the deletion.
        if keys.count <= 3, !CleanupSalvage.intentionalRepeats.contains(first.key) {
            if Array(hunk.following.prefix(keys.count)).map(\.key) == keys { return true }
            if Array(hunk.preceding.suffix(keys.count)).map(\.key) == keys { return true }
        }
        // "diff different", "sor sorry", "S see": a cut-off start of the next
        // word. "a", "I", and "o" are words, not fragments.
        if keys.count == 1, !realOneLetterWords.contains(first.key), let next = hunk.following.first,
           next.key.count > first.key.count, next.key.hasPrefix(first.key) {
            return true
        }
        // "after b doing": a stray letter the recognizer left between words.
        if keys.count == 1, first.key.count == 1, first.key.allSatisfy(\.isLetter),
           !realOneLetterWords.contains(first.key), first.text == first.key,
           !hunk.preceding.isEmpty, !hunk.following.isEmpty {
            return true
        }
        // "I want to, I need to": an abandoned start the next words redo.
        if (2...6).contains(keys.count), let next = hunk.following.first, next.key == first.key,
           hunk.removed.contains(where: { ["," , "—", "-"].contains($0.text) }) {
            return true
        }
        // "doesn't look even look like": a short restart without a comma. Not
        // when it opens with a pronoun — "I think I know" means something.
        if (2...3).contains(keys.count), let next = hunk.following.first, next.key == first.key,
           !pronouns.contains(first.key) {
            return true
        }
        // "send it to John, no, Mary": the model resolved a correction the
        // rules don't cover. High only, with an explicit cue, a short first
        // value that matches the replacement in form, and never in a
        // negative sentence ("I can't do John, no, …" isn't a correction).
        if level == .high, isModelResolvedCorrection(keys: keys, words: words, hunk: hunk) {
            return true
        }
        // "…, scratch that, …": the speaker asked for it.
        if level == .high, keys.count <= 40, phrase.hasSuffix("scratch that") || phrase.hasSuffix("never mind") {
            return true
        }
        return false
    }

    private static func isModelResolvedCorrection(keys: [String], words: [Token], hunk: Hunk) -> Bool {
        guard let cueLength = SpokenCorrectionResolver.cues
            .map({ $0.split(separator: " ").map(String.init) })
            .first(where: { cue in cue.count < keys.count && Array(keys.suffix(cue.count)) == cue })?.count
        else { return false }
        let first = Array(words.dropLast(cueLength))
        guard (1...3).contains(first.count), let replacement = hunk.following.first,
              !hunk.precedingInSentence.contains(where: {
                  SpokenCorrectionResolver.negations.contains($0.key) || $0.key.hasSuffix("n't")
              }) else { return false }
        // "the red one" / "the blue one": same opening word.
        if first.count >= 2, first[0].key == replacement.key { return true }
        // "John" / "Mary": two names.
        let isName = { (token: Token) in token.text.first?.isUppercase == true && token.text != "I" }
        return first.count == 1 && isName(first[0]) && isName(replacement)
    }

    private static func isSpellingFix(_ before: String, _ after: String, isKnownWord: (String) -> Bool) -> Bool {
        guard before.allSatisfy(\.isLetter), after.allSatisfy(\.isLetter),
              before.first == after.first,
              !negations.contains(before), !negations.contains(after),
              !isKnownWord(before), isKnownWord(after) else { return false }
        let distance = editDistance(before, after)
        return distance <= (before.count <= 4 ? 1 : 2)
    }

    // MARK: - Tables

    private static let allowedPunctuation: Set<String> = [",", ".", "!", "?", ";", ":", "—", "–", "-", "…"]

    private static let spokenPunctuation: [String: String] = [
        "comma": ",", "period": ".", "full stop": ".", "question mark": "?",
        "exclamation mark": "!", "exclamation point": "!", "colon": ":", "semicolon": ";",
    ]

    private static let negations: Set<String> = ["not", "no", "never", "nor", "neither", "without", "cannot"]

    private static let realOneLetterWords: Set<String> = ["a", "i", "o"]

    private static let pronouns: Set<String> = [
        "i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "us", "them",
    ]

    private static let contractions: [String: [String]] = [
        "don't": ["do", "not"], "doesn't": ["does", "not"], "didn't": ["did", "not"],
        "isn't": ["is", "not"], "aren't": ["are", "not"], "wasn't": ["was", "not"], "weren't": ["were", "not"],
        "can't": ["can", "not"], "cannot": ["can", "not"], "won't": ["will", "not"], "wouldn't": ["would", "not"],
        "shouldn't": ["should", "not"], "couldn't": ["could", "not"], "haven't": ["have", "not"],
        "hasn't": ["has", "not"], "hadn't": ["had", "not"],
        "i'm": ["i", "am"], "i've": ["i", "have"], "i'll": ["i", "will"], "i'd": ["i", "would"],
        "it's": ["it", "is"], "that's": ["that", "is"], "there's": ["there", "is"], "what's": ["what", "is"],
        "let's": ["let", "us"], "we're": ["we", "are"], "you're": ["you", "are"], "they're": ["they", "are"],
        "we'll": ["we", "will"], "you'll": ["you", "will"], "they'll": ["they", "will"],
        "we've": ["we", "have"], "you've": ["you", "have"], "they've": ["they", "have"],
    ]

    private static func expandContractions(_ words: [String]) -> [String] {
        words.flatMap { contractions[$0.replacingOccurrences(of: "’", with: "'")] ?? [$0] }
    }

    // MARK: - Tokens

    fileprivate struct Token {
        let text: String
        /// Whitespace before it in its own text.
        let leading: String
        /// Lowercased word, or the punctuation itself; what alignment compares.
        let key: String
        let isWord: Bool

        /// `RewriteProtectedText` placeholders and masked snippets.
        var isProtected: Bool {
            text.contains("VOCAKEEP") || text.unicodeScalars.contains { (0xE000...0xF8FF).contains($0.value) }
        }
    }

    private struct Emitted {
        let token: Token
        let leading: String
    }

    private static let tokenExpression = try? NSRegularExpression(
        pattern: #"(\s*)(VOCAKEEPX*\d+END|[\p{L}\p{N}]+(?:['’][\p{L}]+)*|\S)"#
    )

    private static func tokens(in text: String) -> [Token] {
        guard let tokenExpression else { return [] }
        let ns = text as NSString
        return tokenExpression.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            let word = ns.substring(with: match.range(at: 2))
            let isWord = word.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
            return Token(
                text: word, leading: ns.substring(with: match.range(at: 1)),
                key: isWord ? word.lowercased().replacingOccurrences(of: "’", with: "'") : word,
                isWord: isWord
            )
        }
    }

    /// The model's capital for a sentence start or "I"; the user's otherwise,
    /// so "iPhone", "GitHub", and names keep their casing.
    private static func matchedCase(_ original: Token, _ candidate: Token, sentenceStart: Bool) -> Token {
        guard original.text != candidate.text, original.isWord else { return original }
        if original.text == "i", candidate.text == "I" { return candidate }
        if sentenceStart, original.text == original.text.lowercased(),
           candidate.text == candidate.text.prefix(1).uppercased() + candidate.text.dropFirst() {
            return candidate
        }
        return original
    }

    private static func endsSentence(_ output: [Emitted]) -> Bool {
        guard let last = output.last?.token.text else { return true }
        return [".", "!", "?", "…"].contains(last)
    }

    /// Every token keeps the spacing it had in its own text, so "re-review"
    /// and "one-day" stay joined and "," hugs its word. Two words that end up
    /// side by side after a deletion get a space between them.
    private static func render(_ output: [Emitted]) -> String {
        var text = ""
        for (index, item) in output.enumerated() {
            if index == 0 {
                if item.leading.contains("\n") { text += item.leading }
            } else if item.leading.isEmpty, item.token.isWord, output[index - 1].token.isWord {
                text += " "
            } else {
                text += item.leading
            }
            text += item.token.text
        }
        return text
    }

    // MARK: - Alignment

    private enum Operation {
        case match(Int, Int)
        case delete(Int)
        case insert(Int)
    }

    /// Longest common subsequence on the keys; among equal alignments,
    /// earlier words are dropped first, so a repeat loses its first copy.
    private static func align(_ source: [Token], _ target: [Token]) -> [Operation] {
        let rows = source.count, columns = target.count
        var lengths = [[Int32]](repeating: [Int32](repeating: 0, count: columns + 1), count: rows + 1)
        if columns > 0 {
            for i in stride(from: rows - 1, through: 0, by: -1) {
                for j in stride(from: columns - 1, through: 0, by: -1) {
                    lengths[i][j] = source[i].key == target[j].key
                        ? lengths[i + 1][j + 1] + 1
                        : max(lengths[i + 1][j], lengths[i][j + 1])
                }
            }
        }
        var operations: [Operation] = []
        var i = 0, j = 0
        while i < rows || j < columns {
            if i < rows, j < columns, lengths[i + 1][j] != lengths[i][j], source[i].key == target[j].key {
                operations.append(.match(i, j)); i += 1; j += 1
            } else if i < rows, j >= columns || lengths[i + 1][j] >= lengths[i][j + 1] {
                operations.append(.delete(i)); i += 1
            } else {
                operations.append(.insert(j)); j += 1
            }
        }
        return operations
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return a.isEmpty ? b.count : previous[b.count]
    }
}
