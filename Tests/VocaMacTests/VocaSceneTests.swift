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

    func testEverySettingsPageBelongsToItsSidebarGroup() {
        for section in SettingsSection.allCases {
            for page in section.pages {
                XCTAssertEqual(SettingsSection.containing(page), section, "\(page)")
            }
        }
    }

    func testEachSettingsGroupHasItsOwnTimeOfDay() {
        let moods = SettingsSection.allCases.map(\.mood)
        XCTAssertEqual(Set(moods).count, moods.count)
    }
}
