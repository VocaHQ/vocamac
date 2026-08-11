// StatsShareCardTests.swift
// VocaMac Tests

import XCTest
@testable import VocaMac

final class StatsShareCardTests: XCTestCase {

    func testSnapshotFromUserStats() {
        var stats = UserStats()
        stats.totalWords = 1200
        stats.totalTranscriptions = 40
        stats.totalAudioDurationSeconds = 600 // 20 WPM from 1200 words / 10 minutes
        stats.currentStreak = 3
        stats.bestStreak = 12

        let snapshot = StatsShareSnapshot.from(stats)
        XCTAssertEqual(snapshot.totalWords, 1200)
        XCTAssertEqual(snapshot.totalTranscriptions, 40)
        XCTAssertEqual(snapshot.averageWPM, 120.0, accuracy: 0.01)
        XCTAssertEqual(snapshot.currentStreak, 3)
        XCTAssertEqual(snapshot.bestStreak, 12)
    }
}
