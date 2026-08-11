// DictationOutputFormatterTests.swift
// VocaMac Tests
//
// Edge-case coverage for trailing space and sentence capitalization polish.

import XCTest
@testable import VocaMac

final class DictationOutputFormatterTests: XCTestCase {

    // MARK: - Capitalize

    func testCapitalizeEmptyString() {
        XCTAssertEqual(DictationOutputFormatter.capitalizeSentences(""), "")
    }

    func testCapitalizeFirstLetter() {
        XCTAssertEqual(
            DictationOutputFormatter.capitalizeSentences("hello world"),
            "Hello world"
        )
    }

    func testCapitalizeAfterSentencePunctuation() {
        XCTAssertEqual(
            DictationOutputFormatter.capitalizeSentences("hello world. goodbye world"),
            "Hello world. Goodbye world"
        )
        XCTAssertEqual(
            DictationOutputFormatter.capitalizeSentences("what? really! yes. ok"),
            "What? Really! Yes. Ok"
        )
    }

    func testCapitalizeIsIdempotent() {
        let already = "Hello world. Goodbye"
        XCTAssertEqual(DictationOutputFormatter.capitalizeSentences(already), already)
    }

    func testCapitalizePreservesURLsAndDecimals() {
        XCTAssertEqual(
            DictationOutputFormatter.capitalizeSentences("visit example.com for info"),
            "Visit example.com for info"
        )
        XCTAssertEqual(
            DictationOutputFormatter.capitalizeSentences("the value is 3.14 exactly"),
            "The value is 3.14 exactly"
        )
    }

    func testCapitalizeAfterNewlineWhitespace() {
        XCTAssertEqual(
            DictationOutputFormatter.capitalizeSentences("first line.\nsecond line"),
            "First line.\nSecond line"
        )
    }

    // MARK: - Trailing space

    func testAppendTrailingSpaceEmpty() {
        XCTAssertEqual(DictationOutputFormatter.appendTrailingSpace(""), "")
    }

    func testAppendTrailingSpaceAddsSpace() {
        XCTAssertEqual(DictationOutputFormatter.appendTrailingSpace("Hello."), "Hello. ")
    }

    func testAppendTrailingSpaceSkipsExistingWhitespace() {
        XCTAssertEqual(DictationOutputFormatter.appendTrailingSpace("Hello. "), "Hello. ")
        XCTAssertEqual(DictationOutputFormatter.appendTrailingSpace("Hello.\t"), "Hello.\t")
    }

    func testAppendTrailingSpaceSkipsTrailingNewline() {
        XCTAssertEqual(DictationOutputFormatter.appendTrailingSpace("Hello.\n"), "Hello.\n")
        XCTAssertEqual(DictationOutputFormatter.appendTrailingSpace("para\n\n"), "para\n\n")
    }

    // MARK: - Apply

    func testApplyBothFlags() {
        XCTAssertEqual(
            DictationOutputFormatter.apply(
                "hello world. goodbye",
                autoCapitalize: true,
                appendTrailingSpace: true
            ),
            "Hello world. Goodbye "
        )
    }

    func testApplyFlagsOffIsIdentity() {
        let text = "hello world"
        XCTAssertEqual(
            DictationOutputFormatter.apply(
                text,
                autoCapitalize: false,
                appendTrailingSpace: false
            ),
            text
        )
    }

    func testApplyCapitalizeOnly() {
        XCTAssertEqual(
            DictationOutputFormatter.apply(
                "hello. there",
                autoCapitalize: true,
                appendTrailingSpace: false
            ),
            "Hello. There"
        )
    }

    func testApplyTrailingSpaceOnly() {
        XCTAssertEqual(
            DictationOutputFormatter.apply(
                "hello",
                autoCapitalize: false,
                appendTrailingSpace: true
            ),
            "hello "
        )
    }
}
