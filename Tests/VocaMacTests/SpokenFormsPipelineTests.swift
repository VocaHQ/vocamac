// SpokenFormsPipelineTests.swift
// VocaMac Tests
//
// Spoken emoji and number words inside `DictationOutputPipeline`: they convert
// on the user's own words, and nothing the cleanup model answers can drop,
// re-spell, or re-punctuate what they produced.

import XCTest
@testable import VocaMac

@MainActor
final class SpokenFormsPipelineTests: XCTestCase {
    private func process(
        _ input: String, cleaner: MockTranscriptCleanup? = nil,
        format: WritingStyle = .plain, intent: WritingIntent = .preserve,
        cleanup: WritingCleanupPolicy = .inherit, enabled: Bool = true,
        snippets: [Snippet] = [], digits: Bool = true, emoji: Bool = true
    ) async -> DictationOutputResult {
        await DictationOutputPipeline(cleaner: cleaner ?? MockTranscriptCleanup(), snippets: SnippetExpander()).process(
            input,
            profile: WritingProfile(format: format, rules: format.defaultRules, intent: intent, cleanup: cleanup),
            snippetList: snippets, cleanupEnabled: enabled, rewritingEnabled: true,
            model: .defaultKind, customPrompt: "", cleanupLevel: .medium,
            language: "en", autoCapitalize: true, trailingSpace: false,
            numbersAsDigits: digits, spokenEmoji: emoji
        )
    }

    // MARK: - Off, Raw, and formatting only

    func testThePipelineConvertsNothingUnlessAsked() async {
        let result = await DictationOutputPipeline(cleaner: MockTranscriptCleanup(), snippets: SnippetExpander()).process(
            "twenty three people, happy emoji",
            profile: WritingProfile(format: .plain, rules: WritingStyle.plain.defaultRules),
            snippetList: [], cleanupEnabled: false, rewritingEnabled: false,
            model: .defaultKind, customPrompt: "", language: "en",
            autoCapitalize: true, trailingSpace: false
        )
        XCTAssertEqual(result.text, "Twenty three people, happy emoji")
    }

    func testRawTypesTheWordsAsSpoken() async {
        let input = "twenty three people, happy emoji"
        let result = await process(input, cleanup: .raw)
        XCTAssertEqual(result.text, input)
    }

    func testEachToggleOnlyControlsItsOwnConversion() async {
        let digitsOnly = await process("twenty three people, happy emoji", enabled: false, emoji: false)
        XCTAssertEqual(digitsOnly.text, "23 people, happy emoji")
        let emojiOnly = await process("twenty three people, happy emoji", enabled: false, digits: false)
        XCTAssertEqual(emojiOnly.text, "Twenty three people, 😊")
    }

    func testFormattingOnlyStillConverts() async {
        let cleaner = MockTranscriptCleanup()
        let result = await process("I'll be there at six pm, smiling emoji.", cleaner: cleaner, enabled: false)
        XCTAssertEqual(result.text, "I'll be there at 6 pm, 😊")
        XCTAssertEqual(cleaner.cleanCallCount, 0)
    }

    /// "um" goes before conversion, so it can't split a name from its trigger.
    func testHesitationsAreRemovedBeforeConverting() async {
        let result = await process("see you at um five pm, heart um emoji", enabled: false)
        XCTAssertEqual(result.text, "See you at 5 pm, ❤️")
    }

    // MARK: - Cleanup cannot undo them

    func testTheModelNeverSeesTheGlyphOrTheNumberWords() async throws {
        let cleaner = MockTranscriptCleanup()
        _ = await process("we need twenty three chairs, party emoji", cleaner: cleaner)
        XCTAssertEqual(cleaner.cleanCallCount, 1)
        let seen = try XCTUnwrap(cleaner.lastCleanedText)
        XCTAssertFalse(seen.contains("twenty"))
        XCTAssertFalse(seen.contains("emoji"))
        XCTAssertFalse(seen.contains("🎉"))
        XCTAssertEqual(RewriteValidation.substrings("VOCAKEEP[0-9]+END", in: seen).count, 2)
    }

