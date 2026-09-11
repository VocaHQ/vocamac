// WritingStylesSettingsTab.swift
// VocaMac
//
// Settings page for per-app writing styles: the master toggle, the default
// style, the app rule list, a per-app rule editor, and a live preview.

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
            VocaSettingsGroup("Match Each App") {
                SettingsToggleRow(
                    title: "Use app-aware writing",
                    detail: "Format each utterance for the app that receives it—paths in editors, safe shell text in terminals, and natural sentences in chat and email.",
                    isOn: $appState.writingStyleEnabled
                )

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Default format")
                        Text("Used when the receiving app has no rule.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    Picker("Default format", selection: $appState.writingStyleDefault) {
                        ForEach(WritingStyle.allCases) { style in
                            Label(style.displayName, systemImage: style.systemImage).tag(style)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
                .disabled(!appState.writingStyleEnabled)

                Text(appState.writingStyleDefault.shortDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                SettingsToggleRow(
                    title: "Allow Formal and Casual wording",
                    detail: "Optionally rephrase English dictation on this Mac while preserving names, facts, requests, and technical text.",
                    isOn: $appState.writingRewriteEnabled
                )
                .disabled(!appState.writingStyleEnabled)

                HStack {
                    Text("Default wording")
                    Spacer(minLength: 16)
                    Picker("Default wording", selection: $appState.writingIntent) {
                        ForEach(WritingIntent.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
                .disabled(!appState.writingStyleEnabled || !appState.writingRewriteEnabled)

                Text(appState.writingIntent.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                rewriteAvailabilityNotice
            }

            VocaSettingsGroup("App Rules") {
                if appState.writingStyleBindings.isEmpty {
                    // Rules are never created without being asked for, so this
                    // empty state is what every user sees first. It has to say
                    // how to leave it, not just that it is empty.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No app rules yet. Every app uses the default style.")
                            .foregroundStyle(.secondary)
                        Text("Add Suggested Apps sets up the editors, terminals, chat and mail apps you already have installed. Nothing is added until you ask.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(appState.writingStyleBindings) { binding in
                        AppStyleBindingRow(
                            binding: binding,
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

                HStack(spacing: 8) {
                    Button("Choose Running App…") { showingAppPicker = true }
                    Button("Choose Installed App…") { chooseInstalledApp() }
                    Button("Add Suggested Apps…") {
                        Task { await addSuggestions() }
                    }
                    .disabled(isDiscoveringApps)
                }
                if isDiscoveringApps {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking which apps you have installed…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Export Rules…") { exportRules() }
                        .disabled(appState.writingStyleBindings.isEmpty)
                    Button("Import Rules…") { importRules() }
                    Spacer()
                    Button("Remove All", role: .destructive) {
                        appState.removeAllWritingStyleBindings()
                        suggestionNotice = "Removed every app rule. All apps use the default style."
                    }
                    .disabled(appState.writingStyleBindings.isEmpty)
                }

                if let suggestionNotice {
                    Text(suggestionNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!appState.writingStyleEnabled)
            .opacity(appState.writingStyleEnabled ? 1 : 0.45)

            WebsiteRulesSettings()
                .disabled(!appState.writingStyleEnabled)
                .opacity(appState.writingStyleEnabled ? 1 : 0.45)

            VocaSettingsGroup("Preview") {
                Picker("Style", selection: previewTarget) {
                    Section("Presets") {
                        ForEach(WritingStyle.allCases) { style in
                            Text(style.displayName).tag(PreviewTarget.preset(style))
                        }
                    }
                    if !appState.writingStyleBindings.isEmpty {
                        Section("Your App Rules") {
                            ForEach(appState.writingStyleBindings) { binding in
                                Text("\(binding.displayName) — \(binding.style.displayName)")
                                    .tag(PreviewTarget.binding(binding.id))
                            }
                        }
                    }
                }

                TextField("Sample phrase", text: $previewSample, axis: .vertical)
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

                LabeledContent("Formatting preview") {
                    Text(previewResult.isEmpty ? "—" : previewResult)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                WritingProfilePreview(sample: previewSample)

                Text("Test Dictation in the sidebar footer also uses the style selected here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        }
        .sheet(item: $editingBinding) { binding in
            WritingStyleRuleEditor(binding: binding) { updated in
                update(binding) { $0 = updated }
                editingBinding = nil
            } onCancel: {
                editingBinding = nil
            }
        }
    }

    @ViewBuilder
    private var rewriteAvailabilityNotice: some View {
        if appState.writingRewriteEnabled {
            if !appState.transcriptCleanupEnabled {
                Label("Formal and Casual are ready to configure, but need Smart Cleanup enabled before they can run.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if !appState.transcriptCleanup.isDownloaded(appState.selectedCleanupModelKind) {
                Label("Download the selected model in Cleanup before Formal or Casual wording can run.", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Label("Formal and Casual run locally. Unsafe edits automatically fall back to your original wording.", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Code and Terminal keep commands exact: Smart Cleanup may only remove filler there, never reword. Raw transcription bypasses cleanup, snippets, and formatting.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        suggestionNotice = "Added a rule for \(name)."
        // Open the editor straight away: the panel could not ask which style
        // the app should use, and Plain is the safe fallback for unknown apps.
        editingBinding = binding
    }

    private func exportRules() {
        let panel = NSSavePanel()
        panel.title = "Export Writing Style Rules"
        panel.nameFieldStringValue = "vocamac-writing-styles.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let json = WritingStyleBindingStore(bindings: appState.writingStyleBindings).encodedJSON()
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
            suggestionNotice = "Exported \(appState.writingStyleBindings.count) rule(s)."
        } catch {
            suggestionNotice = "Could not write that file: \(error.localizedDescription)"
        }
    }

    private func importRules() {
        let panel = NSOpenPanel()
        panel.title = "Import Writing Style Rules"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let json = try? String(contentsOf: url, encoding: .utf8) else {
            suggestionNotice = "Could not read that file."
            return
        }
        let imported = WritingStyleBindingStore.decode(json: json).bindings
        guard !imported.isEmpty else {
            suggestionNotice = "No readable rules in that file."
            return
        }

        // Imported rules win over existing ones for the same app, the way
        // re-binding does; everything else is left alone.
        var bindings = appState.writingStyleBindings
        for rule in imported {
            bindings.removeAll { $0.id == rule.id }
        }
        appState.writingStyleBindings = bindings + imported
        suggestionNotice = "Imported \(imported.count) rule(s)."
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
            ? "No new suggestions — every supported app you have installed already has a rule."
            : "Added \(added) rule\(added == 1 ? "" : "s") for apps installed on this Mac."
    }
}

// MARK: - Rule row

private struct AppStyleBindingRow: View {
    let binding: AppStyleBinding
    let onEdit: () -> Void
    let onToggle: (Bool) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(binding.displayName)
                if let subtitle = binding.bundleIdentifier ?? binding.processName {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if binding.hasCustomRules {
                Text("Custom")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }

            VStack(alignment: .trailing, spacing: 2) {
                Label(binding.style.displayName, systemImage: binding.style.systemImage)
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                if binding.cleanup == .raw {
                    Text("Raw")
                        .font(.caption2)
                } else if binding.intent != .preserve, binding.style.supportsWording {
                    Text(binding.intent.displayName)
                        .font(.caption2)
                }
            }
            .foregroundStyle(.secondary)

            Toggle("", isOn: Binding(get: { binding.isEnabled }, set: onToggle))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(binding.isEnabled ? "Rule is active" : "Rule is paused")

            Button(action: onEdit) {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("Edit rules for \(binding.displayName)")

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Remove rule")
        }
    }
}

// MARK: - App picker

/// Picker sheet listing running apps, with the style to bind them to.
struct WritingStyleAppPickerSheet: View {
    let onPick: (RunningAppSnapshot, WritingStyle, WritingIntent) -> Void
    let onCancel: () -> Void

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
            Text("Choose Running App")
                .font(.headline)

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

            Text(style.shortDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Wording", selection: $intent) {
                ForEach(WritingIntent.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .disabled(!style.supportsWording)

            Text(style.supportsWording
                 ? intent.description
                 : "Code and Terminal keep your wording. With Smart Cleanup on, the model can only remove filler such as “um”, “like,”, and repeated words; commands and technical text stay exact.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)

            List(filtered, id: \.self) { snapshot in
                Button {
                    onPick(snapshot, style, intent)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.displayName)
                        if let bundle = snapshot.bundleIdentifier {
                            Text(bundle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 240)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 440, height: 540)
        .onAppear {
            apps = AppIdentityMatching.workspaceRunningApps()
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
    }
}

// MARK: - Rule editor

/// Per-app override sheet. Starts from the preset's rules; saving with no
/// changes clears the override so the app tracks future preset improvements.
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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(binding.displayName)
                .font(.headline)
                .padding([.horizontal, .top])

            Form {
                Section("Style") {
                    Picker("Preset", selection: $style) {
                        ForEach(WritingStyle.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .onChange(of: style) { _, newValue in
                        rules = newValue.defaultRules
                    }

                    Text(style.shortDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Wording and Punctuation") {
                    Picker("Wording", selection: $intent) {
                        ForEach(WritingIntent.allCases) { Text($0.displayName).tag($0) }
                    }
                    .disabled(!style.supportsWording || cleanup != .inherit)
                    Picker("Processing", selection: $cleanup) {
                        ForEach(WritingCleanupPolicy.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Cleanup level", selection: $cleanupLevel) {
                        Text("Use global setting").tag(Optional<CleanupLevel>.none)
                        ForEach(CleanupLevel.allCases) { level in
                            Text(level.displayName).tag(Optional(level))
                        }
                    }
                    .disabled(cleanup != .inherit)
                    Text(profileExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Capitalization", selection: $rules.capitalization) {
                        ForEach(CapitalizationPolicy.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Sentence ending", selection: $rules.terminalPunctuation) {
                        ForEach(TerminalPunctuationPolicy.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Trailing space", selection: $rules.trailingSpace) {
                        ForEach(TrailingSpacePolicy.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Leading filler words", selection: $rules.filler) {
                        ForEach(FillerPolicy.allCases) { Text($0.displayName).tag($0) }
                    }
                }

                Section("Custom Cleanup Prompt") {
                    TextEditor(text: $cleanupPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 90)
                    Text("Leave blank to use the global prompt. This prompt applies only when dictating into this app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Code and Paths") {
                    Toggle("Spoken filenames and commands", isOn: tierBinding(.tierA))
                    Text("Turns \"config dot json\" into config.json and honors \"open paren\" / \"close paren\". Safe in prose. Say \"literally\" before a word — \"literally dot json\" — to keep it spoken.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Spoken paths and identifiers", isOn: tierBinding(.tierB))
                    Text("Also joins \"src slash utils\" and \"max underscore retries\". More aggressive — best in editors and terminals.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Multi-word filenames and paths", isOn: $rules.pathStitching)
                    Toggle("Case commands (camel case, snake case)", isOn: $rules.caseCommands)
                }

                Section("Markup") {
                    Picker("Emphasis", selection: $rules.emphasisDialect) {
                        ForEach(EmphasisDialect.allCases) { Text($0.displayName).tag($0) }
                    }
                    Toggle("Bullet lists", isOn: $rules.listMarkers)
                    Toggle("\"New line\" and \"new paragraph\"", isOn: $rules.newlineCommands)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Reset to Preset") { rules = style.defaultRules }
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

    private var profileExplanation: String {
        if !style.supportsWording {
            return "Code and Terminal keep your wording and exact formatting. With Smart Cleanup on, the model only removes filler; it never rewrites a command."
        }
        switch cleanup {
        case .raw:
            return "Raw transcription bypasses cleanup, snippets, and every formatting rule."
        case .off:
            return "Formatting only keeps your wording as spoken and does not use the local model."
        case .inherit:
            return intent.description + " Formal and Casual require the Writing Styles switch and Smart Cleanup model."
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
            Button(running ? "Trying profile…" : "Try full profile") {
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
