// AppState+CalmStyles.swift
// VocaMac
//
// The Styles page groups apps into four tabs (Messages, Email, Code,
// Everything else) and lets one card pick the style for a whole group.
// Writing styles themselves stay per app (`writingStyleBindings`) and per
// website (`websiteStyleBindings`); this file only decides which group a
// rule shows under, which style a group's card shows as chosen, and how
// picking a card or adding an app changes the real rules.

import AppKit
import Foundation

// MARK: - Groups

/// One tab of the Styles page: a kind of app with three style cards.
enum CalmStyleGroup: String, CaseIterable, Identifiable, Codable, Sendable {
    case messages
    case email
    case code
    case everythingElse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .messages: return "Messages"
        case .email: return "Email"
        case .code: return "Code"
        case .everythingElse: return "Everything else"
        }
    }

    /// The three styles the group's cards offer, in card order.
    var cardStyles: [WritingStyle] {
        switch self {
        case .messages: return [.plain, .chat, .slack]
        case .email: return [.plain, .email, .chat]
        case .code: return [.code, .terminal, .plain]
        case .everythingElse: return [.plain, .notes, .email]
        }
    }

    /// The style a group with no apps and no choice yet shows as picked.
    var defaultStyle: WritingStyle {
        switch self {
        case .messages: return .chat
        case .email: return .email
        case .code: return .code
        case .everythingElse: return .plain
        }
    }

    /// What a card pretends you said; the card shows it through its style.
    ///
    /// The words are the group's, but a card only gets spoken commands
    /// (“new line”, “bold”, “bullet”) its style turns into formatting, so
    /// none of them shows up as text: Plain types every word as spoken, and
    /// a command in its sample would read as a mistake. The three samples
    /// in a group differ at a glance (a full stop, a line break, bold or
    /// bullets), not only in a letter.
    func sampleSpeech(for style: WritingStyle) -> String {
        switch (self, style) {
        case (.messages, .chat):
            return "sounds good new line see you Thursday"
        case (.messages, .slack):
            return "bold Thursday plan new line bullet slides new line bullet demo"
        case (.messages, _):
            return "Sure, I can bring the slides on Thursday."
        case (.email, .email), (.email, .chat):
            return "um, hi Sam, new line thanks for the notes. I'll send the draft on Friday"
        case (.email, _):
            return "um, hi Sam, thanks for the notes. I'll send the draft on Friday"
        case (.code, .terminal):
            return "cd sources slash app"
        case (.code, _):
            return "the fix is in main dot swift. can you review it?"
        case (.everythingElse, .notes):
            return "bullet oat milk new line bullet lemons new line bullet basil"
        case (.everythingElse, .email):
            return "um, buy oat milk, lemons and basil"
        case (.everythingElse, _):
            return "buy oat milk, lemons and basil"
        }
    }

    /// The group a style belongs to when nothing else says where an app goes.
    static func family(of style: WritingStyle) -> CalmStyleGroup {
        switch style {
        case .chat, .slack: return .messages
        case .email: return .email
        case .code, .terminal: return .code
        case .plain, .notes: return .everythingElse
        }
    }

    /// The group VocaMac's own app catalog puts an app in, if it knows the app.
    static func catalogGroup(bundleIdentifier: String?, processName: String?, id: String) -> CalmStyleGroup? {
        let snapshot = RunningAppSnapshot(displayName: id, bundleIdentifier: bundleIdentifier, processName: processName)
        func contains(_ list: [WritingStyleCatalog.Suggestion]) -> Bool {
            list.contains { suggestion in
                AppIdentityMatching.matches(
                    configuredBundleIdentifier: suggestion.bundleIdentifier,
                    configuredProcessName: suggestion.processName,
                    configuredID: suggestion.id,
                    snapshot: snapshot
                )
            }
        }
        if contains(WritingStyleCatalog.editors) || contains(WritingStyleCatalog.terminals) { return .code }
        if contains(WritingStyleCatalog.chat) { return .messages }
        if contains(WritingStyleCatalog.mail) { return .email }
        if contains(WritingStyleCatalog.notes) { return .everythingElse }
        return nil
    }

    /// Catalog apps that belong in this group.
    var catalogSuggestions: [WritingStyleCatalog.Suggestion] {
        switch self {
        case .messages: return WritingStyleCatalog.chat
        case .email: return WritingStyleCatalog.mail
        case .code: return WritingStyleCatalog.editors + WritingStyleCatalog.terminals
        case .everythingElse: return WritingStyleCatalog.notes
        }
    }
}

