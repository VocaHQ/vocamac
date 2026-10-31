// InsertionFitTests.swift
// VocaMac
//
// Fitting a dictation to the field it lands in: one-line fields, the
// sentence already there, and a chat draft's register.

import XCTest
@testable import VocaMac

final class InsertionFitTests: XCTestCase {

    private func fit(
        _ text: String, before: String?, after: String? = nil, field: InsertionContext.Field = .multiLine,
        capitalizes: Bool = true, chat: Bool = false
    ) -> InsertionFit.Result {
        InsertionFit.fit(
            text, into: InsertionContext(field: field, before: before, after: after),
            capitalizes: capitalizes, mirrorsRegister: chat
        )
    }

    // MARK: - Unknown or empty fields change nothing

    func testAnUnreadableFieldChangesNothing() {
        XCTAssertEqual(fit("That works.", before: nil), .init(text: "That works.", leadingSpace: false))
        XCTAssertEqual(fit("That works. ", before: nil, after: nil, field: .unknown).text, "That works. ")
    }

    func testAnEmptyFieldChangesNothing() {
        XCTAssertEqual(fit("That works.", before: ""), .init(text: "That works.", leadingSpace: false))
    }

    // MARK: - Joining

    func testContinuingASentenceLowercasesAndAddsASpace() {
        XCTAssertEqual(fit("That we should ship.", before: "I think"), .init(text: "that we should ship.", leadingSpace: true))
        XCTAssertEqual(fit("And then we left.", before: "We ate,"), .init(text: "and then we left.", leadingSpace: true))
        XCTAssertEqual(fit("But not today.", before: "Sure "), .init(text: "but not today.", leadingSpace: false))
    }

    func testANameKeepsItsCapitalMidSentence() {
        XCTAssertEqual(fit("John is coming.", before: "I think"), .init(text: "John is coming.", leadingSpace: true))
        XCTAssertEqual(fit("May works for me.", before: "Let's meet in"), .init(text: "May works for me.", leadingSpace: true))
        XCTAssertEqual(fit("I can do it.", before: "Sure,"), .init(text: "I can do it.", leadingSpace: true))
        XCTAssertEqual(fit("I'll do it.", before: "Sure,"), .init(text: "I'll do it.", leadingSpace: true))
        XCTAssertEqual(fit("API keys rotate.", before: "and the"), .init(text: "API keys rotate.", leadingSpace: true))
    }

    func testAfterASentenceEndTheCapitalStays() {
        XCTAssertEqual(fit("That works.", before: "Done."), .init(text: "That works.", leadingSpace: true))
        XCTAssertEqual(fit("That works.", before: "Done. "), .init(text: "That works.", leadingSpace: false))
        XCTAssertEqual(fit("That works.", before: "Really?"), .init(text: "That works.", leadingSpace: true))
        XCTAssertEqual(fit("That works.", before: "He said \"done.\""), .init(text: "That works.", leadingSpace: true))
    }

    func testANewLineOrOpeningMarkTakesNoSpace() {
        XCTAssertEqual(fit("That works.", before: "Hi Sam,\n"), .init(text: "That works.", leadingSpace: false))
        XCTAssertEqual(fit("That works", before: "note ("), .init(text: "That works", leadingSpace: false))
        XCTAssertEqual(fit("That works", before: "he said \""), .init(text: "That works", leadingSpace: false))
    }

    func testAfterAColonTheCaseIsKept() {
        XCTAssertEqual(fit("The plan is set.", before: "Update:"), .init(text: "The plan is set.", leadingSpace: true))
    }

    func testSymbolsAndPunctuationAttachAsTheyAre() {
        XCTAssertEqual(fit("That", before: "path/"), .init(text: "That", leadingSpace: false))
        XCTAssertEqual(fit(", and then", before: "We left"), .init(text: ", and then", leadingSpace: false))
        XCTAssertEqual(fit("\nNext line", before: "First"), .init(text: "\nNext line", leadingSpace: false))
    }

    func testStylesThatDontCapitalizeAreNeverRecased() {
        XCTAssertEqual(fit("That works", before: "I think", capitalizes: false), .init(text: "That works", leadingSpace: true))
    }

    // MARK: - Space after

    func testNoTrailingSpaceBeforeSpaceOrPunctuation() {
        XCTAssertEqual(fit("that works ", before: "I think ", after: " and more").text, "that works")
        XCTAssertEqual(fit("that works ", before: "I think ", after: ".").text, "that works")
    }

    func testASpaceBeforeAWordTheTextWouldRunInto() {
        XCTAssertEqual(fit("that works", before: "I think ", after: "today").text, "that works ")
    }

    // MARK: - One-line fields

    func testOneLineFieldsDropTheFullStopAndLineBreaks() {
        XCTAssertEqual(fit("Quarterly report.", before: "", field: .singleLine).text, "Quarterly report")
        XCTAssertEqual(fit("Quarterly report. ", before: "", field: .singleLine).text, "Quarterly report")
        XCTAssertEqual(fit("Line one\n\nLine two", before: "", field: .singleLine).text, "Line one Line two")
    }

    func testOneLineFieldsKeepMarksThatCarryMeaning() {
        XCTAssertEqual(fit("Is it done?", before: "", field: .singleLine).text, "Is it done?")
        XCTAssertEqual(fit("Done. Shipping now.", before: "", field: .singleLine).text, "Done. Shipping now.")
        XCTAssertEqual(fit("Wait...", before: "", field: .singleLine).text, "Wait...")
    }

