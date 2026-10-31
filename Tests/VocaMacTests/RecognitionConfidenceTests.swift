// RecognitionConfidenceTests.swift
// VocaMac

import XCTest
@testable import VocaMac

final class RecognitionConfidenceTests: XCTestCase {

    private func word(_ text: String, _ probability: Double?) -> TimedWord {
        TimedWord(word: text, start: 0, end: 0, probability: probability)
    }

    func testNoConfidenceMeansNil() {
        let segment = TimedSegment(start: 0, end: 1, text: "hello there", words: [word("hello", nil), word("there", nil)])
        XCTAssertNil(RecognitionConfidence.lowConfidenceWords(in: [segment]))
        XCTAssertNil(RecognitionConfidence.lowConfidenceWords(in: []))
    }

    func testCollectsUnsureWordsNormalized() {
        let segment = TimedSegment(start: 0, end: 2, text: "Deploy to cooper netties,", words: [
            word(" Deploy", 0.97), word(" to", 0.99), word(" cooper", 0.41), word(" netties,", 0.32),
        ])
        XCTAssertEqual(RecognitionConfidence.lowConfidenceWords(in: [segment]), ["cooper", "netties"])
    }

    /// One unsure "pie" must not let a confidently heard "pie torch"
    /// elsewhere become PyTorch.
    func testAWordHeardOnceSureIsNeverUnsure() {
        let segment = TimedSegment(start: 0, end: 3, text: "pie for dessert then pie torch", words: [
            word(" pie", 0.31), word(" for", 0.98), word(" dessert", 0.97), word(" then", 0.99),
            word(" pie", 0.96), word(" torch", 0.95),
        ])
        let unsure = RecognitionConfidence.lowConfidenceWords(in: [segment])
        XCTAssertEqual(unsure, [])

        let context = DictionaryContext(
            vocabulary: ["PyTorch"], replacements: [], contextTerms: [],
            isKnownWord: { ["pie", "for", "dessert", "then", "torch"].contains($0) },
            lowConfidenceWords: unsure
        )
        let corrected = DictionaryCorrector.correct(
            "pie for dessert then pie torch", context: context, allowIdentifierJoins: false
        )
        XCTAssertEqual(corrected.text, "pie for dessert then pie torch")
    }

    func testSureOfEverythingIsAnEmptySet() {
        let segment = TimedSegment(start: 0, end: 1, text: "yes", words: [word("yes", 0.95)])
        XCTAssertEqual(RecognitionConfidence.lowConfidenceWords(in: [segment]), [])
    }
}