// MARK: - Card copy

extension WritingStyle {
    /// The short line under a style card's name.
    var calmTagline: String {
        switch self {
        case .plain: return "Your words, with punctuation"
        case .chat: return "Capital letters, no forced full stop"
        case .slack: return "Chat, plus Slack bold and bullets"
        case .email: return "Full sentences with a full stop"
        case .code: return "Spoken file names become code"
        case .terminal: return "Exact words, nothing added"
        case .notes: return "Say “bullet” to start a list item"
        }
    }

    /// Terminal output reads best in a monospaced face.
    var calmSampleIsMonospaced: Bool { self == .terminal }
}

// MARK: - Stored group choices

/// Which group each rule was put in and which style each group's card was
/// set to. Only the Styles page reads it: dictation uses the rules alone.
///
/// Keys are `app:<binding id>` and `site:<website id>`. Values are stored as
/// raw strings so one unknown value (a newer build) is skipped rather than
/// failing the whole decode.
struct CalmStyleGroupStore: Codable, Equatable {
    static let defaultsKey = "vocamac.calmStyleGroups"

    var assignments: [String: String] = [:]
    var styles: [String: String] = [:]

    static func appKey(_ id: String) -> String { "app:\(id)" }
    static func websiteKey(_ id: UUID) -> String { "site:\(id.uuidString)" }

    func group(forKey key: String) -> CalmStyleGroup? {
        assignments[key].flatMap(CalmStyleGroup.init(rawValue:))
    }

    mutating func assign(_ group: CalmStyleGroup, toKey key: String) {
        assignments[key] = group.rawValue
    }

    func style(for group: CalmStyleGroup) -> WritingStyle? {
        styles[group.rawValue].flatMap(WritingStyle.init(rawValue:))
    }

    mutating func setStyle(_ style: WritingStyle, for group: CalmStyleGroup) {
        styles[group.rawValue] = style.rawValue
    }

    /// Drop group choices for rules that no longer exist.
    mutating func prune(keepingKeys liveKeys: Set<String>) {
        assignments = assignments.filter { liveKeys.contains($0.key) }
    }

    /// Decode a stored payload; anything unreadable is an empty store.
    static func decode(_ json: String?) -> CalmStyleGroupStore {
        guard let data = json?.data(using: .utf8),
              let store = try? JSONDecoder().decode(CalmStyleGroupStore.self, from: data) else {
            return CalmStyleGroupStore()
        }
        return store
    }

    func encodedJSON() -> String {
        guard let data = try? JSONEncoder().encode(self), let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

// MARK: - Websites

/// Turning what someone typed into a website rule's host.
enum CalmWebsiteHost {
    /// "https://GitHub.com/foo/" → "github.com". Keeps a leading `*.`.
    static func normalized(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.contains("://"), let url = URL(string: value), let host = url.host {
            value = host
        } else if let slash = value.firstIndex(of: "/") {
            value = String(value[..<slash])
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/."))
    }

    /// Whether the text reads as a website address rather than an app name.
    static func looksLikeWebsite(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" ") else { return false }
        let host = normalized(trimmed)
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2,
              tld.allSatisfy(\.isLetter) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-*")
        return labels.allSatisfy { label in
            !label.isEmpty && label.unicodeScalars.allSatisfy(allowed.contains)
        }
    }
}

// MARK: - App candidates

/// Apps the “Add app or website” dialog can offer.
enum CalmAppCandidates {
    /// Folders searched for installed apps, one level deep.
    static var searchFolders: [URL] {
        let fileManager = FileManager.default
        var folders = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
        ]
        if let home = fileManager.urls(for: .applicationDirectory, in: .userDomainMask).first {
            folders.append(home)
        }
        return folders
    }

    /// A snapshot for an app bundle on disk.
    static func snapshot(forAppAt url: URL) -> RunningAppSnapshot {
        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary
        let fallback = url.deletingPathExtension().lastPathComponent
        let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String) ?? fallback
        return RunningAppSnapshot(
            displayName: name.isEmpty ? fallback : name,
            bundleIdentifier: bundle?.bundleIdentifier,
            processName: (info?["CFBundleExecutable"] as? String) ?? fallback
        )
    }

