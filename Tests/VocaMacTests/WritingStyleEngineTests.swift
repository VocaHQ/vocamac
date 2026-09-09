// WritingStyleEngineTests.swift
// VocaMac
//
// End-to-end pipeline behavior per style, plus the fixture corpus.

import XCTest
@testable import VocaMac

final class WritingStyleEngineTests: XCTestCase {

    private func format(_ text: String, _ style: WritingStyle, capitalize: Bool = true, space: Bool = true) -> String {
        WritingStyleEngine.format(
            text,
            style: style,
            globalAutoCapitalize: capitalize,
            globalTrailingSpace: space
        )
    }

    // MARK: - Plain preserves today's behavior

    func testPlainMatchesGlobalPolish() {
        let text = "hello there. this is fine"
        let viaStyle = format(text, .plain)
        let viaFormatter = DictationOutputFormatter.apply(
            text,
            autoCapitalize: true,
            appendTrailingSpace: true
        )
        XCTAssertEqual(viaStyle, viaFormatter)
    }

    func testPlainDoesNotShapeSpokenSymbols() {
        XCTAssertEqual(
            format("open config dot json", .plain, capitalize: false, space: false),
            "open config dot json"
        )
    }

    func testPassthroughRulesChangeNothingButGlobals() {
        let result = WritingStyleEngine.format(
            "the dot product is fine",
            rules: .passthrough,
            globalAutoCapitalize: false,
            globalTrailingSpace: false
        )
        XCTAssertEqual(result, "the dot product is fine")
    }

    // MARK: - Code

    func testCodeStyleProducesFilenameWithoutSentenceCase() {
        XCTAssertEqual(format("open config dot json", .code), "open config.json")
    }

    func testCodeStyleNeverAddsTrailingSpace() {
        // A trailing space in a source file is trailing whitespace, which is
        // exactly what every linter in the editor is there to complain about.
        XCTAssertEqual(format("run the build", .code, space: true), "run the build")
    }

    func testCodeStyleStripsTrailingPeriod() {
        XCTAssertEqual(format("run the tests.", .code, space: false), "run the tests")
    }

    func testCodeStyleTrimsLeadingFiller() {
        XCTAssertEqual(format("um so run the build", .code, space: false), "run the build")
    }

    func testCodeStyleDoesNotCapitalize() {
        XCTAssertEqual(format("handle the error", .code, space: false), "handle the error")
    }

    // MARK: - Terminal

    func testTerminalStyleNeverAddsTrailingSpace() {
        XCTAssertEqual(format("cd src slash utils", .terminal), "cd src/utils")
    }

    func testTerminalStyleStripsPeriod() {
        XCTAssertEqual(format("git status.", .terminal), "git status")
    }

    // MARK: - Chat

    func testChatStyleCapitalizesAndLeavesPunctuationAlone() {
        XCTAssertEqual(format("let's ship it", .chat, space: false), "Let's ship it")
    }

    func testChatStyleDoesNotShapeCode() {
        XCTAssertEqual(format("the dot product again", .chat, space: false), "The dot product again")
    }

    func testChatStyleIgnoresSlashes() {
        XCTAssertEqual(format("open src slash utils", .chat, space: false), "Open src slash utils")
    }

    // MARK: - Slack

    func testSlackUsesSingleAsteriskBold() {
        XCTAssertEqual(format("bold ship this today", .slack, space: false), "*Ship this today*")
    }

    func testSlackBulletMarker() {
        XCTAssertEqual(
            format("bullet fix the tests new line bullet ship it", .slack, space: false),
            "- Fix the tests\n- Ship it"
        )
    }

    // MARK: - Email

    func testEmailEnsuresTerminalPeriod() {
        XCTAssertEqual(format("thanks for the update", .email, space: false), "Thanks for the update.")
    }

    func testEmailDoesNotDoublePunctuate() {
        XCTAssertEqual(format("are you free tomorrow?", .email, space: false), "Are you free tomorrow?")
    }

    func testEmailPunctuatesBeforeATrailingNewline() {
        XCTAssertEqual(format("hello new line", .email, space: false), "Hello.\n")
    }

    func testEmailPunctuatesBeforeATrailingParagraph() {
        XCTAssertEqual(format("hello new paragraph", .email, space: false), "Hello.\n\n")
    }

    // MARK: - Notes

    func testNotesUsesMarkdownBold() {
        XCTAssertEqual(format("bold read this first", .notes, space: false), "**Read this first**")
    }

    func testNotesShapesFilenames() {
        XCTAssertEqual(format("see readme dot md", .notes, space: false), "See readme.md")
    }

    // MARK: - Structural commands

    func testNewParagraphCommand() {
        let result = WritingStyleEngine.applyNewlineCommands("first thought new paragraph second thought")
        XCTAssertEqual(result, "first thought\n\nsecond thought")
    }

    func testNewLineCommand() {
        let result = WritingStyleEngine.applyNewlineCommands("line one new line line two")
        XCTAssertEqual(result, "line one\nline two")
    }

    func testNewParagraphIsNotEatenByNewLine() {
        // Neutral placeholder words: a literal "a"/"b" would be read as the
        // determiner that suppresses the command.
        let result = WritingStyleEngine.applyNewlineCommands("alpha new paragraph beta new line gamma")
        XCTAssertEqual(result, "alpha\n\nbeta\ngamma")
    }

