// TerminalPunctuationTests.swift
// VocaMac
//
// Terminal punctuation across scripts. A speech engine transcribing Hindi
// emits a danda and one transcribing Chinese emits an ideographic full stop;
// an ASCII-only rule reads both as unpunctuated and bolts a second, wrong mark
// onto the sentence.

import XCTest
@testable import VocaMac

final class TerminalPunctuationTests: XCTestCase {

    // MARK: - Already punctuated, in any script

    func testExistingTerminalPunctuationIsNeverDoubled() {
        let alreadyEnded = [
            "Thanks.", "Done!", "Really?", "Note:", "Wait;",
            "धन्यवाद।",          // Devanagari danda
            "यह पूरा हुआ॥",        // Devanagari double danda
            "شكرا لك۔",          // Arabic full stop
            "هل هذا صحيح؟",       // Arabic question mark
            "谢谢。",             // Ideographic full stop
            "已完成！",            // Fullwidth exclamation
            "完成了？",            // Fullwidth question
            "ありがとう。",
            "Ուրեմն։"            // Armenian full stop
        ]
        for text in alreadyEnded {
            XCTAssertEqual(
                DictationOutputFormatter.ensureTerminalPeriod(text),
                text,
                "punctuation was doubled: \(text)"
            )
        }
    }

    func testClosingQuotesAndBracketsEndASentence() {
        for text in ["He said \"hello\"", "He said “hello”", "(as noted)", "見た「そう」"] {
            XCTAssertEqual(DictationOutputFormatter.ensureTerminalPeriod(text), text)
        }
    }

    // MARK: - Unpunctuated

    func testLatinScriptsGainAPeriod() {
        XCTAssertEqual(DictationOutputFormatter.ensureTerminalPeriod("thanks"), "thanks.")
        XCTAssertEqual(DictationOutputFormatter.ensureTerminalPeriod("merci beaucoup"), "merci beaucoup.")
        XCTAssertEqual(DictationOutputFormatter.ensureTerminalPeriod("спасибо"), "спасибо.")
        XCTAssertEqual(DictationOutputFormatter.ensureTerminalPeriod("ευχαριστώ"), "ευχαριστώ.")
        XCTAssertEqual(DictationOutputFormatter.ensureTerminalPeriod("cảm ơn"), "cảm ơn.")
    }

    /// No language signal reaches this rule, so guessing that a Hindi or
    /// Chinese sentence wants an ASCII period is a visible error. Leaving the
    /// sentence as dictated is the recoverable answer.
    func testNonLatinScriptsAreLeftUnpunctuated() {
        let unpunctuated = ["यह एक वाक्य है", "شكرا لك", "谢谢", "ありがとう", "감사합니다", "ขอบคุณ"]
        for text in unpunctuated {
            XCTAssertEqual(
                DictationOutputFormatter.ensureTerminalPeriod(text),
                text,
                "an ASCII period was invented for: \(text)"
            )
        }
    }

    func testEmailStyleHonoursTheSameRule() {
        func email(_ text: String) -> String {
            WritingStyleEngine.format(
                text, style: .email,
                globalAutoCapitalize: false, globalTrailingSpace: false
            )
        }
        XCTAssertEqual(email("धन्यवाद।"), "धन्यवाद।")
        XCTAssertEqual(email("यह एक वाक्य है"), "यह एक वाक्य है")
        XCTAssertEqual(email("谢谢。"), "谢谢。")
        XCTAssertEqual(email("thanks"), "Thanks.", "Email capitalizes as well as punctuating")
    }

    // MARK: - Trailing line endings

    /// A structural command leaves "run tests.\n", and the period is still the
    /// thing Code style must remove.
    func testStrippingSurvivesATrailingNewline() {
        XCTAssertEqual(DictationOutputFormatter.stripTrailingPeriod("run tests."), "run tests")
        XCTAssertEqual(DictationOutputFormatter.stripTrailingPeriod("run tests.\n"), "run tests\n")
        XCTAssertEqual(DictationOutputFormatter.stripTrailingPeriod("run tests.\n\n"), "run tests\n\n")
        XCTAssertEqual(DictationOutputFormatter.stripTrailingPeriod("run tests.\r\n"), "run tests\r\n")
    }

    func testEllipsisAndBareTextAreLeftAlone() {
        XCTAssertEqual(DictationOutputFormatter.stripTrailingPeriod("wait..."), "wait...")
        XCTAssertEqual(DictationOutputFormatter.stripTrailingPeriod("wait...\n"), "wait...\n")
        XCTAssertEqual(DictationOutputFormatter.stripTrailingPeriod("run tests"), "run tests")
        XCTAssertEqual(DictationOutputFormatter.stripTrailingPeriod("."), ".")
    }

    func testCodeStyleStripsThePeriodBeforeALineBreak() {
        XCTAssertEqual(
            WritingStyleEngine.format(
                "run tests. new line", style: .code,
                globalAutoCapitalize: false, globalTrailingSpace: false
            ),
            "run tests\n"
        )
    }

    func testEnsurePeriodStillPlacesItBeforeTheLineBreak() {
        XCTAssertEqual(
            WritingStyleEngine.format(
                "ship it new line", style: .email,
                globalAutoCapitalize: false, globalTrailingSpace: false
            ),
            "Ship it.\n"
        )
    }
}
