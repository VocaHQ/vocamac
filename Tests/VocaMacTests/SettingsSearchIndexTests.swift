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

    func testPasswordQueryFindsTheHistoryExclusions() {
        let first = SettingsSearchIndex.matches(query: "password").first
        XCTAssertEqual(first?.id, "history-excluded-apps")
        XCTAssertEqual(SettingsSearchIndex.matches(query: "exclude").first?.id, "history-excluded-apps")
    }

    func testIdleQueryHitsKeepAlive() {
        let matches = SettingsSearchIndex.matches(query: "idle")
        XCTAssertTrue(matches.contains { $0.id == "idle-unload" })
    }

    func testCleanupQueryHitsCleanupPage() {
        let matches = SettingsSearchIndex.matches(query: "filler")
        XCTAssertTrue(matches.contains { $0.page == .cleanup })
        XCTAssertEqual(SettingsSearchIndex.firstMatchingPage(query: "qwen"), .cleanup)
    }

    func testCommandModeHasItsOwnPage() {
        for term in ["command", "saved commands", "voice actions", "same model"] {
            XCTAssertEqual(SettingsSearchIndex.firstMatchingPage(query: term), .commandMode, term)
        }
        XCTAssertFalse(SettingsSearchIndex.entries.contains { $0.page == .cleanup && $0.id.hasPrefix("command-mode") })
        XCTAssertEqual(CalmNavigation.destination(for: .commandMode), .main(.commands))
    }

    func testEndpointQueryFindsCustomEndpointOnSpeechModel() {
        for term in ["endpoint", "remote", "server"] {
            let matches = SettingsSearchIndex.matches(query: term)
            XCTAssertTrue(
                matches.contains { $0.id == "custom-endpoint" && $0.page == .speechModel },
                "\(term) should find Custom Endpoint"
            )
        }
        XCTAssertEqual(SettingsSearchIndex.firstMatchingPage(query: "whisper.cpp"), .speechModel)
    }

    func testTrailingQueryHitsFormatting() {
        let matches = SettingsSearchIndex.matches(query: "trailing")
        XCTAssertTrue(matches.contains { $0.page == .formatting })
        XCTAssertEqual(SettingsSearchIndex.firstMatchingPage(query: "trailing"), .formatting)
    }

    func testLanguageAndTranslationHaveTheirOwnPage() {
        XCTAssertEqual(SettingsSearchIndex.entries.first { $0.id == "language" }?.page, .language)
        XCTAssertEqual(SettingsSearchIndex.firstMatchingPage(query: "translation"), .language)
        XCTAssertEqual(CalmNavigation.destination(for: .language), .settings(.languages))
        XCTAssertEqual(CalmSettingsDestination.languages.parent, .general)
        XCTAssertEqual(CalmNavigation.destination(for: .formatting), .main(.styles))
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

    /// "Tone" names both the start/stop sound cues and the Formal / Casual
    /// wording setting, so a search for it must find both.
    func testToneQueryHitsSoundsAndWritingTone() {
        let matches = SettingsSearchIndex.matches(query: "tone")
        XCTAssertTrue(matches.contains { $0.id == "sound-effects" })
        XCTAssertTrue(matches.contains { $0.id == "writing-wording" })
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

// MARK: - Window layout (v3)

final class SettingsSectionTests: XCTestCase {
    /// Every old page still has a home, so deep links, menu bar entries
    /// and error fixes that name one keep working.
    func testEveryPageHasExactlyOneHome() {
        for page in SettingsPage.allCases {
            switch CalmNavigation.destination(for: page) {
            case .main(let main):
                XCTAssertTrue(CalmMainPage.allCases.contains(main), "\(page)")
            case .settings(let destination):
                XCTAssertTrue(
                    CalmSettingsMenuGroup.containing(destination) != nil || destination == .about,
                    "\(page) is not reachable from the Settings menu"
                )
            }
        }
        let homes = Set(SettingsPage.allCases.map(CalmNavigation.destination(for:)))
        let mainPages = Set(CalmMainPage.allCases.map(CalmDestination.main))
        XCTAssertTrue(mainPages.isSubset(of: homes), "a sidebar page has nothing mapped to it")
    }

    func testPerformanceSitsBesideTheSpeechModel() {
        // v3: performance joins audio and app settings in System; the
        // speech model has Models to itself, one step away in the menu.
        XCTAssertEqual(CalmNavigation.destination(for: .performance), .settings(.system))
        XCTAssertEqual(CalmNavigation.destination(for: .audio), .settings(.system))
        XCTAssertEqual(CalmNavigation.destination(for: .speechModel), .settings(.models))
        XCTAssertEqual(CalmSettingsMenuGroup.settings.items, [.general, .system, .models, .cleanup])
    }

    func testPermissionsPageKeepsItsStoredRawValue() {
        // A remembered last page is stored by raw value.
        XCTAssertEqual(SettingsPage.advanced.rawValue, "advanced")
        XCTAssertEqual(SettingsPage.advanced.title, "Permissions & Logs")
        XCTAssertEqual(CalmNavigation.destination(for: .advanced), .settings(.advanced))
    }

    func testOldAdvancedSearchTermsStillFindThePermissionsPage() {
        XCTAssertTrue(SettingsSearchIndex.matches(query: "advanced").contains { $0.page == .advanced })
        XCTAssertTrue(CalmNavigation.searchGroups(for: "advanced").contains { $0.destination == .settings(.advanced) })
    }
}
