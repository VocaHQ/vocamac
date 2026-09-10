// ScreenContextTerms.swift
// VocaMac
//
// Picks the words from on-screen text that a speech engine is likely to get
// wrong: code identifiers and names. The dictionary corrector then spells a
// dictation's matching words the way the screen does.

import Foundation

enum ScreenContextTerms {

    static let maximumTerms = 300

    private static let patterns: [NSRegularExpression] = [
        // camelCase and iOS-style names: userId, iPhone, macOS
        #"\b[a-z][a-z0-9]*[A-Z][A-Za-z0-9]*\b"#,
        // Capitals inside a word: GitHub, OpenAI, UserService
        #"\b[A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*\b"#,
        // snake_case and SCREAMING_CASE
        #"\b[A-Za-z][A-Za-z0-9]*(?:_[A-Za-z0-9]+)+\b"#,
        // kebab-case
        #"\b[a-z][a-z0-9]*(?:-[a-z0-9]+)+\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// Capitalized words; kept only when they don't start a sentence and
    /// aren't ordinary words (which would make "Apple" out of "apple").
    private static let capitalizedWord = try? NSRegularExpression(pattern: #"\b[A-Z][a-z]{2,}\b"#)

    /// Distinct terms in reading order, at most `maximumTerms`.
    static func extract(from text: String, isKnownWord: (String) -> Bool) -> [String] {
        guard !text.isEmpty else { return [] }
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)

        var found: [(location: Int, term: String)] = []
        for regex in patterns {
            for match in regex.matches(in: text, range: fullRange) {
                found.append((match.range.location, source.substring(with: match.range)))
            }
        }

        if let capitalizedWord {
            for match in capitalizedWord.matches(in: text, range: fullRange)
            where !startsSentence(at: match.range.location, in: source) {
                let word = source.substring(with: match.range)
                if !isKnownWord(word.lowercased()) {
                    found.append((match.range.location, word))
                }
            }
        }

        var seen = Set<String>()
        var terms: [String] = []
        for item in found.sorted(by: { $0.location < $1.location }) {
            guard DictionaryCorrector.normalized(item.term).count >= 3,
                  seen.insert(item.term).inserted else { continue }
            terms.append(item.term)
            if terms.count == maximumTerms { break }
        }
        return terms
    }

    /// Whether the word at `location` opens a sentence or line, where a
    /// capital letter says nothing about it being a name.
    private static func startsSentence(at location: Int, in source: NSString) -> Bool {
        var index = location - 1
        while index >= 0 {
            guard let scalar = UnicodeScalar(source.character(at: index)) else { return false }
            let character = Character(scalar)
            if character == " " || character == "\t" {
                index -= 1
                continue
            }
            return character == "\n" || character == "." || character == "!" || character == "?"
                || character == "\"" || character == "“" || character == "#" || character == "-"
                || character == "*" || character == ">"
        }
        return true
    }
}