    // MARK: - Register

    func testALowercaseDraftGetsLowercaseStarts() {
        let before = "hey\nare you around later"
        XCTAssertEqual(fit("Sure. That works.", before: before + "\n", chat: true).text, "sure. that works")
    }

    func testOneLowercaseLineIsNotEnoughToGoOn() {
        XCTAssertEqual(fit("Sure. That works.", before: "hey\n", chat: true).text, "Sure. That works.")
    }

    func testADraftWithFullStopsKeepsThem() {
        let before = "Hey. Are you around later?\n"
        XCTAssertEqual(fit("Sure. That works.", before: before, chat: true).text, "Sure. That works.")
    }

    func testNamesKeepTheirCapitalsInALowercaseDraft() {
        let before = "ok\nsounds good to me\n"
        XCTAssertEqual(fit("Sam is in. John too.", before: before, chat: true).text, "Sam is in. John too")
    }

    func testRegisterIsOnlyForChat() {
        let before = "hey\nare you around later\n"
        XCTAssertEqual(fit("Sure. That works.", before: before, chat: false).text, "Sure. That works.")
    }

    // MARK: - Reading the field

    func testContextIsCutAroundTheSelection() {
        let context = InsertionContext(field: .multiLine, value: "Hello world, bye", location: 6, length: 5)
        XCTAssertEqual(context.before, "Hello ")
        XCTAssertEqual(context.after, ", bye")
        let unreadable = InsertionContext(field: .singleLine, value: nil, location: 3)
        XCTAssertNil(unreadable.before)
        XCTAssertEqual(InsertionContext.field(forRole: "AXSearchField"), .singleLine)
        XCTAssertEqual(InsertionContext.field(forRole: "AXTextArea"), .multiLine)
        XCTAssertEqual(InsertionContext.field(forRole: "AXWebArea"), .unknown)
    }

    func testLongFieldsKeepOnlyTheTextNearTheCaret() {
        let value = String(repeating: "a", count: 1_000) + "end"
        let context = InsertionContext(field: .multiLine, value: value, location: 1_003)
        XCTAssertEqual(context.before?.count, InsertionContext.contextLength)
        XCTAssertEqual(context.after, "")
    }

    // MARK: - Protected text

    func testASnippetKeepsItsCapitalAfterASentenceInProgress() {
        let context = InsertionContext(field: .multiLine, before: "I think", after: "")
        let fit = InsertionFit.fit("That works.", into: context, capitalizes: true, mirrorsRegister: false,
                                   protecting: ["That works."])
        XCTAssertEqual(fit.text, "That works.")
        XCTAssertTrue(fit.leadingSpace)
        // Without the protection the everyday word joins the sentence.
        XCTAssertEqual(InsertionFit.fit("That works.", into: context, capitalizes: true, mirrorsRegister: false).text,
                       "that works.")
    }

    func testProtectedTextSurvivesARegisterAndAOneLineField() {
        let chat = InsertionContext(field: .multiLine, before: "sure thing\nsee you there\nok", after: "")
        let mirrored = InsertionFit.fit("Thanks. Best, Kanishk.", into: chat, capitalizes: true, mirrorsRegister: true,
                                        protecting: ["Best, Kanishk."])
        XCTAssertTrue(mirrored.text.hasSuffix("Best, Kanishk."), mirrored.text)

        let line = InsertionContext(field: .singleLine, before: "", after: "")
        XCTAssertEqual(InsertionFit.fit("See VocaMac.", into: line, capitalizes: true, mirrorsRegister: false,
                                        protecting: ["VocaMac."]).text, "See VocaMac.")
    }

    // MARK: - The field at delivery

    func testDeliveryUsesTheFreshReadOfTheSameField() {
        let frame = CGRect(x: 10, y: 20, width: 300, height: 40)
        let start = InsertionContext(field: .multiLine, before: "I think", after: "", frame: frame)
        let now = InsertionContext(field: .multiLine, before: "I think so,", after: "", frame: frame)
        XCTAssertEqual(InsertionFit.deliveryContext(start: start, now: now), now)
    }

    func testAnotherFieldAtDeliveryFitsNothing() {
        let start = InsertionContext(field: .multiLine, before: "I think", after: "", frame: CGRect(x: 0, y: 0, width: 300, height: 40))
        let moved = InsertionContext(field: .multiLine, before: "", after: "", frame: CGRect(x: 0, y: 200, width: 300, height: 40))
        XCTAssertNil(InsertionFit.deliveryContext(start: start, now: moved))
        let otherKind = InsertionContext(field: .singleLine, before: "", after: "", frame: start.frame)
        XCTAssertNil(InsertionFit.deliveryContext(start: start, now: otherKind))
        XCTAssertNil(InsertionFit.deliveryContext(start: start, now: nil), "An unreadable field fits nothing")
        XCTAssertNil(InsertionFit.deliveryContext(start: nil, now: start))
    }

    func testWithoutFramesOnlyUnchangedTextCountsAsTheSameField() {
        let start = InsertionContext(field: .multiLine, before: "I think", after: "")
        XCTAssertEqual(InsertionFit.deliveryContext(start: start, now: start), start)
        let other = InsertionContext(field: .multiLine, before: "", after: "")
        XCTAssertNil(InsertionFit.deliveryContext(start: start, now: other))
    }
}