    /// Installed apps, read from disk. Slow (one bundle read per app), so
    /// call it off the main actor.
    static func installedApps(in folders: [URL] = searchFolders) -> [RunningAppSnapshot] {
        let fileManager = FileManager.default
        var result: [RunningAppSnapshot] = []
        for folder in folders {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for url in urls where url.pathExtension == "app" {
                result.append(snapshot(forAppAt: url))
            }
        }
        return result
    }

    /// Merge app lists, dropping repeats of the same app, sorted by name.
    static func merged(_ lists: [[RunningAppSnapshot]], excludingBundleIdentifier ownID: String? = Bundle.main.bundleIdentifier) -> [RunningAppSnapshot] {
        var seen = Set<String>()
        var result: [RunningAppSnapshot] = []
        for snapshot in lists.joined() {
            if let ownID, snapshot.bundleIdentifier == ownID { continue }
            let key = snapshot.bundleIdentifier?.lowercased() ?? "name:\(snapshot.displayName.lowercased())"
            guard seen.insert(key).inserted else { continue }
            result.append(snapshot)
        }
        return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Apps whose name contains `query` (all of them for an empty query).
    static func filter(_ apps: [RunningAppSnapshot], query: String) -> [RunningAppSnapshot] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return apps }
        let matches = apps.filter { $0.displayName.localizedCaseInsensitiveContains(trimmed) }
        // Names that start with the query first ("n" → Notion before Signal).
        return matches.sorted { lhs, rhs in
            let left = lhs.displayName.lowercased().hasPrefix(trimmed.lowercased())
            let right = rhs.displayName.lowercased().hasPrefix(trimmed.lowercased())
            if left != right { return left }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
}

// MARK: - AppState

extension AppState {
    /// The Styles page's stored group choices. Saving drops choices for
    /// rules that are gone, unless a removal can still be undone (its rule
    /// must come back in the same tab).
    var calmStyleGroupStore: CalmStyleGroupStore {
        get { CalmStyleGroupStore.decode(UserDefaults.standard.string(forKey: CalmStyleGroupStore.defaultsKey)) }
        set {
            var store = newValue
            if undoCenter.current == nil { store.prune(keepingKeys: calmLiveStyleGroupKeys) }
            UserDefaults.standard.set(store.encodedJSON(), forKey: CalmStyleGroupStore.defaultsKey)
            objectWillChange.send()
        }
    }

    /// Store keys of the app and website rules that exist now.
    private var calmLiveStyleGroupKeys: Set<String> {
        Set(writingStyleBindings.map { CalmStyleGroupStore.appKey($0.id) }
            + websiteStyleBindings.map { CalmStyleGroupStore.websiteKey($0.id) })
    }

    /// Drop group choices left behind by removed rules (see `calmStyleGroupStore`).
    func calmPruneStyleGroups() {
        let store = calmStyleGroupStore
        var pruned = store
        pruned.prune(keepingKeys: calmLiveStyleGroupKeys)
        if pruned != store, undoCenter.current == nil { calmStyleGroupStore = pruned }
    }

    /// Forget where these app rules were put, so rules re-added by Set Up My
    /// Apps or an import land in the tab the catalog or their style picks.
    func calmResetStyleGroups(forApps ids: [String]) {
        var store = calmStyleGroupStore
        let keys = Set(ids.map(CalmStyleGroupStore.appKey))
        let before = store.assignments.count
        store.assignments = store.assignments.filter { !keys.contains($0.key) }
        if store.assignments.count != before { calmStyleGroupStore = store }
    }

    /// Keep a rule in the tab it shows under now, so a new style doesn't
    /// move it to another tab.
    private func calmPin(_ group: CalmStyleGroup, key: String) {
        var store = calmStyleGroupStore
        guard store.group(forKey: key) != group else { return }
        store.assign(group, toKey: key)
        calmStyleGroupStore = store
    }

