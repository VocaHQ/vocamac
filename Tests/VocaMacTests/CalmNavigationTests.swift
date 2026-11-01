// CalmNavigationTests.swift
// VocaMac Tests
//
// The v3 window's navigation: old Settings pages and search entries map
// to their new homes, the Settings sheet's sub-pages go back where they
// came from, and the sidebar status card picks the right state.

import AppKit
import SwiftUI
import XCTest
@testable import VocaMac

@MainActor
final class CalmNavigatorTests: XCTestCase {

    func testMainPageRequestClosesSettings() {
        let navigator = CalmNavigator()
        navigator.openSettings(.system)
        navigator.open(.dictionary)
        XCTAssertEqual(navigator.mainPage, .dictionary)
        XCTAssertFalse(navigator.isSettingsPresented)
    }

    func testSettingsRequestOpensTheSheetOnItsPage() {
        let navigator = CalmNavigator(mainPage: .insights)
        navigator.open(.audio)
        XCTAssertTrue(navigator.isSettingsPresented)
        XCTAssertEqual(navigator.settingsDestination, .system)
        // The page under the sheet stays where it was.
        XCTAssertEqual(navigator.mainPage, .insights)
    }

    func testSubPageGoesBackToWhereItWasOpened() {
        let navigator = CalmNavigator()
        navigator.openSettings(.privacy)
        navigator.select(.about)
        XCTAssertEqual(navigator.backDestination, .privacy)
        navigator.goBack()
        XCTAssertEqual(navigator.settingsDestination, .privacy)
        XCTAssertNil(navigator.backDestination)
    }

    func testSubPageOpenedDirectlyGoesBackToItsParent() {
        let navigator = CalmNavigator()
        navigator.open(.language)
        XCTAssertEqual(navigator.settingsDestination, .languages)
        XCTAssertEqual(navigator.backDestination, .general)
        navigator.goBack()
        XCTAssertEqual(navigator.settingsDestination, .general)
    }

    func testMenuPageClearsTheBackStack() {
        let navigator = CalmNavigator()
        navigator.openSettings(.models)
        navigator.select(.allModels)
        navigator.select(.cleanup)
        XCTAssertNil(navigator.backDestination)
        navigator.select(.gateway)
        XCTAssertEqual(navigator.backDestination, .cleanup)
    }

    func testClosingSettingsClearsItsSearch() {
        let navigator = CalmNavigator()
        navigator.openSettings()
        navigator.settingsSearchText = "pause"
        XCTAssertTrue(navigator.isSearching)
        navigator.closeSettings()
        XCTAssertFalse(navigator.isSearching)
        XCTAssertFalse(navigator.isSettingsPresented)
    }

    func testFollowingASearchResultTargetsItsControl() throws {
        let navigator = CalmNavigator()
        navigator.openSettings()
        navigator.settingsSearchText = "exclude"
        let entry = try XCTUnwrap(SettingsSearchIndex.entries.first { $0.id == "history-excluded-apps" })
        navigator.open(entry)
        XCTAssertEqual(navigator.settingsDestination, .privacy)
        XCTAssertEqual(navigator.searchTarget, "history-excluded-apps")
        XCTAssertFalse(navigator.isSearching)
    }

    func testWritingAIResultsOpenModelsOnWritingAI() throws {
        let navigator = CalmNavigator()
        let entry = try XCTUnwrap(SettingsSearchIndex.entries.first { $0.id == "cleanup-provider" })
        navigator.open(entry)
        XCTAssertEqual(navigator.settingsDestination, .models)
        XCTAssertEqual(navigator.modelsTab, .writing)
        navigator.open(.speechModel)
        XCTAssertEqual(navigator.modelsTab, .speech)
    }

    func testSubPageResultGoesBackToItsParent() throws {
        let navigator = CalmNavigator()
        navigator.openSettings(.privacy)
        navigator.modelsTab = .writing
        let entry = try XCTUnwrap(SettingsSearchIndex.entries.first { $0.id == "custom-endpoint" })
        navigator.open(entry)
        XCTAssertEqual(navigator.settingsDestination, .allModels)
        XCTAssertEqual(navigator.modelsTab, .speech)
        XCTAssertEqual(navigator.backDestination, .models)
        XCTAssertEqual(navigator.searchTarget, "custom-endpoint")
    }

    func testMainPageResultClosesTheSheet() throws {
        let navigator = CalmNavigator()
        navigator.openSettings()
        let entry = try XCTUnwrap(SettingsSearchIndex.entries.first { $0.id == "snippets" })
        navigator.open(entry)
        XCTAssertFalse(navigator.isSettingsPresented)
        XCTAssertEqual(navigator.mainPage, .snippets)
        XCTAssertEqual(navigator.searchTarget, "snippets")
    }

