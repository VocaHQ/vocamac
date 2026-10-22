// ModelUsageLogTests.swift
// VocaMac Tests

import XCTest
@testable import VocaMac

final class ModelUsageLogTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ModelUsageLogTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private let day: TimeInterval = 86_400

    func testMarkUsedRecordsLastUseAndKeepsFirstSeen() {
        let log = ModelUsageLog(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_000_000)
        log.noteSeen([.speech(.small)], at: start)
        log.markUsed([.speech(.small)], at: start.addingTimeInterval(day))

        let entry = log.entry(for: .speech(.small))
        XCTAssertEqual(entry?.firstSeen, start)
        XCTAssertEqual(entry?.lastUsed, start.addingTimeInterval(day))
    }

    func testNoteSeenDoesNotResetAnExistingEntry() {
        let log = ModelUsageLog(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_000_000)
        log.markUsed([.writing(.qwen25_0_5b_q4_k_m)], at: start)
        log.noteSeen([.writing(.qwen25_0_5b_q4_k_m)], at: start.addingTimeInterval(10 * day))

        XCTAssertEqual(log.entry(for: .writing(.qwen25_0_5b_q4_k_m))?.firstSeen, start)
    }

    func testForgetDropsTheEntry() {
        let log = ModelUsageLog(defaults: defaults)
        log.markUsed([.speech(.parakeetV3)])
        log.forget(.speech(.parakeetV3))
        XCTAssertNil(log.entry(for: .speech(.parakeetV3)))
    }

    func testSpeechAndWritingKeysDontCollide() {
        XCTAssertNotEqual(
            DownloadedModelID.speech(.small).storageKey,
            DownloadedModelID.writing(.qwen25_0_5b_q4_k_m).storageKey
        )
        XCTAssertTrue(DownloadedModelID.speech(.small).storageKey.hasPrefix("speech."))
    }

    // MARK: Idle

    func testUnknownModelIsNeverIdle() {
        XCTAssertFalse(ModelUsageLog.isIdle(nil))
    }

    func testIdleCountsFromLastUse() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let old = now.addingTimeInterval(-100 * day)
        let recent = ModelUsageLog.Entry(lastUsed: now.addingTimeInterval(-29 * day), firstSeen: old)
        let stale = ModelUsageLog.Entry(lastUsed: now.addingTimeInterval(-30 * day), firstSeen: old)
        XCTAssertFalse(ModelUsageLog.isIdle(recent, now: now))
        XCTAssertTrue(ModelUsageLog.isIdle(stale, now: now))
    }

    func testNeverUsedCountsFromFirstSeen() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        XCTAssertFalse(ModelUsageLog.isIdle(.init(lastUsed: nil, firstSeen: now.addingTimeInterval(-5 * day)), now: now))
        XCTAssertTrue(ModelUsageLog.isIdle(.init(lastUsed: nil, firstSeen: now.addingTimeInterval(-31 * day)), now: now))
    }
}

final class CalmModelStorageTests: XCTestCase {
    private let day: TimeInterval = 86_400

    private func model(_ id: DownloadedModelID, bytes: Int64, path: String?, usage: ModelUsageLog.Entry? = nil) -> CalmDownloadedModel {
        CalmDownloadedModel(id: id, location: path.map { URL(fileURLWithPath: $0) }, bytes: bytes, usage: usage)
    }

    func testTotalCountsASharedFolderOnce() {
        let storage = CalmModelStorage(
            speech: [
                model(.speech(.parakeetV3), bytes: 500, path: "/models/parakeet-v3"),
                model(.speech(.parakeetUltra), bytes: 500, path: "/models/parakeet-v3"),
                model(.speech(.small), bytes: 300, path: "/models/small"),
            ],
            writing: [model(.writing(.qwen25_0_5b_q4_k_m), bytes: 200, path: "/models/q.gguf")]
        )
        XCTAssertEqual(storage.totalBytes, 1000)
    }

