// ShortcutsLibraryTests.swift
// VocaMac
//
// A renamed or deleted shortcut must be reported, not announced as run.

import XCTest
@testable import VocaMac

final class ShortcutsLibraryTests: XCTestCase {
    private let installed = ["Morning Routine", "Open App", "New Shortcut 3"]

    func testExactNameMatches() {
        XCTAssertEqual(ShortcutsLibrary.installedName(matching: "Morning Routine", in: installed), "Morning Routine")
    }

    func testCaseOnlyDifferenceUsesTheInstalledSpelling() {
        XCTAssertEqual(ShortcutsLibrary.installedName(matching: "morning routine", in: installed), "Morning Routine")
    }

    func testRenamedShortcutIsMissing() {
        XCTAssertNil(ShortcutsLibrary.installedName(matching: "Morning Routine v1", in: installed))
        XCTAssertNil(ShortcutsLibrary.installedName(matching: "Evening Routine", in: installed))
    }

    func testListOutputIsSplitIntoNames() {
        XCTAssertEqual(
            ShortcutsLibrary.names(fromListOutput: "Morning Routine\nOpen App\n\n  New Shortcut 3  \n"),
            installed
        )
    }

    func testMissingShortcutMessageSaysWhatToDo() {
        let message = VoiceActionError.shortcutMissing("Morning Routine").message
        XCTAssertTrue(message.contains("Morning Routine"))
        XCTAssertTrue(message.contains("renamed"))
    }
}
