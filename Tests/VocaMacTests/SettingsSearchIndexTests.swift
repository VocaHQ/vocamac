// SettingsSearchIndexTests.swift
// VocaMac Tests

import XCTest
@testable import VocaMac

final class SettingsSearchIndexTests: XCTestCase {

    func testEmptyQueryReturnsAllEntries() {
        let matches = SettingsSearchIndex.matches(query: "")
        XCTAssertEqual(matches.count, SettingsSearchIndex.entries.count)
        XCTAssertTrue(SettingsSearchIndex.matchCounts(query: "   ").isEmpty)
        XCTAssertNil(SettingsSearchIndex.firstMatchingPage(query: ""))
    }

    func testPauseQueryHitsPerformance() {
        let matches = SettingsSearchIndex.matches(query: "pause")
        XCTAssertFalse(matches.isEmpty)
        XCTAssertTrue(matches.contains { $0.page == .performance })
        XCTAssertEqual(SettingsSearchIndex.firstMatchingPage(query: "pause"), .performance)
    }

    func testIdleQueryHitsKeepAlive() {
        let matches = SettingsSearchIndex.matches(query: "idle")
        XCTAssertTrue(matches.contains { $0.id == "idle-unload" })
    }

    func testTrailingQueryHitsDictation() {
        let matches = SettingsSearchIndex.matches(query: "trailing")
        XCTAssertTrue(matches.contains { $0.page == .dictation })
        XCTAssertEqual(SettingsSearchIndex.firstMatchingPage(query: "trailing"), .dictation)
    }

    func testUnknownQueryIsEmpty() {
        XCTAssertTrue(SettingsSearchIndex.matches(query: "zzznomatch999").isEmpty)
        XCTAssertNil(SettingsSearchIndex.firstMatchingPage(query: "zzznomatch999"))
    }

    func testMatchCountsBadgePerformance() {
        let counts = SettingsSearchIndex.matchCounts(query: "unload")
        XCTAssertGreaterThan(counts[.performance] ?? 0, 0)
        XCTAssertNil(counts[.about])
    }

    func testResourceQueryHitsAdvanced() {
        let matches = SettingsSearchIndex.matches(query: "resource")
        XCTAssertTrue(matches.contains { $0.page == .advanced })
        XCTAssertEqual(SettingsSearchIndex.firstMatchingPage(query: "resource"), .advanced)
    }

    func testToneQueryHitsAudio() {
        let matches = SettingsSearchIndex.matches(query: "tone")
        XCTAssertTrue(matches.contains { $0.id == "sound-effects" })
        XCTAssertEqual(SettingsSearchIndex.firstMatchingPage(query: "tone"), .audio)
    }
}
