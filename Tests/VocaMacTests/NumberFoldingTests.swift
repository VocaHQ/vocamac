// NumberFoldingTests.swift
// VocaMac

import XCTest
@testable import VocaMac

final class NumberFoldingTests: XCTestCase {
    private func fold(_ text: String) -> String {
        NumberFolding.fold(text.split(separator: " ").map(String.init)).joined(separator: " ")
    }

    func testCardinals() {
        XCTAssertEqual(fold("three"), "3")
        XCTAssertEqual(fold("twenty one"), "21")
        XCTAssertEqual(fold("one hundred and five"), "105")
        XCTAssertEqual(fold("one hundred twenty three"), "123")
        XCTAssertEqual(fold("two thousand twenty six"), "2026")
        XCTAssertEqual(fold("five million two hundred thousand"), "5200000")
        XCTAssertEqual(fold("ten thousand"), "10000")
        XCTAssertEqual(fold("zero"), "0")
    }

    func testYearsReadAsPairs() {
        XCTAssertEqual(fold("nineteen ninety nine"), "1999")
        XCTAssertEqual(fold("twenty twenty six"), "2026")
        XCTAssertEqual(fold("nineteen hundred"), "1900")
    }

    func testOrdinalsEndANumber() {
        XCTAssertEqual(fold("the third"), "the 3rd")
        XCTAssertEqual(fold("twenty first floor"), "21st floor")
        XCTAssertEqual(fold("eleventh"), "11th")
        XCTAssertEqual(fold("twentieth"), "20th")
    }

    func testWordsThatCannotContinueStartANewNumber() {
        XCTAssertEqual(fold("one two three"), "1 2 3")
        XCTAssertEqual(fold("twenty thirty"), "2030")
        XCTAssertEqual(fold("one of them"), "1 of them")
        XCTAssertEqual(fold("thousand islands"), "thousand islands")
        XCTAssertEqual(fold("rock and roll"), "rock and roll")
        XCTAssertEqual(fold("one hundred and counting"), "100 and counting")
    }

    func testDecimalPoint() {
        XCTAssertEqual(fold("three point five"), "3 5")
        XCTAssertEqual(fold("the point is"), "the point is")
    }
}
