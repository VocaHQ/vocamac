// DictionaryCorrector.swift
// VocaMac
//
// Applies the personal dictionary to a transcript from any engine.
//
// Whisper can take vocabulary as a recognition hint, but Parakeet, Apple
// Speech, and the ONNX models cannot, and even Whisper still misspells. This
// runs after transcription for every engine and does three things, in order:
//
// 1. Replacements: exact spoken forms → the user's text ("get hub" → "GitHub").
// 2. Vocabulary: spoken words whose letters match a term, ignoring case,
//    spaces, and punctuation ("voca mac" → "VocaMac"), plus a conservative
//    fuzzy match for near-misses of longer terms ("Namratha" → "Namrata"),
//    and, only where the engine was unsure of the words, a run of ordinary
//    words that sounds exactly like a term ("cooper netties" → Kubernetes).
// 3. Screen context: the same letter match against names and identifiers
//    read from the screen, never fuzzy.
//
// Everything here is pure and deterministic, so it is fast, testable, and
// never rewrites a sentence the way a language model can.

import Foundation

struct DictionaryCorrection: Equatable {
    struct Change: Equatable {
        let from: String
        let to: String
    }

    var text: String
    /// Terms the dictionary put in the text whose exact spelling later
    /// formatting must not touch (e.g. `iPhone` must not become `IPhone`).
    var protectedTerms: [String]
    var changes: [Change]
}

enum DictionaryCorrector {

    /// Longest run of spoken words that can join into one term.
    static let maximumWindow = 4

    static func correct(
        _ text: String,
        context: DictionaryContext,
        allowIdentifierJoins: Bool
    ) -> DictionaryCorrection {
        var result = DictionaryCorrection(text: text, protectedTerms: [], changes: [])
        guard !text.isEmpty, !context.isEmpty else { return result }

        applyReplacements(context.replacements, to: &result)
        applyTerms(
            vocabulary: context.vocabulary,
            contextTerms: context.contextTerms,
            allowIdentifierJoins: allowIdentifierJoins,
            isKnownWord: context.isKnownWord,
            lowConfidenceWords: context.lowConfidenceWords,
            to: &result
        )

        var seen = Set<String>()
        result.protectedTerms = result.protectedTerms.filter { seen.insert($0).inserted }
        return result
    }

    // MARK: - Replacements

    private static func applyReplacements(_ replacements: [WordReplacement], to result: inout DictionaryCorrection) {
        let pairs = replacements
            .filter(\.isValid)
            .flatMap { replacement in
                replacement.heardForms.map { (heard: $0, replacement: replacement.replacement) }
            }
            .sorted { $0.heard.count > $1.heard.count }
        guard !pairs.isEmpty else { return }

        let pattern = pairs.map { pair -> String in
            let escaped = NSRegularExpression.escapedPattern(for: pair.heard)
            let prefix = pair.heard.first.map(isWordCharacter) == true ? "\\b" : "(?<!\\S)"
            let suffix = pair.heard.last.map(isWordCharacter) == true ? "\\b" : "(?!\\S)"
            return "(\(prefix)\(escaped)\(suffix))"
        }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }

        let source = result.text as NSString
        let matches = regex.matches(in: result.text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return }

