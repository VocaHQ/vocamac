// CalmNavigation.swift
// VocaMac
//
// Where things live in the v3 window: six everyday pages in the sidebar,
// and Settings in a sheet with its own menu and sub-pages. Maps the old
// `SettingsPage` vocabulary (deep links, menu bar entries, error fixes,
// search entries) onto the new places so every route keeps working.

import Foundation
import Observation
import SwiftUI

// MARK: - Destinations

/// The everyday pages in the window's sidebar, top to bottom.
enum CalmMainPage: String, CaseIterable, Identifiable, Hashable, Sendable {
    case home
    case notes
    case insights
    case dictionary
    case snippets
    case styles
    case commands

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .notes: return "Notes"
        case .insights: return "Insights"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .styles: return "Styles"
        case .commands: return "Commands"
        }
    }

    var icon: CalmIconName {
        switch self {
        case .home: return .home
        case .notes: return .notes
        case .insights: return .insights
        case .dictionary: return .dictionary
        case .snippets: return .snippets
        case .styles: return .styles
        case .commands: return .commands
        }
    }
}

/// Every page of the Settings sheet: the six in its menu, plus sub-pages
/// that replace the sheet body and show a back link.
enum CalmSettingsDestination: String, CaseIterable, Identifiable, Hashable, Sendable {
    case general
    case languages
    case system
    case models
    case allModels
    case cleanup
    case privacy
    case advanced
    case gateway
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .languages: return "Languages"
        case .system: return "System"
        case .models: return "Models"
        case .allModels: return "All models"
        case .cleanup: return "Smart Cleanup"
        case .privacy: return "Privacy and History"
        case .advanced: return "Advanced"
        case .gateway: return "Phone gateway"
        case .about: return "About"
        }
    }

    var icon: CalmIconName {
        switch self {
        case .general, .languages: return .general
        case .system: return .system
        case .models, .allModels: return .models
        case .cleanup: return .cleanup
        case .privacy: return .privacy
        case .advanced, .gateway: return .advanced
        case .about: return .info
        }
    }

    /// The menu page a sub-page belongs to; nil for menu pages and About,
    /// which opens from the menu footer.
    var parent: CalmSettingsDestination? {
        switch self {
        case .languages: return .general
        case .allModels: return .models
        case .gateway: return .advanced
        default: return nil
        }
    }

    /// Whether the page replaces the sheet body with a back link.
    var isSubPage: Bool { parent != nil || self == .about }

    /// The menu item highlighted while this page shows (nil for About).
    var menuItem: CalmSettingsDestination? {
        if let parent { return parent }
        return self == .about ? nil : self
    }
}

/// The Settings sheet menu's two groups.
enum CalmSettingsMenuGroup: CaseIterable, Identifiable, Sendable {
    case settings
    case data

    var id: Self { self }

    /// The caption over the group.
    var title: String {
        switch self {
        case .settings: return "Settings"
        case .data: return "Data"
        }
    }

    /// Menu items, top to bottom.
    var items: [CalmSettingsDestination] {
        switch self {
        case .settings: return [.general, .system, .models, .cleanup]
        case .data: return [.privacy, .advanced]
        }
    }

    /// The group a page's menu item sits in (nil for About).
    static func containing(_ destination: CalmSettingsDestination) -> CalmSettingsMenuGroup? {
        guard let item = destination.menuItem else { return nil }
        return allCases.first { $0.items.contains(item) }
    }
}

/// The two tabs of Settings › Models.
enum CalmModelsTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case speech
    case writing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speech: return "Speech to text"
        case .writing: return "Writing AI"
        }
    }
}

/// Anywhere the window can show: a sidebar page or a Settings page.
enum CalmDestination: Hashable, Sendable {
    case main(CalmMainPage)
    case settings(CalmSettingsDestination)

    var title: String {
        switch self {
        case .main(let page): return page.title
        case .settings(let page): return page.title
        }
    }

    var icon: CalmIconName {
        switch self {
        case .main(let page): return page.icon
        case .settings(let page): return page.icon
        }
    }

    /// Every destination in search-result order: Settings first (menu order,
    /// sub-pages after their parent), then the sidebar pages.
    static let searchOrder: [CalmDestination] =
        CalmSettingsDestination.allCases.map { .settings($0) } + CalmMainPage.allCases.map { .main($0) }
}

