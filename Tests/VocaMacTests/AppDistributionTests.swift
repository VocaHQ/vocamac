// AppDistributionTests.swift
// VocaMac Tests
//
// The direct download keeps every feature. Only the Mac App Store build
// (compiled with APP_STORE, never by `swift test`) leaves some out.

import XCTest
@testable import VocaMac

final class AppDistributionTests: XCTestCase {

    func testDirectDownloadKeepsEveryFeature() {
        XCTAssertFalse(AppDistribution.isAppStore)
        XCTAssertTrue(AppDistribution.hasSelfUpdate)
        XCTAssertTrue(AppDistribution.hasPhoneGateway)
        XCTAssertTrue(AppDistribution.hasAppleScriptControl)
        XCTAssertTrue(AppDistribution.canResetPermissions)
        XCTAssertTrue(AppDistribution.canReadCrashReports)
        XCTAssertEqual(AppDistribution.hiddenSettingsTargets, [])
    }

    /// The direct download keeps its name; only the App Store build is "Voca".
    func testDirectDownloadIsNamedVocaMac() {
        XCTAssertEqual(AppDistribution.displayName, "VocaMac")
    }

    /// Text people see is built from the display name, so the store build
    /// says "Voca" wherever the direct download says "VocaMac".
    func testUserVisibleTextUsesTheDisplayName() {
        let name = AppDistribution.displayName
        XCTAssertEqual(SettingsSection.app.title, name)
        let ready = DictationReadiness.ready(preparingAnother: false)
        XCTAssertEqual(MenuBarAccessibility.label(status: .idle, readiness: ready), name)
        XCTAssertEqual(MenuBarAccessibility.label(status: .recording, readiness: ready), "\(name), recording")
        XCTAssertEqual(
            OnboardingPermissionGaps.consequences(
                microphone: .denied, accessibility: .granted, inputMonitoring: .granted
            ),
            ["Without Microphone, \(name) can't hear you, so dictation won't work."]
        )
    }

    /// App Review (Guideline 5.1.1(iv)) rejects "Allow" on a button shown
    /// before a system permission prompt; those buttons say "Continue".
    func testPermissionFixButtonsDoNotSayAllow() {
        for action in [ErrorFixAction.openMicrophonePrivacy, .openAccessibilityPrivacy] {
            XCTAssertFalse(action.title.localizedCaseInsensitiveContains("allow"), action.title)
            XCTAssertFalse(action.title.localizedCaseInsensitiveContains("grant"), action.title)
        }
        XCTAssertEqual(ErrorFixAction.openMicrophonePrivacy.title, "Continue…")
    }

    func testDirectDownloadSearchesEverySetting() {
        let ids = Set(SettingsSearchIndex.entries.map(\.id))
        for id in ["updates", "gateway", "gateway-pair", "gateway-docker", "spotify-pause"] {
            XCTAssertTrue(ids.contains(id), id)
        }
        let actions = SettingsSearchIndex.entries.first { $0.id == "command-mode-actions" }
        XCTAssertEqual(actions?.subtitle, "Open apps, search the web, add reminders, run Shortcuts")
    }

    func testDirectDownloadShowsTheGatewayPage() {
        XCTAssertTrue(SettingsSection.app.pages.contains(.gateway))
        for page in SettingsPage.allCases {
            XCTAssertEqual(page.shownInThisBuild, page, "\(page)")
        }
    }
}
