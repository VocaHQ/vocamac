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

    func testAboutSearchEntriesStayIndexed() {
        let requiredIDs = ["about", "family", "discord", "email", "github-issues", "x"]
        let entriesByID = Dictionary(
            uniqueKeysWithValues: SettingsSearchIndex.entries.map { ($0.id, $0) }
        )

        for id in requiredIDs {
            guard let entry = entriesByID[id] else {
                XCTFail("Missing About search entry \(id)")
                continue
            }
            XCTAssertEqual(entry.page, .about, id)
        }

        XCTAssertTrue(SettingsSearchIndex.matches(query: "About").contains { $0.id == "about" })
        XCTAssertEqual(SettingsSearchIndex.firstMatchingPage(query: "family"), .about)
        XCTAssertEqual(SettingsSearchIndex.firstMatchingPage(query: "discord"), .about)
        XCTAssertEqual(SettingsSearchIndex.firstMatchingPage(query: "email"), .about)
        XCTAssertTrue(SettingsSearchIndex.matches(query: "github").contains { $0.id == "github-issues" })
        XCTAssertTrue(SettingsSearchIndex.matches(query: "vocahq").contains { $0.id == "family" })

        guard let xEntry = entriesByID["x"] else {
            return
        }
        XCTAssertEqual(xEntry.title, "X")
        XCTAssertFalse(xEntry.title.lowercased().contains("twitter"))
        XCTAssertEqual(SettingsSearchIndex.firstMatchingPage(query: "x.com"), .about)
        XCTAssertEqual(SettingsSearchIndex.firstMatchingPage(query: "twitter"), .about)
        XCTAssertTrue(SettingsSearchIndex.matches(query: "x.com").contains { $0.id == "x" })
        XCTAssertTrue(SettingsSearchIndex.matches(query: "twitter").contains { $0.id == "x" })
    }
}
