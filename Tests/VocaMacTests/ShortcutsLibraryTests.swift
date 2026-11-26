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

    // MARK: - Deadline

    func testAListThatNeverAnswersGivesUpAtTheDeadline() async {
        let start = Date()
        let names = await ShortcutsLibrary.names(within: 0.2) {
            Thread.sleep(forTimeInterval: 3)
            return ["Too late"]
        }
        XCTAssertNil(names)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5, "the caller isn't held past the deadline")
    }

    func testAPromptListIsReturned() async {
        let names = await ShortcutsLibrary.names(within: 2) { ["Morning Routine"] }
        XCTAssertEqual(names, ["Morning Routine"])
    }
}

// MARK: - Performer

@MainActor
final class ShortcutVoiceActionTests: XCTestCase {
    private func failure(_ result: Result<Void, VoiceActionError>) -> VoiceActionError? {
        if case .failure(let error) = result { return error }
        return nil
    }
    func testCancellingDuringTheLookupDoesNotRunTheShortcut() async {
        let gate = StepGate()
        var opened: [URL] = []
        let performer = SystemVoiceActionPerformer(
            installedShortcutNames: {
                await gate.wait()
                return ["Morning Routine"]
            },
            openShortcutURL: { opened.append($0); return true }
        )

        let run = Task { await performer.perform(.runShortcut("Morning Routine"), input: nil) }
        let reachedGate = await gate.waitUntilReached()
        XCTAssertTrue(reachedGate)
        run.cancel()
        gate.open()

        let result = await run.value
        XCTAssertEqual(failure(result), .cancelled)
        XCTAssertTrue(opened.isEmpty, "Escape means the shortcut doesn't run")
    }

    func testACommandCancelledDuringTheLookupDoesNotRunTheShortcut() async {
        var opened: [URL] = []
        var wanted = true
        let performer = SystemVoiceActionPerformer(
            installedShortcutNames: { ["Morning Routine"] },
            openShortcutURL: { opened.append($0); return true }
        )

        wanted = false  // Escape while the names were being read
        let result = await performer.perform(.runShortcut("Morning Routine"), input: nil) { wanted }

        XCTAssertEqual(failure(result), .cancelled)
        XCTAssertTrue(opened.isEmpty)
    }

    func testMissingShortcutIsReportedAndNotOpened() async {
        var opened: [URL] = []
        let performer = SystemVoiceActionPerformer(
            installedShortcutNames: { ["Evening Routine"] },
            openShortcutURL: { opened.append($0); return true }
        )

        let result = await performer.perform(.runShortcut("Morning Routine"), input: nil)

        XCTAssertEqual(failure(result), .shortcutMissing("Morning Routine"))
        XCTAssertTrue(opened.isEmpty)
    }

    func testUnreadableListRunsTheShortcutAsBefore() async {
        var opened: [URL] = []
        let performer = SystemVoiceActionPerformer(
            installedShortcutNames: { nil },
            openShortcutURL: { opened.append($0); return true }
        )

        let result = await performer.perform(.runShortcut("Morning Routine"), input: nil)

        XCTAssertNil(failure(result))
        XCTAssertEqual(opened.count, 1)
    }
}
