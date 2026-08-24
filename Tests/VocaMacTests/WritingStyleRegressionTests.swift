// WritingStyleRegressionTests.swift
// VocaMac Tests
//
// One test per shipped writing-style bug. Each names the failure it locks out,
// so a future refactor that reintroduces it fails here rather than in a user's
// editor.

import XCTest
@testable import VocaMac

final class WritingStyleRegressionTests: XCTestCase {

    private func format(
        _ text: String,
        _ style: WritingStyle,
        capitalize: Bool = true,
        space: Bool = false
    ) -> String {
        WritingStyleEngine.format(
            text,
            style: style,
            globalAutoCapitalize: capitalize,
            globalTrailingSpace: space
        )
    }

    // MARK: - "literally" is a word before it is a command

    func testLiterallyInProseSurvivesEveryStyle() {
        for style in WritingStyle.allCases {
            let result = format("I literally cannot believe it", style)
            XCTAssertTrue(
                result.lowercased().contains("literally"),
                "\(style.rawValue) deleted the word 'literally'"
            )
        }
    }

    func testLiterallyStillEscapesACommandWord() {
        XCTAssertEqual(format("say config literally dot json", .code), "say config dot json")
    }

    func testLiterallyEscapesAGluedSymbolWord() {
        XCTAssertEqual(
            SpokenSymbolTransformer.apply(
                "say literally slashcomponents and slashbutton",
                tiers: .all,
                pathStitching: true,
                caseCommandsEnabled: true
            ),
            "say slashcomponents and slashbutton"
        )
    }

    func testTrailingLiterallyIsNotSwallowed() {
        // Nothing follows it, so it cannot be an escape.
        XCTAssertEqual(format("that is true literally", .plain), "That is true literally")
    }

    // MARK: - Untouched text keeps its own spacing

    func testUntouchedTextKeepsRunsOfSpaces() {
        XCTAssertEqual(format("hello  world", .plain, capitalize: false), "hello  world")
    }

    func testUntouchedTextKeepsTabs() {
        XCTAssertEqual(format("hello\tworld", .plain, capitalize: false), "hello\tworld")
    }

    // MARK: - Case commands stop at symbol words

    func testCaseCommandDoesNotSwallowTheFileExtension() {
        XCTAssertEqual(
            format("camel case handle user input dot swift", .code),
            "handleUserInput.swift"
        )
    }

    func testCaseCommandDoesNotSwallowAPathSeparator() {
        XCTAssertEqual(
            format("open snake case my module slash snake case my file", .code),
            "open my_module/my_file"
        )
    }

    // MARK: - Substitution preserves the case the engine produced

    func testFilenameKeepsItsCase() {
        XCTAssertEqual(format("open Info dot plist", .code), "open Info.plist")
        XCTAssertEqual(format("open README dot md", .code), "open README.md")
    }

    func testPathKeepsItsCase() {
        XCTAssertEqual(
            format("open Sources slash AppState dot swift", .code),
            "open Sources/AppState.swift"
        )
        XCTAssertEqual(
            format("edit Sources slash Views slash MenuBar", .code),
            "edit Sources/Views/MenuBar"
        )
    }

    func testIdentifierJoinerKeepsItsCase() {
        XCTAssertEqual(
            format("open config dot json and set maxRetries underscore Count", .code),
            "open config.json and set maxRetries_Count"
        )
    }

    // MARK: - Sentence case and generated identifiers

    func testCapitalizationDoesNotRenameAFilename() {
        XCTAssertEqual(format("readme dot md needs work", .notes), "readme.md needs work")
    }

    func testCapitalizationStillFiresAroundAFilename() {
        XCTAssertEqual(
            format("open readme dot md and edit it", .notes),
            "Open readme.md and edit it"
        )
    }

    // MARK: - Sentence case after a line break

    func testEachLineGetsSentenceCase() {
        XCTAssertEqual(
            format("hello there new paragraph regards", .email),
            "Hello there\n\nRegards."
        )
    }

    func testBulletLinesAreCapitalized() {
        XCTAssertEqual(
            format("bullet buy milk new line bullet buy eggs", .notes),
            "- Buy milk\n- Buy eggs"
        )
    }

    func testCapitalizeAfterNewlineIsIdempotent() {
        let once = DictationOutputFormatter.capitalizeSentences("first\nsecond")
        XCTAssertEqual(once, "First\nSecond")
        XCTAssertEqual(DictationOutputFormatter.capitalizeSentences(once), once)
    }

    // MARK: - The bare backtick is not a command

    func testBacktickInProseIsLeftAlone() {
        XCTAssertEqual(format("wrap it in a backtick", .plain), "Wrap it in a backtick")
    }

    // MARK: - Code style leaves no trailing whitespace

    func testCodeStyleIgnoresTheGlobalTrailingSpace() {
        XCTAssertEqual(format("run the build", .code, space: true), "run the build")
    }

    // MARK: - Every style stays idempotent after the fixes

    func testIdempotenceOnTheRegressionCorpus() {
        let samples = [
            "I literally cannot believe it",
            "camel case handle user input dot swift",
            "open Info dot plist",
            "readme dot md needs work",
            "hello there new paragraph regards",
            "wrap it in a backtick",
            "hello  world"
        ]
        for style in WritingStyle.allCases {
            for sample in samples {
                let once = format(sample, style)
                let twice = format(once, style)
                XCTAssertEqual(once, twice, "\(style.rawValue) is not idempotent on '\(sample)'")
            }
        }
    }
}
