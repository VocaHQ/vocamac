// DictationHistoryStoreTests.swift
// VocaMac

import XCTest
@testable import VocaMac

@MainActor
final class DictationHistoryStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocaMacHistoryTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private let target = RunningAppSnapshot(displayName: "Notes", bundleIdentifier: "com.apple.Notes")
    private let audio = [Float](repeating: 0.25, count: 16_000)

    func testCompletedDictationKeepsTextAndAudio() async throws {
        let store = DictationHistoryStore(directory: directory)
        let id = store.begin(audio: audio, target: target, modelID: "tiny", language: "en", audioSeconds: 1)
        XCTAssertEqual(store.entry(id: id)?.status, .pending)

        store.complete(id, rawText: "hello world", finalText: "Hello world. ", summary: "Formatting only",
                       language: "en", transcriptionSeconds: 0.3, keepAudio: true)

        let entry = try XCTUnwrap(store.entry(id: id))
        XCTAssertEqual(entry.status, .completed)
        XCTAssertEqual(entry.appName, "Notes")
        XCTAssertEqual(entry.displayText, "Hello world.")
        XCTAssertFalse(entry.hasEditedOutput, "Case and punctuation alone aren't an edit")
        XCTAssertEqual(store.latestDeliveredText, "Hello world. ")

        let samples = try await store.loadAudio(for: entry)
        XCTAssertEqual(samples.count, audio.count)
    }

    func testAudioIsDroppedOnSuccessWhenNotKept() async {
        let store = DictationHistoryStore(directory: directory)
        let id = store.begin(audio: audio, target: nil, modelID: "tiny", language: nil, audioSeconds: 1)
        store.complete(id, rawText: "hi", finalText: "Hi", summary: nil, language: nil,
                       transcriptionSeconds: nil, keepAudio: false)
        XCTAssertFalse(store.entry(id: id)?.hasAudio ?? true)
        await store.waitForPendingWrites()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: store.audioDirectory!.path)) ?? []
        XCTAssertTrue(files.isEmpty)
    }

    func testFailedDictationIsRecoverable() {
        let store = DictationHistoryStore(directory: directory)
        let id = store.begin(audio: audio, target: nil, modelID: "tiny", language: nil, audioSeconds: 1)
        store.markFailed(id, message: "decoder exploded")
        XCTAssertEqual(store.latestRecoverableEntry?.id, id)
        XCTAssertEqual(store.entry(id: id)?.errorMessage, "decoder exploded")

        // A later success supersedes it.
        let next = store.begin(audio: audio, target: nil, modelID: "tiny", language: nil, audioSeconds: 1)
        store.complete(next, rawText: "ok", finalText: "Ok", summary: nil, language: nil,
                       transcriptionSeconds: nil, keepAudio: true)
        XCTAssertNil(store.latestRecoverableEntry)
    }

    func testPendingEntryBecomesInterruptedAfterRelaunch() async {
        let store = DictationHistoryStore(directory: directory)
        let id = store.begin(audio: audio, target: nil, modelID: "tiny", language: nil, audioSeconds: 1)
        await store.waitForPendingWrites()

        let relaunched = DictationHistoryStore(directory: directory)
        XCTAssertEqual(relaunched.entry(id: id)?.status, .interrupted)
        XCTAssertEqual(relaunched.latestRecoverableEntry?.id, id)
    }

    func testRetryUpdatesEntry() {
        let store = DictationHistoryStore(directory: nil)
        let id = store.begin(audio: nil, target: nil, modelID: "tiny", language: nil, audioSeconds: 1)
        store.markFailed(id, message: "boom")
        store.recordRetry(id, rawText: "fixed", finalText: "Fixed", summary: nil, language: "en",
                          modelID: "parakeet", transcriptionSeconds: 0.2)
        let entry = store.entry(id: id)
        XCTAssertEqual(entry?.status, .completed)
        XCTAssertEqual(entry?.retryCount, 1)
        XCTAssertEqual(entry?.modelID, "parakeet")
        XCTAssertNil(entry?.errorMessage)
    }

    func testCancelOnlyAffectsPendingEntries() {
        let store = DictationHistoryStore(directory: nil)
        let id = store.begin(audio: nil, target: nil, modelID: "tiny", language: nil, audioSeconds: 1)
        store.complete(id, rawText: "done", finalText: "Done", summary: nil, language: nil,
                       transcriptionSeconds: nil, keepAudio: true)
        store.markCancelled(id)
        XCTAssertEqual(store.entry(id: id)?.status, .completed)
    }

    func testRetentionDeletesOldEntries() {
        let store = DictationHistoryStore(directory: nil)
        let now = Date()
        let old = store.begin(audio: nil, target: nil, modelID: "tiny", language: nil, audioSeconds: 1,
                              now: now.addingTimeInterval(-3 * 24 * 60 * 60))
        let recent = store.begin(audio: nil, target: nil, modelID: "tiny", language: nil, audioSeconds: 1, now: now)
        store.applyRetention(.day, now: now)
        XCTAssertNil(store.entry(id: old))
        XCTAssertNotNil(store.entry(id: recent))

        store.applyRetention(.forever, now: now.addingTimeInterval(1_000_000))
        XCTAssertNotNil(store.entry(id: recent))
    }

    func testSearchMatchesEveryWord() {
        let store = DictationHistoryStore(directory: nil)
        let first = store.begin(audio: nil, target: target, modelID: "tiny", language: nil, audioSeconds: 1)
        store.complete(first, rawText: "ship the release", finalText: "Ship the release.", summary: nil,
                       language: nil, transcriptionSeconds: nil, keepAudio: true)
        let second = store.begin(audio: nil, target: nil, modelID: "tiny", language: nil, audioSeconds: 1)
        store.complete(second, rawText: "lunch plans", finalText: "Lunch plans.", summary: nil,
                       language: nil, transcriptionSeconds: nil, keepAudio: true)

        XCTAssertEqual(store.search("release ship").map(\.id), [first])
        XCTAssertEqual(store.search("notes").map(\.id), [first])
        XCTAssertEqual(store.search("").count, 2)
        XCTAssertTrue(store.search("nothing").isEmpty)
    }

    func testDeleteAllRemovesEntriesAndAudio() async {
        let store = DictationHistoryStore(directory: directory)
        store.begin(audio: audio, target: nil, modelID: "tiny", language: nil, audioSeconds: 1)
        store.deleteAll()
        await store.waitForPendingWrites()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioDirectory!.path))
        XCTAssertTrue(DictationHistoryStore(directory: directory).entries.isEmpty)
    }

    func testEditedOutputDetection() {
        var entry = DictationHistoryEntry(rawText: "um gonna ship it", finalText: "Going to ship it.",
                                          modelID: "tiny", audioSeconds: 1)
        XCTAssertTrue(entry.hasEditedOutput)
        entry.finalText = "Um gonna ship it."
        XCTAssertFalse(entry.hasEditedOutput)
    }

    func testRetentionResolvesUnknownValues() {
        XCTAssertEqual(HistoryRetention.resolved(stored: "bogus"), .month)
        XCTAssertEqual(HistoryRetention.resolved(stored: "week"), .week)
    }
}
