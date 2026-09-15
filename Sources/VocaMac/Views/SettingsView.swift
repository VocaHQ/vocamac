// SettingsView.swift
// VocaMac
//
// Settings window for VocaMac configuration.
// Left sidebar topics with live search and a persistent dictation footer.

import SwiftUI
import AppKit

extension Notification.Name {
    static let showOnboarding = Notification.Name("com.vocamac.showOnboarding")
}

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    @State private var selectedPage: SettingsPage? = .dictation
    @State private var searchText = ""
    @State private var pageBeforeSearch: SettingsPage = .dictation
    @AppStorage("settings.lastPage") private var lastPage = SettingsPage.dictation.rawValue
    @AppStorage("settings.sidebarVisible") private var sidebarVisible = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var didRestore = false

    private var matchCounts: [SettingsPage: Int] {
        SettingsSearchIndex.matchCounts(query: searchText)
    }

    private var visiblePages: [SettingsPage] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SettingsPage.allCases }
        let counts = matchCounts
        return SettingsPage.allCases.filter { counts[$0, default: 0] > 0 }
    }

    private var hasSearchQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            settingsSidebar
                .frame(minHeight: 0, maxHeight: .infinity)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                // Title only: the sidebar already says where you are, and a
                // tagline under every page was one more line to read past.
                VocaPageHeader(title: (selectedPage ?? .dictation).title, subtitle: nil)
                settingsDetail
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .background(VocaDesign.canvas)
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: columnVisibility) { _, value in
            sidebarVisible = value != .detailOnly
        }
        .onChange(of: searchText) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                selectedPage = pageBeforeSearch
                return
            }
            if let current = selectedPage, matchCounts[current, default: 0] == 0 {
                selectedPage = SettingsSearchIndex.firstMatchingPage(query: trimmed)
            } else if selectedPage == nil {
                selectedPage = SettingsSearchIndex.firstMatchingPage(query: trimmed)
            }
        }
        .onChange(of: selectedPage) { _, newValue in
            if !hasSearchQuery, let newValue {
                pageBeforeSearch = newValue
                lastPage = newValue.rawValue
            }
        }
        .onAppear {
            if !didRestore {
                selectedPage = SettingsPage(rawValue: lastPage) ?? .dictation
                pageBeforeSearch = selectedPage ?? .dictation
                columnVisibility = sidebarVisible ? .all : .detailOnly
                didRestore = true
            }
            showRequestedPage()
        }
        .onChange(of: appState.requestedSettingsPage) { showRequestedPage() }
        .frame(minWidth: 760, minHeight: 580)
        .tint(VocaDesign.accent)
        .groupBoxStyle(VocaGroupBoxStyle())
    }

    /// Jump to a page another part of the app asked for (e.g. History from
    /// the menu bar), once.
    private func showRequestedPage() {
        guard let page = appState.requestedSettingsPage else { return }
        searchText = ""
        selectedPage = page
        appState.requestedSettingsPage = nil
    }

    private var settingsSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BrandLogoView(size: 26)
                Text("VocaMac").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            SettingsSidebarSearchField(text: $searchText)

            // A real List keeps arrow-key navigation, type-select, the focus
            // ring, and the system's active/inactive selection colours. Rolling
            // the rows by hand as buttons loses all four.
            List(selection: $selectedPage) {
                ForEach(SettingsSection.allCases) { section in
                    let pages = section.pages.filter(visiblePages.contains)
                    if !pages.isEmpty {
                        Section(section.title) {
                            ForEach(pages) { page in
                                Label(page.title, systemImage: page.systemImage)
                                    // Some glyphs here ship a multicolour variant — the
                                    // ladybug renders red and black by default, which made
                                    // Advanced the only coloured row in a monochrome list.
                                    .symbolRenderingMode(.monochrome)
                                    .badge(hasSearchQuery ? (matchCounts[page] ?? 0) : 0)
                                    .tag(page)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .overlay {
                if hasSearchQuery && visiblePages.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            Divider()
            SettingsSidebarFooter()
                .padding(12)
        }
    }

    @ViewBuilder
    private var settingsDetail: some View {
        Group {
            switch selectedPage ?? .dictation {
            case .dictation:
                DictationSettingsPage()
            case .history:
                HistorySettingsPage()
            case .dictionary:
                DictionarySettingsPage()
            case .writingStyles:
                WritingStylesSettingsTab()
            case .snippets:
                SnippetsSettingsTab()
            case .cleanup:
                CleanupSettingsPage()
            case .speechModel:
                SpeechModelSettingsPage()
            case .audio:
                AudioSettingsTab()
            case .performance:
                PerformanceSettingsTab()
            case .application:
                ApplicationSettingsPage()
            case .stats:
                StatsSettingsTab()
            case .advanced:
                DebugTab()
            case .about:
                AboutTab()
            }
        }
    }
}

// MARK: - Sidebar Search (System Settings style)

/// Pill search field pinned to the top of the settings sidebar.
struct SettingsSidebarSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search settings", text: $text)
                .textFieldStyle(.plain)
                .font(.body)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

// MARK: - Sidebar Footer

struct SettingsSidebarFooter: View {
    @EnvironmentObject var appState: AppState

    private var isActiveSession: Bool {
        appState.isRecording
            || appState.appStatus == .recording
            || appState.appStatus == .processing
    }

    private var isPracticeRecording: Bool { appState.isPracticeRecording }
    private var externalRecording: Bool {
        (appState.isRecording || appState.appStatus == .recording) && !appState.isPracticeRecording
    }

    private var resultText: String? {
        let text = appState.settingsTestResultText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusLabel)
                    .font(.caption)
                    .fontWeight(isActiveSession ? .semibold : .regular)
                    .foregroundStyle(isActiveSession ? .primary : .secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if appState.isAutoPaused {
                    Text("Paused")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            if isActiveSession {
                ObservedAudioLevelView(meter: appState.audioMeter, tint: VocaDesign.accent)
                    .frame(height: 5)
            }
            if let resultText, !isActiveSession {
                Text(resultText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

            Button {
                Task { @MainActor in
                    if isPracticeRecording {
                        await appState.stopRecordingAndTranscribe()
                    } else if !externalRecording {
                        appState.settingsTestResultText = nil
                        // TOCTOU re-check after Task hop
                        if (appState.isRecording || appState.appStatus == .recording) && !appState.isPracticeRecording {
                            return
                        }
                        guard appState.appStatus == .idle, !appState.isRecording else { return }
                        await appState.startRecording(injectResult: false)
                    }
                }
            } label: {
                Label(
                    isPracticeRecording ? "Stop Dictation" : "Test Dictation",
                    systemImage: isPracticeRecording ? "stop.fill" : "mic.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .vocaGlassButton()
            .controlSize(.regular)
            .help("Try dictation here. The result stays in this window.")
            .disabled(externalRecording || appState.appStatus == .processing || (appState.isAutoPaused && !appState.isRecording))

            if externalRecording {
                Text("Dictation is active elsewhere. Finish it with your shortcut before testing here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
    }

    private var statusLabel: String {
        if appState.isAutoPaused { return "Auto-paused" }
        switch appState.appStatus {
        case .idle:
            guard appState.whisperService.isModelLoaded else { return "Speech model not loaded" }
            return appState.cleanupReadinessLabel.map { "Dictation ready · \($0)" } ?? "Dictation ready"
        case .recording: return "Recording…"
        case .processing: return "Transcribing…"
        case .error: return appState.errorMessage ?? "Error"
        }
    }

    private var statusColor: Color {
        if appState.isAutoPaused { return .orange }
        switch appState.appStatus {
        case .idle:
            return appState.whisperService.isModelLoaded && appState.cleanupReadinessLabel == nil
                ? VocaDesign.success : .orange
        case .recording: return Color(nsColor: BrandAssets.brandGreen)
        // Matches MenuBarView.statusColor; the same state must not change hue
        // between the menu bar and the settings footer.
        case .processing: return .yellow
        case .error: return .orange
        }
    }
}

// MARK: - Dictation Settings

struct DictationSettingsPage: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VocaSettingsPageContent {
            VocaSettingsGroup("Start Dictating") {
                ActivationModeSelector(selection: $appState.activationMode) {
                    appState.syncHotKeyConfiguration()
                }
                Divider()
                HotKeySelectionControl(
                    pickerLabel: "Shortcut",
                    footerText: "Reserved while VocaMac is running."
                )
                if appState.activationMode == .doubleTapToggle {
                    HStack {
                        Text("Double-tap speed")
                        Slider(value: $appState.doubleTapThreshold, in: 0.2...0.8, step: 0.05,
                               onEditingChanged: { editing in
                            if !editing { appState.syncHotKeyConfiguration() }
                        })
                        Text("\(String(format: "%.2f", appState.doubleTapThreshold))s")
                            .monospacedDigit().frame(width: 44)
                    }
                    .help("A longer interval makes double-tapping more forgiving.")
                }
            }

            // One group for everything that shapes the typed text. Per-app
            // overrides live in Writing Styles.
            VocaSettingsGroup("Your Text") {
                SettingsToggleRow(
                    title: "Add a trailing space",
                    detail: "Keeps dictations from running together.",
                    isOn: $appState.appendTrailingSpace
                )
                Divider()
                SettingsToggleRow(
                    title: "Capitalize sentences",
                    detail: "Starts each sentence with a capital letter.",
                    isOn: $appState.autoCapitalize
                )
                Divider()
                SettingsToggleRow(
                    title: "Write numbers as digits",
                    detail: "“six pm” becomes “6 pm”. English only.",
                    isOn: $appState.numbersAsDigits
                )
                Divider()
                SettingsToggleRow(
                    title: "Spoken emoji",
                    detail: "Say “party emoji” to type 🎉.",
                    isOn: $appState.spokenEmoji
                )
            }

            ShortcutSettingsGroup()
        }
    }
}

/// A label-plus-explanation row with the switch on the trailing edge, used by
/// the hand-built settings pages so their toggle rows stay identical.
struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

// MARK: - Application Settings

struct ApplicationSettingsPage: View {
    @EnvironmentObject var appState: AppState
    @State private var backupNotice: String?

    var body: some View {
        Form {
            Section("Behavior") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { appState.launchAtLogin },
                    set: { appState.setLaunchAtLogin($0) }
                ))

                Toggle("Restore clipboard after typing", isOn: $appState.preserveClipboard)
                    .help("Puts your clipboard back after VocaMac types text.")
            }

            Section("Recording Overlay") {
                Picker("Style", selection: $appState.overlayStyle) {
                    ForEach(OverlayStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: appState.overlayStyle) {
                    appState.showCursorIndicator = appState.overlayStyle != .off
                }

                Text(appState.overlayStyle.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Position", selection: $appState.overlayPosition) {
                    ForEach(OverlayPosition.allCases) { position in
                        Text(position.displayName).tag(position)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(appState.overlayStyle == .off)
            }

            Section("Settings Backup") {
                HStack {
                    Button("Export Settings…", action: exportSettings)
                    Button("Import Settings…", action: importSettings)
                }
                .help("Includes preferences, shortcuts, rules, snippets, and dictionary. Not history, stats, models, cleanup endpoints, or API keys.")
                if let backupNotice {
                    Text(backupNotice).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.title = "Export VocaMac Settings"
        panel.nameFieldStringValue = "vocamac-settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SettingsArchiveService.encode().write(to: url, options: .atomic)
            backupNotice = "Settings exported. Cleanup endpoints and API keys were not included."
        } catch {
            backupNotice = "Could not export settings: \(error.localizedDescription)"
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.title = "Import VocaMac Settings"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let devices = Set(appState.availableInputDevices().map(\.id))
            try SettingsArchiveService.restore(Data(contentsOf: url), isAvailableInputDevice: devices.contains)
            appState.reloadImportedSettings()
            backupNotice = "Settings imported. The existing cleanup endpoint and API key were left unchanged."
        } catch {
            backupNotice = "Could not import settings: \(error.localizedDescription)"
        }
    }
}

// MARK: - Speech Model Settings (catalog + language / translation / vocab)

struct SpeechModelSettingsPage: View {
    var body: some View {
        ModelSettingsTab(showsLanguageHints: true)
    }
}

// MARK: - Snippets Settings

struct SnippetsSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var showingAddSnippet = false

    var body: some View {
        Form {
            Section("Custom Snippets") {
                if appState.snippets.isEmpty {
                    Text("No snippets yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.snippets) { snippet in
                        SnippetRow(snippet: snippet)
                    }
                }

                Button("Add Snippet…") {
                    showingAddSnippet = true
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showingAddSnippet) {
            AddSnippetView(isPresented: $showingAddSnippet)
        }
    }
}

struct SnippetRow: View {
    @EnvironmentObject var appState: AppState
    let snippet: Snippet
    @State private var isEditing = false
    @State private var editedTrigger: String
    @State private var editedExpansion: String

    init(snippet: Snippet) {
        self.snippet = snippet
        _editedTrigger = State(initialValue: snippet.trigger)
        _editedExpansion = State(initialValue: snippet.expansion)
    }

    private var isEditValid: Bool {
        !editedTrigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !editedExpansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Trigger", text: $editedTrigger, prompt: Text("e.g. My Mail"))
                    .textFieldStyle(.roundedBorder)
                TextField("Expansion", text: $editedExpansion, prompt: Text("e.g. me@example.com"))
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Spacer()
                    Button("Cancel") {
                        editedTrigger = snippet.trigger
                        editedExpansion = snippet.expansion
                        isEditing = false
                    }
                    Button("Save") {
                        updateSnippet()
                        isEditing = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isEditValid)
                }
            }
            .padding(.vertical, 4)
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snippet.trigger)
                    Text(snippet.expansion)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    editedTrigger = snippet.trigger
                    editedExpansion = snippet.expansion
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit Snippet")
                .accessibilityLabel("Edit Snippet")

                Button(role: .destructive) {
                    appState.snippets.removeAll { $0.id == snippet.id }
                } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Remove Snippet")
                .accessibilityLabel("Remove Snippet")
            }
        }
    }

    private func updateSnippet() {
        if let index = appState.snippets.firstIndex(where: { $0.id == snippet.id }) {
            // Trim the trigger for matching, but keep the expansion as entered —
            // leading/trailing whitespace can be intentional formatting.
            appState.snippets[index].trigger = editedTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
            appState.snippets[index].expansion = editedExpansion
        }
    }
}

struct AddSnippetView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var trigger = ""
    @State private var expansion = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("Add New Snippet")
                .font(.headline)

            Form {
                TextField("Trigger Phrase", text: $trigger, prompt: Text("e.g. My Mail"))
                TextField("Expansion Text", text: $expansion, prompt: Text("e.g. me@example.com"))
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(height: 120)

            Text("VocaMac will listen for the trigger phrase and replace it with the expansion text.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("Add Snippet") {
                    // Trim the trigger for matching, but keep the expansion as entered —
                    // leading/trailing whitespace can be intentional formatting.
                    let trimmedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
                    let newSnippet = Snippet(trigger: trimmedTrigger, expansion: expansion)
                    appState.snippets.append(newSnippet)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 400)
    }
}

// MARK: - Permission Row

struct PermissionRow: View {
    let name: String
    let icon: String
    let status: PermissionStatus
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .frame(width: 16)
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(name)
            Spacer()
            switch status {
            case .granted:
                Text("Granted")
                    .font(.caption)
                    .foregroundStyle(VocaDesign.success)
            case .notDetermined:
                Button("Grant") { action() }
                    .controlSize(.small)
            case .denied:
                Button("Open Settings") { action() }
                    .controlSize(.small)
            }
        }
    }

    private var statusIcon: String {
        switch status {
        case .granted: return "checkmark.circle.fill"
        case .notDetermined: return "questionmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch status {
        case .granted: return VocaDesign.success
        case .notDetermined: return .orange
        case .denied: return .red
        }
    }
}

// MARK: - Performance Settings

struct PerformanceSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var showingAppPicker = false

    private let idleTimeoutChoices: [(label: String, seconds: Double)] = [
        ("1 minute", 60),
        ("2 minutes", 120),
        ("5 minutes", 300),
        ("10 minutes", 600),
        ("15 minutes", 900),
        ("30 minutes", 1800),
    ]

    var body: some View {
        Form {
            Section("Model Status") {
                HStack {
                    Label(
                        appState.whisperService.isModelLoaded ? "Model loaded" : "Model unloaded",
                        systemImage: appState.whisperService.isModelLoaded ? "checkmark.circle.fill" : "memorychip"
                    )
                    .foregroundStyle(appState.whisperService.isModelLoaded ? VocaDesign.success : .orange)
                    Spacer()
                    if appState.whisperService.isModelLoaded {
                        Text(loadedModelLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if appState.whisperService.isModelLoaded {
                    if let estimate = estimatedModelRAMLabel {
                        LabeledContent("Estimated model RAM", value: estimate)
                    }
                    LabeledContent(
                        "App memory (RSS)",
                        value: String(format: "%.0f MB", ProcessMonitor.currentResidentMemoryMB())
                    )
                } else if let message = appState.modelUnloadStatusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    if let freed = appState.approximateMemoryFreedMB {
                        Text(String(format: "About %.0f MB of process memory was released on unload.", freed))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No speech model is loaded right now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Auto-Pause for Apps") {
                Toggle("Pause dictation while these apps run", isOn: $appState.autoPauseEnabled)
                    .help("Unloads the speech model and blocks dictation while a listed app is running, then reloads it.")

                Group {
                    if !appState.autoPauseApps.isEmpty {
                        ForEach(appState.autoPauseApps) { app in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.displayName)
                                    if let bundle = app.bundleIdentifier {
                                        Text(bundle)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    } else if let process = app.processName {
                                        Text(process)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    appState.autoPauseApps.removeAll { $0.id == app.id }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }

                    Button("Add App…") {
                        showingAppPicker = true
                    }
                }
                .disabled(!appState.autoPauseEnabled)
                .opacity(appState.autoPauseEnabled ? 1 : 0.45)

                if appState.isAutoPaused {
                    Label(
                        appState.autoPauseTriggerDisplayName.map { "Paused while \($0) is running." }
                            ?? "Dictation is currently paused by a listed app.",
                        systemImage: "pause.circle.fill"
                    )
                    .foregroundStyle(.orange)
                    .font(.caption)
                }
            }

            Section("Unload When Idle") {
                Toggle("Unload model when idle", isOn: $appState.modelKeepAliveEnabled)
                    .help("Frees memory after you stop dictating. The next dictation reloads the model, which can take a moment.")

                Picker("Idle timeout", selection: $appState.modelKeepAliveIdleTimeoutSeconds) {
                    ForEach(idleTimeoutChoices, id: \.seconds) { choice in
                        Text(choice.label).tag(choice.seconds)
                    }
                }
                .disabled(!appState.modelKeepAliveEnabled)
                .opacity(appState.modelKeepAliveEnabled ? 1 : 0.45)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showingAppPicker) {
            AutoPauseAppPickerSheet { entry in
                var apps = appState.autoPauseApps
                if !apps.contains(where: { $0.id == entry.id }) {
                    apps.append(entry)
                    appState.autoPauseApps = apps
                }
                showingAppPicker = false
            } onCancel: {
                showingAppPicker = false
            }
        }
    }

    private var loadedModelLabel: String {
        if let model = appState.currentModel {
            return model.size.displayName
        }
        return appState.whisperService.loadedModelName ?? "Ready"
    }

    private var estimatedModelRAMLabel: String? {
        let size = appState.currentModel?.size
            ?? ModelSize(rawValue: appState.selectedModelSize)
        guard let size else { return nil }
        return String(format: "~%.1f GB", size.ramRequiredGB)
    }
}

/// Picker sheet listing currently running apps for the auto-pause list.
struct AutoPauseAppPickerSheet: View {
    let onPick: (AutoPauseAppEntry) -> Void
    let onCancel: () -> Void

    @State private var apps: [RunningAppSnapshot] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose Running App")
                .font(.headline)

            Text("Pick an app. Dictation pauses while that app is running.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List(apps, id: \.self) { snap in
                Button {
                    onPick(AutoPauseAppEntry.from(snapshot: snap))
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snap.displayName)
                        if let bundle = snap.bundleIdentifier {
                            Text(bundle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 280)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 420, height: 420)
        .onAppear {
            apps = AutoPauseMatching.workspaceRunningApps()
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
    }
}

// MARK: - Model Settings

struct ModelSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var languageSearch = ""
    @State private var isLanguageSectionExpanded = false
    @State private var expandedEngines: Set<TranscriptionEngine> = []

    /// Rows that stay visible without expanding: anything on disk, in use,
    /// in flight, or recommended for this Mac.
    private func isProminent(_ model: WhisperModelInfo) -> Bool {
        if model.isDownloaded || model.isActive || model.isLoading || model.downloadProgress != nil {
            return true
        }
        guard model.isSupported, let recommended = appState.deviceRecommendedModel else { return false }
        return appState.modelManager.modelSize(from: recommended) == model.size
    }

    private func expansionBinding(for engine: TranscriptionEngine) -> Binding<Bool> {
        Binding(
            get: { expandedEngines.contains(engine) },
            set: { isExpanded in
                if isExpanded { expandedEngines.insert(engine) } else { expandedEngines.remove(engine) }
            }
        )
    }

    /// When true, show language / translation / vocabulary below the catalog.
    var showsLanguageHints: Bool = false

    init(showsLanguageHints: Bool = false) {
        self.showsLanguageHints = showsLanguageHints
    }

    /// Catalog entries grouped by engine, preserving catalog order within
    /// each group. Engines with no available models are omitted.
    private var modelsByEngine: [(engine: TranscriptionEngine, models: [WhisperModelInfo])] {
        TranscriptionEngine.allCases.compactMap { engine in
            let models = appState.availableModels.filter { $0.size.engine == engine }
            return models.isEmpty ? nil : (engine: engine, models: models)
        }
    }

    private var filteredLanguages: [TranscriptionLanguage] {
        TranscriptionLanguage.filtered(search: languageSearch)
    }

    private var activeEngine: TranscriptionEngine? {
        appState.currentModel?.size.engine
            ?? ModelSize(rawValue: appState.selectedModelSize)?.engine
    }

    private func engineIconName(_ engine: TranscriptionEngine) -> String {
        switch engine {
        case .parakeet:    return "bolt.fill"
        case .whisperKit:  return "globe"
        case .appleSpeech: return "apple.logo"
        case .sherpaOnnx:  return "puzzlepiece.extension"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if appState.appStatus == .error, let errorMessage = appState.errorMessage {
                    GroupBox {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button {
                                appState.errorMessage = nil
                                appState.appStatus = .idle
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Dismiss")
                        }
                        .padding(4)
                    }
                }

                // Model list, grouped by engine. Each engine shows what you
                // have (and what's recommended); the rest of the catalog
                // waits behind one row instead of twenty download buttons.
                ForEach(modelsByEngine, id: \.engine) { group in
                    // Hiding one or two rows behind a disclosure costs more
                    // than it saves, so only collapse a real list.
                    let collapses = group.models.filter { !isProminent($0) }.count >= 3
                    let shown = collapses ? group.models.filter(isProminent) : group.models
                    let more = collapses ? group.models.filter { !isProminent($0) } : []
                    VocaSettingsGroup(
                        group.engine.displayName,
                        systemImage: engineIconName(group.engine),
                        subtitle: group.engine.summary
                    ) {
                        ForEach(shown) { model in
                            ModelRow(model: model, appState: appState)
                            if model.id != shown.last?.id || !more.isEmpty {
                                Divider()
                            }
                        }

                        if !more.isEmpty {
                            DisclosureGroup(isExpanded: expansionBinding(for: group.engine)) {
                                ForEach(more) { model in
                                    ModelRow(model: model, appState: appState)
                                    if model.id != more.last?.id {
                                        Divider()
                                    }
                                }
                            } label: {
                                Text(shown.isEmpty
                                     ? "Show \(more.count) \(more.count == 1 ? "model" : "models")"
                                     : "\(more.count) more \(more.count == 1 ? "model" : "models")")
                            }
                            .disclosureGroupStyle(VocaDisclosureGroupStyle())
                        }
                    }
                }

                Label("Models download from Hugging Face and stay on this Mac · \(appState.modelManager.diskUsageDescription()) used",
                      systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Larger models are more accurate but slower and use more memory. Apple Speech assets are managed by macOS.")

                if showsLanguageHints {
                    languageAndHintsSection
                }
            }
            .padding()
        }
    }

    private var languageAndHintsSection: some View {
        // Collapsed by default: building this section's controls costs about
        // 80ms of the Speech Model page's load, and picking a model is what
        // the page is for. Language is a second, rarer errand.
        VocaDisclosureCard(
            title: "Language & Hints",
            subtitle: "Recognition language, translation, and custom vocabulary.",
            systemImage: "globe",
            isExpanded: $isLanguageSectionExpanded
        ) {
            TextField("Search languages", text: $languageSearch)
                .textFieldStyle(.roundedBorder)

            Picker("Language", selection: $appState.selectedLanguage) {
                ForEach(filteredLanguages) { language in
                    Text(language.code == "auto"
                         ? language.displayName
                         : "\(language.displayName) (\(language.code))")
                        .tag(language.code)
                }
            }

            if !filteredLanguages.contains(where: { $0.code == appState.selectedLanguage }),
               let current = TranscriptionLanguage.catalog.first(where: { $0.code == appState.selectedLanguage }) {
                Text("Current: \(current.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Auto-detect works well for most cases. Set a specific language for better accuracy.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let model = appState.currentModel?.size, model.bindsLanguageAtLoadTime {
                Text("\(model.displayName) applies the language when it loads, so changing it reloads the model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if activeEngine?.supportsTranslation == true {
                Divider()

                Toggle("Enable translation", isOn: $appState.translationEnabled)

                Text(appState.translationEnabled
                     ? "Speech is translated to the selected language (or English if set to Auto-detect)."
                     : "Speech is transcribed as spoken. The language setting is only a recognition hint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Vocabulary")
                    Text(activeEngine?.supportsCustomVocabulary == true
                         ? "Your dictionary spells names your way with every model; this model also uses it as a recognition hint."
                         : "Your dictionary spells names your way with every model.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Open Dictionary") { appState.requestSettingsPage(.dictionary) }
            }
    }
        .onChange(of: appState.selectedLanguage) {
            Task { @MainActor in
                await appState.reloadModelForLanguageChangeIfNeeded()
            }
        }
    }
}

struct SystemInfoPill: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ModelRow: View {
    let model: WhisperModelInfo
    @ObservedObject var appState: AppState
    @State private var showForceDownloadAlert = false
    @State private var showDeleteAlert = false

    /// Apple Speech models are managed by the OS, not stored by the app, so there's nothing to
    /// delete. A model that's mid-load or mid-download is also excluded so its files aren't
    /// removed out from under an in-flight read.
    private var canDelete: Bool {
        model.isDownloaded && !model.isActive && !model.size.isSystemManaged
            && !model.isLoading && model.downloadProgress == nil
    }

    var body: some View {
        HStack {
            // Who made it; the check marks the model in use.
            ModelCreatorMark(creator: model.size.creator, isActive: model.isActive)
                .padding(.trailing, 4)

            // Model info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.size.displayName)
                        .font(.callout)
                        .fontWeight(model.isActive ? .semibold : .regular)

                    if model.isSupported,
                       let recommended = appState.deviceRecommendedModel {
                        if appState.modelManager.modelSize(from: recommended) == model.size {
                            Text("Recommended")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(VocaDesign.accent.opacity(0.12))
                                .foregroundStyle(VocaDesign.accent)
                                .cornerRadius(4)
                        }
                    }

                    if !model.isSupported {
                        Text("Experimental")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.2))
                            .foregroundStyle(.orange)
                            .cornerRadius(4)
                            .help("WhisperKit hasn't verified this model on your chip family. It may fail to load, or it may run slower than tuned models.")
                    }
                }

                HStack(spacing: 4) {
                    Text(model.size.creator.displayName)
                    Text("•")
                    Text(model.size.fileSizeDescription)
                    Text("•")
                    Text(model.size.qualityDescription)
                    Text("•")
                    Text("~\(String(format: "%.1f", model.size.ramRequiredGB)) GB RAM")
                    Text("•")
                    Label("Speed \(max(1, 6 - model.size.relativeSpeed))/5", systemImage: "bolt")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Download progress or loading indicator
            if let progress = model.downloadProgress {
                VStack(spacing: 2) {
                    ProgressView(value: progress)
                        .frame(width: 60)
                        .controlSize(.small)
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if model.isLoading {
                VStack(spacing: 2) {
                    ProgressView()
                        .frame(width: 60)
                        .controlSize(.small)
                    Text(model.loadingStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Action button
            if model.isActive {
                Label("Active", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(VocaDesign.success)
            } else if !model.isSupported {
                if model.isLoading || model.downloadProgress != nil {
                    EmptyView()
                } else if model.isDownloaded {
                    Button("Load Anyway") {
                        showForceDownloadAlert = true
                    }
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                } else {
                    Button("Try Anyway") {
                        showForceDownloadAlert = true
                    }
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                }
            } else if model.isLoading || model.downloadProgress != nil {
                // Show nothing - progress indicator handles the feedback
                EmptyView()
            } else if model.isDownloaded {
                Button("Load") {
                    Task { @MainActor in await appState.loadModel(model.size) }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            } else {
                Button("Download & Load") {
                    Task { @MainActor in
                        await appState.downloadModel(model.size)
                        if appState.availableModels.first(where: { $0.size == model.size })?.isDownloaded == true {
                            await appState.loadModel(model.size)
                        }
                    }
                }
                .controlSize(.small)
            }

            if canDelete {
                Button {
                    showDeleteAlert = true
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Delete downloaded model")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .alert("Use Experimental Model?", isPresented: $showForceDownloadAlert) {
            Button("Cancel", role: .cancel) {}
            Button(model.isDownloaded ? "Load Anyway" : "Download & Load", role: .destructive) {
                Task { @MainActor in
                    if !model.isDownloaded {
                        await appState.downloadModel(model.size)
                    }
                    if model.isDownloaded || appState.availableModels.first(where: { $0.size == model.size })?.isDownloaded == true {
                        await appState.loadModel(model.size)
                    }
                }
            }
        } message: {
            Text("WhisperKit hasn't verified this model on your chip family. It may fail to load, or it may run slower than tuned models.")
        }
        .alert("Delete \(model.size.displayName)?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { @MainActor in await appState.deleteModel(model.size) }
            }
        } message: {
            Text("This removes the downloaded model file (\(model.size.fileSizeDescription)) from disk. You can download it again later.")
        }
    }
}

// MARK: - Audio Settings

struct AudioSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var audioDevices: [AudioDevice] = []

    var body: some View {
        Form {
            inputDeviceSection

            Section("Recording") {
                Picker("Max recording duration", selection: $appState.maxRecordingDuration) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("60 seconds").tag(60)
                    Text("120 seconds").tag(120)
                    Text("300 seconds (5 min)").tag(300)
                    Text("10 minutes").tag(600)
                    Text("20 minutes").tag(1200)
                }
                .onChange(of: appState.maxRecordingDuration) {
                    appState.syncHotKeyConfiguration()
                }

                HStack {
                    Text("Silence sensitivity")
                    Slider(
                        value: $appState.silenceThreshold,
                        in: 0.001...0.05,
                        step: 0.001
                    )
                    Text(sensitivityLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }

                HStack {
                    Text("Auto-stop after silence")
                    Spacer()
                    TextField(
                        "Seconds",
                        value: silenceDurationBinding,
                        format: .number.precision(.fractionLength(0...1))
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 72)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }
                .help("Hands-free and double-tap recordings stop after this much silence (0.5–300 seconds). Push-to-talk stops when you release the key.")
            }

            Section("Sounds") {
                Toggle("Play start and stop sounds", isOn: $appState.soundEffectsEnabled)

                HStack {
                    Picker("Dictation tone", selection: $appState.dictationTone) {
                        ForEach(DictationTone.allCases) { tone in
                            Text(tone.displayName).tag(tone)
                        }
                    }
                    Button {
                        Task {
                            await appState.previewDictationTone()
                        }
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(appState.dictationTone == .off)
                    .help("Preview")
                    .accessibilityLabel("Preview tone")
                }

                Toggle("Mute other audio while dictating", isOn: $appState.duckOtherAudioEnabled)
                    .help("Mutes speakers or headphones while the microphone is open, only when something is playing.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            refreshAudioDevices()
        }
        .onReceive(NotificationCenter.default.publisher(for: .vocaAudioDevicesChanged)) { _ in
            refreshAudioDevices()
        }
    }

    private var inputDeviceSection: some View {
        Section("Microphone") {
            HStack {
                Picker("Microphone", selection: $appState.selectedAudioDeviceID) {
                    Text("System Default").tag("")
                    if selectedAudioDeviceIsUnavailable {
                        Text("\(selectedAudioDeviceDisplayName) (Unavailable)").tag(appState.selectedAudioDeviceID)
                    }
                    ForEach(audioDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .onChange(of: appState.selectedAudioDeviceID) {
                    syncSelectedAudioDeviceName()
                    syncSelectedAudioChannel()
                }
                Button {
                    refreshAudioDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh devices")
                .accessibilityLabel("Refresh devices")
            }
            .help("System Default follows macOS. Picking a microphone never changes macOS's own setting.")

            if activeInputChannelCount > 1 {
                Picker("Input channel", selection: selectedAudioChannelBinding) {
                    ForEach(0..<activeInputChannelCount, id: \.self) { channel in
                        Text("Channel \(channel + 1)").tag(channel)
                    }
                }
                .help("The interface input your microphone is plugged into. VocaMac keeps it fixed while recording.")
            }

            // Only say something when there is a problem to act on.
            if audioDevices.isEmpty {
                Label("No audio input devices found", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if selectedAudioDeviceIsUnavailable {
                Label("\(selectedAudioDeviceDisplayName) is unavailable. Using System Default until it reconnects.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            if let fallbackNotice = appState.inputDeviceFallbackNotice {
                Label(fallbackNotice, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            Toggle("Use an external microphone when the lid is closed", isOn: $appState.externalMicWhenLidClosed)
                .help("While your MacBook is closed, records from an available external input. Your saved choice is not changed.")
        }
    }

    private var selectedAudioDevice: AudioDevice? {
        guard !appState.selectedAudioDeviceID.isEmpty else { return nil }
        return audioDevices.first { $0.id == appState.selectedAudioDeviceID }
    }

    private var activeAudioDevice: AudioDevice? {
        if appState.selectedAudioDeviceID.isEmpty {
            return audioDevices.first(where: { $0.isDefault })
        }
        return selectedAudioDevice
    }

    private var activeInputChannelCount: Int {
        activeAudioDevice?.channelCount ?? 0
    }

    private var selectedAudioDeviceIsUnavailable: Bool {
        !appState.selectedAudioDeviceID.isEmpty && selectedAudioDevice == nil
    }

    private var selectedAudioDeviceDisplayName: String {
        appState.selectedAudioDeviceName.isEmpty ? "Selected microphone" : appState.selectedAudioDeviceName
    }

    private func refreshAudioDevices() {
        audioDevices = AudioEngine.availableInputDevices()
        syncSelectedAudioDeviceName()
        syncSelectedAudioChannel()
    }

    private func syncSelectedAudioDeviceName() {
        guard !appState.selectedAudioDeviceID.isEmpty else {
            appState.selectAudioDevice(nil)
            return
        }

        if let selectedAudioDevice {
            appState.selectAudioDevice(selectedAudioDevice)
        }
    }

    private func syncSelectedAudioChannel() {
        guard let activeAudioDevice else { return }
        appState.syncSelectedAudioChannel(with: activeAudioDevice)
    }

    private var selectedAudioChannelBinding: Binding<Int> {
        Binding(
            get: { appState.selectedAudioChannel },
            set: { channel in
                guard let activeAudioDevice else { return }
                appState.selectAudioChannel(channel, for: activeAudioDevice)
            }
        )
    }

    private var silenceDurationBinding: Binding<Double> {
        Binding(
            get: { appState.silenceDuration },
            set: {
                appState.silenceDuration = SilenceDetectionSettings.clampedDuration($0)
            }
        )
    }

    private var sensitivityLabel: String {
        if appState.silenceThreshold < 0.01 { return "High" }
        if appState.silenceThreshold < 0.03 { return "Medium" }
        return "Low"
    }
}

// MARK: - Debug Tab

struct DebugTab: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var processMonitor = ProcessMonitor(useTimer: false)
    @State private var logEntryCount: Int = VocaLogger.logEntryCount

    var body: some View {
        // Permissions first: they are why most people open this page. The
        // device details that used to lead it are already under About.
        Form {
            Section("Permissions") {
                PermissionRow(
                    name: "Microphone",
                    icon: "mic.fill",
                    status: appState.micPermission,
                    action: { appState.requestMicrophonePermission() }
                )

                PermissionRow(
                    name: "Accessibility",
                    icon: "accessibility",
                    status: appState.accessibilityPermission,
                    action: { appState.requestAccessibilityPermission() }
                )

                PermissionRow(
                    name: "Input Monitoring",
                    icon: "keyboard",
                    status: appState.inputMonitoringPermission,
                    action: { appState.requestInputMonitoringPermission() }
                )

                if appState.micPermission == .denied || appState.accessibilityPermission == .denied || appState.inputMonitoringPermission == .denied {
                    Text("Turn denied permissions on in System Settings → Privacy & Security.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Re-check") {
                        appState.checkPermissions()
                    }
                    Button("Restart VocaMac", action: restartApp)
                        .help("Quit and relaunch. Can fix stuck permissions or audio devices.")

                    Spacer()

                    Button("Reset All…", role: .destructive, action: resetPermissions)
                        .help("Clear every permission grant for VocaMac. The app quits and asks again on next launch.")
                }
                .controlSize(.small)
            }

            Section("Debug Logs") {
                LabeledContent("Log entries") {
                    Text("\(logEntryCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .help(VocaLogger.logFileURL().lastPathComponent)

                HStack {
                    Button("Copy", action: copyDebugLogs)
                        .help("Copy the last 500 lines")
                    Button("Export…", action: exportDebugLogs)
                        .help("Save logs to a file and reveal it in Finder")
                    Spacer()
                    Button("Clear", role: .destructive) {
                        VocaLogger.clearLogs()
                        logEntryCount = VocaLogger.logEntryCount
                    }
                }
                .controlSize(.small)
            }

            Section("Resource Usage") {
                HStack(spacing: 12) {
                    SystemInfoPill(
                        icon: "cpu",
                        label: "App CPU",
                        value: String(format: "%.1f%%", processMonitor.cpuUsage)
                    )
                    SystemInfoPill(
                        icon: "memorychip",
                        label: "Memory",
                        value: processMonitor.memoryMB >= 1024
                            ? String(format: "%.1f GB", processMonitor.memoryMB / 1024)
                            : String(format: "%.0f MB", processMonitor.memoryMB)
                    )
                    SystemInfoPill(
                        icon: "chart.line.uptrend.xyaxis",
                        label: "Peak",
                        value: processMonitor.memoryPeakMB >= 1024
                            ? String(format: "%.1f GB", processMonitor.memoryPeakMB / 1024)
                            : String(format: "%.0f MB", processMonitor.memoryPeakMB)
                    )
                    SystemInfoPill(
                        icon: "arrow.triangle.branch",
                        label: "Threads",
                        value: "\(processMonitor.threadCount)"
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .help("VocaMac's whole process, refreshed every few seconds. Not a model-only VRAM or ANE reading.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { processMonitor.start() }
        .onDisappear { processMonitor.stop() }
    }

    // MARK: - Actions

    private func resetPermissions() {
        let alert = NSAlert()
        alert.messageText = "Reset All Permissions?"
        alert.informativeText = "This will clear all permission grants (Microphone, Accessibility, Input Monitoring) for VocaMac. The app will quit and you'll need to re-grant permissions on next launch.\n\nThis is useful when permissions appear stuck or aren't being recognized after an update."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset & Quit")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Run tccutil to reset all TCC permissions for this app
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = ["reset", "All", "com.vocamac.app"]
            try? task.run()
            task.waitUntilExit()

            VocaLogger.info(.general, "TCC permissions reset via tccutil")

            // Quit the app so permissions take effect on next launch
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func restartApp() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundlePath, "--args", "--restarted"]
        try? task.run()

        // Give the new instance a moment to start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Debug Log Actions

    private func copyDebugLogs() {
        let logs = VocaLogger.exportLogs(lastLines: 500)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(logs, forType: .string)
    }

    private func exportDebugLogs() {
        let logs = VocaLogger.exportLogs(lastLines: 1000)

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "VocaMac-Debug-\(ISO8601DateFormatter().string(from: Date()).prefix(19)).log"
        savePanel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        savePanel.begin { response in
            if response == .OK, let fileURL = savePanel.url {
                do {
                    try logs.write(to: fileURL, atomically: true, encoding: .utf8)
                    NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: fileURL.deletingLastPathComponent().path)
                } catch {
                    VocaLogger.error(.general, "Failed to export logs: \(error)")
                }
            }
        }
    }
}
