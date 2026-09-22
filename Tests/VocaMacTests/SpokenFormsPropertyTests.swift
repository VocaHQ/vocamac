// SpokenFormsPropertyTests.swift
// VocaMac Tests
//
// Properties of SpokenNumbers and SpokenEmoji that hold for every input, not
// just the listed cases: numbers spelled out come back as their digits,
// ordinary English comes back untouched, and whitespace always survives.

import XCTest
@testable import VocaMac

final class SpokenFormsPropertyTests: XCTestCase {
    // MARK: - Numbers

    /// Every number up to 9,999, and a spread up to 999,999, spelled the way
    /// a speech model writes it, converts back to its digits.
    func testSpelledNumbersComeBackAsTheirDigits() {
        var failures: [String] = []
        let values = Array(0...9_999) + Array(stride(from: 10_000, through: 999_999, by: 997))
        for value in values where value != 1 {
            let spoken = Self.spell(value)
            let output = SpokenNumbers.digits(in: spoken)
            if output != Self.written(value) { failures.append("\(spoken) → \(output)") }
            // The same number, hyphenated the way people type it.
            let hyphenated = Self.spell(value, hyphenated: true)
            if hyphenated != spoken, SpokenNumbers.digits(in: hyphenated) != Self.written(value) {
                failures.append("\(hyphenated) → \(SpokenNumbers.digits(in: hyphenated))")
            }
        }
        XCTAssertEqual(failures.prefix(20), [])
    }

    /// A number keeps converting whatever sentence it is dictated in.
    func testANumberConvertsInsideASentence() {
        for value in stride(from: 2, through: 99_999, by: 331) {
            let spoken = "We need \(Self.spell(value)) chairs by Friday."
            XCTAssertEqual(
                SpokenNumbers.digits(in: spoken), "We need \(Self.written(value)) chairs by Friday.",
                spoken
            )
        }
    }

    /// Mixed scales are written in full, with separators.
    func testNumbersPastAMillionWithARemainderAreWrittenInFull() {
        XCTAssertEqual(SpokenNumbers.digits(in: Self.spell(2_003_500)), "2,003,500")
        XCTAssertEqual(SpokenNumbers.digits(in: Self.spell(45_000_001)), "45,000,001")
        XCTAssertEqual(SpokenNumbers.digits(in: Self.spell(7_250_000_000)), "7,250,000,000")
    }

    func testTheLargestExpressibleNumberConvertsAndNothingBeyondIt() {
        XCTAssertEqual(SpokenNumbers.digits(in: Self.spell(SpokenNumbers.maximum)), "999,999,999,999")
        let beyond = Self.spell(SpokenNumbers.maximum) + " trillion"
        XCTAssertEqual(SpokenNumbers.digits(in: beyond), beyond)
    }

    // MARK: - Ordinary English

    func testOrdinaryDictationIsUntouched() throws {
        for line in try Self.plainLines() {
            XCTAssertEqual(SpokenNumbers.digits(in: line), line, "digits: \(line)")
            XCTAssertEqual(SpokenNumbers.digits(in: line, symbols: true), line, "symbols: \(line)")
            XCTAssertEqual(SpokenEmoji.glyphs(in: line), line, "emoji: \(line)")
        }
    }

    /// The whole corpus as one dictation, with line breaks, is untouched too:
    /// nothing reads across a line.
    func testOrdinaryDictationAsOneTextIsUntouched() throws {
        let text = try Self.plainLines().joined(separator: "\n")
        XCTAssertEqual(SpokenNumbers.digits(in: text, symbols: true), text)
        XCTAssertEqual(SpokenEmoji.glyphs(in: text), text)
    }

    // MARK: - Whitespace

    /// Line breaks, tabs and runs of spaces between converted phrases survive
    /// exactly.
    func testWhitespaceBetweenPhrasesSurvives() {
        for separator in ["\n", "\n\n", "\t", "  ", " \n "] {
            let text = ["twenty three people", "fire emoji", "five dollars"].joined(separator: separator)
            let numbers = SpokenNumbers.digits(in: text, symbols: true)
            XCTAssertEqual(numbers, ["23 people", "fire emoji", "$5"].joined(separator: separator))
            XCTAssertEqual(SpokenEmoji.glyphs(in: text), ["twenty three people", "🔥", "five dollars"].joined(separator: separator))
        }
    }

