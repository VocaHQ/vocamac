import XCTest
@testable import VocaMac

final class CleanupAccuracyTests: XCTestCase {
    private func merge(_ source: String, _ candidate: String, level: CleanupLevel = .medium,
                       english: Bool = true) -> String {
        EditMerge.merge(original: source, candidate: candidate, level: level,
                        allowsEnglishGrammar: english, isKnownWord: { _ in true }).text
    }

    func testMeaningfulWordsSurviveModelDeletions() {
        for (source, candidate) in [
            ("Well water is safe", "Water is safe"),
            ("Now we need approval", "We need approval"),
            ("I guess, we can ship tomorrow", "We can ship tomorrow"),
            ("It is, kind of, dangerous", "It is dangerous"),
            ("I can candy fruit", "I candy fruit"),
            ("take vitamin b daily", "take vitamin daily")
        ] {
            XCTAssertEqual(merge(source, candidate), source, source)
        }
    }

    func testPunctuationDoesNotAddEmphasisOrRemoveWordHyphens() {
        XCTAssertEqual(merge("We meet at noon", "We meet at noon!"), "We meet at noon")
        XCTAssertEqual(merge("re-sign the form", "re sign the form"), "re-sign the form")
        XCTAssertEqual(merge("Can we ship?", "Can we ship."), "Can we ship?")
        XCTAssertEqual(merge("well water is safe", "Well, water is safe."), "Well water is safe.")
        XCTAssertEqual(merge("He said \"go\".", "He said go."), "He said \"go\".")
    }

    func testCombiningMarksStayAttachedEvenWhenARewriteIsRejected() {
        for text in ["कल deploy मत करना।", "हमें रिपोर्ट चाहिए।", "cafe\u{301}", "مَرْحَبًا"] {
            XCTAssertEqual(merge(text, text, level: .light), text)
        }
        XCTAssertEqual(merge("कल deploy मत करना।", "Do not deploy tomorrow.", level: .light), "कल deploy मत करना।")
    }

    func testMinimalGrammarRequiresExplicitLevelAndEnglish() {
        let source = "she go to office every day"
        let candidate = "She goes to the office every day."
        XCTAssertEqual(merge(source, candidate, level: .grammar), candidate)
        for level in [CleanupLevel.light, .medium, .high] {
            XCTAssertEqual(merge(source, candidate, level: level), "She go to office every day.")
        }
        XCTAssertEqual(merge(source, candidate, level: .grammar, english: false), "She go to office every day.")
    }

    func testAgreementAndArticlesPreserveTense() {
        for (source, candidate) in [
            ("they was ready", "They were ready."),
            ("she have a report", "She has a report."),
            ("she don't need it", "She doesn't need it."),
            ("I needs a report", "I need a report."),
            ("I need email", "I need an email."),
            ("we need report", "We need a report.")
        ] {
            XCTAssertEqual(merge(source, candidate, level: .grammar), candidate)
        }
        XCTAssertEqual(merge("she was ready", "She is ready.", level: .grammar), "She was ready.")
        XCTAssertEqual(merge("I need information", "I need an information.", level: .grammar), "I need information.")
        XCTAssertEqual(merge("I agree, I disagree", "I disagree"), "I agree, I disagree")
    }

    func testGrammarEditsAreAtomicWhenAnotherWordChangeIsUnsafe() {
        XCTAssertEqual(merge("she go", "She goes?", level: .grammar), "She go")
        XCTAssertEqual(merge("she go to office tomorrow", "She goes to the office today.", level: .grammar),
                       "She go to office tomorrow.")
        XCTAssertEqual(merge("she do not need report", "She does need a report.", level: .grammar),
                       "She do not need report.")
        XCTAssertEqual(merge("I had finished", "I'd finished.", level: .grammar), "I had finished.")
    }

    func testDictatedRefusalIsNotMistakenForAModelRefusal() {
        XCTAssertEqual(TranscriptCleanup.acceptedOutput("I cannot attend today.", original: "I cannot attend today"),
                       "I cannot attend today.")
        XCTAssertNil(TranscriptCleanup.acceptedOutput("I cannot help with that.", original: "Send the report."))
    }

    func testLongMergeRemainsBoundedAndPreservesSentences() {
        let source = String(repeating: "we need the report for the meeting tomorrow.\n", count: 250)
        let candidate = String(repeating: "We need the report for the meeting tomorrow.\n", count: 250)
        XCTAssertEqual(merge(source, candidate), candidate)
        XCTAssertEqual(merge(source, "One sentence."), source)
    }

    func testSalvageAlsoPreservesUncertaintyAndTiming() {
        for (source, candidate) in [
            ("I guess, we can ship", "We can ship"),
            ("Now, we need approval", "We need approval"),
            ("It is, sort of, working", "It is working")
        ] {
            XCTAssertTrue(CleanupSalvage.safeDeletions(original: source, candidate: candidate).isEmpty)
        }
    }
}

final class CleanupContextTests: XCTestCase {
    func testChunksPreserveAllCharactersAndParagraphs() async {
        let source = "First sentence.\n\nSecond sentence. Third sentence."
        let chunks = await CleanupContext.chunks(source, contextTokens: 360, promptTokens: 0,
                                                  countTokens: { $0.count })
        XCTAssertNotNil(chunks)
        XCTAssertGreaterThan(chunks?.count ?? 0, 1)
        XCTAssertEqual(chunks?.joined(), source)
    }

    func testOversizedSentenceAndTransformNeverSplit() async {
        let oversized = await CleanupContext.chunks(String(repeating: "word ", count: 100),
            contextTokens: 400, promptTokens: 0, countTokens: { $0.count })
        XCTAssertNil(oversized)
        let transform = await CleanupContext.chunks("First sentence. Second sentence.",
            contextTokens: 330, promptTokens: 0, allowsSplitting: false, countTokens: { $0.count })
        XCTAssertNil(transform)
    }

    func testTokenCountsRatherThanCharacterCountsDecideFit() async {
        let dense = await CleanupContext.chunks("你好", contextTokens: 512, promptTokens: 10,
                                               countTokens: { _ in 200 })
        XCTAssertNil(dense)
        let sparse = await CleanupContext.chunks(String(repeating: "a", count: 1000),
            contextTokens: 512, promptTokens: 10, countTokens: { _ in 20 })
        XCTAssertEqual(sparse?.count, 1)
    }

    @MainActor
    func testSelectedModelDeterminesEstimatedBudget() {
        let service = TranscriptCleanupService()
        XCTAssertGreaterThan(service.inputBudget(forPrompt: "", model: .qwen25_1_5b_q4_k_m),
                             service.inputBudget(forPrompt: "", model: .defaultKind))
    }
}