    /// A result's hint belongs to the page it opened; leaving that page
    /// (another menu page, the back link, closing the sheet) clears it.
    func testSearchHintClearsWhenLeavingItsPage() throws {
        let navigator = CalmNavigator()
        let entry = try XCTUnwrap(SettingsSearchIndex.entries.first { $0.id == "gateway-docker" })
        XCTAssertNotNil(entry.navigationHint)

        navigator.open(entry)
        XCTAssertEqual(navigator.settingsDestination, .gateway)
        XCTAssertNotNil(navigator.searchHint)
        navigator.goBack()
        XCTAssertNil(navigator.searchHint)

        navigator.open(entry)
        navigator.select(.system)
        XCTAssertNil(navigator.searchHint)

        navigator.open(entry)
        navigator.closeSettings()
        XCTAssertNil(navigator.searchHint)
    }
}

final class CalmNavigationMappingTests: XCTestCase {

    func testEveryOldPageMapsToItsBriefedHome() {
        let expected: [SettingsPage: CalmDestination] = [
            .dictation: .settings(.general), .language: .settings(.languages),
            .audio: .settings(.system), .performance: .settings(.system), .application: .settings(.system),
            .speechModel: .settings(.models), .cleanup: .settings(.cleanup),
            .advanced: .settings(.advanced), .gateway: .settings(.gateway), .about: .settings(.about),
            .history: .main(.home), .stats: .main(.insights), .dictionary: .main(.dictionary),
            .snippets: .main(.snippets), .formatting: .settings(.general), .writingStyles: .main(.styles),
            .commandMode: .main(.commands), .silentMode: .settings(.silentMode),
        ]
        XCTAssertEqual(Set(expected.keys), Set(SettingsPage.allCases))
        for (page, destination) in expected {
            XCTAssertEqual(CalmNavigation.destination(for: page), destination, "\(page)")
        }
    }

    func testOverriddenEntriesExist() {
        let ids = Set(SettingsSearchIndex.entries.map(\.id))
        for id in CalmNavigation.entryOverrides.keys {
            XCTAssertTrue(ids.contains(id), "override for unknown search entry \(id)")
        }
        XCTAssertTrue(CalmNavigation.writingAIEntryIDs.isSubset(of: Set(CalmNavigation.entryOverrides.keys)))
    }

    func testMovedControlsSearchToTheirNewPages() throws {
        func destination(_ id: String) throws -> CalmDestination {
            let entry = try XCTUnwrap(SettingsSearchIndex.entries.first { $0.id == id })
            return CalmNavigation.destination(for: entry)
        }
        XCTAssertEqual(try destination("microphone"), .settings(.general))
        XCTAssertEqual(try destination("process-while-speaking"), .settings(.system))
        XCTAssertEqual(try destination("history-retention"), .settings(.privacy))
        XCTAssertEqual(try destination("screen-context"), .settings(.privacy))
        XCTAssertEqual(try destination("settings-backup"), .settings(.privacy))
        XCTAssertEqual(try destination("model-status"), .settings(.advanced))
        XCTAssertEqual(try destination("history"), .main(.home))
        XCTAssertEqual(try destination("trailing-space"), .settings(.general))
    }

    func testSearchGroupsFollowTheMenuOrder() {
        let groups = CalmNavigation.searchGroups(for: "pause")
        XCTAssertFalse(groups.isEmpty)
        let order = groups.compactMap { CalmDestination.searchOrder.firstIndex(of: $0.destination) }
        XCTAssertEqual(order, order.sorted())
        XCTAssertTrue(CalmNavigation.searchGroups(for: "   ").isEmpty)
        XCTAssertTrue(CalmNavigation.searchGroups(for: "zzznomatch999").isEmpty)
    }

    func testSearchKeepsEveryMatch() {
        for query in ["model", "history", "shortcut", "a"] {
            let grouped = CalmNavigation.searchGroups(for: query).reduce(0) { $0 + $1.entries.count }
            XCTAssertEqual(grouped, SettingsSearchIndex.matches(query: query).count, query)
        }
    }

    func testMenuHighlightsTheParentOfASubPage() {
        XCTAssertEqual(CalmSettingsDestination.languages.menuItem, .general)
        XCTAssertEqual(CalmSettingsDestination.allModels.menuItem, .models)
        XCTAssertEqual(CalmSettingsDestination.system.menuItem, .system)
        XCTAssertNil(CalmSettingsDestination.about.menuItem)
        XCTAssertTrue(CalmSettingsDestination.about.isSubPage)
        XCTAssertFalse(CalmSettingsDestination.privacy.isSubPage)
    }