    /// The tab an app rule shows under: where it was put, else where the
    /// catalog says it belongs, else the group of its style.
    func calmStyleGroup(of binding: AppStyleBinding, store: CalmStyleGroupStore? = nil) -> CalmStyleGroup {
        let store = store ?? calmStyleGroupStore
        if let group = store.group(forKey: CalmStyleGroupStore.appKey(binding.id)) { return group }
        if let group = CalmStyleGroup.catalogGroup(
            bundleIdentifier: binding.bundleIdentifier, processName: binding.processName, id: binding.id
        ) {
            return group
        }
        return CalmStyleGroup.family(of: binding.style)
    }

    /// The tab a website rule shows under: where it was put, else the group of its style.
    func calmStyleGroup(of website: WebsiteStyleBinding, store: CalmStyleGroupStore? = nil) -> CalmStyleGroup {
        let store = store ?? calmStyleGroupStore
        return store.group(forKey: CalmStyleGroupStore.websiteKey(website.id)) ?? CalmStyleGroup.family(of: website.style)
    }

    /// App rules in a group, in list order.
    func calmApps(in group: CalmStyleGroup) -> [AppStyleBinding] {
        let store = calmStyleGroupStore
        return writingStyleBindings.filter { calmStyleGroup(of: $0, store: store) == group }
    }

    /// Website rules in a group, in list order.
    func calmWebsites(in group: CalmStyleGroup) -> [WebsiteStyleBinding] {
        let store = calmStyleGroupStore
        return websiteStyleBindings.filter { calmStyleGroup(of: $0, store: store) == group }
    }

    /// The style a group's card shows as chosen. Everything else is the
    /// default style. Other groups use the style last picked on their card;
    /// before that, the style most of their apps use; with no apps, the
    /// group's own default.
    func calmStyle(for group: CalmStyleGroup) -> WritingStyle {
        if group == .everythingElse { return writingStyleDefault }
        if let picked = calmStyleGroupStore.style(for: group) { return picked }
        let apps = calmApps(in: group)
        let websites = calmWebsites(in: group)
        let enabled = apps.filter(\.isEnabled).map(\.style) + websites.filter(\.isEnabled).map(\.style)
        let all = apps.map(\.style) + websites.map(\.style)
        return Self.mostCommonStyle(enabled.isEmpty ? all : enabled, preferring: group.cardStyles) ?? group.defaultStyle
    }

    /// The style used most often; ties go to the earlier style in `order`,
    /// then to `WritingStyle.allCases` order.
    static func mostCommonStyle(_ styles: [WritingStyle], preferring order: [WritingStyle]) -> WritingStyle? {
        guard !styles.isEmpty else { return nil }
        var counts: [WritingStyle: Int] = [:]
        for style in styles { counts[style, default: 0] += 1 }
        let ranking = order + WritingStyle.allCases.filter { !order.contains($0) }
        return ranking.max { lhs, rhs in
            let left = counts[lhs, default: 0]
            let right = counts[rhs, default: 0]
            if left != right { return left < right }
            // Equal counts: the style earlier in the ranking counts as larger.
            return (ranking.firstIndex(of: lhs) ?? 0) > (ranking.firstIndex(of: rhs) ?? 0)
        }
    }

    /// Apps and websites in `group` that chose a style of their own: not
    /// the group's current style, and not `style`. Picking a card leaves
    /// them alone unless the user confirms applying it to all.
    func calmOtherStyleMembers(
        in group: CalmStyleGroup, besides style: WritingStyle
    ) -> (apps: [AppStyleBinding], websites: [WebsiteStyleBinding]) {
        let current = calmStyle(for: group)
        return (
            calmApps(in: group).filter { $0.style != current && $0.style != style },
            calmWebsites(in: group).filter { $0.style != current && $0.style != style }
        )
    }

    /// Apps in `group` whose customized formatting picking `style` would
    /// reset: those following the group's current style, or every app in
    /// the group when `includingOtherStyles`.
    func calmCustomizedApps(
        in group: CalmStyleGroup, switchingTo style: WritingStyle, includingOtherStyles: Bool = false
    ) -> [AppStyleBinding] {
        let current = calmStyle(for: group)
        return calmApps(in: group).filter {
            $0.style != style && $0.hasCustomRules && (includingOtherStyles || $0.style == current)
        }
    }