    func testIdleKeepsOnlyRemovableStaleModels() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let stale = ModelUsageLog.Entry(lastUsed: now.addingTimeInterval(-40 * day), firstSeen: now.addingTimeInterval(-90 * day))
        let fresh = ModelUsageLog.Entry(lastUsed: now.addingTimeInterval(-2 * day), firstSeen: now.addingTimeInterval(-90 * day))
        let storage = CalmModelStorage(speech: [
            model(.speech(.small), bytes: 1, path: "/a", usage: stale),
            model(.speech(.tiny), bytes: 1, path: "/b", usage: stale),
            model(.speech(.base), bytes: 1, path: "/c", usage: fresh),
            model(.speech(.medium), bytes: 1, path: "/d", usage: nil),
        ])
        let idle = storage.idle(removable: { $0 != .speech(.tiny) }, now: now)
        XCTAssertEqual(idle.map(\.id), [.speech(.small)])
    }

    // MARK: Fit

    func testMemoryFit() {
        XCTAssertEqual(CalmMemoryFit.of(requiredGB: 2, memoryGB: 16, share: 0.5), .comfortable)
        XCTAssertEqual(CalmMemoryFit.of(requiredGB: 5, memoryGB: 8, share: 0.5), .tight)
        XCTAssertEqual(CalmMemoryFit.of(requiredGB: 9, memoryGB: 8, share: 0.5), .tooBig)
        XCTAssertNil(CalmMemoryFit.comfortable.warning(requiredGB: 1, memoryGB: 8))
        XCTAssertEqual(CalmMemoryFit.tooBig.warning(requiredGB: 9, memoryGB: 8), "Needs about 9 GB, more than this Mac has")
        XCTAssertEqual(CalmMemoryFit.tight.warning(requiredGB: 4.5, memoryGB: 8), "Needs about 4.5 GB, a lot for this Mac’s 8 GB")
    }

    // MARK: Text

    func testLastUsedText() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 10_000_000)
        func text(_ daysAgo: Double) -> String? {
            CalmModelText.lastUsed(.init(lastUsed: now.addingTimeInterval(-daysAgo * day), firstSeen: now), now: now, calendar: calendar)
        }
        XCTAssertEqual(text(0), "Used today")
        XCTAssertEqual(text(1), "Used yesterday")
        XCTAssertEqual(text(3), "Used 3 days ago")
        XCTAssertEqual(text(21), "Used 3 weeks ago")
        XCTAssertEqual(text(95), "Used 3 months ago")
        XCTAssertNil(CalmModelText.lastUsed(.init(lastUsed: nil, firstSeen: now), now: now))
        XCTAssertNil(CalmModelText.lastUsed(nil))
    }

    func testDeviceAndStorageText() {
        XCTAssertEqual(CalmModelText.device(chip: "Apple M1 Pro", memoryGB: 16), "Apple M1 Pro · 16 GB memory")
        XCTAssertEqual(CalmModelText.device(chip: "Unknown", memoryGB: 8), "8 GB memory")
        XCTAssertEqual(CalmModelText.storage(totalBytes: 5_800_000_000, freeBytes: 120_000_000_000), "Models use 5.8 GB · 120 GB free")
        XCTAssertEqual(CalmModelText.storage(totalBytes: 483_000_000, freeBytes: nil), "Models use 483 MB")
        XCTAssertEqual(CalmModelText.storage(totalBytes: 483_000_000, freeBytes: 115_070_000_000), "Models use 483 MB · 115 GB free")
        XCTAssertEqual(CalmModelText.roughSize(bytes: 4_230_000_000), "4.2 GB")
        XCTAssertEqual(CalmModelText.roughSize(bytes: 700_000_000), "700 MB")
    }

    func testDiskWarningOnlyWhenTooLittleSpace() {
        XCTAssertNil(CalmModelText.diskWarning(required: 1_000_000_000, free: 2_000_000_000))
        XCTAssertEqual(
            CalmModelText.diskWarning(required: 2_100_000_000, free: 1_400_000_000),
            "Needs 2.1 GB free to download, 1.4 GB left"
        )
    }

    func testDiskBytesReadsAFileOrAFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("model.gguf")
        try Data(count: 1234).write(to: file)
        try Data(count: 66).write(to: folder.appendingPathComponent("vocab.json"))
        XCTAssertEqual(AppState.diskBytes(at: file), 1234)
        XCTAssertEqual(AppState.diskBytes(at: folder), 1300)
    }
}

@MainActor
final class CalmModelStorageAppStateTests: XCTestCase {
    func testStorageListsDownloadsThePickerNoLongerOffers() async {
        let (state, mocks) = AppState.makeTestState()
        mocks.modelManager.downloadedModels = [.medium]
        state.availableModels.removeAll { $0.size == .medium }

        let storage = await state.calmMeasureModelStorage()
        XCTAssertTrue(storage.speech.contains { $0.id == .speech(.medium) })
    }

    func testDeletingAnUnlistedDownloadRemovesIt() async {
        let (state, mocks) = AppState.makeTestState()
        mocks.modelManager.downloadedModels = [.medium]
        state.availableModels.removeAll { $0.size == .medium }

        await state.deleteModel(.medium)
        XCTAssertFalse(mocks.modelManager.downloadedModels.contains(.medium))
        XCTAssertEqual(state.unlistedModelRemovals, 1)
    }

    func testDictationStampsAtMostHourly() {
        let (state, _) = AppState.makeTestState()
        let start = Date(timeIntervalSince1970: 2_000_000)
        state.stampModelsInUseIfStale(now: start)
        XCTAssertEqual(state.lastModelUsageStamp, start)
        state.stampModelsInUseIfStale(now: start.addingTimeInterval(600))
        XCTAssertEqual(state.lastModelUsageStamp, start)
        state.stampModelsInUseIfStale(now: start.addingTimeInterval(3700))
        XCTAssertEqual(state.lastModelUsageStamp, start.addingTimeInterval(3700))
    }
}
