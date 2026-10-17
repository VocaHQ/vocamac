// VocaSceneTests.swift
// VocaMac

import XCTest
@testable import VocaMac

final class VocaSceneTests: XCTestCase {

    // MARK: - Time of day

    func testMoodFollowsTheHour() {
        XCTAssertEqual(SceneMood.forHour(4), .night)
        XCTAssertEqual(SceneMood.forHour(5), .dawn)
        XCTAssertEqual(SceneMood.forHour(8), .dawn)
        XCTAssertEqual(SceneMood.forHour(9), .day)
        XCTAssertEqual(SceneMood.forHour(16), .day)
        XCTAssertEqual(SceneMood.forHour(17), .dusk)
        XCTAssertEqual(SceneMood.forHour(19), .dusk)
        XCTAssertEqual(SceneMood.forHour(20), .night)
        XCTAssertEqual(SceneMood.forHour(0), .night)
        XCTAssertEqual(SceneMood.forHour(23), .night)
    }

    func testCurrentMoodReadsTheCalendarHour() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let morning = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 6)))
        let evening = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 18)))
        XCTAssertEqual(SceneMood.current(at: morning, calendar: calendar), .dawn)
        XCTAssertEqual(SceneMood.current(at: evening, calendar: calendar), .dusk)
    }

    func testMenuHeaderMoodClampsNightInLightMode() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let night = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 23)))
        let noon = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12)))
        XCTAssertEqual(SceneMood.menuHeader(for: .light, at: night, calendar: calendar), .dusk)
        XCTAssertEqual(SceneMood.menuHeader(for: .dark, at: night, calendar: calendar), .night)
        XCTAssertEqual(SceneMood.menuHeader(for: .light, at: noon, calendar: calendar), .day)
        XCTAssertEqual(SceneMood.menuHeader(for: .dark, at: noon, calendar: calendar), .day)
    }

    func testOnlyNightHasStars() {
        for mood in SceneMood.allCases {
            XCTAssertEqual(mood.palette.hasStars, mood == .night, "\(mood)")
        }
    }

    // MARK: - Onboarding

    func testOnboardingRunsFromDawnToNight() {
        XCTAssertEqual(OnboardingStep.allCases.first?.mood, .dawn)
        XCTAssertEqual(OnboardingStep.allCases.last?.mood, .night)
    }

    func testOnboardingSceneCaptionIsNumbered() {
        XCTAssertEqual(OnboardingStep.welcome.sceneCaption, "01 — Welcome")
        XCTAssertEqual(OnboardingStep.complete.sceneCaption, "06 — \(OnboardingStep.complete.shortTitle)")
    }

    // MARK: - Settings

    // v3 drops the per-group scene headers; the Settings sheet's menu
    // groups are what keep the pages apart now.
    func testEverySettingsPageBelongsToItsMenuGroup() {
        for group in CalmSettingsMenuGroup.allCases {
            for item in group.items {
                XCTAssertEqual(CalmSettingsMenuGroup.containing(item), group, "\(item)")
            }
        }
        for destination in CalmSettingsDestination.allCases where destination.parent != nil {
            XCTAssertEqual(
                CalmSettingsMenuGroup.containing(destination),
                destination.parent.flatMap(CalmSettingsMenuGroup.containing), "\(destination)"
            )
        }
    }

    func testEachSettingsGroupHasItsOwnCaption() {
        let titles = CalmSettingsMenuGroup.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
        let items = CalmSettingsMenuGroup.allCases.flatMap(\.items)
        XCTAssertEqual(Set(items).count, items.count, "a menu item is listed twice")
    }
}
