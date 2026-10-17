// CalmStylesDialogs.swift
// VocaMac
//
// The Styles page's dialogs: “Add app or website” (search installed and
// open apps, type a website, or pick from the Applications folder), the
// per-app editor with every Advanced override, and the website editor.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Add app or website

/// One row of the Add dialog.
private enum CalmStylesAddCandidate: Identifiable, Hashable {
    case website(String)
    case app(RunningAppSnapshot)

    var id: String {
        switch self {
        case .website(let host): return "site:\(host)"
        case .app(let app): return "app:\(app.bundleIdentifier ?? app.displayName)"
        }
    }

    var name: String {
        switch self {
        case .website(let host): return host
        case .app(let app): return app.displayName
        }
    }
}

/// Searches installed and open apps as you type; a typed address becomes a
/// website row. The new rule uses the group's style.
struct CalmStylesAddDialog: View {
    let group: CalmStyleGroup
    let onAdded: (String) -> Void

    @EnvironmentObject private var appState: AppState
    @Environment(\.calmDismissDialog) private var dismiss

    @State private var query = ""
    @State private var running: [RunningAppSnapshot] = []
    @State private var installed: [RunningAppSnapshot] = []
    @State private var isLoading = true
    @State private var selectionID: String?
    @FocusState private var isSearchFocused: Bool

    /// Rows kept on screen; the list scrolls past five.
    private static let visibleRows = 5
    private static let rowHeight: CGFloat = 48

    var body: some View {
        CalmDialog("Add app or website", description: "It will use this group’s style.", width: 480) {
            VStack(alignment: .leading, spacing: 12) {
                CalmSearchField(text: $query, prompt: "Search apps", focus: $isSearchFocused) { addSelected() }
                list
                Text("Or type a website, like github.com")
                    .calmType(.description)
            }
        } footer: {
            CalmDialogFooter(
                primaryTitle: "Add",
                isPrimaryEnabled: selected.map(canAdd) ?? false,
                dismissesOnPrimary: false,
                onPrimary: addSelected
            ) {
                Button("Choose from Applications…") { chooseFromApplications() }
                    .calmButton(.quiet)
            }
        }
        .task {
            running = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { AppIdentityMatching.snapshot(for: $0) }
            let onDisk = await Task.detached(priority: .userInitiated) { CalmAppCandidates.installedApps() }.value
            installed = CalmAppCandidates.merged([onDisk, running])
            isLoading = false
        }
        .onAppear { isSearchFocused = true }
        .onChange(of: query) { selectionID = nil }
    }

    // MARK: Rows

