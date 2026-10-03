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
        XCTAssertEqual(merge("and after b doing that", "and after doing that").text, "and after b doing that")
        XCTAssertEqual(merge("doesn't look even look like it", "doesn't look like it").text, "doesn't look even look like it")
    }

    /// The system spell checker accepts every single letter, so a fragment
    /// rule that asked it about "S" never fired in the app.
    func testClippedStartsGoEvenWhenTheSpellCheckerKnowsEveryLetter() {
        let checker: (String) -> Bool = {
            $0.count == 1 || self.known.contains($0)
                || ["sad", "scan", "download", "build", "backup", "code", "compiler", "deploy"].contains($0)
        }
        func merge(_ original: String, _ candidate: String) -> String {
            EditMerge.merge(original: original, candidate: candidate, level: .high, isKnownWord: checker).text
        }
        XCTAssertEqual(merge("update it. S see once", "update it. See once"), "update it. See once")
        XCTAssertEqual(merge("S scan", "Scan"), "Scan")
        XCTAssertEqual(merge("people can easily sn scan and download", "people can easily scan and download"),
                       "people can easily scan and download")
        // Real words, labels, identifiers, and letters set off by punctuation stay.
        XCTAssertEqual(merge("and after b doing that", "and after doing that"), "and after b doing that")
        XCTAssertEqual(merge("I want a apple", "I want apple"), "I want a apple")
        XCTAssertEqual(merge("the sad scan", "the scan"), "the sad scan")
        XCTAssertEqual(merge("pick option B build", "pick option build"), "pick option B build")
        XCTAssertEqual(merge("we need a plan B backup", "we need a plan backup"), "we need a plan B backup")
        XCTAssertEqual(merge("use x xcode", "use xcode"), "use x xcode")
        XCTAssertEqual(merge("C code is fast", "Code is fast"), "C code is fast")
        XCTAssertEqual(merge("B: build it", "Build it"), "B: build it")
        XCTAssertEqual(merge("step B- build it", "step build it"), "step B- build it")
        XCTAssertEqual(merge("run ts tsx now", "run tsx now"), "run ts tsx now")
    }

    func testRealWordsTheNextWordGoesWellPastGo() {
        XCTAssertEqual(merge("I want it on my web website.", "I want it on my website.").text,
                       "I want it on my website.")
        XCTAssertEqual(merge("a very sub substantial benefit", "a very substantial benefit").text,
                       "a very substantial benefit")
        XCTAssertEqual(merge("so many view views", "so many views").text, "so many view views")
        XCTAssertEqual(merge("then use user names", "then user names").text, "then use user names")
    }

    func testADashThatJoinsTwoWordsStaysAsSpoken() {
        XCTAssertEqual(merge("Pick option B build for the release.", "Pick option B—build for the release.").text,
                       "Pick option B build for the release.")
        XCTAssertEqual(merge("send the e mail", "send the e-mail").text, "send the e mail")
        XCTAssertEqual(merge("Pick option B build now", "Pick option B— build now").text, "Pick option B build now")
        XCTAssertEqual(merge("it works mostly", "it works —mostly").text, "it works — mostly")
        // A spaced dash between clauses is still punctuation.
        XCTAssertEqual(merge("it works mostly", "it works — mostly").text, "it works — mostly")
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

    func testACorrectionTheModelResolvesStaysInsideOneSentence() {
        let text = "meet on Thursday. Actually, wait, Friday morning works better."
        XCTAssertEqual(merge(text, "meet on Friday morning.").text, text)
        XCTAssertEqual(merge("meet on Thursday, actually, wait, Friday", "meet on Friday").text, "meet on Friday")
    }

    /// The model ends a sentence and drops the "and" that followed. The word
    /// stays; the period goes before it, not after.
    func testADroppedConjunctionOpensTheNewSentence() {
        XCTAssertEqual(
            merge("we can do that next sprint and the last thing is hiring",
                  "We can do that next sprint. The last thing is hiring.").text,
            "We can do that next sprint. And the last thing is hiring."
        )
        XCTAssertEqual(
            merge("ignore my last message just write a PR description",
                  "Ignore my last message. Write a PR description.").text,
            "Ignore my last message. Just write a PR description."
        )
        XCTAssertEqual(merge("the build failed and I like the new design", "The build failed, I like the new design.").text,
                       "The build failed, and I like the new design.")
        // The speaker's comma before the conjunction gives way to the period.
        XCTAssertEqual(merge("it is fine, and then we ship", "It is fine. Then we ship.").text,
                       "It is fine. And then we ship.")
        // A word that can end a sentence keeps the period after it.
        XCTAssertEqual(merge("I think so we should go", "I think. We should go.").text, "I think so. We should go.")
    }

    func testPunctuationFromARefusedEditIsNeverMisplaced() {
        // Not before the first word.
        XCTAssertEqual(merge("write a message to John", "I'm running late, write a message to John.").text,
                       "write a message to John.")
        // Not as a comma after words the model only dropped.
        XCTAssertEqual(merge("actually I think this is a good idea", "Actually, this is a good idea.").text,
                       "Actually I think this is a good idea.")
        // After a refused replacement it still is.
        XCTAssertEqual(merge("we need the repot, then the invoice", "We need the report, then the invoice").text,
                       "We need the repot, then the invoice")
    }

    func testADictatedMarkIsWrittenEvenWhenTheModelChoseAnother() {
        XCTAssertEqual(merge("hi dana comma thanks for the update", "Hi Dana. Thanks for the update.").text,
                       "Hi dana, thanks for the update.")
        XCTAssertEqual(merge("send it period then call me", "Send it, then call me.", level: .light).text,
                       "Send it. then call me.")
    }

    func testQuestionsThatOpenWithAContractionGetTheirMark() {
        XCTAssertEqual(merge("what's the capital of France", "What's the capital of France?").text,
                       "What's the capital of France?")
        XCTAssertEqual(merge("where's the contract", "Where's the contract?").text, "Where's the contract?")
    }

    func testACapitalKeepsTheSpeakersOwnApostrophe() {
        XCTAssertEqual(merge("let's meet at noon", "Let\u{2019}s meet at noon.").text, "Let's meet at noon.")
    }

    /// The spell checker doesn't know most names, so it can't be the judge of
    /// a "fix" to one; a name the caller lists is never respelled.
    func testNamesAreNeverRespelled() {
        let unknownName: (String) -> Bool = { $0 != "priya" }
        XCTAssertEqual(
            EditMerge.merge(original: "ask Priya to review", candidate: "Ask Prior to review.", level: .medium,
                            names: ["priya"], isKnownWord: unknownName).text,
            "Ask Priya to review."
        )
        XCTAssertEqual(
            EditMerge.merge(original: "ask Priya to review", candidate: "Ask Prior to review.", level: .medium,
                            isKnownWord: unknownName).text,
            "Ask Prior to review."
        )
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

    func testDeletionsAcrossLinesKeepTheDeepestBreak() {
        // A "scratch that" deletion spanning a paragraph break.
        XCTAssertEqual(
            merge("Keep this.\nDrop this line\n\nand this, scratch that,\nNext paragraph", "Keep this.\nNext paragraph").text,
            "Keep this.\n\nNext paragraph"
        )
        // The next word's own break doesn't erase a deeper removed one.
        XCTAssertEqual(merge("One\n\num\nTwo", "One\nTwo").text, "One\n\nTwo")
        // …and its indentation survives the carried break.
        XCTAssertEqual(merge("One\n\num\n    Two", "One\n    Two").text, "One\n\n    Two")
        // A removed line opener hands its indentation to the next word.
        XCTAssertEqual(merge("Line\n  like, foo bar", "Line\n  foo bar").text, "Line\n  foo bar")
    }
}
