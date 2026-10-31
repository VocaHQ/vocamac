// SpokenListsTests.swift
// VocaMac
//
// A spoken "first, … second, … third, …" becomes a numbered list, and
// nothing that only looks like one does.

import XCTest
@testable import VocaMac

final class SpokenListsTests: XCTestCase {

    func testAnOrderedRunBecomesANumberedList() {
        let text = "First, we need to buy milk. Second, call the bank. Third, book the flights."
        XCTAssertEqual(
            SpokenLists.numbered(text),
            "1. We need to buy milk.\n2. Call the bank.\n3. Book the flights."
        )
    }

    func testAnIntroductionAndAClosingSentenceStayOutsideTheList() {
        let text = "Three things for today. Firstly, ship the build. Secondly, write the notes. "
            + "Thirdly, email the team.\n\nThat's all for now."
        XCTAssertEqual(
            SpokenLists.numbered(text),
            "Three things for today.\n1. Ship the build.\n2. Write the notes.\n3. Email the team.\n\nThat's all for now."
        )
    }

    func testFinallyEndsAList() {
        let text = "First, fix the login bug. Second, update the docs. Finally, tag the release."
        XCTAssertEqual(
            SpokenLists.numbered(text),
            "1. Fix the login bug.\n2. Update the docs.\n3. Tag the release."
        )
    }

    func testSentencesBetweenMarkersBelongToTheItem() {
        let text = "First, check the logs. They rotate daily. Second, restart the server. Third, page on call."
        XCTAssertEqual(
            SpokenLists.numbered(text),
            "1. Check the logs. They rotate daily.\n2. Restart the server.\n3. Page on call."
        )
    }

    func testNumberWordsWithACommaCount() {
        let text = "One, pick a venue. Two, send the invites. Three, order the food."
        XCTAssertEqual(SpokenLists.numbered(text), "1. Pick a venue.\n2. Send the invites.\n3. Order the food.")
    }

    // MARK: - Look-alikes stay as spoken

    /// "First impressions" is a noun phrase, not a marker: a bare ordinal
    /// needs a comma or colon after it.
    func testSentencesThatOpenWithOrdinalsAsWordsStay() {
        let text = "First impressions matter. Second chances are rare. Third place is fine."
        XCTAssertEqual(SpokenLists.numbered(text), text)
    }

    /// With numbers written as digits, "One," "Two," "Three," arrive as
    /// "1," "2," "3,".
    func testDigitMarkersCount() {
        let text = "1, pick a venue. 2, send the invites. 3, order the food."
        XCTAssertEqual(SpokenLists.numbered(text), "1. pick a venue.\n2. send the invites.\n3. order the food.")
        // "10," doesn't read as "1,".
        XCTAssertEqual(SpokenLists.numbered("10, pick a venue. 2, send the invites. 3, order the food."),
                       "10, pick a venue. 2, send the invites. 3, order the food.")
    }

    func testASentenceThatMerelyContainsFirstStays() {
        let text = "First impressions matter. The second meeting went well. A third person joined."
        XCTAssertEqual(SpokenLists.numbered(text), text)
    }

    func testTwoItemsAreNotAList() {
        let text = "First, buy milk today. Second, call mom tonight."
        XCTAssertEqual(SpokenLists.numbered(text), text)
    }

    func testOutOfOrderMarkersAreNotAList() {
        let text = "Second, buy milk today. First, call mom tonight. Third, pay the rent."
        XCTAssertEqual(SpokenLists.numbered(text), text)
    }

    func testMarkersInsideSentencesDontCount() {
        let text = "We came first, second and third in the races. It was fun. Really fun."
        XCTAssertEqual(SpokenLists.numbered(text), text)
    }

    func testCountingIsNotAList() {
        let text = "One, two, three, go! Two of us ran. Three of us walked."
        XCTAssertEqual(SpokenLists.numbered(text), text)
    }

    func testOneWordItemsAreNotAList() {
        let text = "First, milk. Second, eggs. Third, bread."
        XCTAssertEqual(SpokenLists.numbered(text), text)
    }

    func testLowercaseTextStaysLowercase() {
        let text = "first, buy the milk. second, call the bank. third, book the flights."
        XCTAssertEqual(SpokenLists.numbered(text), "1. buy the milk.\n2. call the bank.\n3. book the flights.")
    }

    // MARK: - In the pipeline

    @MainActor
    func testListsAreLaidOutInProseStylesOnly() async {
        let spoken = "first, buy the milk. second, call the bank. third, book the flights."
        func run(_ style: WritingStyle) async -> String {
            await DictationOutputPipeline(cleaner: MockTranscriptCleanup(), snippets: SnippetExpander()).process(
                spoken, profile: WritingProfile(format: style, rules: style.defaultRules),
                snippetList: [], cleanupEnabled: false, rewritingEnabled: false,
                model: .defaultKind, customPrompt: "", language: "en",
                autoCapitalize: true, trailingSpace: false, laysOutParagraphs: style.allowsParagraphs
            ).text
        }
        let notes = await run(.notes)
        let digits = await DictationOutputPipeline(cleaner: MockTranscriptCleanup(), snippets: SnippetExpander()).process(
            "One, pick a venue. Two, send the invites. Three, order the food.",
            options: DictationOutputOptions(
                profile: WritingProfile(format: .notes, rules: WritingStyle.notes.defaultRules), snippetList: [],
                cleanupEnabled: false, rewritingEnabled: false, model: .defaultKind, customPrompt: "",
                language: "en", autoCapitalize: true, trailingSpace: false, numbers: .digits,
                laysOutParagraphs: true
            )
        ).text
        XCTAssertTrue(digits.hasPrefix("1. "), digits)
        XCTAssertEqual(digits.components(separatedBy: "\n").count, 3, digits)
        XCTAssertEqual(notes, "1. Buy the milk.\n2. Call the bank.\n3. Book the flights.")
        let chat = await run(.chat)
        XCTAssertFalse(chat.contains("\n"))
    }
}