    func testAModelThatDropsTheEmojiDoesNotLoseIt() async {
        let cleaner = MockTranscriptCleanup()
        // Deletes every protected token and emoji, as a small model might.
        cleaner.cleanHandler = { text in
            RewriteValidation.matches("\\s*(?:VOCAKEEP[0-9]+END|\\p{Extended_Pictographic})", in: text).reversed()
                .reduce(text as NSString) { $0.replacingCharacters(in: $1, with: "") as NSString } as String
        }
        let result = await process("I got the job, happy emoji", cleaner: cleaner)
        XCTAssertEqual(result.text, "I got the job, 😊")
    }

    func testAModelThatSpellsTheNumberOutAgainIsNotTaken() async {
        let cleaner = MockTranscriptCleanup()
        cleaner.cleanHandler = { text in
            RewriteValidation.matches("VOCAKEEP[0-9]+END", in: text).reversed()
                .reduce(text as NSString) { $0.replacingCharacters(in: $1, with: "twenty three") as NSString } as String
        }
        let result = await process("send twenty three copies", cleaner: cleaner)
        XCTAssertEqual(result.text, "Send 23 copies")
    }

    func testFillerCleanupStillAppliesAroundConvertedText() async {
        let cleaner = MockTranscriptCleanup()
        cleaner.cleanHandler = { $0.replacingOccurrences(of: "was was", with: "was") }
        let result = await process("it was was five stars, fire emoji", cleaner: cleaner)
        XCTAssertEqual(result.text, "It was 5 stars, 🔥")
        XCTAssertEqual(result.summary, "Cleaned up")
    }

    func testAFullStopTheModelAddsAfterAClosingGlyphIsDropped() async {
        let cleaner = MockTranscriptCleanup()
        cleaner.cleanHandler = { $0 + "." }
        let closing = await process("see you soon, heart emoji", cleaner: cleaner)
        XCTAssertEqual(closing.text, "See you soon, ❤️")

        // A glyph mid-sentence is not the end, so the sentence keeps its stop.
        let midSentence = await process("fire emoji is how I feel", cleaner: cleaner)
        XCTAssertEqual(midSentence.text, "🔥 is how I feel.")
    }

    func testRewordingIntentsKeepConvertedText() async {
        let cleaner = MockTranscriptCleanup()
        cleaner.cleanHandler = { "Please " + $0 }
        let result = await process("send five copies, thumbs up emoji", cleaner: cleaner, intent: .professional)
        XCTAssertEqual(result.text, "Please send 5 copies, 👍")
    }

    // MARK: - Interplay with the rest of the pipeline

    func testSnippetTriggersWinOverConversions() async {
        let result = await process(
            "ping me at one two three, fire emoji", enabled: false,
            snippets: [Snippet(trigger: "one two three", expansion: "123-456-7890")]
        )
        XCTAssertEqual(result.text, "Ping me at 123-456-7890, 🔥")
    }

    func testAGlyphIsNeverCapitalizedOrStyledAway() async {
        for format in [WritingStyle.chat, .email, .notes, .slack] {
            let result = await process("party emoji, we shipped it", format: format, enabled: false)
            XCTAssertTrue(result.text.hasPrefix("🎉"), "\(format): \(result.text)")
        }
    }

    func testTechnicalStylesConvertToo() async {
        let result = await process("sleep five", format: .terminal)
        XCTAssertEqual(result.text, "sleep 5")
    }

    func testDroppingTheFullStopOnlyTouchesTheVeryEnd() {
        XCTAssertEqual(DictationOutputPipeline.droppingFullStop(after: "😊", in: "Yay 😊. "), "Yay 😊 ")
        XCTAssertEqual(DictationOutputPipeline.droppingFullStop(after: "😊", in: "Yay 😊!"), "Yay 😊!")
        XCTAssertEqual(DictationOutputPipeline.droppingFullStop(after: "😊", in: "😊. Yay."), "😊. Yay.")
    }
}
