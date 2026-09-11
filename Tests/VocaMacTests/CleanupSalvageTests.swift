import XCTest
@testable import VocaMac

final class CleanupSalvageTests: XCTestCase {
    private func salvage(_ original: String, _ candidate: String) -> String {
        WritingStyleEngine.removeWordRuns(
            CleanupSalvage.safeDeletions(original: original, candidate: candidate), from: original
        )
    }

    func testKeepsSafeDeletionsAndIgnoresRiskyEdits() {
        // The model dropped fillers and also turned "George" into "our".
        XCTAssertEqual(
            salvage("Also I have gone gone through yours and George com uh uh conversations",
                    "Also I have gone through yours and our conversations."),
            "Also I have gone through yours and George com conversations"
        )
    }

    func testCommaFillersAndOpenersGoOnlyWhenSetOff() {
        XCTAssertEqual(salvage("It was, like, really big", "It was really big"), "It was, really big")
        XCTAssertEqual(salvage("So, we ship Friday", "We ship Friday"), "We ship Friday")
        // Without the comma "like" is a verb, whatever the model did.
        XCTAssertEqual(salvage("I like the new design", "I the new design"), "I like the new design")
    }

    func testRepeatsDropTheAbandonedFirstCopy() {
        XCTAssertEqual(salvage("check the, the build logs", "check the build logs"), "check the build logs")
        XCTAssertEqual(salvage("I I think so", "I think so"), "I think so")
        // Emphasis is kept even if the model removed it.
        XCTAssertEqual(salvage("this is very very important", "this is very important"), "this is very very important")
    }

    func testRestartsNeedAMarkerAndAMatchingStart() {
        XCTAssertEqual(salvage("I want to, I need to finish it", "I need to finish it"), "I need to finish it")
        XCTAssertEqual(salvage("I want to finish it", "finish it"), "I want to finish it")
    }

    func testProtectedTokensAndInsertionsAreNeverApplied() {
        XCTAssertEqual(salvage("open VOCAKEEP0END now", "open now"), "open VOCAKEEP0END now")
        XCTAssertEqual(salvage("git push origin main", "Git push origin main please."), "git push origin main")
    }
}

@MainActor
final class TechnicalCleanupPipelineTests: XCTestCase {
    private func process(_ input: String, format: WritingStyle, model output: @escaping (String) -> String) async -> (DictationOutputResult, MockTranscriptCleanup) {
        let cleaner = MockTranscriptCleanup()
        cleaner.cleanHandler = output
        let result = await DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander()).process(
            input, profile: WritingProfile(format: format, rules: format.defaultRules),
            snippetList: [], cleanupEnabled: true, rewritingEnabled: true,
            model: .defaultKind, customPrompt: "", cleanupLevel: .medium,
            language: "en", autoCapitalize: true, trailingSpace: false
        )
        return (result, cleaner)
    }

    func testTerminalProseLosesFillerButNeverTheModelsWording() async {
        let (result, cleaner) = await process(
            "can you, like, check the build logs for the failing test", format: .terminal
        ) { _ in "Can you check the build logs for the failing test?" }
        XCTAssertEqual(cleaner.previewCallCount, 1, "Terminal answers never count toward the give-up limit")
        XCTAssertTrue(cleaner.lastPrompt?.contains("terminal or code editor") == true)
        // The model's capital and question mark are not taken; its deletion is.
        XCTAssertEqual(result.text, "can you, check the build logs for the failing test")
        XCTAssertTrue(result.summary.contains("removed filler only"))
    }

    func testShortCommandsSkipTheModel() async {
        let (result, cleaner) = await process("git push origin", format: .terminal) { _ in "Git push origin." }
        XCTAssertEqual(cleaner.previewCallCount, 0)
        XCTAssertEqual(result.text, "git push origin")
        XCTAssertTrue(result.summary.contains("short command"))
    }

    func testCommandsTheModelRewordsStayExact() async {
        let (result, _) = await process("git log --oneline for the last week", format: .terminal) { _ in
            "Show the git log for last week."
        }
        XCTAssertEqual(result.text, "git log --oneline for the last week")
    }

    func testRemovingAnOpeningHesitationNeverRecasesACommand() async {
        let (result, _) = await process("Um git push origin", format: .terminal) { $0 }
        XCTAssertEqual(result.text, "git push origin")
        XCTAssertEqual(WritingStyleEngine.removeHesitations("Um git push.", prose: false).text, "git push.")
    }

    func testCommandsNeverGoToARemoteEndpoint() async {
        let cleaner = MockTranscriptCleanup()
        cleaner.isOnDevice = false
        cleaner.cleanHandler = { _ in "check the logs" }
        let result = await DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander()).process(
            "can you, like, check the logs please", profile: WritingProfile(format: .terminal, rules: WritingStyle.terminal.defaultRules),
            snippetList: [], cleanupEnabled: true, rewritingEnabled: true, model: .defaultKind,
            customPrompt: "", cleanupLevel: .medium, language: "en", autoCapitalize: true, trailingSpace: false
        )
        XCTAssertEqual(cleaner.previewCallCount + cleaner.cleanCallCount, 0)
        XCTAssertTrue(result.summary.contains("aren't sent"))
    }

    func testRejectedProseRewriteKeepsItsFillerRemoval() async {
        let (result, _) = await process("Hi, I have gone gone through Sergey conversations", format: .chat) { _ in
            "Hi, I have gone through our conversations."
        }
        // The stutter and the period are kept; "Sergey" → "our" is not.
        XCTAssertEqual(result.text, "Hi, I have gone through Sergey conversations.")
        XCTAssertTrue(result.summary.contains("1 risky edit left as spoken"), result.summary)
    }
}