    func testSidebarOrder() {
        XCTAssertEqual(CalmMainPage.allCases.map(\.title), ["Home", "Insights", "Dictionary", "Snippets", "Styles", "Commands"])
        XCTAssertEqual(CalmSettingsMenuGroup.data.items, [.privacy, .advanced])
    }
}

final class CalmSidebarStatusTests: XCTestCase {
    private func inputs(
        status: AppStatus = .idle, readiness: DictationReadiness = .ready(preparingAnother: false)
    ) -> CalmSidebarStatus.Inputs {
        CalmSidebarStatus.Inputs(status: status, readiness: readiness, keys: ["Right ⌥"], modelName: "Parakeet v3")
    }

    func testReady() {
        XCTAssertEqual(
            CalmSidebarStatus.resolve(inputs()),
            .ready(verb: "Hold", keys: ["Right ⌥"], detail: "Parakeet v3 · on this Mac", paused: false)
        )
        var remote = inputs()
        remote.isRemote = true
        remote.isToggleActivation = true
        XCTAssertEqual(
            CalmSidebarStatus.resolve(remote),
            .ready(verb: "Double-tap", keys: ["Right ⌥"], detail: "Parakeet v3 · on your server", paused: false)
        )
    }

    func testActivityWinsOverReadiness() {
        XCTAssertEqual(
            CalmSidebarStatus.resolve(inputs(status: .recording, readiness: .needsAccessibility)),
            .listening(keys: ["Right ⌥"], isToggle: false, escapeCancels: true)
        )
        XCTAssertEqual(
            CalmSidebarStatus.resolve(inputs(status: .processing)),
            .working(title: "Transcribing…", detail: "Parakeet v3")
        )
        guard case .error = CalmSidebarStatus.resolve(inputs(status: .error)) else {
            return XCTFail("an error status shows the error card")
        }
    }

    func testMissingPermissionNeedsAccess() {
        for readiness in [DictationReadiness.needsMicrophone, .needsInputMonitoring, .needsAccessibility] {
            guard case .needsAccess = CalmSidebarStatus.resolve(inputs(readiness: readiness)) else {
                return XCTFail("\(readiness)")
            }
        }
    }

    func testPreparingModelShowsProgress() {
        var downloading = inputs(readiness: .preparingModel)
        downloading.isDownloading = true
        downloading.downloadProgress = 0.4
        downloading.preparingModelName = "Whisper Small"
        XCTAssertEqual(
            CalmSidebarStatus.resolve(downloading),
            .loadingModel(title: "Downloading model", detail: "Whisper Small · 40%", progress: 0.4)
        )
    }

    func testBackgroundDownloadShowsOnTheReadyCard() {
        // A newly picked model downloads while the current one keeps working.
        var downloading = inputs()
        downloading.isDownloading = true
        downloading.downloadProgress = 0.426
        downloading.preparingModelName = "Whisper Large v3 Latest"
        XCTAssertEqual(
            CalmSidebarStatus.resolve(downloading),
            .ready(
                verb: "Hold", keys: ["Right ⌥"], detail: "Parakeet v3 · on this Mac", paused: false,
                download: .init(model: "Whisper Large v3 Latest", progress: 0.426)
            )
        )
        XCTAssertEqual(CalmSidebarStatus.Download(model: "Parakeet v3", progress: 0.426).title, "Downloading Parakeet v3")
        XCTAssertEqual(CalmSidebarStatus.Download(model: nil, progress: 0.426).percent, "42%")
        // Loading a model that is already on disk isn't a download.
        var loading = inputs()
        loading.preparingModelName = "Whisper Small"
        XCTAssertEqual(
            CalmSidebarStatus.resolve(loading),
            .ready(verb: "Hold", keys: ["Right ⌥"], detail: "Parakeet v3 · on this Mac", paused: false)
        )
    }

    func testModelLineCanDropWhereItRuns() {
        // The card drops “· on this Mac” before it lets the line wrap.
        XCTAssertEqual(CalmSidebarStatus.shortModelLine("Parakeet Unified · on this Mac"), "Parakeet Unified")
        XCTAssertEqual(CalmSidebarStatus.shortModelLine("Parakeet v3 · on your server"), "Parakeet v3")
        XCTAssertEqual(CalmSidebarStatus.shortModelLine("On this Mac"), "On this Mac")
    }

    func testMissingModelOffersAFix() {
        guard case .error(_, _, let action) = CalmSidebarStatus.resolve(inputs(readiness: .needsModel)) else {
            return XCTFail("a missing model is an error with a fix")
        }
        XCTAssertEqual(action, "Choose a model")
    }