    func testLeadingAndTrailingWhitespaceSurvives() {
        XCTAssertEqual(SpokenNumbers.digits(in: "  twenty three\n"), "  23\n")
        XCTAssertEqual(SpokenEmoji.glyphs(in: "\tfire emoji "), "\t🔥 ")
    }

    // MARK: - Emoji

    /// Every spoken alias converts, and wins over the generated table.
    func testEverySpokenAliasConverts() {
        XCTAssertGreaterThan(EmojiTable.aliases.count, 50)
        for (key, glyph) in EmojiTable.aliases where key.count >= EmojiTable.minimumLength {
            XCTAssertEqual(EmojiTable.triggers[key], glyph, key)
            XCTAssertEqual(SpokenEmoji.glyphs(in: "\(key) emoji"), glyph, key)
        }
    }

    func testAnAliasReplacesTheGeneratedEntry() {
        let merged = EmojiTable.merged(table: ["salute": "🖖", "fire": "🔥"], aliases: ["salute": "🫡"])
        XCTAssertEqual(merged, ["salute": "🫡", "fire": "🔥"])
    }

    /// Every glyph that takes a skin tone takes each of the five.
    func testEveryModifierBaseTakesEverySkinTone() {
        let tones: [(String, Unicode.Scalar)] = [
            ("light", "\u{1F3FB}"), ("medium-light", "\u{1F3FC}"), ("medium", "\u{1F3FD}"),
            ("medium-dark", "\u{1F3FE}"), ("dark", "\u{1F3FF}"),
        ]
        var checked = 0
        for (key, glyph) in EmojiTable.triggers
        where key.count >= EmojiTable.minimumLength && key != "korea"
            && glyph.unicodeScalars.first?.properties.isEmojiModifierBase == true {
            for (name, tone) in tones {
                let output = SpokenEmoji.glyphs(in: "\(key) \(name) skin tone emoji")
                XCTAssertEqual(Array(output.unicodeScalars).dropFirst().first, tone, "\(key) \(name) → \(output)")
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 50)
    }

    /// A count repeats exactly, and never past the maximum.
    func testCountsRepeatExactly() {
        for count in 2...SpokenEmoji.maximumRepeat {
            XCTAssertEqual(SpokenEmoji.glyphs(in: "\(count) fire emojis"), String(repeating: "🔥", count: count))
            XCTAssertEqual(SpokenEmoji.glyphs(in: "fire emoji x\(count)"), String(repeating: "🔥", count: count))
        }
        let tooMany = "\(SpokenEmoji.maximumRepeat + 1) fire emojis"
        XCTAssertEqual(SpokenEmoji.glyphs(in: tooMany), tooMany)
    }

    // MARK: - Helpers

    private static func plainLines() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/spoken-forms-plain.txt")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasPrefix("#") }
    }

    /// `value` as SpokenNumbers writes it.
    static func written(_ value: Int) -> String {
        guard value >= SpokenNumbers.groupingThreshold else { return String(value) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// A reference speller, the way an American speech model writes numbers:
    /// "one hundred twenty three thousand four hundred five".
    static func spell(_ value: Int, hyphenated: Bool = false) -> String {
        let units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
                     "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
                     "seventeen", "eighteen", "nineteen"]
        let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        func belowThousand(_ n: Int) -> [String] {
            var words: [String] = []
            if n >= 100 { words += [units[n / 100], "hundred"] }
            let rest = n % 100
            if rest >= 20 {
                let ten = tens[rest / 10]
                if rest % 10 == 0 {
                    words.append(ten)
                } else if hyphenated {
                    words.append("\(ten)-\(units[rest % 10])")
                } else {
                    words += [ten, units[rest % 10]]
                }
            } else if rest > 0 || words.isEmpty {
                words.append(units[rest])
            }
            return words
        }
        guard value > 0 else { return "zero" }
        var words: [String] = []
        var remaining = value
        for (scale, name) in [(1_000_000_000, "billion"), (1_000_000, "million"), (1_000, "thousand")] {
            if remaining >= scale {
                words += belowThousand(remaining / scale) + [name]
                remaining %= scale
            }
        }
        if remaining > 0 { words += belowThousand(remaining) }
        return words.joined(separator: " ")
    }
}
