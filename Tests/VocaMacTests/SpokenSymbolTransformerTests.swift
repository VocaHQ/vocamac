// SpokenSymbolTransformerTests.swift
// VocaMac
//
// The negative cases matter as much as the positive ones: this transformer
// runs on every utterance in Code and Terminal styles, and a rule that
// rewrites ordinary prose is worse than no rule at all.

import XCTest
@testable import VocaMac

final class SpokenSymbolTransformerTests: XCTestCase {

    private func tierA(_ text: String, pathStitching: Bool = true) -> String {
        SpokenSymbolTransformer.apply(text, tiers: .tierA, pathStitching: pathStitching, caseCommandsEnabled: true)
    }

    private func all(_ text: String, pathStitching: Bool = true) -> String {
        SpokenSymbolTransformer.apply(text, tiers: .all, pathStitching: pathStitching, caseCommandsEnabled: true)
    }

    // MARK: - Tier A: file extensions

    func testSpokenExtensionBecomesFilename() {
        XCTAssertEqual(tierA("open config dot json"), "open config.json")
    }

    func testMultiWordFilenameIsStitched() {
        XCTAssertEqual(tierA("open my file dot md"), "open myfile.md")
    }

    func testFilenameLookbackStopsAtBoundaryWord() {
        XCTAssertEqual(tierA("edit the config dot json"), "edit the config.json")
    }

    func testFilenameWithoutStitchingKeepsPrecedingWords() {
        XCTAssertEqual(tierA("open my file dot md", pathStitching: false), "open my file.md")
    }

    func testTrailingPunctuationSurvivesFilenameMerge() {
        XCTAssertEqual(tierA("check readme dot md, then stop"), "check readme.md, then stop")
    }

    func testSeveralFilenamesInOneUtterance() {
        XCTAssertEqual(
            tierA("compare readme dot md and config dot yaml"),
            "compare readme.md and config.yaml"
        )
    }

    // MARK: - Tier A: prose must survive

    func testDotProductIsNotAFilename() {
        XCTAssertEqual(tierA("compute the dot product first"), "compute the dot product first")
    }

    func testDotComIsNotAFilename() {
        XCTAssertEqual(tierA("visit example dot com today"), "visit example dot com today")
    }

    func testDotWithNoPrecedingWordIsUntouched() {
        XCTAssertEqual(tierA("dot md"), "dot md")
    }

    func testLiterallyEscapesSubstitution() {
        XCTAssertEqual(tierA("say config literally dot json"), "say config dot json")
    }

    // MARK: - Case commands

    func testCamelCase() {
        XCTAssertEqual(tierA("rename it to camel case handle user input"), "rename it to handleUserInput")
    }

    func testPascalCase() {
        XCTAssertEqual(tierA("pascal case user service"), "UserService")
    }

    func testSnakeCase() {
        XCTAssertEqual(tierA("snake case max retry count"), "max_retry_count")
    }

    func testKebabCase() {
        XCTAssertEqual(tierA("kebab case my new branch"), "my-new-branch")
    }

    func testScreamingSnakeCaseWinsOverSnakeCase() {
        XCTAssertEqual(tierA("screaming snake case api key"), "API_KEY")
    }

    func testCaseCommandStopsAtPunctuation() {
        XCTAssertEqual(tierA("camel case user name, then save"), "userName, then save")
    }

    func testCaseCommandWithNothingFollowingIsLeftSpoken() {
        XCTAssertEqual(tierA("camel case"), "camel case")
    }

    func testCaseCommandsDisabledLeavesTextAlone() {
        let result = SpokenSymbolTransformer.apply(
            "camel case handle user input",
            tiers: .tierA,
            pathStitching: true,
            caseCommandsEnabled: false
        )
        XCTAssertEqual(result, "camel case handle user input")
    }

    // MARK: - Bracket commands

    func testParenCommands() {
        XCTAssertEqual(tierA("call open paren value close paren"), "call (value)")
    }

    func testBacktickCommand() {
        XCTAssertEqual(tierA("wrap backtick here"), "wrap ` here")
    }

    // MARK: - Tier B: paths

    func testTwoSlashesFormAPath() {
        XCTAssertEqual(all("src slash components slash button"), "src/components/button")
    }

    func testSingleSlashWithPathCue() {
        XCTAssertEqual(all("open src slash utils"), "open src/utils")
    }

    func testSingleSlashInProseIsUntouched() {
        XCTAssertEqual(all("that was slash and burn"), "that was slash and burn")
    }

    func testPathCombinedWithExtension() {
        XCTAssertEqual(
            all("edit src slash components slash button dot tsx"),
            "edit src/components/button.tsx"
        )
    }

    func testTierBDisabledLeavesSlashesSpoken() {
        XCTAssertEqual(tierA("src slash components slash button"), "src slash components slash button")
    }

    // MARK: - Tier B: identifier joiners

    func testUnderscoreJoinsOnlyWithAnIdentifierSignal() {
        // No signal anywhere in the line — leave the spoken word alone.
        XCTAssertEqual(all("max underscore retries"), "max underscore retries")
    }

    func testUnderscoreJoinsAfterAnIdentifierSignal() {
        XCTAssertEqual(
            all("open config dot json and set max underscore retries"),
            "open config.json and set max_retries"
        )
    }

    func testDashInProseIsUntouchedWithoutSignal() {
        XCTAssertEqual(all("dash it all"), "dash it all")
    }

    // MARK: - Edge cases

    func testEmptyInput() {
        XCTAssertEqual(all(""), "")
    }

    func testWhitespaceOnlyInput() {
        XCTAssertEqual(all("   "), "   ")
    }

    func testNoTiersEnabledIsAPassthrough() {
        let result = SpokenSymbolTransformer.apply(
            "open config dot json",
            tiers: .none,
            pathStitching: true,
            caseCommandsEnabled: false
        )
        XCTAssertEqual(result, "open config dot json")
    }

    func testNewlinesArePreserved() {
        XCTAssertEqual(all("open config dot json\nedit readme dot md"), "open config.json\nedit readme.md")
    }

    func testIdempotence() {
        let once = all("edit src slash components slash button dot tsx")
        let twice = all(once)
        XCTAssertEqual(once, twice)
    }

    // MARK: - Helpers

    func testSplitTrailingPunctuation() {
        XCTAssertEqual(SpokenSymbolTransformer.splitTrailingPunctuation("json,").core, "json")
        XCTAssertEqual(SpokenSymbolTransformer.splitTrailingPunctuation("json,").suffix, ",")
        XCTAssertEqual(SpokenSymbolTransformer.splitTrailingPunctuation("json").suffix, "")
        XCTAssertEqual(SpokenSymbolTransformer.splitTrailingPunctuation("done?!").suffix, "?!")
    }

    func testKnownExtensionsExcludeTopLevelDomains() {
        for domain in ["com", "net", "org", "io", "co", "ai"] {
            XCTAssertFalse(
                SpokenSymbolTransformer.knownExtensions.contains(domain),
                "\(domain) must not be treated as a file extension"
            )
        }
    }
}
