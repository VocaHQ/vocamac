// TranscriptionLanguageTests.swift
// VocaMac Tests

import XCTest
@testable import VocaMac

final class TranscriptionLanguageTests: XCTestCase {

    func testCatalogIncludesAutoAndHungarian() {
        XCTAssertTrue(TranscriptionLanguage.catalog.contains { $0.code == "auto" })
        XCTAssertTrue(TranscriptionLanguage.catalog.contains { $0.code == "hu" })
        XCTAssertTrue(TranscriptionLanguage.catalog.contains { $0.code == "vi" })
        XCTAssertGreaterThanOrEqual(TranscriptionLanguage.catalog.count, 30)
    }

    func testCodesAreUnique() {
        let codes = TranscriptionLanguage.catalog.map(\.code)
        XCTAssertEqual(codes.count, Set(codes).count)
    }

    func testFilterByNameAndCode() {
        let byName = TranscriptionLanguage.filtered(search: "hungar")
        XCTAssertEqual(byName.map(\.code), ["hu"])

        let byCode = TranscriptionLanguage.filtered(search: "ja")
        XCTAssertTrue(byCode.contains { $0.code == "ja" })
    }

    func testSelectableExcludesAutoAndIsSorted() {
        let selectable = TranscriptionLanguage.selectable
        XCTAssertFalse(selectable.contains { $0.code == "auto" })
        let names = selectable.map(\.displayName)
        XCTAssertEqual(names, names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }
}