// MARK: - Mapping

/// Maps the old Settings vocabulary to v3 places.
enum CalmNavigation {
    /// Help in the sidebar opens the website.
    static let helpURL = URL(string: StatsShareComposer.siteURL)

    /// Where an old Settings page now lives.
    static func destination(for page: SettingsPage) -> CalmDestination {
        switch page {
        case .dictation: return .settings(.general)
        case .language: return .settings(.languages)
        case .audio, .performance, .application: return .settings(.system)
        case .speechModel: return .settings(.models)
        case .cleanup: return .settings(.cleanup)
        case .advanced: return .settings(.advanced)
        // The App Store build has no phone gateway page.
        case .gateway: return .settings(AppDistribution.hasPhoneGateway ? .gateway : .advanced)
        case .about: return .settings(.about)
        case .history: return .main(.home)
        case .notes: return .main(.notes)
        case .stats: return .main(.insights)
        case .dictionary: return .main(.dictionary)
        case .snippets: return .main(.snippets)
        // Typed-text rules apply in every app, whatever the style: General.
        case .formatting: return .settings(.general)
        case .writingStyles: return .main(.styles)
        case .commandMode: return .main(.commands)
        }
    }

    /// Search entries whose control moved somewhere other than its old
    /// page's new home (per the v3 brief's “Where existing features go”).
    static let entryOverrides: [String: CalmDestination] = [
        // Dictation page → General, except this App row in System.
        "process-while-speaking": .settings(.system),
        // Audio's microphone controls live in General's Microphone picker.
        "microphone": .settings(.general),
        "closed-lid-microphone": .settings(.general),
        // History storage, screen spelling and backups → Privacy and History.
        "history-retention": .settings(.privacy),
        "history-excluded-apps": .settings(.privacy),
        "screen-context": .settings(.privacy),
        "settings-backup": .settings(.privacy),
        // Model memory status → Advanced.
        "model-status": .settings(.advanced),
        // The AI model library, where cleanup runs and what Command Mode
        // uses (“Command Mode uses”) → Models › Writing AI.
        "cleanup-provider": .settings(.models),
        "command-mode-models": .settings(.models),
        "command-mode-model": .settings(.models),
        "command-mode-share": .settings(.models),
        // Your own server is a row in All models.
        "custom-endpoint": .settings(.allModels),
        // Imported models sit under the list in All models.
        "imported-models": .settings(.allModels),
    ]

    /// Entries that open Models on its Writing AI tab.
    static let writingAIEntryIDs: Set<String> = [
        "cleanup-provider", "command-mode-models", "command-mode-model", "command-mode-share",
    ]

    /// Where a search entry's control now lives.
    static func destination(for entry: SettingsSearchEntry) -> CalmDestination {
        entryOverrides[entry.id] ?? destination(for: entry.page)
    }

    /// Search matches grouped by destination, in `CalmDestination.searchOrder`.
    static func searchGroups(for query: String) -> [(destination: CalmDestination, entries: [SettingsSearchEntry])] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let matches = SettingsSearchIndex.matches(query: trimmed)
        return CalmDestination.searchOrder.compactMap { destination in
            let entries = matches.filter { self.destination(for: $0) == destination }
            return entries.isEmpty ? nil : (destination, entries)
        }
    }
}

// MARK: - Navigator

/// The window's navigation state: the sidebar page, whether the Settings
/// sheet is open and on which page, the sheet's search text, and the
/// control a search result points at. Injected with `.environment(_:)`;
/// read with `@Environment(CalmNavigator.self)`.
///
/// ```swift
/// navigator.show(.dictionary)
/// navigator.openSettings(.languages)          // back link returns to General
/// navigator.open(.speechModel)                // old vocabulary
/// navigator.open(.settings(.models), target: "custom-endpoint")
/// ```
@MainActor
@Observable
final class CalmNavigator {
    /// The sidebar page under the sheet.
    var mainPage: CalmMainPage
    /// Whether the Settings sheet is showing.
    private(set) var isSettingsPresented = false
    /// The page the sheet shows.
    private(set) var settingsDestination: CalmSettingsDestination = .general
    /// Pages to return to from sub-pages, most recent last.
    private var settingsBackStack: [CalmSettingsDestination] = []
    /// The text in the sheet's search field; results replace the body while it is not empty.
    var settingsSearchText = ""
    /// The Models page's tab. Set before opening Models to land on Writing AI.
    var modelsTab: CalmModelsTab = .speech
    /// The `.settingsTarget` id to scroll to and flash, cleared after the flash.
    private(set) var searchTarget: String?
    /// A one-line hint for a search result that needs a further step.
    private(set) var searchHint: String?