    func testBulletMarkersApplyPerLine() {
        let result = WritingStyleEngine.applyListMarkers("bullet first\nbullet second")
        XCTAssertEqual(result, "- first\n- second")
    }

    func testBulletWithNoBodyIsLeftAlone() {
        XCTAssertEqual(WritingStyleEngine.applyListMarkers("bullet"), "bullet")
    }

    // MARK: - Emphasis

    func testBoldOnlyFiresAtLineStart() {
        // "a bold move" must not become "a **move**".
        XCTAssertEqual(
            WritingStyleEngine.applyEmphasis("that was a bold move", dialect: .markdown),
            "that was a bold move"
        )
    }

    func testExplicitEndBoldSpanWorksMidSentence() {
        XCTAssertEqual(
            WritingStyleEngine.applyEmphasis("please make bold this part end bold now", dialect: .markdown),
            "please make **this part** now"
        )
    }

    func testEmphasisOffIsAPassthrough() {
        XCTAssertEqual(
            WritingStyleEngine.applyEmphasis("bold ship it", dialect: .none),
            "bold ship it"
        )
    }

    // MARK: - Filler

    func testLeadingFillerTrimmed() {
        XCTAssertEqual(WritingStyleEngine.trimLeadingFiller("um so let's go"), "let's go")
    }

    func testMidSentenceFillerKept() {
        XCTAssertEqual(WritingStyleEngine.trimLeadingFiller("we should so do it"), "we should so do it")
    }

    func testFillerOnlyUtteranceIsNotEmptied() {
        XCTAssertEqual(WritingStyleEngine.trimLeadingFiller("okay"), "okay")
    }

    // MARK: - Policy resolution

    func testInheritCapitalizationFollowsGlobal() {
        XCTAssertEqual(format("hello there", .plain, capitalize: false, space: false), "hello there")
        XCTAssertEqual(format("hello there", .plain, capitalize: true, space: false), "Hello there")
    }

    func testInheritTrailingSpaceFollowsGlobal() {
        XCTAssertEqual(format("hello", .plain, capitalize: false, space: true), "hello ")
        XCTAssertEqual(format("hello", .plain, capitalize: false, space: false), "hello")
    }

    func testStyleOverridesGlobalTrailingSpace() {
        // Terminal forces the space off even when the global preference is on.
        XCTAssertEqual(format("ls", .terminal, capitalize: false, space: true), "ls")
    }

    func testStyleOverridesGlobalCapitalization() {
        // Code forces capitalization off even when the global preference is on.
        XCTAssertEqual(format("handle it", .code, capitalize: true, space: false), "handle it")
    }

    // MARK: - Edge cases

    func testEmptyInputIsUnchangedForEveryStyle() {
        for style in WritingStyle.allCases {
            XCTAssertEqual(format("", style), "", "\(style.rawValue) changed empty input")
        }
    }

    func testSingleWordSurvivesEveryStyle() {
        for style in WritingStyle.allCases {
            let result = format("okay", style, capitalize: false, space: false)
            XCTAssertFalse(result.isEmpty, "\(style.rawValue) emptied a single-word utterance")
        }
    }

    func testVeryLongInputIsHandled() {
        let long = Array(repeating: "word", count: 2000).joined(separator: " ")
        for style in WritingStyle.allCases {
            XCTAssertFalse(format(long, style).isEmpty)
        }
    }

    func testIdempotenceAcrossStyles() {
        let samples = [
            "open config dot json",
            "edit src slash components slash button dot tsx",
            "bold ship this today",
            "thanks for the update",
            "camel case handle user input"
        ]
        for style in WritingStyle.allCases {
            for sample in samples {
                let once = format(sample, style, capitalize: true, space: false)
                let twice = format(once, style, capitalize: true, space: false)
                XCTAssertEqual(once, twice, "\(style.rawValue) is not idempotent on '\(sample)'")
            }
        }
    }

    // MARK: - Fixture corpus

    /// One-line additions when a new case is found in the wild.
    func testFixtureCorpus() {
        let fixtures: [(spoken: String, style: WritingStyle, expected: String)] = [
            ("open my file dot md", .code, "open myfile.md"),
            ("compare readme dot md and config dot yaml", .code, "compare readme.md and config.yaml"),
            ("the dot product of the vectors", .code, "the dot product of the vectors"),
            ("visit example dot com", .code, "visit example dot com"),
            ("cd src slash utils", .terminal, "cd src/utils"),
            ("that was slash and burn", .code, "that was slash and burn"),
            ("snake case max retry count", .code, "max_retry_count"),
            ("let's ship it", .chat, "Let's ship it"),
            ("bold this is important", .slack, "*This is important*"),
            ("bold this is important", .notes, "**This is important**"),
            ("i will send it over", .email, "I will send it over."),
            ("see readme dot md for details", .notes, "See readme.md for details")
        ]

        for fixture in fixtures {
            let result = format(fixture.spoken, fixture.style, capitalize: true, space: false)
            XCTAssertEqual(
                result,
                fixture.expected,
                "style \(fixture.style.rawValue) on '\(fixture.spoken)'"
            )
        }
    }
}