    private var candidates: [CalmStylesAddCandidate] {
        var rows: [CalmStylesAddCandidate] = []
        if CalmWebsiteHost.looksLikeWebsite(query) {
            rows.append(.website(CalmWebsiteHost.normalized(query)))
        }
        let apps: [RunningAppSnapshot]
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Apps VocaMac knows for this group first, then whatever is open.
            let suggested = appState.calmSuggestedApps(for: group, installed: installed.isEmpty ? running : installed)
            let suggestedKeys = Set(suggested.map(Self.key))
            apps = suggested + CalmAppCandidates.merged([running]).filter { !suggestedKeys.contains(Self.key($0)) }
        } else {
            apps = CalmAppCandidates.filter(installed.isEmpty ? running : installed, query: query)
        }
        rows += apps.prefix(60).map { .app($0) }
        return rows
    }

    private static func key(_ app: RunningAppSnapshot) -> String {
        app.bundleIdentifier?.lowercased() ?? "name:\(app.displayName.lowercased())"
    }

    private var selected: CalmStylesAddCandidate? {
        let rows = candidates
        if let selectionID, let row = rows.first(where: { $0.id == selectionID }) { return row }
        return rows.first
    }

    @ViewBuilder
    private var list: some View {
        let rows = candidates
        let shape = RoundedRectangle(cornerRadius: CalmMetrics.Radius.list, style: .continuous)
        if rows.isEmpty {
            Text(isLoading ? "Finding your apps…" : (query.isEmpty ? "No open apps." : "No apps match “\(query)”."))
                .font(CalmFont.control)
                .foregroundStyle(CalmColor.muted)
                .frame(maxWidth: .infinity)
                .padding(24)
                .overlay(shape.strokeBorder(CalmColor.line2, lineWidth: 1))
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Rectangle().fill(CalmColor.line).frame(height: 1) }
                        rowView(row, isSelected: row.id == selected?.id)
                    }
                }
            }
            .scrollIndicators(rows.count > Self.visibleRows ? .automatic : .never)
            .frame(height: min(CGFloat(rows.count), CGFloat(Self.visibleRows)) * (Self.rowHeight + 1) - 1)
            .background(shape.fill(CalmColor.content))
            .clipShape(shape)
            .overlay(shape.strokeBorder(CalmColor.line2, lineWidth: 1))
        }
    }

    private func rowView(_ row: CalmStylesAddCandidate, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            switch row {
            case .website(let host):
                CalmAppTile(name: host)
            case .app(let app):
                CalmAppTile(name: app.displayName, bundleIdentifier: app.bundleIdentifier)
            }
            Text(row.name)
                .font(CalmFont.body)
                .foregroundStyle(CalmColor.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let note = note(for: row) {
                Text(note).font(CalmFont.note).foregroundStyle(CalmColor.muted)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Self.rowHeight)
        .background(isSelected ? CalmColor.panel2 : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            selectionID = row.id
            addSelected()
        }
        .onTapGesture { selectionID = row.id }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selectionID = row.id }
    }

    /// “In Code” for an app another tab already has, “Added” for one here.
    private func note(for row: CalmStylesAddCandidate) -> String? {
        switch row {
        case .website(let host):
            if let existing = appState.websiteStyleBindings.first(where: { $0.hostPattern.lowercased() == host }) {
                let current = appState.calmStyleGroup(of: existing)
                return current == group ? "Added" : "In \(current.title)"
            }
            return "Website"
        case .app(let app):
            guard let current = appState.calmExistingGroup(for: app) else { return nil }
            return current == group ? "Added" : "In \(current.title)"
        }
    }

    private func canAdd(_ row: CalmStylesAddCandidate) -> Bool {
        note(for: row) != "Added"
    }

    // MARK: Actions

    private func addSelected() {
        guard let row = selected, canAdd(row) else { return }
        switch row {
        case .website(let host):
            guard let rule = appState.calmAddWebsite(host, to: group) else { return }
            onAdded("Added \(rule.displayName).")
        case .app(let app):
            let binding = appState.calmAddApp(app, to: group)
            onAdded("Added \(binding.displayName).")
        }
        dismiss?()
    }

    /// An app that's installed somewhere else, picked from disk.
    private func chooseFromApplications() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Application"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let binding = appState.calmAddApp(CalmAppCandidates.snapshot(forAppAt: url), to: group)
        onAdded("Added \(binding.displayName).")
        dismiss?()
    }
}

// MARK: - Shared editor pieces

private extension WritingCleanupPolicy {
    /// What each AI cleanup choice does for one app or website.
    func explanation(for style: WritingStyle) -> String {
        switch self {
        case .raw: return "Types exactly what was heard: no cleanup, snippets, or formatting."
        case .off: return "Applies the style’s formatting but never runs the AI model."
        case .inherit:
            return style.supportsWording
                ? "Follows Smart Cleanup."
                : "Follows Smart Cleanup, but only removes filler words. Commands stay exact."
        }
    }
}

private enum CalmStylesOptions {
    static var styles: [CalmOption<WritingStyle>] { WritingStyle.allCases.map { CalmOption($0, $0.displayName) } }
    static var intents: [CalmOption<WritingIntent>] { WritingIntent.allCases.map { CalmOption($0, $0.displayName) } }
    static var cleanup: [CalmOption<WritingCleanupPolicy>] { WritingCleanupPolicy.allCases.map { CalmOption($0, $0.displayName) } }
    static var levels: [CalmOption<CleanupLevel?>] {
        [CalmOption(nil, "Same as Smart Cleanup")] + CleanupLevel.displayOrder.map { CalmOption(Optional($0), $0.displayName) }
    }
}