        let output = NSMutableString(string: result.text)
        for match in matches.reversed() {
            guard let group = (1..<match.numberOfRanges).first(where: { match.range(at: $0).location != NSNotFound }) else {
                continue
            }
            let replacement = pairs[group - 1].replacement
            let heard = source.substring(with: match.range)
            output.replaceCharacters(in: match.range, with: replacement)
            result.changes.insert(.init(from: heard, to: replacement), at: 0)
            if needsProtection(replacement) {
                result.protectedTerms.append(replacement)
            }
        }
        result.text = output as String
    }

    // MARK: - Vocabulary and Screen Terms

    private struct Candidate {
        let term: String
        let isUserTerm: Bool
    }

    private static func applyTerms(
        vocabulary: [String],
        contextTerms: [String],
        allowIdentifierJoins: Bool,
        isKnownWord: (String) -> Bool,
        lowConfidenceWords: Set<String>?,
        to result: inout DictionaryCorrection
    ) {
        var exact: [String: Candidate] = [:]
        for term in contextTerms {
            for key in exactKeys(for: term) {
                exact[key] = Candidate(term: term, isUserTerm: false)
            }
        }
        // The user's own terms win over anything read from the screen.
        for term in vocabulary {
            for key in exactKeys(for: term) {
                exact[key] = Candidate(term: term, isUserTerm: true)
            }
        }
        guard !exact.isEmpty else { return }

        let fuzzyTerms = vocabulary.filter { normalized($0).count >= 5 }
        let tokens = self.tokens(in: result.text)
        guard !tokens.isEmpty else { return }

        let source = result.text as NSString
        var edits: [(range: NSRange, term: String)] = []
        var index = 0

        while index < tokens.count {
            let joinable = joinableLength(from: index, tokens: tokens, source: source)
            var matched = false

            // 1. Exact letter match, longest window first.
            for length in stride(from: min(maximumWindow, joinable), through: 1, by: -1) {
                let window = tokens[index..<(index + length)]
                let key = window.map { normalized($0.text) }.joined()
                guard let candidate = exact[key] else { continue }
                if length > 1, !candidate.isUserTerm, isIdentifierShaped(candidate.term), !allowIdentifierJoins {
                    continue
                }
                // "email" stays "email" when the screen shows "e-mail" or a
                // `setUp` method: outside Code and Terminal, an ordinary word
                // is only respelled as a screen identifier when it isn't one.
                if length == 1, !candidate.isUserTerm, isIdentifierShaped(candidate.term), !allowIdentifierJoins,
                   isKnownWord(normalized(window[window.startIndex].text)) {
                    continue
                }
                let range = span(of: window)
                let spoken = source.substring(with: range)
                let term = candidate.isUserTerm ? casedLike(spoken, term: candidate.term) : candidate.term
                if spoken != term {
                    edits.append((range, term))
                }
                if needsProtection(term) {
                    result.protectedTerms.append(term)
                }
                index += length
                matched = true
                break
            }
            if matched { continue }

            // 2. Near-miss of a longer vocabulary term.
            if let (length, term) = fuzzyMatch(
                at: index, tokens: tokens, joinable: joinable,
                terms: fuzzyTerms, isKnownWord: isKnownWord
            ) ?? soundAlikeJoin(
                at: index, tokens: tokens, joinable: joinable, terms: fuzzyTerms,
                isKnownWord: isKnownWord, lowConfidenceWords: lowConfidenceWords
            ) {
                let range = span(of: tokens[index..<(index + length)])
                let term = casedLike(source.substring(with: range), term: term)
                edits.append((range, term))
                if needsProtection(term) {
                    result.protectedTerms.append(term)
                }
                index += length
                continue
            }

            index += 1
        }

        guard !edits.isEmpty else { return }
        let output = NSMutableString(string: result.text)
        for edit in edits.reversed() {
            let spoken = source.substring(with: edit.range)
            output.replaceCharacters(in: edit.range, with: edit.term)
            result.changes.append(.init(from: spoken, to: edit.term))
        }
        result.text = output as String
    }

    private static func fuzzyMatch(
        at index: Int,
        tokens: [Token],
        joinable: Int,
        terms: [String],
        isKnownWord: (String) -> Bool
    ) -> (length: Int, term: String)? {
        guard !terms.isEmpty else { return nil }
        var best: (length: Int, term: String, distance: Int)?

        for length in 1...min(3, joinable) {
            let window = tokens[index..<(index + length)]
            // A real word is never "corrected" into a term on its own: "cloud"
            // must stay "cloud" even when "Claude" is in the dictionary.
            if window.allSatisfy({ isKnownWord($0.text) }) { continue }
            let key = window.map { normalized($0.text) }.joined()
            guard key.count >= 4 else { continue }

            for term in terms {
                let target = normalized(term)
                // One more edit for a word that sounds the same ("Kayzer" →
                // Kaiser), still within the same first sound and length; two
                // more for a term of eight letters or more ("Pachori" →
                // Pachauri, "Shwarzeneger" → Schwarzenegger).
                let limit = editBudget(heard: key, term: target)
                guard abs(target.count - key.count) <= limit,
                      firstSound(target) == firstSound(key) else { continue }
                let distance = levenshtein(key, target, limit: limit)
                guard distance > 0, distance <= limit else { continue }
                if best == nil || distance < best!.distance {
                    best = (length, term, distance)
                }
            }
        }
        return best.map { ($0.length, $0.term) }
    }

    /// Most edits a heard spelling may be from `term`: one, two for a term
    /// of nine letters or more, and more when the two sound alike — one
    /// more, or two more for a term of eight letters or more.
    static func editBudget(heard: String, term: String) -> Int {
        let base = term.count >= 9 ? 2 : 1
        guard soundsAlike(heard, term) else { return base }
        return term.count >= 8 ? max(base + 1, 3) : base + 1
    }

    /// Whether two letter keys sound alike: their Double Metaphone keys
    /// meet, or, for what Metaphone can't key, their Soundex codes agree.
    static func soundsAlike(_ heard: String, _ term: String) -> Bool {
        if let heardKey = DoubleMetaphone.encode(heard), let termKey = DoubleMetaphone.encode(term) {
            return heardKey.matches(termKey)
        }
        return soundex(heard) != nil && soundex(heard) == soundex(term)
    }

    /// Two or three ordinary words heard for one longer term that sounds
    /// exactly like them: "cooper netties" for Kubernetes, "pie torch" for
    /// PyTorch. Real words are never respelled on spelling alone, so this
    /// needs evidence the engine misheard them: one of the words isn't a
    /// word at all, or was decoded with low confidence. With an engine that
    /// reports no confidence (`lowConfidenceWords` nil), a run of real words
    /// is left alone, and a single word never takes this path ("cloud"
    /// stays "cloud" with Claude listed).
    private static func soundAlikeJoin(
        at index: Int,
        tokens: [Token],
        joinable: Int,
        terms: [String],
        isKnownWord: (String) -> Bool,
        lowConfidenceWords: Set<String>?
    ) -> (length: Int, term: String)? {
        guard joinable >= 2, !terms.isEmpty else { return nil }
        for length in stride(from: min(3, joinable), through: 2, by: -1) {
            let window = tokens[index..<(index + length)]
            let keys = window.map { normalized($0.text) }
            let misheard = keys.contains { !isKnownWord($0) }
                || keys.contains { lowConfidenceWords?.contains($0) == true }
            guard misheard else { continue }
            let joined = keys.joined()
            guard let heardKey = DoubleMetaphone.encode(joined), heardKey.primary.count >= 3 else { continue }
            for term in terms {
                let target = normalized(term)
                guard target.count >= 6, !isKnownWord(target),
                      abs(target.count - joined.count) <= max(2, target.count / 3),
                      firstSound(target) == firstSound(joined),
                      let termKey = DoubleMetaphone.encode(target),
                      termKey.primary == heardKey.primary else { continue }
                return (length, term)
            }
        }
        return nil
    }

    // MARK: - Tokens

    struct Token {
        let text: String
        let range: NSRange
    }

    private static let tokenRegex = try? NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}]+)*"#)

    static func tokens(in text: String) -> [Token] {
        guard let tokenRegex else { return [] }
        let source = text as NSString
        return tokenRegex.matches(in: text, range: NSRange(location: 0, length: source.length)).map {
            Token(text: source.substring(with: $0.range), range: $0.range)
        }
    }

    /// How many tokens starting at `index` are separated only by spaces or
    /// hyphens — a comma or full stop between words means they are not one term.
    private static func joinableLength(from index: Int, tokens: [Token], source: NSString) -> Int {
        var length = 1
        while index + length < tokens.count, length < maximumWindow {
            let previous = tokens[index + length - 1].range
            let next = tokens[index + length].range
            let gapStart = previous.location + previous.length
            let gap = source.substring(with: NSRange(location: gapStart, length: next.location - gapStart))
            guard gap.allSatisfy({ $0 == " " || $0 == "-" }) else { break }
            length += 1
        }
        return length
    }

    private static func span(of window: ArraySlice<Token>) -> NSRange {
        guard let first = window.first?.range, let last = window.last?.range else {
            return NSRange(location: 0, length: 0)
        }
        return NSRange(location: first.location, length: last.location + last.length - first.location)
    }

    // MARK: - Helpers

    /// Letter keys that spell a term exactly: its own letters, and for a term
    /// with "&" also the spoken form ("R and D" → R&D).
    static func exactKeys(for term: String) -> [String] {
        var keys: [String] = []
        let key = normalized(term)
        if key.count >= 2 { keys.append(key) }
        if term.contains("&") {
            let spoken = normalized(term.replacingOccurrences(of: "&", with: " and "))
            if spoken != key { keys.append(spoken) }
        }
        return keys
    }

    /// American Soundex of a lowercase ASCII key, or nil for anything else.
    /// English-only by design: it only widens the edit budget, never matches
    /// on its own.
    static func soundex(_ key: String) -> String? {
        guard let first = key.first, key.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        func code(_ character: Character) -> Character? {
            switch character {
            case "b", "f", "p", "v": return "1"
            case "c", "g", "j", "k", "q", "s", "x", "z": return "2"
            case "d", "t": return "3"
            case "l": return "4"
            case "m", "n": return "5"
            case "r": return "6"
            default: return nil
            }
        }
        var result = String(first)
        var previous = code(first)
        for character in key.dropFirst() {
            let current = code(character)
            if let current, current != previous {
                result.append(current)
                if result.count == 4 { break }
            }
            // "h" and "w" do not separate equal codes; vowels do.
            if character != "h" && character != "w" { previous = current }
        }
        return result.padding(toLength: 4, withPad: "0", startingAt: 0)
    }

    /// Letters and digits only, lowercased: "Voca-Mac" and "voca mac" agree.
    static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Whether formatting could change the term's spelling: a lowercase start
    /// (sentence case would capitalize it), capitals after the first letter,
    /// or anything that isn't a letter.
    /// `term` as it should be written over `spoken`. A Dictionary entry typed
    /// all in lowercase ("sergey", "claude") says how a word is spelled, not
    /// how it is cased: when the engine heard a capitalized word, a name, the
    /// capital stays. Written as typed, those entries lowercased every name
    /// they matched, and protected the result from sentence case too. An
    /// all-capitals or lowercase spoken word ("NPM", "npm") takes the entry's
    /// casing, so a tool entered as "npm" stays "npm".
    ///
    /// Word by word when the spoken words line up with the entry's ("New
    /// York" over "new york"); otherwise by the first spoken word ("Voca
    /// Mac" over "vocamac" stays "vocamac": joined, it isn't a name heard).
    static func casedLike(_ spoken: String, term: String) -> String {
        guard term == term.lowercased(), term.allSatisfy({ $0.isLetter || $0 == " " || $0 == "'" || $0 == "’" })
        else { return term }
        func isCapitalized<S: StringProtocol>(_ word: S) -> Bool {
            let letters = word.filter(\.isLetter)
            return letters.first?.isUppercase == true && letters.dropFirst().allSatisfy(\.isLowercase)
        }
        func capitalized<S: StringProtocol>(_ word: S) -> String { word.prefix(1).uppercased() + word.dropFirst() }
        let termWords = term.split(separator: " ", omittingEmptySubsequences: false)
        let spokenWords = spoken.split(whereSeparator: \.isWhitespace)
        if termWords.count > 1, spokenWords.count == termWords.count {
            return zip(termWords, spokenWords)
                .map { isCapitalized($1) ? capitalized($0) : String($0) }
                .joined(separator: " ")
        }
        guard isCapitalized(spoken) else { return term }
        return termWords.map(capitalized).joined(separator: " ")
    }

    static func needsProtection(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, trimmed.contains(where: \.isLetter) else { return false }
        if first.isLetter && first.isLowercase { return true }
        // Capitals inside a word ("GitHub"), not at the start of each word ("New York").
        if trimmed.split(separator: " ").contains(where: { $0.dropFirst().contains(where: \.isUppercase) }) {
            return true
        }
        return trimmed.contains { !$0.isLetter && $0 != " " && $0 != "'" && $0 != "’" }
    }

    /// camelCase, snake_case, kebab-case, dotted, or containing digits — a code
    /// identifier rather than a name. Only joined from several spoken words in
    /// code and terminal apps.
    static func isIdentifierShaped(_ term: String) -> Bool {
        guard let first = term.first else { return false }
        if first.isLowercase && term.contains(where: { $0.isUppercase }) { return true }
        return term.contains { $0 == "_" || $0 == "-" || $0 == "." || $0.isNumber }
    }

    /// Rough first sound, so fuzzy matching never swaps a word for a term that
    /// starts differently: c/k/q, s/z, and ph/f are treated as one.
    static func firstSound(_ key: String) -> Character? {
        var text = key
        if text.hasPrefix("ph") { text = "f" + text.dropFirst(2) }
        guard let first = text.first else { return nil }
        switch first {
        case "c", "q": return "k"
        case "z": return "s"
        default: return first
        }
    }

    /// Edit distance, giving up once it exceeds `limit`.
    static func levenshtein(_ a: String, _ b: String, limit: Int = .max) -> Int {
        let left = Array(a)
        let right = Array(b)
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }
        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: right.count + 1)
        for i in 1...left.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...right.count {
                let cost = left[i - 1] == right[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMinimum = min(rowMinimum, current[j])
            }
            if rowMinimum > limit { return rowMinimum }
            swap(&previous, &current)
        }
        return previous[right.count]
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
