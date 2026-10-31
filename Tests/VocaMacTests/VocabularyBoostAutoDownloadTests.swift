// VocabularyBoostAutoDownloadTests.swift
// VocaMac

import XCTest
@testable import VocaMac

final class VocabularyBoostAutoDownloadTests: XCTestCase {

    private func downloads(
        engine: TranscriptionEngine? = .parakeet, vocabulary: String = "Kubernetes",
        status: VocabularyBoostStatus = .notDownloaded, removed: Bool = false
    ) -> Bool {
        VocabularyBoostStatus.downloadsAutomatically(
            engine: engine, vocabulary: vocabulary, status: status, removedByUser: removed
        )
    }

    func testParakeetWithAWordToListenForDownloads() {
        XCTAssertTrue(downloads())
    }

    func testOtherEnginesNeverDownload() {
        XCTAssertFalse(downloads(engine: .whisperKit))
        XCTAssertFalse(downloads(engine: .appleSpeech))
        XCTAssertFalse(downloads(engine: nil))
    }

    func testNothingToListenForMeansNoDownload() {
        XCTAssertFalse(downloads(vocabulary: ""))
        // Too short for the boost to spot.
        XCTAssertFalse(downloads(vocabulary: "AI"))
    }

    func testRemovedOrFailedOrPresentIsLeftAlone() {
        XCTAssertFalse(downloads(removed: true))
        XCTAssertFalse(downloads(status: .ready))
        XCTAssertFalse(downloads(status: .downloading))
        XCTAssertFalse(downloads(status: .failed("offline")))
    }
}
