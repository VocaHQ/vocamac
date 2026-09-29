// CorrectionLearnerTests.swift
// VocaMac

import XCTest
@testable import VocaMac

final class CorrectionLearnerTests: XCTestCase {

    private let isKnown: (String) -> Bool = { TestWords.common.contains($0.lowercased()) }

    private func learn(_ inserted: String, before: String, after: String, caret: Int? = nil) -> [CorrectionLearner.Correction] {
        CorrectionLearner.corrections(inserted: inserted, before: before, after: after,
                                      caretLocation: caret, isKnownWord: isKnown)
    }

    func testNameSpellingFix() {
        let corrections = learn("ask Namratha about it", before: "Hi. ask Namratha about it",
                                after: "Hi. ask Namrata about it")
        XCTAssertEqual(corrections, [.init(heard: "Namratha", corrected: "Namrata")])
    }

    func testCasingAndJoiningFix() {
        XCTAssertEqual(learn("push to git hub", before: "push to git hub", after: "push to GitHub"),
                       [.init(heard: "git hub", corrected: "GitHub")])
        XCTAssertEqual(learn("push to github", before: "push to github", after: "push to GitHub"),
                       [.init(heard: "github", corrected: "GitHub")])
    }

    func testSentenceCapitalizationIsNotATerm() {
        XCTAssertTrue(learn("hello world", before: "hello world", after: "Hello world").isEmpty)
    }

    func testCommonWordSwapIsIgnored() {
        XCTAssertTrue(learn("put it there", before: "put it there", after: "put it their").isEmpty)
    }

    func testRewordingIsIgnored() {
        XCTAssertTrue(learn("that is big", before: "that is big", after: "that is large").isEmpty)
    }

    func testEditOutsideTheDictationIsIgnored() {
        XCTAssertTrue(learn("ask Namratha", before: "Dear Bobb, ask Namratha", after: "Dear Bob, ask Namratha").isEmpty)
    }

    func testTextNotFoundIsIgnored() {
        XCTAssertTrue(learn("something else", before: "hello", after: "hullo").isEmpty)
    }

    func testCaretPicksTheCopyJustTyped() {
        let before = "ask Namratha. ask Namratha"
        let after = "ask Namratha. ask Namrata"
        XCTAssertEqual(learn("ask Namratha", before: before, after: after, caret: before.count),
                       [.init(heard: "Namratha", corrected: "Namrata")])
        // A caret at the first copy means the second edit wasn't in the dictation.
        XCTAssertTrue(learn("ask Namratha", before: before, after: after, caret: 12).isEmpty)
    }

    func testLargeRewriteIsIgnored() {
        let inserted = "one two three four five six seven eight nine ten eleven twelve thirteen"
        let after = "uno dos tres cuatro cinco seis siete ocho nueve diez once doce trece"
        XCTAssertTrue(learn(inserted, before: inserted, after: after).isEmpty)
    }
}

final class ScreenContextTermsTests: XCTestCase {

    private let isKnown: (String) -> Bool = { TestWords.common.contains($0.lowercased()) }

    func testExtractsIdentifiersAndNames() {
        let text = """
        func loadUser(userId: String) { let max_retries = 3 }
        Ping Namrata about the GitHub and OpenAI keys in api-client.
        """
        let terms = ScreenContextTerms.extract(from: text, isKnownWord: isKnown)
        XCTAssertTrue(terms.contains("loadUser"))
        XCTAssertTrue(terms.contains("userId"))
        XCTAssertTrue(terms.contains("max_retries"))
        XCTAssertTrue(terms.contains("Namrata"))
        XCTAssertTrue(terms.contains("GitHub"))
        XCTAssertTrue(terms.contains("OpenAI"))
        XCTAssertTrue(terms.contains("api-client"))
    }

    func testSkipsSentenceStartsAndOrdinaryCapitalizedWords() {
        let terms = ScreenContextTerms.extract(from: "Tomorrow we ship. Check the Apple notes.", isKnownWord: isKnown)
        XCTAssertFalse(terms.contains("Tomorrow"))
        XCTAssertFalse(terms.contains("Check"))
        XCTAssertFalse(terms.contains("Apple"))
    }

    func testDeduplicatesAndCaps() {
        let text = (0..<400).map { "varName\($0)" }.joined(separator: " ") + " varName0"
        let terms = ScreenContextTerms.extract(from: text, isKnownWord: isKnown)
        XCTAssertEqual(terms.count, ScreenContextTerms.maximumTerms)
        XCTAssertEqual(terms.first, "varName0")
    }
}
