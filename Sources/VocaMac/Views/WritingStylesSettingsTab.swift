// WritingStylesSettingsTab.swift
// VocaMac
//
// Settings page for per-app writing styles: the master toggle, the style for
// everywhere else, the app list, tone, a per-app editor, and a live preview.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct WritingStylesSettingsTab: View {
    @EnvironmentObject var appState: AppState

    @State private var showingAppPicker = false
    @State private var editingBinding: AppStyleBinding?
    @State private var previewSample = WritingStylesSettingsTab.sampleChips[0].text
    @State private var suggestionNotice: String?
    /// True while the LaunchServices sweep behind "Add Suggested Apps" runs.
    @State private var isDiscoveringApps = false

    /// Ready-made phrases that show what each style does in one click.
    static let sampleChips: [(label: String, text: String)] = [
        ("Filename", "open my file dot md and check the config dot json"),
        ("Path", "edit src slash components slash button dot tsx"),
        ("Identifier", "rename it to camel case handle user input"),
        ("Emphasis", "bold ship this today"),
        ("Sentence", "um so this is a normal sentence")
    ]

    var body: some View {
        VocaSettingsPageContent {
            VocaSettingsGroup(
                "Writing Styles",
                subtitle: "Make your dictation fit the app you're typing in."
            ) {
                SettingsToggleRow(
                    title: "Format text for each app",
                    detail: "Code editors get config.json, chat apps get casual sentences, and email gets full sentences with a period.",
                    isOn: $appState.writingStyleEnabled
                )

                Divider()

                StylePickerRow(
                    title: "Everywhere else",
                    detail: "The style for apps you haven't set up below.",
                    selection: $appState.writingStyleDefault
                )
                .disabled(!appState.writingStyleEnabled)
            }

            VocaSettingsGroup(
                "Your Apps",
                subtitle: "Give an app its own style. Apps not listed here use \(appState.writingStyleDefault.displayName)."
            ) {
                if appState.writingStyleBindings.isEmpty {
                    // Rules are never created without being asked for, so this
                    // is what every user sees first. Offer the one-click setup
                    // up front instead of making them find it in a menu.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No apps set up yet.")
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await addSuggestions() }
                        } label: {
                            Label("Set Up My Apps", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isDiscoveringApps)
                        Text("Finds the code editors, terminals, and chat and email apps on this Mac and picks a style for each. You can change any of them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ForEach(appState.writingStyleBindings) { binding in
                        AppStyleBindingRow(
                            binding: binding,
                            onStyleChange: { style in
                                update(binding) { $0.style = style; $0.ruleOverrides = nil }
                            },
                            onEdit: { editingBinding = binding },
                            onToggle: { isEnabled in
                                update(binding) { $0.isEnabled = isEnabled }
                            },
                            onRemove: {
                                appState.writingStyleBindings.removeAll { $0.id == binding.id }
                            }
                        )
                        if binding.id != appState.writingStyleBindings.last?.id {
                            Divider()
                        }
                    }
                }

                Divider()

                // One "Add" menu and one overflow menu instead of six buttons.
                HStack(spacing: 8) {
                    Menu("Add App") {
                        // Menu items can't show tooltips, so the label says it.
                        Button("Suggested Apps You Have Installed") {
                            Task { await addSuggestions() }
                        }
                        .disabled(isDiscoveringApps)
                        Divider()
                        Button("An App That's Open…") { showingAppPicker = true }
                        Button("Choose From Applications Folder…") { chooseInstalledApp() }
                    }
                    .fixedSize()

                    if isDiscoveringApps {
                        ProgressView().controlSize(.small)
                        Text("Finding your apps…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Menu {
                        Button("Export App List…") { exportRules() }
                            .disabled(appState.writingStyleBindings.isEmpty)
                        Button("Import App List…") { importRules() }
                        Divider()
                        Button("Remove All Apps", role: .destructive) {
                            appState.removeAllWritingStyleBindings()
                            suggestionNotice = "Removed every app. All apps now use \(appState.writingStyleDefault.displayName)."
                        }
                        .disabled(appState.writingStyleBindings.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Import, export, or remove your app list")
                }

                if let suggestionNotice {
                    Text(suggestionNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!appState.writingStyleEnabled)
            .opacity(appState.writingStyleEnabled ? 1 : 0.45)

            VocaSettingsGroup(
                "Tone",
                subtitle: "Optional. Rewords English dictation with the model you chose in Smart Cleanup."
            ) {
                SettingsToggleRow(
                    title: "Reword to sound Formal or Casual",
                    detail: "Names, facts, and code stay the same. If a rewrite looks unsafe, your original words are used.",
                    isOn: $appState.writingRewriteEnabled
                )

                // Only worth a row once rewording is on.
                if appState.writingRewriteEnabled {
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Tone everywhere else")
                            Text(appState.writingIntent.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 16)
                        Picker("Tone everywhere else", selection: $appState.writingIntent) {
                            ForEach(WritingIntent.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }
                }

                rewriteAvailabilityNotice
            }
            .disabled(!appState.writingStyleEnabled)
            .opacity(appState.writingStyleEnabled ? 1 : 0.45)

            WebsiteRulesSettings()
                .disabled(!appState.writingStyleEnabled)
                .opacity(appState.writingStyleEnabled ? 1 : 0.45)

            VocaSettingsGroup("Try It", subtitle: "Type what you'd say and see what gets typed.") {
                Picker("Style", selection: previewTarget) {
                    Section("Styles") {
                        ForEach(WritingStyle.allCases) { style in
                            Text(style.displayName).tag(PreviewTarget.preset(style))
                        }
                    }
                    if !appState.writingStyleBindings.isEmpty {
                        Section("Your Apps") {
                            ForEach(appState.writingStyleBindings) { binding in
                                Text("\(binding.displayName) — \(binding.style.displayName)")
                                    .tag(PreviewTarget.binding(binding.id))
                            }
                        }
                    }
                }

                TextField("You say", text: $previewSample, axis: .vertical)
                    .lineLimit(1...3)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Self.sampleChips, id: \.label) { chip in
                            Button(chip.label) { previewSample = chip.text }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }

                LabeledContent("VocaMac types") {
                    Text(previewResult.isEmpty ? "—" : previewResult)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // The full pipeline (cleanup, tone, numbers, emoji) can run the
                // cleanup model, so it stays behind an explicit button.
                WritingProfilePreview(sample: previewSample)
            }
        }
        .toggleStyle(.switch)
        .sheet(isPresented: $showingAppPicker) {
            WritingStyleAppPickerSheet { snapshot, style, intent in
                var bindings = appState.writingStyleBindings
                bindings.removeAll { $0.matches(snapshot) }
                var binding = AppStyleBinding.from(snapshot: snapshot, style: style)
                binding.intent = intent
                bindings.append(binding)
                appState.writingStyleBindings = bindings
                showingAppPicker = false
            } onCancel: {
                showingAppPicker = false
            }
            .environmentObject(appState)
        }
        .sheet(item: $editingBinding) { binding in
            WritingStyleRuleEditor(binding: binding) { updated in
                update(binding) { $0 = updated }
                editingBinding = nil
            } onCancel: {
                editingBinding = nil
            }
            .environmentObject(appState)
        }
    }

    /// Why Formal and Casual can't run yet, if they can't. The working state
    /// needs no caption.
    @ViewBuilder
    private var rewriteAvailabilityNotice: some View {
        if appState.writingRewriteEnabled {
            if !appState.transcriptCleanupEnabled {
                Label("Turn on Smart Cleanup in the Cleanup page to use Formal or Casual.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if !appState.transcriptCleanup.isDownloaded(appState.selectedCleanupModelKind) {
                Label("Finish setting up the Smart Cleanup model in the Cleanup page to use Formal or Casual.", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var previewResult: String {
        appState.writingStylePreview(previewSample, rules: appState.settingsPreviewRules)
    }

    /// What the preview is showing: a bare preset, or one saved app rule
    /// including its overrides.
    private enum PreviewTarget: Hashable {
        case preset(WritingStyle)
        case binding(String)
    }

    private var previewTarget: Binding<PreviewTarget> {
        Binding(
            get: {
                if let id = appState.settingsPreviewBindingID,
                   appState.writingStyleBindings.contains(where: { $0.id == id }) {
                    return .binding(id)
                }
                return .preset(appState.settingsPreviewStyle)
            },
            set: { target in
                switch target {
                case .preset(let style):
                    appState.settingsPreviewBindingID = nil
                    appState.settingsPreviewStyle = style
                case .binding(let id):
                    appState.settingsPreviewBindingID = id
                    if let binding = appState.writingStyleBindings.first(where: { $0.id == id }) {
                        appState.settingsPreviewStyle = binding.style
                    }
                }
            }
        )
    }

    private func update(_ binding: AppStyleBinding, _ mutate: (inout AppStyleBinding) -> Void) {
        var bindings = appState.writingStyleBindings
        guard let index = bindings.firstIndex(where: { $0.id == binding.id }) else { return }
        mutate(&bindings[index])
        appState.writingStyleBindings = bindings
    }

    /// Bind an app that is installed but not running, picked from disk.
    ///
    /// The running-app list cannot offer an editor the user has quit, and
    /// launching an app just to configure it is a silly thing to ask.
    private func chooseInstalledApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Application"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let bundle = Bundle(url: url)
        let name = (bundle?.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let snapshot = RunningAppSnapshot(
            displayName: name,
            bundleIdentifier: bundle?.bundleIdentifier,
            processName: (bundle?.infoDictionary?["CFBundleExecutable"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
        )

        var bindings = appState.writingStyleBindings
        bindings.removeAll { $0.matches(snapshot) }
        let binding = WritingStyleCatalog.suggestion(matching: snapshot)?.binding
            ?? AppStyleBinding.from(snapshot: snapshot, style: .plain)
        bindings.append(binding)
        appState.writingStyleBindings = bindings
        suggestionNotice = "Added \(name)."
        // Open the editor straight away: the panel could not ask which style
        // the app should use, and Plain is the safe fallback for unknown apps.
        editingBinding = binding
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
            suggestionNotice = "Exported \(appState.writingStyleBindings.count) app(s)."
        } catch {
            suggestionNotice = "Could not write that file: \(error.localizedDescription)"
        }
    }

    private func importRules() {
        let panel = NSOpenPanel()
        panel.title = "Import App List"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let json = try? String(contentsOf: url, encoding: .utf8) else {
            suggestionNotice = "Could not read that file."
            return
        }
        let imported = WritingStyleBindingStore.decode(json: json).bindings
        guard !imported.isEmpty else {
            suggestionNotice = "No apps found in that file."
            return
        }

        // Imported rules win over existing ones for the same app, the way
        // re-binding does; everything else is left alone.
        var bindings = appState.writingStyleBindings
        for rule in imported {
            bindings.removeAll { $0.id == rule.id }
        }
        appState.writingStyleBindings = bindings + imported
        suggestionNotice = "Imported \(imported.count) app(s)."
    }

    /// Discovery is a few dozen LaunchServices lookups, so it runs off the main
    /// actor and the button shows a progress view instead of freezing the
    /// Settings window.
    private func addSuggestions() async {
        isDiscoveringApps = true
        suggestionNotice = nil
        defer { isDiscoveringApps = false }

        let added = await appState.addSuggestedWritingStyles()
        suggestionNotice = added == 0
            ? "Nothing new to add. Every app VocaMac recognizes on this Mac is already listed."
            : "Added \(added) app\(added == 1 ? "" : "s"). Change any style from the list."
    }
}

// MARK: - Style picker

/// A style menu with a caption that says what the chosen style is for and
/// shows it working on a real example.
private struct StylePickerRow: View {
    let title: String
    let detail: String
    @Binding var selection: WritingStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Picker(title, selection: $selection) {
                    ForEach(WritingStyle.allCases) { style in
                        Label(style.displayName, systemImage: style.systemImage).tag(style)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
            }
            WritingStyleExample(style: selection)
        }
    }
}

/// "What it's for" plus a before/after line, run through the real engine.
struct WritingStyleExample: View {
    @EnvironmentObject var appState: AppState
    let style: WritingStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(style.shortDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("You say “\(style.exampleSentence)”")
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                Text(appState.writingStylePreview(style.exampleSentence, style: style))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            .font(.caption)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }
}

// MARK: - App row

private struct AppStyleBindingRow: View {
    let binding: AppStyleBinding
    let onStyleChange: (WritingStyle) -> Void
    let onEdit: () -> Void
    let onToggle: (Bool) -> Void
    let onRemove: () -> Void

    /// A style picked for an app with custom rules, held until the user
    /// confirms: each style has its own rules, so switching resets them.
    @State private var pendingStyle: WritingStyle?

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(bundleIdentifier: binding.bundleIdentifier)
                .opacity(binding.isEnabled ? 1 : 0.4)

            VStack(alignment: .leading, spacing: 2) {
                Text(binding.displayName)
                    .foregroundStyle(binding.isEnabled ? .primary : .secondary)
                if let status {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // The common change — which style this app uses — happens right
            // here, without opening a sheet.
            Picker("Style for \(binding.displayName)", selection: Binding(
                get: { binding.style },
                set: { style in
                    guard style != binding.style else { return }
                    if binding.hasCustomRules {
                        pendingStyle = style
                    } else {
                        onStyleChange(style)
                    }
                }
            )) {
                ForEach(WritingStyle.allCases) { style in
                    Label(style.displayName, systemImage: style.systemImage).tag(style)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            .disabled(!binding.isEnabled)

            Menu {
                Button("Customize…", action: onEdit)
                Button(binding.isEnabled ? "Pause" : "Resume") { onToggle(!binding.isEnabled) }
                Divider()
                Button("Remove", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More options for \(binding.displayName)")
        }
        .confirmationDialog(
            "Switch \(binding.displayName) to \(pendingStyle?.displayName ?? "")?",
            isPresented: Binding(
                get: { pendingStyle != nil },
                set: { if !$0 { pendingStyle = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Switch and Reset Formatting", role: .destructive) {
                if let pendingStyle { onStyleChange(pendingStyle) }
                pendingStyle = nil
            }
            Button("Cancel", role: .cancel) { pendingStyle = nil }
        } message: {
            Text("\(binding.displayName) has customized formatting under Advanced. Switching styles replaces it with the new style's formatting. Tone and AI cleanup settings are kept.")
        }
    }

    /// One short line on anything unusual about this app's setup.
    private var status: String? {
        var parts: [String] = []
        if !binding.isEnabled { parts.append("Paused, uses the default style") }
        if binding.cleanup == .raw {
            parts.append("Exactly as transcribed")
        } else if binding.intent != .preserve, binding.style.supportsWording {
            parts.append("\(binding.intent.displayName) tone")
        }
        if binding.hasCustomRules
            || binding.cleanup == .off
            || binding.cleanupLevel != nil
            || binding.cleanupPrompt != nil {
            parts.append("Customized")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The app's own icon, so a row is recognizable before it is read.
private struct AppIconView: View {
    let bundleIdentifier: String?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
    }

    /// Icons are cached: Settings re-renders on every AppState change, and
    /// each lookup is a LaunchServices round trip.
    @MainActor private static var cache: [String: NSImage] = [:]

    private var icon: NSImage? {
        guard let bundleIdentifier else { return nil }
        if let cached = Self.cache[bundleIdentifier] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        Self.cache[bundleIdentifier] = image
        return image
    }
}

// MARK: - App picker

/// Picker sheet listing running apps, with the style to use for them.
struct WritingStyleAppPickerSheet: View {
    let onPick: (RunningAppSnapshot, WritingStyle, WritingIntent) -> Void
    let onCancel: () -> Void

    @EnvironmentObject var appState: AppState
    @State private var apps: [RunningAppSnapshot] = []
    @State private var style: WritingStyle = .plain
    @State private var intent: WritingIntent = .preserve
    @State private var search = ""

    private var filtered: [RunningAppSnapshot] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return apps }
        return apps.filter { $0.displayName.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add an App That's Open")
                .font(.headline)

            Text("1. Choose a style")
                .font(.subheadline.weight(.semibold))

            Picker("Style", selection: $style) {
                ForEach(WritingStyle.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .onChange(of: style) { _, newValue in
                if !newValue.supportsWording {
                    intent = .preserve
                }
            }

            WritingStyleExample(style: style)

            // Tone does nothing unless rewording is on, so don't ask.
            if appState.writingRewriteEnabled {
                Picker("Tone", selection: $intent) {
                    ForEach(WritingIntent.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .disabled(!style.supportsWording)
                .help(style.supportsWording ? intent.description : "Code and Terminal always keep your exact words.")
            }

            Text("2. Click the app")
                .font(.subheadline.weight(.semibold))

            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)

            List(filtered, id: \.self) { snapshot in
                Button {
                    onPick(snapshot, style, intent)
                } label: {
                    HStack(spacing: 8) {
                        AppIconView(bundleIdentifier: snapshot.bundleIdentifier)
                        Text(snapshot.displayName)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 220)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 460, height: 600)
        .onAppear {
            apps = AppIdentityMatching.workspaceRunningApps()
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
    }
}

// MARK: - Rule editor

/// Per-app sheet. The style and tone are all most people change; everything
/// else sits under Advanced. Saving with no rule changes clears the override
/// so the app tracks future preset improvements.
struct WritingStyleRuleEditor: View {
    let binding: AppStyleBinding
    let onSave: (AppStyleBinding) -> Void
    let onCancel: () -> Void

    @State private var style: WritingStyle
    @State private var rules: WritingStyleRules
    @State private var intent: WritingIntent
    @State private var cleanup: WritingCleanupPolicy
    @State private var cleanupLevel: CleanupLevel?
    @State private var cleanupPrompt: String
    @State private var showsAdvanced: Bool

    init(
        binding: AppStyleBinding,
        onSave: @escaping (AppStyleBinding) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.binding = binding
        self.onSave = onSave
        self.onCancel = onCancel
        _style = State(initialValue: binding.style)
        _rules = State(initialValue: binding.effectiveRules)
        _intent = State(initialValue: binding.intent)
        _cleanup = State(initialValue: binding.cleanup)
        _cleanupLevel = State(initialValue: binding.cleanupLevel)
        _cleanupPrompt = State(initialValue: binding.cleanupPrompt ?? "")
        // Open Advanced only when something in it was already changed, so
        // the user can see why this app behaves differently.
        _showsAdvanced = State(initialValue: binding.hasCustomRules
            || binding.cleanup != .inherit
            || binding.cleanupLevel != nil
            || binding.cleanupPrompt != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AppIconView(bundleIdentifier: binding.bundleIdentifier)
                Text(binding.displayName)
                    .font(.headline)
            }
            .padding([.horizontal, .top])

            Form {
                Section {
                    Picker("Style", selection: $style) {
                        ForEach(WritingStyle.allCases) { option in
                            Label(option.displayName, systemImage: option.systemImage).tag(option)
                        }
                    }
                    .onChange(of: style) { _, newValue in
                        rules = newValue.defaultRules
                    }

                    WritingStyleExample(style: style)

                    Picker("Tone", selection: $intent) {
                        ForEach(WritingIntent.allCases) { Text($0.displayName).tag($0) }
                    }
                    .disabled(!style.supportsWording || cleanup != .inherit)
                    Text(toneExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                        advancedOptions
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Reset to Style Defaults") {
                    rules = style.defaultRules
                    cleanup = .inherit
                    cleanupLevel = nil
                    cleanupPrompt = ""
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 500, height: 620)
    }

    @ViewBuilder
    private var advancedOptions: some View {
        Picker("AI cleanup", selection: $cleanup) {
            ForEach(WritingCleanupPolicy.allCases) { Text($0.displayName).tag($0) }
        }
        Picker("Cleanup level", selection: $cleanupLevel) {
            Text("Same as Cleanup page").tag(Optional<CleanupLevel>.none)
            ForEach(CleanupLevel.allCases) { level in
                Text(level.displayName).tag(Optional(level))
            }
        }
        .disabled(cleanup != .inherit)
        Text(cleanupExplanation)
            .font(.caption)
            .foregroundStyle(.secondary)

        Picker("Capital letters", selection: $rules.capitalization) {
            ForEach(CapitalizationPolicy.allCases) { Text($0.displayName).tag($0) }
        }
        Picker("End of sentence", selection: $rules.terminalPunctuation) {
            ForEach(TerminalPunctuationPolicy.allCases) { Text($0.displayName).tag($0) }
        }
        Picker("Space after text", selection: $rules.trailingSpace) {
            ForEach(TrailingSpacePolicy.allCases) { Text($0.displayName).tag($0) }
        }
        Picker("“Um” at the start", selection: $rules.filler) {
            ForEach(FillerPolicy.allCases) { Text($0.displayName).tag($0) }
        }

        Toggle("Spoken filenames", isOn: tierBinding(.tierA))
        Text("“config dot json” becomes config.json. Say “literally” first to keep a word as spoken.")
            .font(.caption)
            .foregroundStyle(.secondary)
        Toggle("Spoken paths and names", isOn: tierBinding(.tierB))
        Text("“src slash utils” becomes src/utils. Best in code editors and terminals.")
            .font(.caption)
            .foregroundStyle(.secondary)
        Toggle("Join multi-word filenames and paths", isOn: $rules.pathStitching)
        Toggle("“camel case” and “snake case”", isOn: $rules.caseCommands)

        Picker("“Bold” and “italic”", selection: $rules.emphasisDialect) {
            ForEach(EmphasisDialect.allCases) { Text($0.displayName).tag($0) }
        }
        Toggle("“Bullet” starts a list item", isOn: $rules.listMarkers)
        Toggle("“New line” and “new paragraph”", isOn: $rules.newlineCommands)

        VStack(alignment: .leading, spacing: 4) {
            Text("Custom cleanup instructions")
            TextEditor(text: $cleanupPrompt)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 70)
            Text("Leave blank to use the instructions from the Cleanup page.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

    private func save() {
        var updated = binding
        updated.style = style
        updated.intent = intent
        updated.cleanup = cleanup
        updated.cleanupLevel = cleanupLevel
        let trimmedPrompt = cleanupPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.cleanupPrompt = trimmedPrompt.isEmpty ? nil : cleanupPrompt
        // Storing nil when nothing was changed lets the binding inherit future
        // improvements to the preset.
        updated.ruleOverrides = (rules == style.defaultRules) ? nil : rules
        onSave(updated)
    }

    private var toneExplanation: String {
        if !style.supportsWording {
            return "Code and Terminal always keep your exact words."
        }
        if cleanup != .inherit {
            return "Tone needs AI cleanup, which is off for this app under Advanced."
        }
        return intent.description + " Needs “Reword to sound Formal or Casual” and Smart Cleanup."
    }

    private var cleanupExplanation: String {
        switch cleanup {
        case .raw:
            return "Types exactly what was heard: no cleanup, snippets, or formatting."
        case .off:
            return "Applies the style's formatting but never runs the AI model."
        case .inherit:
            return style.supportsWording
                ? "Follows the Cleanup page."
                : "Follows the Cleanup page, but only removes filler words. Commands stay exact."
        }
    }
}

/// Explicit inference only: editing a sample never launches model work.
private struct WritingProfilePreview: View {
    @EnvironmentObject var appState: AppState
    let sample: String
    @State private var result: DictationOutputResult?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(running ? "Trying…" : "Try With All My Settings") {
                running = true
                Task { @MainActor in
                    result = await appState.previewWritingProfile(sample)
                    running = false
                }
            }
            .disabled(running || sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let result {
                Text(result.summary).font(.caption).foregroundStyle(.secondary)
                Text("Input: \(result.original)").font(.caption).textSelection(.enabled)
                Text(result.text).textSelection(.enabled)
            }
        }
    }
}
