// CalmStylesPage.swift
// VocaMac
//
// Styles: how dictation is written in each kind of app. Four tabs group
// the apps and websites that have a style (Messages, Email, Code,
// Everything else); one card per tab picks the group's style. Below: the
// switches for per-app styles and tone, a Try it preview, and the typed
// text rules that apply in every app.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Styles: writing styles per kind of app, and typed-text formatting.
struct CalmStylesPage: View {
    @EnvironmentObject private var appState: AppState
    @Environment(CalmNavigator.self) private var navigator: CalmNavigator?
    @Environment(\.settingsSearchTarget) private var searchTarget

    @AppStorage("calm.styles.tab") private var storedTab = CalmStyleGroup.messages.rawValue

    @State private var addingTo: CalmStyleGroup?
    @State private var customizing: AppStyleBinding?
    @State private var editingWebsite: WebsiteStyleBinding?
    @State private var pendingGroupStyle: CalmStylesPendingGroupStyle?
    @State private var pendingApplyToAll: CalmStylesPendingApplyToAll?
    @State private var pendingAppStyle: CalmStylesPendingAppStyle?
    @State private var isConfirmingRemoveAll = false
    @State private var notice: CalmStylesNotice?
    @State private var isDiscoveringApps = false

    private var group: CalmStyleGroup { CalmStyleGroup(rawValue: storedTab) ?? .messages }