    func testErrorUsesTheNoticeAndItsFix() {
        var failed = inputs(status: .error)
        failed.errorMessage = "Microphone access is off."
        failed.errorActionTitle = "Allow Microphone…"
        XCTAssertEqual(
            CalmSidebarStatus.resolve(failed),
            .error(title: "Something went wrong", message: "Microphone access is off.", actionTitle: "Allow Microphone…")
        )
    }

    func testAutoPauseShowsPaused() {
        var paused = inputs()
        paused.isAutoPaused = true
        guard case .ready(_, _, _, true, _) = CalmSidebarStatus.resolve(paused) else {
            return XCTFail("auto-pause shows the paused ready card")
        }
    }
}

final class CalmFoundationTests: XCTestCase {
    func testKeyCapsSplitModifiersAndKeepSides() {
        XCTAssertEqual(CalmKeyCaps.labels(for: HotKeyCombo(keyCode: 61, modifiers: [])), ["Right ⌥"])
        XCTAssertEqual(CalmKeyCaps.labels(for: HotKeyCombo(keyCode: 54, modifiers: [])), ["Right ⌘"])
        XCTAssertEqual(CalmKeyCaps.labels(for: HotKeyCombo(keyCode: 63, modifiers: [])), ["Fn"])
        XCTAssertEqual(CalmKeyCaps.labels(for: HotKeyCombo(keyCode: 49, modifiers: [.control, .option])), ["⌃", "⌥", "Space"])
        XCTAssertEqual(CalmKeyCaps.labels(for: HotKeyCombo(keyCode: 96, modifiers: [])), ["F5"])
    }

    func testHeatLevels() {
        XCTAssertEqual(CalmHeatLevel.level(forWords: 0), 0)
        XCTAssertEqual(CalmHeatLevel.level(forWords: 1), 1)
        XCTAssertEqual(CalmHeatLevel.level(forWords: 219), 1)
        XCTAssertEqual(CalmHeatLevel.level(forWords: 220), 2)
        XCTAssertEqual(CalmHeatLevel.level(forWords: 479), 2)
        XCTAssertEqual(CalmHeatLevel.level(forWords: 480), 3)
        XCTAssertEqual(CalmHeatLevel.level(forWords: 800), 4)
        XCTAssertEqual(CalmHeatLevel.level(forWords: -3), 0)
    }

    func testCSSWeightsInterpolateBetweenNamedWeights() {
        XCTAssertEqual(CalmFont.cssWeight(400), NSFont.Weight.regular.rawValue, accuracy: 0.0001)
        XCTAssertEqual(CalmFont.cssWeight(600), NSFont.Weight.semibold.rawValue, accuracy: 0.0001)
        let w560 = CalmFont.cssWeight(560)
        XCTAssertGreaterThan(w560, NSFont.Weight.medium.rawValue)
        XCTAssertLessThan(w560, NSFont.Weight.semibold.rawValue)
        XCTAssertEqual(CalmFont.cssWeight(50), NSFont.Weight.ultraLight.rawValue, accuracy: 0.0001)
        XCTAssertEqual(CalmFont.cssWeight(1000), NSFont.Weight.black.rawValue, accuracy: 0.0001)
    }

    func testDayCaptions() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        calendar.locale = Locale(identifier: "en_GB")
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 12)))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now))
        let older = try XCTUnwrap(calendar.date(byAdding: .day, value: -4, to: now))
        XCTAssertEqual(CalmDaySection<EmptyView>.caption(for: now, now: now, calendar: calendar), "Today")
        XCTAssertEqual(CalmDaySection<EmptyView>.caption(for: yesterday, now: now, calendar: calendar), "Yesterday")
        XCTAssertNotEqual(CalmDaySection<EmptyView>.caption(for: older, now: now, calendar: calendar), "Yesterday")
    }

    func testEveryIconAndLogoParses() {
        for icon in CalmIconName.allCases {
            XCTAssertNotNil(SVGPath.makeCGPath(from: icon.pathData), icon.rawValue)
        }
        for logo in CalmLogoName.allCases {
            XCTAssertNotNil(SVGPath.makeCGPath(from: logo.pathData), logo.rawValue)
        }
    }

    func testFeatureCardDismissalIsPerPage() {
        let defaults = UserDefaults.standard
        let key = CalmFeatureCard<EmptyView>.storageKey("test-page")
        defaults.removeObject(forKey: key)
        XCTAssertFalse(CalmFeatureCard<EmptyView>.isDismissed("test-page"))
        defaults.set(true, forKey: key)
        XCTAssertTrue(CalmFeatureCard<EmptyView>.isDismissed("test-page"))
        XCTAssertFalse(CalmFeatureCard<EmptyView>.isDismissed("other-page"))
        defaults.removeObject(forKey: key)
    }
}
