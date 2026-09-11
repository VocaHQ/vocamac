import XCTest
@testable import VocaMac

/// Cases taken from real dictations the old all-or-nothing check rejected.
final class EditMergeTests: XCTestCase {
    private let known: Set<String> = ["expander", "see", "different", "if", "sorry", "look", "like"]

    private func merge(_ original: String, _ candidate: String, level: CleanupLevel = .high) -> EditMerge.Result {
        EditMerge.merge(original: original, candidate: candidate, level: level) { self.known.contains($0) }
    }

    func testStuttersAndFragmentsGoWhileTheRestStays() {
        XCTAssertEqual(merge("So tell me if if it is all good", "So tell me if it is all good").text,
                       "So tell me if it is all good")
        XCTAssertEqual(merge("its indicator is diff different", "its indicator is different").text,
                       "its indicator is different")
        XCTAssertEqual(merge("update it. S see once", "update it. See once").text, "update it. See once")
        XCTAssertEqual(merge("and after b doing that", "and after doing that").text, "and after doing that")
        XCTAssertEqual(merge("doesn't look even look like it", "doesn't look like it").text, "doesn't look like it")
    }

    func testRiskyEditsStayAsSpokenWhileSafeOnesApply() {
        // Filler and a period are fine; a changed number is not.
        let result = merge("a quick meeting, like, at max 15 minutes", "A quick meeting at max 10 minutes.")
        XCTAssertEqual(result.text, "A quick meeting at max 15 minutes.")
        XCTAssertGreaterThan(result.applied, 0)
        XCTAssertGreaterThan(result.skipped, 0)
        // A dropped name or sentence stays.
        XCTAssertEqual(merge("coming in Vocamac.", "coming in.").text, "coming in Vocamac.")
        XCTAssertEqual(merge("fix it. First of all", "First of all,").text, "fix it. First of all,")
    }

    func testPunctuationCapitalsSpellingAndSpokenMarks() {
        XCTAssertEqual(merge("i think so", "I think so.").text, "I think so.")
        XCTAssertEqual(merge("it looks like an expender", "it looks like an expander").text, "it looks like an expander")
        XCTAssertEqual(merge("do it tomorrow, comma we should", "do it tomorrow, we should").text, "do it tomorrow, we should")
        XCTAssertEqual(merge("I do not know", "I don't know").text, "I don't know")
        // Hyphenated words keep their spelling.
        XCTAssertEqual(merge("re-review the one-day plan", "re-review the one-day plan.").text, "re-review the one-day plan.")
    }

    func testMeaningChangesAreNeverApplied() {
        XCTAssertEqual(merge("do not deploy today", "Deploy today.").text, "do not deploy today.")
        XCTAssertEqual(merge("we might ship today", "We will ship today.").text, "We might ship today.")
        XCTAssertEqual(merge("can you send the report?", "Can you send the report.").text, "Can you send the report?")
    }

    func testARefusedRewriteNeverAddsAQuestion() {
        XCTAssertEqual(merge("we might ship today", "Will we ship today?").text, "we might ship today")
        // A sentence that opens like a question still gets its "?".
        XCTAssertEqual(merge("hey can you send it today", "Hey, can you send it today?").text, "Hey, can you send it today?")
    }

    func testAnAnswerInsteadOfAnEditContributesNothing() {
        let result = merge("hey can you send the report today",
                           "Sure, I can do that. Could you please provide the report for today?")
        XCTAssertEqual(result.text, "hey can you send the report today")
        XCTAssertEqual(result.applied, 0)
    }

    func testHighLevelAcceptsTheModelsLooserCorrections() {
        XCTAssertEqual(merge("send it to John, no, Mary today", "send it to Mary today").text, "send it to Mary today")
        XCTAssertEqual(merge("pick the red one, no wait, the blue one", "pick the blue one").text, "pick the blue one")
        // Medium leaves them to the speaker.
        XCTAssertEqual(merge("send it to John, no, Mary", "send it to Mary", level: .medium).text, "send it to John, no, Mary")
        // No cue, no correction: the model just dropped a name.
        XCTAssertEqual(merge("send it to John and Mary", "send it to Mary").text, "send it to John and Mary")
        // A negative sentence keeps its "no".
        XCTAssertEqual(merge("I don't want John, no, Mary", "I don't want Mary").text, "I don't want John, no, Mary")
    }

    func testLightLevelTakesPunctuationButKeepsEveryWord() {
        XCTAssertEqual(merge("so tell me if if it works", "So tell me if it works.", level: .light).text,
                       "So tell me if if it works.")
        // No spelling fixes or contractions either: those change words.
        XCTAssertEqual(merge("it looks like an expender", "It looks like an expander.", level: .light).text,
                       "It looks like an expender.")
        XCTAssertEqual(merge("I do not know", "I don't know.", level: .light).text, "I do not know.")
    }

    func testRemovingTheFirstWordOnALineKeepsTheLineBreak() {
        XCTAssertEqual(merge("Heading\nlike, then more", "Heading\nthen more").text, "Heading\nthen more")
        XCTAssertEqual(merge("First line\nif if second", "First line\nif second").text, "First line\nif second")
    }
}
