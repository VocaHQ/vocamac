// StatsShareCardTests.swift
// VocaMac Tests

import XCTest
@testable import VocaMac

final class StatsShareCardTests: XCTestCase {

    func testSnapshotFromUserStats() {
        var stats = UserStats()
        stats.totalWords = 1200
        stats.totalTranscriptions = 40
        stats.totalAudioDurationSeconds = 3600
        stats.averageWPM = 95
        stats.currentStreak = 3
        stats.bestStreak = 12

        let snapshot = StatsShareSnapshot.from(stats)
        XCTAssertEqual(snapshot.totalWords, 1200)
        XCTAssertEqual(snapshot.totalTranscriptions, 40)
        XCTAssertEqual(snapshot.averageWPM, 95)
        XCTAssertEqual(snapshot.currentStreak, 3)
        XCTAssertEqual(snapshot.bestStreak, 12)
    }
}
