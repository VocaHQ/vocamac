// SpokenNumbersTests.swift
// VocaMac Tests
//
// Ported from VocaPhone's SpokenNumbersTests, so the clients stay in step.
// Mostly about what must *not* change: a converter that turns "no one" into
// "no 1" is worse than no converter at all.

import XCTest
@testable import VocaMac

final class SpokenNumbersTests: XCTestCase {
    private func converted(_ text: String) -> String {
        SpokenNumbers.digits(in: text)
    }

    // MARK: - The thing it is for

    func testATimeBecomesDigits() {
        XCTAssertEqual(converted("six pm at office"), "6 pm at office")
        XCTAssertEqual(converted("call me at eight am"), "call me at 8 am")
        XCTAssertEqual(converted("the meeting is at eleven o'clock"), "the meeting is at 11 o'clock")
    }

    func testPlainQuantitiesBecomeDigits() {
        XCTAssertEqual(converted("I need five copies"), "I need 5 copies")
        XCTAssertEqual(converted("zero results"), "0 results")
        XCTAssertEqual(converted("ten people came"), "10 people came")
        XCTAssertEqual(converted("nineteen days later"), "19 days later")
    }

    func testCompoundNumbersReadAsOneNumber() {
        XCTAssertEqual(converted("twenty three people"), "23 people")
        XCTAssertEqual(converted("twenty-three people"), "23 people")
        XCTAssertEqual(converted("ninety nine problems"), "99 problems")
        XCTAssertEqual(converted("two hundred fifty"), "250")
        XCTAssertEqual(converted("two hundred and fifty"), "250")
        XCTAssertEqual(converted("three thousand"), "3000")
        XCTAssertEqual(converted("twenty five hundred"), "2500")
        XCTAssertEqual(converted("two thousand five hundred"), "2500")
        XCTAssertEqual(converted("one hundred"), "100")
        XCTAssertEqual(converted("two million three thousand five hundred"), "2003500")
    }

    func testDecimalsAreReadOutDigitByDigit() {
        XCTAssertEqual(converted("three point five hours"), "3.5 hours")
        XCTAssertEqual(converted("three point one four"), "3.14")
        XCTAssertEqual(converted("zero point five"), "0.5")
    }

    func testACapitalisedNumberStillConverts() {
        XCTAssertEqual(converted("Twenty people came."), "20 people came.")
        XCTAssertEqual(converted("Six pm works."), "6 pm works.")
    }

    func testPunctuationAroundANumberSurvives() {
        XCTAssertEqual(converted("at six, then seven."), "at 6, then 7.")
        XCTAssertEqual(converted("(twenty three)"), "(23)")
        XCTAssertEqual(converted("six!"), "6!")
    }

    // MARK: - The pronoun problem

    func testALoneOneStaysAWord() {
        XCTAssertEqual(converted("no one came"), "no one came")
        XCTAssertEqual(converted("one of them is broken"), "one of them is broken")
        XCTAssertEqual(converted("one day I'll get to it"), "one day I'll get to it")
        XCTAssertEqual(converted("that's the one"), "that's the one")
        XCTAssertEqual(converted("one another"), "one another")
        XCTAssertEqual(converted("a one-off thing"), "a one-off thing")
    }

    func testALoneOneBeforeAUnitConverts() {
        XCTAssertEqual(converted("see you at one pm"), "see you at 1 pm")
        XCTAssertEqual(converted("one hour later"), "1 hour later")
        XCTAssertEqual(converted("one percent of them"), "1 percent of them")
        XCTAssertEqual(converted("one kg of rice"), "1 kg of rice")
    }

    /// Only a plain space attaches the unit. "one, pm" is a list, not a time.
    func testALoneOneKeepsItsWordAcrossPunctuation() {
        XCTAssertEqual(converted("one, pm"), "one, pm")
        XCTAssertEqual(converted("one\npm"), "one\npm")
    }

    func testOneInsideALargerNumberConverts() {
        XCTAssertEqual(converted("twenty one people"), "21 people")
        XCTAssertEqual(converted("one thousand"), "1000")
        XCTAssertEqual(converted("one hundred and one"), "101")
    }

    // MARK: - What it refuses to guess

    /// Two numbers side by side are two numbers. "6 7" and "13" are both worse
    /// than what the user actually said.
    func testAdjacentNumbersThatDoNotComposeAreLeftAlone() {
        XCTAssertEqual(converted("six seven"), "six seven")
        XCTAssertEqual(converted("one two three four"), "one two three four")
        XCTAssertEqual(converted("nineteen eighty four"), "nineteen eighty four")
        XCTAssertEqual(converted("twenty twenty five"), "twenty twenty five")
    }