    /// Pick a group's card: the group uses `style` for new apps, and so do
    /// the apps and websites that used its previous style. Apps with a
    /// style of their own keep it unless `includingOtherStyles`; that change
    /// can be undone. A changed app's formatting goes back to the style's
    /// own; tone and AI cleanup choices are kept. Everything else also sets
    /// the default style.
    func calmApplyStyle(_ style: WritingStyle, to group: CalmStyleGroup, includingOtherStyles: Bool = false) {
        let previous = calmStyle(for: group)
        var store = calmStyleGroupStore
        let storeBefore = store
        let defaultBefore = writingStyleDefault
        let apps = calmApps(in: group)
        let websites = calmWebsites(in: group)
        if group == .everythingElse {
            writingStyleDefault = style
        } else {
            store.setStyle(style, for: group)
        }
        // Pin members to this group so a new style can't move them to another tab.
        for app in apps { store.assign(group, toKey: CalmStyleGroupStore.appKey(app.id)) }
        for site in websites { store.assign(group, toKey: CalmStyleGroupStore.websiteKey(site.id)) }
        calmStyleGroupStore = store

        func follows(_ memberStyle: WritingStyle) -> Bool {
            memberStyle != style && (includingOtherStyles || memberStyle == previous)
        }
        let changedApps = apps.filter { follows($0.style) }
        let changedSites = websites.filter { follows($0.style) }
        let appIDs = Set(changedApps.map(\.id))
        if !appIDs.isEmpty {
            writingStyleBindings = writingStyleBindings.map { binding in
                guard appIDs.contains(binding.id) else { return binding }
                var updated = binding
                updated.style = style
                updated.ruleOverrides = nil
                return updated
            }
        }
        let siteIDs = Set(changedSites.map(\.id))
        if !siteIDs.isEmpty {
            websiteStyleBindings = websiteStyleBindings.map { site in
                guard siteIDs.contains(site.id) else { return site }
                var updated = site
                updated.style = style
                return updated
            }
        }
        VocaLogger.info(.appState, "Styles: \(group.rawValue) now uses \(style.rawValue)")

        guard includingOtherStyles, !changedApps.isEmpty || !changedSites.isEmpty else { return }
        let count = changedApps.count + changedSites.count
        undoCenter.offer("\(style.displayName) for \(count) app\(count == 1 ? "" : "s")") { [weak self] in
            self?.calmRestore(apps: changedApps, websites: changedSites, store: storeBefore, defaultStyle: defaultBefore)
        }
    }

