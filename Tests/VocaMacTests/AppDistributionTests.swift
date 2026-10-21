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

    func testDirectDownloadSearchesEverySetting() {
        let ids = Set(SettingsSearchIndex.entries.map(\.id))
        for id in ["updates", "gateway", "gateway-pair", "gateway-docker", "spotify-pause"] {
            XCTAssertTrue(ids.contains(id), id)
        }
        let actions = SettingsSearchIndex.entries.first { $0.id == "command-mode-actions" }
        XCTAssertEqual(actions?.subtitle, "Open apps, search the web, add reminders, run Shortcuts")
        XCTAssertEqual(CalmNavigation.destination(for: .gateway), .settings(.gateway))
    }
}
