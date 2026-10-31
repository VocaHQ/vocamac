// VoiceNoteSafetyTests.swift
// VocaMac
//
// Notes keep their audio through failures: a recorder that stops at the
// limit, a save that can't be written, an index set aside for recovery.
// Plus retention for every source, export names, and where a summary was
// written.

import XCTest
@testable import VocaMac

@MainActor
final class VoiceNoteSafetyTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VocaMac-NoteSafety-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: Limit

    func testARecorderStoppedAtTheLimitStillHandsOverItsAudio() {
        let session = MeetingCaptureSession()
        session.markRecordingForTesting(system: false, microphone: true)
        session.microphone.receiveForTesting([Float](repeating: 0.2, count: 16_000), reachingLimit: true)
        XCTAssertFalse(session.microphone.isRecording, "The recorder stopped itself")
        XCTAssertTrue(session.didReachLimit)

        let samples = session.stop()
        XCTAssertFalse(samples.isEmpty, "What was recorded before the limit is kept")
    }

    // MARK: Failed saves

    func testAFailedSaveThrowsAndLeavesNoNote() async throws {
        let directory = temporaryDirectory()
        // A file where the folder should be: nothing can be written there.
        try Data("x".utf8).write(to: directory)
        let store = VoiceNoteStore(directory: directory)
        do {
            _ = try await store.begin(audio: [0.1, 0.2], source: .meeting)
            XCTFail("The save must fail")
        } catch {
            XCTAssertNotNil(error as? VoiceNoteStoreError)
        }
        XCTAssertTrue(store.notes.isEmpty)
    }

    // MARK: Recovery

    func testFoldersAreKeptWhileABadIndexWaitsForRecovery() throws {
        let directory = temporaryDirectory()
        let folder = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: folder.appendingPathComponent(VoiceNoteStore.audioFileName))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("index.json"))

        _ = VoiceNoteStore.read(directory: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(VoiceNoteStore.corruptIndexName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        // The next launch finds no index, and still must not remove it.
        _ = VoiceNoteStore.read(directory: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: Retention

    func testEverySourceKeepsToRetention() {
        let store = VoiceNoteStore(directory: nil)
        store.retention = .day
        let old = store.addText("from long ago", source: .scratchpad, now: Date(timeIntervalSinceNow: -3 * 86_400))
        let recent = store.addText("from today", source: .scratchpad)
        XCTAssertNil(store.note(id: old))
        XCTAssertNotNil(store.note(id: recent))
    }

    // MARK: Export names

    func testFolderExportNamesCarryTheNoteID() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let date = Date(timeIntervalSince1970: 1_793_200_000)
        let first = VoiceNote(createdAt: date, title: "Sync", source: .meeting, status: .completed)
        let second = VoiceNote(createdAt: date, title: "Sync", source: .meeting, status: .completed)
        let firstName = NoteExporter.fileName(first, format: .markdown, uniquing: true, timeZone: utc)
        XCTAssertNotEqual(firstName, NoteExporter.fileName(second, format: .markdown, uniquing: true, timeZone: utc))
        XCTAssertTrue(firstName.hasSuffix(" \(first.id.uuidString.prefix(8)).md"), firstName)
        XCTAssertEqual(NoteExporter.fileName(first, format: .markdown, timeZone: utc), "2026-10-28 15-06 Sync.md")
    }

    // MARK: Summary provenance

    func testTheSummaryLineSaysWhereItWasWritten() {
        var summary = VoiceNoteSummary(overview: "o", decisions: [], actionItems: [], model: "Ministral", createdAt: Date())
        XCTAssertEqual(summary.provenance, "Written by Ministral.")
        summary.place = VoiceNoteSummaryPlace(engine: .local(.defaultKind))
        XCTAssertEqual(summary.provenance, "Written on this Mac by Ministral.")
        summary.place = VoiceNoteSummaryPlace(engine: .endpoint)
        XCTAssertEqual(summary.provenance, "Written by Ministral on the server Command Mode uses.")
        summary.place = VoiceNoteSummaryPlace(engine: .appleIntelligence)
        XCTAssertEqual(summary.provenance, "Written by Apple Intelligence.")
    }

    // MARK: Summaries and edits

    func testAnEditWaitsForASummary() async {
        let (appState, _) = AppState.makeTestState()
        var refused = false
        let run = await appState.runOnCommandEngine(prompt: "summarize") { _, _ in
            XCTAssertTrue(appState.isSummarizingNote)
            await appState.runCommand(instruction: "make it shorter")
            refused = appState.errorMessage == AppState.summaryBusyMessage
            return 1
        }
        XCTAssertEqual(run.value, 1)
        XCTAssertTrue(refused, appState.errorMessage ?? "no message")
        XCTAssertFalse(appState.isSummarizingNote)
    }
}

final class ImportedGGUFUsersTests: XCTestCase {
    func testCommandModeCountsAsAUser() {
        let both = AppState.importedGGUFUsers(cleanupKind: .customGGUF, commandEngine: .local(.customGGUF))
        XCTAssertTrue(both.cleanup && both.command)
        let commandOnly = AppState.importedGGUFUsers(cleanupKind: .defaultKind, commandEngine: .local(.customGGUF))
        XCTAssertFalse(commandOnly.cleanup)
        XCTAssertTrue(commandOnly.command)
        let neither = AppState.importedGGUFUsers(cleanupKind: .defaultKind, commandEngine: .appleIntelligence)
        XCTAssertFalse(neither.cleanup || neither.command)
    }
}