    @ObservationIgnored private var clearTargetTask: Task<Void, Never>?

    init(mainPage: CalmMainPage = .home) {
        self.mainPage = mainPage
    }

    /// Whether the sheet's body shows search results.
    var isSearching: Bool {
        !settingsSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Where the current sub-page's back link goes (nil on menu pages).
    var backDestination: CalmSettingsDestination? {
        guard settingsDestination.isSubPage else { return nil }
        return settingsBackStack.last ?? settingsDestination.parent
    }

    /// Show a sidebar page, closing Settings.
    func show(_ page: CalmMainPage, target: String? = nil) {
        mainPage = page
        closeSettings()
        setTarget(target)
    }

    /// Open the Settings sheet, on `destination` or where it was last.
    /// A sub-page opened while the sheet is closed (a deep link, the
    /// status card) goes back to its parent, not to the last page seen.
    func openSettings(_ destination: CalmSettingsDestination? = nil, target: String? = nil) {
        if let destination {
            if isSettingsPresented {
                select(destination)
            } else {
                settingsSearchText = ""
                settingsBackStack.removeAll()
                settingsDestination = destination
            }
        }
        isSettingsPresented = true
        setTarget(target)
    }

    /// Close the Settings sheet and clear its search.
    func closeSettings() {
        isSettingsPresented = false
        settingsSearchText = ""
        searchHint = nil
    }

    /// Go to a Settings page inside the open sheet. Menu pages reset the
    /// back stack; sub-pages remember where they were opened from.
    func select(_ destination: CalmSettingsDestination) {
        settingsSearchText = ""
        searchHint = nil
        guard destination != settingsDestination else { return }
        if destination.isSubPage {
            settingsBackStack.append(settingsDestination)
        } else {
            settingsBackStack.removeAll()
        }
        settingsDestination = destination
    }

    /// Follow a sub-page's back link.
    func goBack() {
        guard let back = backDestination else { return }
        searchHint = nil
        if !settingsBackStack.isEmpty { settingsBackStack.removeLast() }
        settingsDestination = back
    }

    /// Go anywhere, optionally to one control.
    func navigate(to destination: CalmDestination, target: String? = nil) {
        switch destination {
        case .main(let page): show(page, target: target)
        case .settings(let page): openSettings(page, target: target)
        }
    }

    /// Honour an old `SettingsPage` request (menu bar, deep links, error fixes).
    func open(_ page: SettingsPage, target: String? = nil) {
        if page == .speechModel { modelsTab = .speech }
        navigate(to: CalmNavigation.destination(for: page), target: target)
    }

    /// Follow a Settings search result: go to its page and flash its control.
    func open(_ entry: SettingsSearchEntry) {
        if CalmNavigation.writingAIEntryIDs.contains(entry.id) {
            modelsTab = .writing
        } else if entry.page == .speechModel {
            modelsTab = .speech
        }
        settingsSearchText = ""
        let destination = CalmNavigation.destination(for: entry)
        // A result on a sub-page goes back to that page's parent, not to
        // whatever page the search was typed over.
        if case .settings(let page) = destination, page.isSubPage, let parent = page.parent,
           isSettingsPresented, settingsDestination != parent {
            select(parent)
        }
        navigate(to: destination, target: entry.id)
        searchHint = entry.navigationHint
    }

    /// Clear a shown search hint.
    func dismissSearchHint() { searchHint = nil }

    private func setTarget(_ target: String?) {
        clearTargetTask?.cancel()
        searchHint = nil
        searchTarget = target
        guard target != nil else { return }
        // Clear after the flash so picking the same result again flashes again.
        clearTargetTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3.2)) } catch { return }
            self?.searchTarget = nil
        }
    }
}
