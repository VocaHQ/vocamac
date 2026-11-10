// WordErrorRateTests.swift
// VocaMac

import XCTest
@testable import VocaMac

final class WordErrorRateTests: XCTestCase {

    func testIdenticalTextHasNoErrors() {
        let result = WordErrorRate.measure(reference: "the quick brown fox", hypothesis: "the quick brown fox")
        XCTAssertEqual(result, WordErrorRate(substitutions: 0, deletions: 0, insertions: 0, referenceWords: 4))
        XCTAssertEqual(result.rate, 0)
    }

    func testCountsSubstitutionDeletionAndInsertion() {
        XCTAssertEqual(
            WordErrorRate.measure(reference: "the quick brown fox", hypothesis: "the quack brown fox"),
            WordErrorRate(substitutions: 1, deletions: 0, insertions: 0, referenceWords: 4)
        )
        XCTAssertEqual(
            WordErrorRate.measure(reference: "the quick brown fox", hypothesis: "the brown fox"),
            WordErrorRate(substitutions: 0, deletions: 1, insertions: 0, referenceWords: 4)
        )
        XCTAssertEqual(
            WordErrorRate.measure(reference: "the quick brown fox", hypothesis: "the very quick brown fox"),
            WordErrorRate(substitutions: 0, deletions: 0, insertions: 1, referenceWords: 4)
        )
    }

    func testMixedEditsUseTheMinimumAlignment() {
        // Dropping "b" and adding "e" (2 edits) beats three substitutions.
        let shifted = WordErrorRate.measure(reference: "a b c d", hypothesis: "a c d e")
        XCTAssertEqual(shifted, WordErrorRate(substitutions: 0, deletions: 1, insertions: 1, referenceWords: 4))
        XCTAssertEqual(shifted.rate, 0.5, accuracy: 1e-9)

        // Equal-cost alignments prefer substitutions: three either way.
        let tied = WordErrorRate.measure(reference: "a b c d e", hypothesis: "a x c e f")
        XCTAssertEqual(tied.errors, 3)
        XCTAssertEqual(tied.substitutions, 3)
        XCTAssertEqual(tied.rate, 0.6, accuracy: 1e-9)
    }

    func testDroppedTailCountsEveryMissingWord() {
        // The kind of loss a clipped final window causes.
        let result = WordErrorRate.measure(
            reference: "please send the report to Namrata by Friday",
            hypothesis: "Please send the report to Namrata."
        )
        XCTAssertEqual(result, WordErrorRate(substitutions: 0, deletions: 2, insertions: 0, referenceWords: 8))
    }

    func testEmptyCases() {
        XCTAssertEqual(WordErrorRate.measure(reference: "", hypothesis: ""), .zero)
        XCTAssertEqual(WordErrorRate.measure(reference: "", hypothesis: "").rate, 0)

        let silenceHallucination = WordErrorRate.measure(reference: "", hypothesis: "Thank you.")
        XCTAssertEqual(silenceHallucination.insertions, 2)
        XCTAssertEqual(silenceHallucination.rate, 2)

        let empty = WordErrorRate.measure(reference: "hello there", hypothesis: "  ")
        XCTAssertEqual(empty, WordErrorRate(substitutions: 0, deletions: 2, insertions: 0, referenceWords: 2))
        XCTAssertEqual(empty.rate, 1)
    }

    func testNormalizationIgnoresCasePunctuationAndQuotes() {
        XCTAssertEqual(
            WordErrorRate.normalizedWords("Hello, World! Don\u{2019}t \u{201C}panic\u{201D}."),
            ["hello", "world", "don't", "panic"]
        )
        XCTAssertEqual(WordErrorRate.normalizedWords("Wi-Fi on/off"), ["wi", "fi", "on", "off"])
        XCTAssertEqual(WordErrorRate.normalizedWords("'quoted' words"), ["quoted", "words"])
        XCTAssertEqual(WordErrorRate.normalizedWords("end.Next"), ["end", "next"])
        XCTAssertEqual(WordErrorRate.normalizedWords("version 3.5"), ["version", "3", "5"])
        XCTAssertEqual(WordErrorRate.normalizedWords("1,000 users, 50% off"), ["1000", "users", "50", "percent", "off"])
        XCTAssertEqual(
            WordErrorRate.measure(reference: "Ship it, Jatin.", hypothesis: "ship it jatin").errors,
            0
        )
    }

    func testNumberSpellingIsNotAnError() {
        XCTAssertEqual(WordErrorRate.measure(reference: "three apples", hypothesis: "3 apples").errors, 0)
        XCTAssertEqual(WordErrorRate.measure(reference: "twenty one guests", hypothesis: "21 guests").errors, 0)
        XCTAssertEqual(WordErrorRate.measure(reference: "version three point five", hypothesis: "version 3.5").errors, 0)
        XCTAssertEqual(WordErrorRate.measure(reference: "fifty percent", hypothesis: "50%").errors, 0)
        XCTAssertEqual(WordErrorRate.measure(reference: "the twenty first", hypothesis: "the 21st").errors, 0)
        // A different number is still an error.
        XCTAssertEqual(WordErrorRate.measure(reference: "three apples", hypothesis: "4 apples").substitutions, 1)
        // Folding can be turned off.
        XCTAssertEqual(WordErrorRate.normalizedWords("three apples", foldsNumbers: false), ["three", "apples"])
    }

    func testCharacterErrorRateForUnspacedScripts() {
        XCTAssertEqual(WordErrorRate.unit(for: "今日は良い天気です"), .characters)
        XCTAssertEqual(WordErrorRate.unit(for: "สวัสดีครับ"), .characters)
        XCTAssertEqual(WordErrorRate.unit(for: "the weather is nice"), .words)
        XCTAssertEqual(WordErrorRate.unit(for: "안녕하세요 반갑습니다"), .words)
        XCTAssertEqual(WordErrorRate.unit(for: ""), .words)

        let cer = WordErrorRate.measure(reference: "今日は良い天気です。", hypothesis: "今日は良い電気です", unit: .characters)
        XCTAssertEqual(cer, WordErrorRate(substitutions: 1, deletions: 0, insertions: 0, referenceWords: 9))
        XCTAssertEqual(WordErrorRate.characterUnits("A b, C"), ["a", "b", "c"])
    }

    func testSurfaceWordsKeepCaseAndTrailingMarks() {
        let words = WordErrorRate.surfaceWords("Hello, World! Is it \u{201C}done\u{201D}? Yes.")
        XCTAssertEqual(words.map(\.text), ["Hello", "World", "Is", "it", "done", "Yes"])
        XCTAssertEqual(words.map(\.trailingMark), [",", "!", nil, nil, "?", "."])
        XCTAssertEqual(words.map(\.isCapitalized), [true, true, true, false, false, true])
    }

    func testAggregateWeighsByReferenceWords() {
        let short = WordErrorRate.measure(reference: "yes", hypothesis: "no")
        let long = WordErrorRate.measure(
            reference: "one two three four five six seven eight nine",
            hypothesis: "one two three four five six seven eight nine"
        )
        let corpus = [short, long].reduce(.zero, +)
        XCTAssertEqual(corpus.referenceWords, 10)
        XCTAssertEqual(corpus.errors, 1)
        XCTAssertEqual(corpus.rate, 0.1, accuracy: 1e-9)
    }
}
