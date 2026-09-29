// StructuralCommandProseTests.swift
// VocaMac
//
// The negative corpus for the three writing-style rules that are not part of
// `SpokenSymbolTransformer`: newline commands, list markers, and emphasis.
//
// Every phrase these rules key off — "new line", "bullet", "bold" — is also
// ordinary English, and unlike a symbol substitution a misfire here *deletes*
// the spoken word, so the user cannot see what happened. `SpokenSymbolTransformerTests`
// carries the same kind of corpus for the symbol rules; this is its counterpart.

import XCTest
@testable import VocaMac

final class StructuralCommandProseTests: XCTestCase {

    // MARK: - Newline commands

    /// Sentences that contain "new line" / "new paragraph" as a noun phrase.
    func testProseKeepsItsNewlineWords() {
        let prose = [
            "draw a new line on the chart",
            "that new paragraph reads better",
            "new line of thinking here",
            "the next line is the chorus",
            "add another new line to the drawing",
            "every new line costs us a token",
            "my new paragraph is the weakest one",
            "new lines are hard to review",
            "the new paragraph between the tables",
            "this new line looks wrong"
        ]
        for sentence in prose {
            XCTAssertEqual(
                WritingStyleEngine.applyNewlineCommands(sentence),
                sentence,
                "prose was rewritten: \(sentence)"
            )
        }
    }

    /// The command forms still fire, so the guard did not simply disable them.
    func testCommandFormsStillFire() {
        XCTAssertEqual(
            WritingStyleEngine.applyNewlineCommands("ship it new line then rest"),
            "ship it\nthen rest"
        )
        XCTAssertEqual(
            WritingStyleEngine.applyNewlineCommands("intro new paragraph body"),
            "intro\n\nbody"
        )
        // A cue word the guard deliberately does not block: real content can
        // start with a preposition.
        XCTAssertEqual(
            WritingStyleEngine.applyNewlineCommands("check it new line in the config"),
            "check it\nin the config"
        )
    }

    // MARK: - List markers

    /// A single leading keyword is not evidence that a list was dictated.
    func testLoneLeadingKeywordIsNotAList() {
        let prose = [
            "bullet proof vest",
            "list item pricing was wrong",
            "bullet points are useful",
            "bullet point three is the weak one",
            "new bullet trains run on time"
        ]
        for sentence in prose {
            XCTAssertEqual(
                WritingStyleEngine.applyListMarkers(sentence),
                sentence,
                "prose was rewritten: \(sentence)"
            )
        }
    }

    /// Two or more marked lines are a list, which is how dictating one works:
    /// "bullet buy milk new line bullet buy eggs".
    func testRepeatedKeywordsMarkAList() {
        XCTAssertEqual(
            WritingStyleEngine.applyListMarkers("bullet buy milk\nbullet buy eggs"),
            "- buy milk\n- buy eggs"
        )
        XCTAssertEqual(
            WritingStyleEngine.applyListMarkers("list item one\nbullet point two\nnew bullet three"),
            "- one\n- two\n- three"
        )
    }

    /// Unmarked lines around the list are untouched.
    func testUnmarkedLinesSurvive() {
        XCTAssertEqual(
            WritingStyleEngine.applyListMarkers("shopping\nbullet milk\nbullet eggs\nthanks"),
            "shopping\n- milk\n- eggs\nthanks"
        )
    }

    // MARK: - Emphasis

    /// Sentences that open with an emphasis word used as adjective or subject.
    func testProseKeepsItsEmphasisWords() {
        let prose = [
            "bold move by the team",
            "bold claims need evidence",
            "italic text is hard to read",
            "strikethrough is a formatting option",
            "bold and italic are both fine",
            "italic font looks better here",
            "bold statement from the CEO",
            "bold decision but the right one"
        ]
        for sentence in prose {
            for dialect in [EmphasisDialect.markdown, .slackMrkdwn] {
                XCTAssertEqual(
                    WritingStyleEngine.applyEmphasis(sentence, dialect: dialect),
                    sentence,
                    "prose was rewritten: \(sentence) [\(dialect.rawValue)]"
                )
            }
        }
    }

    /// The implicit and explicit command forms both still work.
    func testEmphasisCommandFormsStillFire() {
        XCTAssertEqual(
            WritingStyleEngine.applyEmphasis("bold ship this today", dialect: .markdown),
            "**ship this today**"
        )
        XCTAssertEqual(
            WritingStyleEngine.applyEmphasis("bold ship this today", dialect: .slackMrkdwn),
            "*ship this today*"
        )
        // An explicit close is proof on its own, so the denylist is bypassed:
        // "bold move" is emphasised here because the user said where it ends.
        XCTAssertEqual(
            WritingStyleEngine.applyEmphasis("that was a bold move end bold really", dialect: .markdown),
            "that was a **move** really"
        )
        XCTAssertEqual(
            WritingStyleEngine.applyEmphasis("start bold ship it end bold now", dialect: .markdown),
            "**ship it** now"
        )
    }

    // MARK: - End to end

    /// The same prose through the real style pipeline, which is where a
    /// misfire would actually reach the user.
    func testProseSurvivesTheStyledPipeline() {
        let cases: [(text: String, style: WritingStyle, expected: String)] = [
            ("draw a new line on the chart", .chat, "Draw a new line on the chart"),
            ("that new paragraph reads better", .email, "That new paragraph reads better."),
            ("bullet proof vest", .slack, "Bullet proof vest"),
            ("list item pricing was wrong", .slack, "List item pricing was wrong"),
            ("bold move by the team", .slack, "Bold move by the team"),
            ("strikethrough is a formatting option", .notes, "Strikethrough is a formatting option"),
            ("italic text is hard to read", .email, "Italic text is hard to read.")
        ]
        for testCase in cases {
            XCTAssertEqual(
                WritingStyleEngine.format(
                    testCase.text,
                    style: testCase.style,
                    globalAutoCapitalize: true,
                    globalTrailingSpace: false
                ),
                testCase.expected,
                "prose was rewritten: \(testCase.text)"
            )
        }
    }
}