    func testSpokenTimesAreLeftAlone() {
        XCTAssertEqual(converted("seven thirty"), "seven thirty")
        XCTAssertEqual(converted("meet me at seven thirty"), "meet me at seven thirty")
    }

    func testOrdinalsAreNeverRewritten() {
        XCTAssertEqual(converted("first of May"), "first of May")
        XCTAssertEqual(converted("second thoughts"), "second thoughts")
        XCTAssertEqual(converted("the twenty first"), "the twenty first")
        XCTAssertEqual(converted("the twenty-first"), "the twenty-first")
        XCTAssertEqual(converted("her thirtieth birthday"), "her thirtieth birthday")
    }

    /// In dictation "second" is a unit far more often than an ordinal.
    func testSecondIsTreatedAsAUnitRatherThanAnOrdinal() {
        XCTAssertEqual(converted("a five second delay"), "a 5 second delay")
        XCTAssertEqual(converted("one second please"), "1 second please")
    }

    func testConnectingWordsAreNotNumbersOnTheirOwn() {
        XCTAssertEqual(converted("hundreds of people"), "hundreds of people")
        XCTAssertEqual(converted("that is the point"), "that is the point")
        XCTAssertEqual(converted("you and I"), "you and I")
        XCTAssertEqual(converted("hundred"), "hundred")
    }

    func testAConjunctionBetweenNumbersIsNotPartOfThem() {
        XCTAssertEqual(converted("between five and ten"), "between 5 and 10")
        XCTAssertEqual(converted("two and three"), "2 and 3")
        XCTAssertEqual(converted("two hundred and the rest"), "200 and the rest")
    }

    func testATrailingConnectorIsReturnedToTheSentence() {
        XCTAssertEqual(converted("five point Nemo"), "5 point Nemo")
        XCTAssertEqual(converted("at some point five people came"), "at some point 5 people came")
    }

    func testImpossibleCombinationsAreLeftAsWords() {
        XCTAssertEqual(converted("zero hundred"), "zero hundred")
        XCTAssertEqual(converted("twenty hundred"), "twenty hundred")
        XCTAssertEqual(converted("three thousand two million"), "three thousand two million")
    }

    func testTheLargestExpressibleNumberConvertsAndNothingBeyondIt() {
        let largest = "nine hundred ninety nine billion "
            + "nine hundred ninety nine million "
            + "nine hundred ninety nine thousand "
            + "nine hundred ninety nine"
        XCTAssertEqual(converted(largest), "999999999999")
        XCTAssertEqual(SpokenNumbers.maximum, 999_999_999_999)
        XCTAssertEqual(converted("one trillion"), "one trillion")
    }

    // MARK: - Everything else passes through

    func testTextWithoutNumbersIsUnchanged() {
        let sentence = "Ship the release notes to the team before standup."
        XCTAssertEqual(converted(sentence), sentence)
        XCTAssertEqual(converted(""), "")
    }

    func testDigitsAlreadyInTheTextAreUntouched() {
        XCTAssertEqual(converted("call 9876543210 now"), "call 9876543210 now")
        XCTAssertEqual(converted("version 2.1 is out"), "version 2.1 is out")
    }

    func testOtherLanguagesPassThrough() {
        XCTAssertEqual(converted("मुझे तीन कॉपी चाहिए"), "मुझे तीन कॉपी चाहिए")
        XCTAssertEqual(converted("necesito cinco copias"), "necesito cinco copias")
    }

    func testNumbersInsideWordsAreNotNumbers() {
        XCTAssertEqual(converted("someone told me"), "someone told me")
        XCTAssertEqual(converted("anyone can join"), "anyone can join")
        XCTAssertEqual(converted("tennis at noon"), "tennis at noon")
    }

    func testLineBreaksEndARun() {
        XCTAssertEqual(converted("twenty\nthree"), "20\n3")
    }

    /// Masked snippets and glyphs are private-use scalars the word pattern
    /// never matches, and they end a run like any other punctuation.
    func testPlaceholdersAreNotWordsAndBreakARun() {
        XCTAssertEqual(converted("twenty \u{E000} three"), "20 \u{E000} 3")
        XCTAssertEqual(converted("\u{E001}five copies"), "\u{E001}5 copies")
    }
}