    var body: some View {
        CalmPage(.list, spacing: 24) {
            CalmPageHeader("Styles", description: "How your words look in each kind of app. Pick one per group.") {
                optionsMenu
            }

            VStack(alignment: .leading, spacing: 24) {
                CalmTabs(
                    selection: Binding(get: { group }, set: { storedTab = $0.rawValue }),
                    tabs: CalmStyleGroup.allCases.map { CalmOption($0, $0.title) }
                ) {
                    // Text, not a 34-point control: lift it onto the tabs'
                    // baseline (they sit 11 above the line, trailing 6).
                    otherStylesMenu.padding(.bottom, 5)
                }
                cards
                    .settingsTarget("writing-styles", aliases: ["default-writing-style"])
                usedIn
                    .settingsTarget(
                        "app-style-rules",
                        aliases: ["app-cleanup-prompt", "spoken-symbols", "website-style-rules"]
                    )
            }
            .calmDisabledByParent(!appState.writingStyleEnabled)

            infoPanel

            CalmModesSection()
                .padding(.top, 16)
                .settingsTarget("dictation-modes")

            CalmStylesSettingsSections()
                .padding(.top, 16)
        }
        .onChange(of: searchTarget, initial: true) { _, target in
            // “Style everywhere else” is the Everything else card.
            if target == "default-writing-style" { storedTab = CalmStyleGroup.everythingElse.rawValue }
        }
        .onChange(of: storedTab) { notice = nil }
        // Try it starts on the style each tab uses, not a fixed Plain: on
        // opening a tab (even one sharing the last tab's style, after Try it
        // was pointed elsewhere) and when the tab's style changes.
        .onChange(of: "\(group.rawValue)|\(appState.calmStyle(for: group).rawValue)", initial: true) {
            appState.settingsPreviewBindingID = nil
            appState.settingsPreviewStyle = appState.calmStyle(for: group)
        }
        .onAppear { appState.calmPruneStyleGroups() }
        .calmDialog(item: $addingTo) { group in
            CalmStylesAddDialog(group: group) { message in notice = CalmStylesNotice(message, tone: .success) }
        }
        .calmDialog(item: $customizing) { binding in
            CalmStylesAppEditorDialog(binding: binding)
        }
        .calmDialog(item: $editingWebsite) { rule in
            CalmStylesWebsiteEditorDialog(rule: rule)
        }
        .calmDialog(item: $pendingGroupStyle) { pending in
            CalmDialog(
                "Use \(pending.style.displayName) for \(pending.group.title)?",
                description: "\(Self.nameList(pending.customizedNames)) \(pending.customizedNames.count == 1 ? "has" : "have") customized formatting. "
                    + "Switching replaces it with \(pending.style.displayName)’s formatting. Tone and AI cleanup settings are kept."
            ) {
                CalmDialogFooter(primaryTitle: "Switch and reset formatting", primaryKind: .destructive) {
                    appState.calmApplyStyle(pending.style, to: pending.group)
                    noteOtherStyles(in: pending.group, style: pending.style)
                }
            }
        }
        .calmDialog(item: $pendingApplyToAll) { pending in
            CalmDialog(
                "Use \(pending.style.displayName) for every app in \(pending.group.title)?",
                description: "These keep their own style unless you apply \(pending.style.displayName) to all. "
                    + "Customized formatting goes back to \(pending.style.displayName)’s. Tone and AI cleanup settings are kept."
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(pending.members, id: \.self) { member in
                        Text(member)
                            .font(CalmFont.control)
                            .foregroundStyle(CalmColor.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .calmDialogScrollingList(maxHeight: 220)
            } footer: {
                CalmDialogFooter(primaryTitle: pending.total > 1 ? "Apply to all \(pending.total) apps" : "Apply") {
                    appState.calmApplyStyle(pending.style, to: pending.group, includingOtherStyles: true)
                    notice = nil
                }
            }
        }
        .calmDialog(item: $pendingAppStyle) { pending in
            CalmDialog(
                "Switch \(pending.binding.displayName) to \(pending.style.displayName)?",
                description: "\(pending.binding.displayName) has customized formatting. Switching replaces it with "
                    + "\(pending.style.displayName)’s formatting. Tone and AI cleanup settings are kept."
            ) {
                CalmDialogFooter(primaryTitle: "Switch and reset formatting", primaryKind: .destructive) {
                    appState.calmSetStyle(pending.style, forApp: pending.binding.id)
                }
            }
        }
        .calmDialog(isPresented: $isConfirmingRemoveAll) {
            CalmDialog(
                "Remove all apps?",
                description: "All \(appState.writingStyleBindings.count) apps go back to "
                    + "\(appState.writingStyleDefault.displayName), the style for everything else. Websites stay. You can undo this."
            ) {
                CalmDialogFooter(primaryTitle: "Remove all", primaryKind: .destructive) {
                    let style = appState.writingStyleDefault.displayName
                    appState.removeAllAppStyleBindingsWithUndo { notice = nil }
                    notice = CalmStylesNotice("Removed every app. All apps now use \(style).", tone: .info)
                }
            }
        }
    }

    // MARK: Header menu

    private var optionsMenu: some View {
        Menu {
            Button("Set up my apps") { Task { await addSuggestions() } }
                .disabled(isDiscoveringApps)
            Divider()
            Button("Export App List…") { exportRules() }
                .disabled(appState.writingStyleBindings.isEmpty)
            Button("Import App List…") { importRules() }
            Divider()
            Button("Remove All Apps…", role: .destructive) { isConfirmingRemoveAll = true }
                .disabled(appState.writingStyleBindings.isEmpty)
        } label: {
            CalmIconMenuLabel("App list options", icon: .more, size: 18, weight: 2.4)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(CalmIconButtonStyle())
        .focusEffectDisabled()
        .fixedSize()
        .help("Set up, import, export, or remove your app list")
        .accessibilityLabel("App list options")
        .settingsTarget("writing-style-rule-transfer")
    }

    // MARK: Tabs and cards

    /// Styles beyond the three cards, for a group that wants one of them.
    private var otherStylesMenu: some View {
        let current = appState.calmStyle(for: group)
        let isOther = !group.cardStyles.contains(current)
        return Menu {
            Picker("Style for \(group.title)", selection: Binding(
                get: { current },
                set: { pick($0) }
            )) {
                ForEach(WritingStyle.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text(isOther ? "Uses \(current.displayName)" : "All styles")
                CalmIcon(.chevDown, size: 13)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(CalmLinkButtonStyle(muted: !isOther, font: CalmFont.sf(13, weight: isOther ? 600 : 400)))
        .focusEffectDisabled()
        .fixedSize()
        .accessibilityLabel("All styles for \(group.title)")
    }

    private var cards: some View {
        let selected = appState.calmStyle(for: group)
        return HStack(alignment: .top, spacing: 14) {
            ForEach(group.cardStyles) { style in
                CalmStyleCard(
                    style: style,
                    sample: appState.writingStylePreview(group.sampleSpeech(for: style), style: style),
                    isSelected: style == selected
                ) {
                    pick(style)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Style for \(group.title)")
    }

    /// Pick a card. A new style applies to the group and to the apps that
    /// used its previous one (confirming first when that resets customized
    /// apps); apps with a style of their own keep it. Picking the chosen
    /// card again offers to apply it to those apps too.
    private func pick(_ style: WritingStyle) {
        let group = group
        if style == appState.calmStyle(for: group) {
            let others = appState.calmOtherStyleMembers(in: group, besides: style)
            guard !others.apps.isEmpty || !others.websites.isEmpty else { return }
            pendingApplyToAll = CalmStylesPendingApplyToAll(
                group: group, style: style,
                members: others.apps.map { "\($0.displayName) · \($0.style.displayName)" }
                    + others.websites.map { "\($0.displayName) · \($0.style.displayName)" },
                total: appState.calmApps(in: group).count + appState.calmWebsites(in: group).count
            )
            return
        }
        let customized = appState.calmCustomizedApps(in: group, switchingTo: style)
        if customized.isEmpty {
            appState.calmApplyStyle(style, to: group)
            noteOtherStyles(in: group, style: style)
        } else {
            pendingGroupStyle = CalmStylesPendingGroupStyle(
                group: group, style: style, customizedNames: customized.map(\.displayName)
            )
        }
    }

    /// After a pick, say which apps kept a style of their own and how to change them.
    private func noteOtherStyles(in group: CalmStyleGroup, style: WritingStyle) {
        let others = appState.calmOtherStyleMembers(in: group, besides: style)
        let names = others.apps.map(\.displayName) + others.websites.map(\.displayName)
        guard !names.isEmpty else { return }
        notice = CalmStylesNotice(
            "\(Self.nameList(names)) \(names.count == 1 ? "keeps its" : "keep their") own style. "
                + "Click \(style.displayName) again to use it for all.",
            tone: .info
        )
    }

    // MARK: Used in

    private var usedIn: some View {
        let apps = appState.calmApps(in: group)
        let websites = appState.calmWebsites(in: group)
        let selected = appState.calmStyle(for: group)
        return CalmGroup("Used in") {
            VStack(alignment: .leading, spacing: 10) {
                FlowLayout(spacing: 8) {
                    if group == .everythingElse {
                        CalmStylesStaticChip(title: "All other apps")
                    }
                    ForEach(apps) { binding in
                        appChip(binding, groupStyle: selected)
                    }
                    ForEach(websites) { rule in
                        websiteChip(rule, groupStyle: selected)
                    }
                    if apps.isEmpty, websites.isEmpty, group != .everythingElse {
                        Text("No apps yet.")
                            .font(CalmFont.description)
                            .foregroundStyle(CalmColor.muted)
                            .frame(height: 32)
                            .padding(.horizontal, 2)
                    }
                    Button { addingTo = group } label: { CalmStylesAddLabel(title: "Add app or website") }
                        .buttonStyle(CalmStylesChipButtonStyle())
                        .focusEffectDisabled()
                    if appState.writingStyleBindings.isEmpty {
                        Button("Set up my apps") { Task { await addSuggestions() } }
                            .buttonStyle(CalmStylesChipButtonStyle())
                            .focusEffectDisabled()
                            .disabled(isDiscoveringApps)
                            .help("Finds the code editors, terminals, and chat and email apps on this Mac and picks a style for each.")
                    }
                }
                if isDiscoveringApps {
                    HStack(spacing: 8) {
                        CalmSpinner()
                        Text("Finding your apps…").font(CalmFont.note).foregroundStyle(CalmColor.muted)
                    }
                    .padding(.leading, 2)
                } else if let notice {
                    CalmInlineNotice(notice.message, tone: notice.tone).padding(.leading, 2)
                }
            }
        }
    }

    private func appChip(_ binding: AppStyleBinding, groupStyle: WritingStyle) -> some View {
        var notes: [String] = []
        if binding.style != groupStyle { notes.append("\(binding.style.displayName) style") }
        if !binding.isEnabled { notes.append("Paused") } else if binding.hasCustomRules { notes.append("Customized") }
        return Menu {
            Picker("Style", selection: Binding(
                get: { binding.style },
                set: { style in
                    guard style != binding.style else { return }
                    if binding.hasCustomRules {
                        pendingAppStyle = CalmStylesPendingAppStyle(binding: binding, style: style)
                    } else {
                        appState.calmSetStyle(style, forApp: binding.id)
                    }
                }
            )) {
                ForEach(WritingStyle.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Customize…") { customizing = binding }
            Button(binding.isEnabled ? "Pause" : "Resume") {
                appState.calmUpdateApp(binding.id) { $0.isEnabled.toggle() }
            }
            Divider()
            Button("Remove", role: .destructive) { appState.removeAppStyleBinding(binding) }
        } label: {
            CalmStylesChipLabel(name: binding.displayName, notes: notes, isDimmed: !binding.isEnabled)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(CalmStylesChipStyle())
        .focusEffectDisabled()
        .fixedSize()
        .help("Style, customize, pause or remove \(binding.displayName)")
        .accessibilityLabel(([binding.displayName] + notes).joined(separator: ", "))
    }

    private func websiteChip(_ rule: WebsiteStyleBinding, groupStyle: WritingStyle) -> some View {
        var notes: [String] = []
        if rule.style != groupStyle { notes.append("\(rule.style.displayName) style") }
        if !rule.isEnabled { notes.append("Off") }
        return Menu {
            Picker("Style", selection: Binding(
                get: { rule.style },
                set: { style in appState.calmUpdateWebsite(rule.id) { $0.style = style } }
            )) {
                ForEach(WritingStyle.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Edit…") { editingWebsite = rule }
            Button(rule.isEnabled ? "Turn Off" : "Turn On") {
                appState.calmUpdateWebsite(rule.id) { $0.isEnabled.toggle() }
            }
            Divider()
            Button("Remove", role: .destructive) { appState.removeWebsiteRule(rule) }
        } label: {
            CalmStylesChipLabel(name: rule.displayName, notes: notes, isDimmed: !rule.isEnabled)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(CalmStylesChipStyle())
        .focusEffectDisabled()
        .fixedSize()
        .help("\(rule.hostPattern): style, edit, turn off or remove")
        .accessibilityLabel(([rule.displayName, "website"] + notes).joined(separator: ", "))
    }

    // MARK: Info panel

    private var infoPanel: some View {
        HStack(spacing: 14) {
            CalmIcon(.cleanup, size: 18)
                .foregroundStyle(appState.writingStyleEnabled ? CalmColor.accent : CalmColor.amber)
            Text(appState.writingStyleEnabled
                 ? "Styles set capitals, punctuation and symbols. Smart Cleanup removes filler and rewords tone."
                 : "Styles are off, so every app gets the same text.")
                .font(CalmFont.description)
                .foregroundStyle(CalmColor.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if appState.writingStyleEnabled {
                Button("Smart Cleanup settings") { navigator?.openSettings(.cleanup) }
                    .calmLink(font: CalmFont.sf(13, weight: 600))
            } else {
                Button("Turn on") { appState.writingStyleEnabled = true }
                    .calmLink(font: CalmFont.sf(13, weight: 600))
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .calmPanelBackground()
    }

    // MARK: Actions

    static func nameList(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }

    /// Discovery is a few dozen LaunchServices lookups, run off the main actor.
    private func addSuggestions() async {
        isDiscoveringApps = true
        notice = nil
        defer { isDiscoveringApps = false }
        let added = await appState.addSuggestedWritingStyles()
        notice = added == 0
            ? CalmStylesNotice("Nothing new to add. Every app VocaMac recognizes on this Mac is already listed.", tone: .info)
            : CalmStylesNotice("Added \(added) app\(added == 1 ? "" : "s"). Click an app to change its style.", tone: .success)
    }

    private func exportRules() {
        let panel = NSSavePanel()
        panel.title = "Export App List"
        panel.nameFieldStringValue = "vocamac-writing-styles.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let json = WritingStyleBindingStore(bindings: appState.writingStyleBindings).encodedJSON()
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
            notice = CalmStylesNotice("Exported \(appState.writingStyleBindings.count) app(s).", tone: .success)
        } catch {
            VocaLogger.warning(.appState, "Could not export the app list: \(error.localizedDescription)")
            notice = CalmStylesNotice("Could not write that file: \(error.localizedDescription)", tone: .warning)
        }
    }

    private func importRules() {
        let panel = NSOpenPanel()
        panel.title = "Import App List"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let json = try? String(contentsOf: url, encoding: .utf8) else {
            notice = CalmStylesNotice("Could not read that file.", tone: .warning)
            return
        }
        let imported = WritingStyleBindingStore.decode(json: json).bindings
        guard !imported.isEmpty else {
            notice = CalmStylesNotice("No apps found in that file.", tone: .warning)
            return
        }
        // Imported rules win over existing ones for the same app, the way
        // re-binding does; everything else is left alone.
        var bindings = appState.writingStyleBindings
        for rule in imported {
            bindings.removeAll { $0.id == rule.id }
        }
        appState.writingStyleBindings = bindings + imported
        // Imported rules show where the catalog or their style puts them.
        appState.calmResetStyleGroups(forApps: imported.map(\.id))
        notice = CalmStylesNotice("Imported \(imported.count) app(s).", tone: .success)
    }
}

// MARK: - Page state

/// A one-line result under the chips (added, imported, removed).
struct CalmStylesNotice: Equatable {
    let message: String
    let tone: CalmTone

    init(_ message: String, tone: CalmTone) {
        self.message = message
        self.tone = tone
    }

    static func == (lhs: CalmStylesNotice, rhs: CalmStylesNotice) -> Bool { lhs.message == rhs.message }
}

/// A card pick waiting for “Switch and reset formatting”.
struct CalmStylesPendingGroupStyle: Identifiable {
    let group: CalmStyleGroup
    let style: WritingStyle
    let customizedNames: [String]
    var id: String { "\(group.rawValue).\(style.rawValue)" }
}

/// Picking the chosen card again: apply its style to the apps that have
/// their own, after “Apply to all”.
struct CalmStylesPendingApplyToAll: Identifiable {
    let group: CalmStyleGroup
    let style: WritingStyle
    /// “Discord · Slack” for each app or website that will change.
    let members: [String]
    /// Every app and website in the group.
    let total: Int
    var id: String { "\(group.rawValue).\(style.rawValue).all" }
}

/// One app's new style waiting for “Switch and reset formatting”.
struct CalmStylesPendingAppStyle: Identifiable {
    let binding: AppStyleBinding
    let style: WritingStyle
    var id: String { "\(binding.id).\(style.rawValue)" }
}
