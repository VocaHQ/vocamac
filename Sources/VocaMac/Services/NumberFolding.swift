// NumberFolding.swift
// VocaMac
//
// Spelled-out English numbers to digits, for scoring transcripts.

import Foundation

/// Rewrites English number words in a lowercased word list as digits, so an
/// error rate does not count "three" against "3".
///
/// For scoring only: both sides of a comparison are folded the same way, so
/// it favours being predictable over reading every phrase as a person would.
/// "one of them" becomes "1 of them" on both sides and still matches. It is
/// not `SpokenNumbers`, which decides how dictated text is written.
///
/// - "twenty one" → "21", "one hundred and five" → "105",
///   "two thousand twenty six" → "2026", "nineteen ninety nine" → "1999"
/// - ordinals end a number: "twenty first" → "21st", "third" → "3rd"
/// - "point" between two numbers is dropped, as the tokenizer splits
///   "3.5" into "3 5": "three point five" → "3 5"
/// - a word that cannot continue the number starts a new one:
///   "one two three" → "1 2 3"
enum NumberFolding {

    static func fold(_ words: [String]) -> [String] {
        var output: [String] = []
        var index = 0
        while index < words.count {
            if let (text, consumed) = number(at: index, in: words) {
                output.append(text)
                index += consumed
            } else {
                output.append(words[index])
                index += 1
            }
        }
        return droppingDecimalPoints(output)
    }

    // MARK: - Vocabulary

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = [
        "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
    ]
    private static let unitOrdinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
    ]
    private static let tensOrdinals: [String: Int] = [
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50, "sixtieth": 60, "seventieth": 70,
        "eightieth": 80, "ninetieth": 90,
    ]

    // MARK: - Parsing

    /// The number starting at `start`, as digits, and how many words it used.
    private static func number(at start: Int, in words: [String]) -> (String, Int)? {
        var total = 0      // completed thousands/millions
        var group = 0      // the current group below 1,000
        var lastSmall: Int? // the value of the last unit/teen/tens word in this group
        var hasHundred = false
        var used = 0
        var yearPrefix: Int?
        var index = start

        func value() -> Int { total + group + (yearPrefix ?? 0) }

        while index < words.count {
            let word = words[index]
            if let ordinal = unitOrdinals[word] ?? tensOrdinals[word] {
                let isTens = tensOrdinals[word] != nil
                guard canTake(ordinal, isTens: isTens, lastSmall: lastSmall, group: group) else { break }
                group += ordinal
                used += 1
                return (String(value()) + suffix(for: value()), used)
            }
            if let small = units[word] ?? teens[word] ?? tens[word] {
                let isTens = tens[word] != nil
                if canTake(small, isTens: isTens, lastSmall: lastSmall, group: group) {
                    group += small
                    lastSmall = small
                } else if yearPrefix == nil, total == 0, !hasHundred, (10...99).contains(group),
                          teens[word] != nil || isTens {
                    // "nineteen ninety nine": two pairs of digits.
                    yearPrefix = group * 100
                    group = small
                    lastSmall = small
                } else {
                    break
                }
                used += 1
                index += 1
                continue
            }
            if word == "hundred", yearPrefix == nil, !hasHundred, group < 100 {
                group = max(group, 1) * 100
                hasHundred = true
                lastSmall = nil
                used += 1
                index += 1
                continue
            }
            if let scale = scales[word], yearPrefix == nil, used > 0, total == 0 || total > scale * max(group, 1) {
                total += max(group, 1) * scale
                group = 0
                lastSmall = nil
                hasHundred = false
                used += 1
                index += 1
                continue
            }
            if word == "and", used > 0, hasHundred || total > 0, lastSmall == nil,
               index + 1 < words.count, isSmallNumberWord(words[index + 1]) {
                used += 1
                index += 1
                continue
            }
            break
        }
        guard used > 0 else { return nil }
        return (String(value()), used)
    }

    /// Whether a unit, teen or tens word can extend the current group:
    /// a first word, a unit after a tens ("twenty one"), or anything below a
    /// hundred after "hundred" or a scale word.
    private static func canTake(_ small: Int, isTens: Bool, lastSmall: Int?, group: Int) -> Bool {
        guard let lastSmall else {
            // Nothing yet in this group below the hundreds.
            return group % 100 == 0
        }
        // Only "twenty" + "one" style pairs continue: a unit after a tens.
        return !isTens && small < 10 && small > 0 && lastSmall >= 20 && lastSmall % 10 == 0
    }

    private static func isSmallNumberWord(_ word: String) -> Bool {
        units[word] != nil || teens[word] != nil || tens[word] != nil
            || unitOrdinals[word] != nil || tensOrdinals[word] != nil
    }

    private static func suffix(for number: Int) -> String {
        switch (number % 10, number % 100) {
        case (_, 11...13): return "th"
        case (1, _): return "st"
        case (2, _): return "nd"
        case (3, _): return "rd"
        default: return "th"
        }
    }

    /// "3 point 5" → "3 5": the tokenizer already splits "3.5" that way.
    private static func droppingDecimalPoints(_ words: [String]) -> [String] {
        var output: [String] = []
        for (index, word) in words.enumerated() {
            if word == "point", index > 0, index + 1 < words.count,
               isDigits(words[index - 1]), isDigits(words[index + 1]) {
                continue
            }
            output.append(word)
        }
        return output
    }

    private static func isDigits(_ word: String) -> Bool {
        !word.isEmpty && word.allSatisfy(\.isNumber)
    }
}