/// The dialog body scrolls when Advanced makes it taller than the window allows.
private struct CalmStylesDialogScroll<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
        }
        .padding(.horizontal, -4)
        .frame(maxHeight: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - App editor

/// Per-app editor. The style and tone are all most people change;
/// everything else sits under Advanced. Saving with no rule changes clears
/// the override so the app tracks future preset improvements.
struct CalmStylesAppEditorDialog: View {
    let binding: AppStyleBinding

    @EnvironmentObject private var appState: AppState

    @State private var style: WritingStyle
    @State private var rules: WritingStyleRules
    @State private var intent: WritingIntent
    @State private var cleanup: WritingCleanupPolicy
    @State private var cleanupLevel: CleanupLevel?
    @State private var cleanupPrompt: String
    @State private var showsAdvanced: Bool

    init(binding: AppStyleBinding) {
        self.binding = binding
        _style = State(initialValue: binding.style)
        _rules = State(initialValue: binding.effectiveRules)
        _intent = State(initialValue: binding.intent)
        _cleanup = State(initialValue: binding.cleanup)
        _cleanupLevel = State(initialValue: binding.cleanupLevel)
        _cleanupPrompt = State(initialValue: binding.cleanupPrompt ?? "")
        // Open Advanced only when something in it was already changed, so the
        // user can see why this app behaves differently.
        _showsAdvanced = State(initialValue: binding.hasCustomRules
            || binding.cleanup != .inherit
            || binding.cleanupLevel != nil
            || binding.cleanupPrompt != nil)
    }

    var body: some View {
        CalmDialog(binding.displayName, description: "How dictation is written in this app.", width: CalmMetrics.dialogListWidth) {
            CalmStylesDialogScroll {
                CalmStylesDialogRow("Style") {
                    CalmDropdown(selection: Binding(
                        get: { style },
                        set: { newValue in
                            guard newValue != style else { return }
                            style = newValue
                            rules = newValue.defaultRules
                        }
                    ), options: CalmStylesOptions.styles)
                }
                CalmStylesExample(style: style, rules: rules)
                CalmStylesDialogRow("Tone", note: toneExplanation) {
                    CalmDropdown(selection: $intent, options: CalmStylesOptions.intents)
                        .disabled(!style.supportsWording || cleanup != .inherit)
                }
                CalmStylesDisclosure(title: "Advanced", isExpanded: $showsAdvanced)
                if showsAdvanced { advanced }
            }
        } footer: {
            CalmDialogFooter(primaryTitle: "Save", onPrimary: save) {
                Button("Reset to style defaults") {
                    rules = style.defaultRules
                    cleanup = .inherit
                    cleanupLevel = nil
                    cleanupPrompt = ""
                }
                .calmButton(.quiet)
            }
        }
    }

    @ViewBuilder
    private var advanced: some View {
        CalmStylesDialogRow("AI cleanup", note: cleanup.explanation(for: style)) {
            CalmDropdown(selection: $cleanup, options: CalmStylesOptions.cleanup)
        }
        CalmStylesDialogRow("Cleanup level") {
            CalmDropdown(selection: $cleanupLevel, options: CalmStylesOptions.levels)
                .disabled(cleanup != .inherit)
        }
        CalmStylesDialogRow("Capital letters") {
            CalmDropdown(selection: $rules.capitalization, options: CapitalizationPolicy.allCases.map { CalmOption($0, $0.displayName) })
        }
        CalmStylesDialogRow("End of sentence") {
            CalmDropdown(selection: $rules.terminalPunctuation, options: TerminalPunctuationPolicy.allCases.map { CalmOption($0, $0.displayName) })
        }
        CalmStylesDialogRow("Space after text") {
            CalmDropdown(selection: $rules.trailingSpace, options: TrailingSpacePolicy.allCases.map { CalmOption($0, $0.displayName) })
        }
        CalmStylesDialogRow("“Um” at the start") {
            CalmDropdown(selection: $rules.filler, options: FillerPolicy.allCases.map { CalmOption($0, $0.displayName) })
        }
        CalmStylesDialogToggle(
            "Spoken filenames",
            note: "“config dot json” becomes config.json. Say “literally” first to keep a word as spoken.",
            isOn: tierBinding(.tierA)
        )
        CalmStylesDialogToggle(
            "Spoken paths and names",
            note: "“src slash utils” becomes src/utils. Best in code editors and terminals.",
            isOn: tierBinding(.tierB)
        )
        CalmStylesDialogToggle("Join multi-word filenames and paths", isOn: $rules.pathStitching)
        CalmStylesDialogToggle("“camel case” and “snake case”", isOn: $rules.caseCommands)
        CalmStylesDialogRow("“Bold” and “italic”") {
            CalmDropdown(selection: $rules.emphasisDialect, options: EmphasisDialect.allCases.map { CalmOption($0, $0.displayName) })
        }
        CalmStylesDialogToggle("“Bullet” starts a list item", isOn: $rules.listMarkers)
        CalmStylesDialogToggle("“New line” and “new paragraph”", isOn: $rules.newlineCommands)
        CalmTextEditor(
            "Custom cleanup instructions", text: $cleanupPrompt,
            prompt: "Leave blank to use the instructions from Smart Cleanup.", minHeight: 70
        )
    }

    private func tierBinding(_ tier: SpokenSymbolTiers) -> Binding<Bool> {
        Binding(
            get: { rules.spokenSymbols.contains(tier) },
            set: { isOn in
                if isOn {
                    rules.spokenSymbols.insert(tier)
                } else {
                    rules.spokenSymbols.remove(tier)
                }
            }
        )
    }

    private var toneExplanation: String {
        if !style.supportsWording { return "Code and Terminal always keep your exact words." }
        if cleanup != .inherit { return "Tone needs AI cleanup, which is off for this app under Advanced." }
        return intent.description + " Needs “Reword to sound Formal or Casual” and Smart Cleanup."
    }

    private func save() {
        let trimmedPrompt = cleanupPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let style = style
        let rules = rules
        let intent = intent
        let cleanup = cleanup
        let cleanupLevel = cleanupLevel
        let prompt = trimmedPrompt.isEmpty ? nil : cleanupPrompt
        appState.calmUpdateApp(binding.id) { updated in
            updated.style = style
            updated.intent = intent
            updated.cleanup = cleanup
            updated.cleanupLevel = cleanupLevel
            updated.cleanupPrompt = prompt
            // Storing nil when nothing was changed lets the binding inherit
            // future improvements to the preset.
            updated.ruleOverrides = rules == style.defaultRules ? nil : rules
        }
    }
}

// MARK: - Website editor

/// Edit one website rule: name, domain, style, tone and Advanced cleanup.
struct CalmStylesWebsiteEditorDialog: View {
    let rule: WebsiteStyleBinding

    @EnvironmentObject private var appState: AppState
    @State private var draft: WebsiteStyleBinding
    @State private var showsAdvanced: Bool

    init(rule: WebsiteStyleBinding) {
        self.rule = rule
        _draft = State(initialValue: rule)
        _showsAdvanced = State(initialValue: rule.cleanup != .inherit
            || rule.cleanupLevel != nil
            || rule.cleanupPrompt != nil)
    }

    var body: some View {
        CalmDialog(
            "Edit website",
            description: "VocaMac reads the focused tab’s address through Accessibility. Addresses are never saved to history.",
            width: 480
        ) {
            CalmStylesDialogScroll {
                CalmTextField("Name", text: $draft.displayName, prompt: normalizedHost)
                VStack(alignment: .leading, spacing: 6) {
                    CalmTextField("Domain", text: $draft.hostPattern, prompt: "example.com or *.example.com")
                    Text("A domain also matches its subdomains: example.com covers mail.example.com.")
                        .font(CalmFont.note)
                        .foregroundStyle(CalmColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                CalmStylesDialogRow("Style") {
                    CalmDropdown(selection: $draft.style, options: CalmStylesOptions.styles)
                }
                CalmStylesExample(style: draft.style)
                CalmStylesDialogRow("Tone") {
                    CalmDropdown(selection: $draft.intent, options: CalmStylesOptions.intents)
                        .disabled(!draft.style.supportsWording)
                }
                CalmStylesDisclosure(title: "Advanced", isExpanded: $showsAdvanced)
                if showsAdvanced {
                    CalmStylesDialogRow("AI cleanup", note: draft.cleanup.explanation(for: draft.style)) {
                        CalmDropdown(selection: $draft.cleanup, options: CalmStylesOptions.cleanup)
                    }
                    CalmStylesDialogRow("Cleanup level") {
                        CalmDropdown(selection: $draft.cleanupLevel, options: CalmStylesOptions.levels)
                            .disabled(draft.cleanup != .inherit)
                    }
                    CalmTextEditor(
                        "Custom cleanup instructions",
                        text: Binding(
                            get: { draft.cleanupPrompt ?? "" },
                            set: { draft.cleanupPrompt = $0.isEmpty ? nil : $0 }
                        ),
                        prompt: "Leave blank to use the instructions from Smart Cleanup. Applies only on this website.",
                        minHeight: 70
                    )
                }
            }
        } footer: {
            CalmDialogFooter(primaryTitle: "Save", isPrimaryEnabled: !normalizedHost.isEmpty) {
                var value = draft
                value.hostPattern = normalizedHost
                if value.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    value.displayName = normalizedHost
                }
                appState.calmUpdateWebsite(rule.id) { $0 = value }
            }
        }
    }

    private var normalizedHost: String { CalmWebsiteHost.normalized(draft.hostPattern) }
}