    /// Put rules (still present) and the group choices back as they were.
    private func calmRestore(
        apps: [AppStyleBinding], websites: [WebsiteStyleBinding], store: CalmStyleGroupStore, defaultStyle: WritingStyle
    ) {
        let appsByID = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sitesByID = Dictionary(websites.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        writingStyleBindings = writingStyleBindings.map { appsByID[$0.id] ?? $0 }
        websiteStyleBindings = websiteStyleBindings.map { sitesByID[$0.id] ?? $0 }
        writingStyleDefault = defaultStyle
        calmStyleGroupStore = store
    }

    /// Change one app's style. Its formatting goes back to the new style's own.
    func calmSetStyle(_ style: WritingStyle, forApp id: String) {
        calmUpdateApp(id) { binding in
            guard binding.style != style else { return }
            binding.style = style
            binding.ruleOverrides = nil
        }
    }

    /// Edit one app rule in place. A style change pins the rule to the tab
    /// it shows under, so it doesn't jump to another tab.
    func calmUpdateApp(_ id: String, _ mutate: (inout AppStyleBinding) -> Void) {
        var bindings = writingStyleBindings
        guard let index = bindings.firstIndex(where: { $0.id == id }) else { return }
        let before = bindings[index]
        mutate(&bindings[index])
        if bindings[index].style != before.style {
            calmPin(calmStyleGroup(of: before), key: CalmStyleGroupStore.appKey(before.id))
        }
        writingStyleBindings = bindings
    }

    /// Edit one website rule in place. A style change pins the rule to the
    /// tab it shows under.
    func calmUpdateWebsite(_ id: UUID, _ mutate: (inout WebsiteStyleBinding) -> Void) {
        var rules = websiteStyleBindings
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        let before = rules[index]
        mutate(&rules[index])
        if rules[index].style != before.style {
            calmPin(calmStyleGroup(of: before), key: CalmStyleGroupStore.websiteKey(before.id))
        }
        websiteStyleBindings = rules
    }

    /// Add an app to a group with the group's style. An app that already
    /// has a rule (in another tab) keeps it: the rule moves to this group
    /// and only its style changes, so its tone, cleanup, prompt, overrides
    /// and paused state stay. Known apps keep their suggested tone.
    @discardableResult
    func calmAddApp(_ snapshot: RunningAppSnapshot, to group: CalmStyleGroup) -> AppStyleBinding {
        let style = calmStyle(for: group)
        var bindings = writingStyleBindings
        if let index = bindings.firstIndex(where: { $0.matches(snapshot) }) {
            bindings[index].style = style
            let moved = bindings[index]
            writingStyleBindings = bindings
            var store = calmStyleGroupStore
            store.assign(group, toKey: CalmStyleGroupStore.appKey(moved.id))
            calmStyleGroupStore = store
            return moved
        }
        var binding: AppStyleBinding
        if let suggestion = WritingStyleCatalog.suggestion(matching: snapshot) {
            binding = suggestion.binding
            binding.displayName = snapshot.displayName.isEmpty ? suggestion.displayName : snapshot.displayName
            if binding.style != style {
                binding.style = style
                binding.ruleOverrides = nil
            }
        } else {
            binding = AppStyleBinding.from(snapshot: snapshot, style: style)
        }
        bindings.append(binding)
        writingStyleBindings = bindings

        var store = calmStyleGroupStore
        store.assign(group, toKey: CalmStyleGroupStore.appKey(binding.id))
        calmStyleGroupStore = store
        return binding
    }

    /// Add a website to a group with the group's style. Returns nil when the
    /// text is not a usable address. A rule for the same host moves here
    /// and keeps everything but its style.
    @discardableResult
    func calmAddWebsite(_ text: String, to group: CalmStyleGroup) -> WebsiteStyleBinding? {
        let host = CalmWebsiteHost.normalized(text)
        guard !host.isEmpty else { return nil }
        var rule = WebsiteStyleBinding(hostPattern: host, displayName: host, style: calmStyle(for: group))
        var rules = websiteStyleBindings
        if let index = rules.firstIndex(where: { WebsiteStyleBinding.sharesHost($0, rule) }) {
            // Move the existing rule here; only its style changes.
            rules[index].style = rule.style
            rule = rules[index]
        } else {
            rules.append(rule)
        }
        websiteStyleBindings = rules

        var store = calmStyleGroupStore
        store.assign(group, toKey: CalmStyleGroupStore.websiteKey(rule.id))
        calmStyleGroupStore = store
        return rule
    }

    /// The group an app already has a rule in, if any.
    func calmExistingGroup(for snapshot: RunningAppSnapshot) -> CalmStyleGroup? {
        let store = calmStyleGroupStore
        return writingStyleBindings.first { $0.matches(snapshot) }.map { calmStyleGroup(of: $0, store: store) }
    }

    /// Catalog apps for `group` that are installed or running and not yet set up.
    func calmSuggestedApps(for group: CalmStyleGroup, installed: [RunningAppSnapshot]) -> [RunningAppSnapshot] {
        let bundleIDs = Set(installed.compactMap { $0.bundleIdentifier?.lowercased() })
        return group.catalogSuggestions.compactMap { suggestion in
            guard let bundleID = suggestion.bundleIdentifier, bundleIDs.contains(bundleID.lowercased()) else { return nil }
            let snapshot = installed.first { $0.bundleIdentifier?.lowercased() == bundleID.lowercased() }
                ?? RunningAppSnapshot(displayName: suggestion.displayName, bundleIdentifier: bundleID, processName: suggestion.processName)
            return calmExistingGroup(for: snapshot) == nil ? snapshot : nil
        }
    }
}
