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
    /// Manual sidebar visibility. Avoids NavigationSplitView relocating system toggles.
    @State private var isSidebarVisible = true

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
        NavigationStack {
            HStack(spacing: 0) {
                if isSidebarVisible {
                    settingsSidebar
                        .frame(width: 220)
                        .transition(.move(edge: .leading).combined(with: .opacity))

                    Divider()
                }

                settingsDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            isSidebarVisible.toggle()
                        }
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .help(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
                    .accessibilityLabel(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
                }
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
                }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    private var settingsSidebar: some View {
        VStack(spacing: 0) {
            SettingsSidebarSearchField(text: $searchText)

            List(selection: $selectedPage) {
                ForEach(visiblePages) { page in
                    Label(page.title, systemImage: page.systemImage)
                        .badge(hasSearchQuery ? (matchCounts[page] ?? 0) : 0)
                        .tag(page)
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
        }
        .background(.background)
    }

    @ViewBuilder
    private var settingsDetail: some View {
        Group {
            switch selectedPage ?? .dictation {
            case .dictation:
                DictationSettingsPage()
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

            TextField("Search", text: $text)
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
        .background(.bar)
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

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(appState.appStatus == .recording
                              ? Color(nsColor: BrandAssets.brandGreen)
                              : Color.accentColor)
                        .frame(width: max(4, geo.size.width * CGFloat(min(max(appState.audioLevel, 0), 1))))
                }
            }
            .frame(height: isActiveSession ? 8 : 5)
            .animation(.easeInOut(duration: 0.15), value: isActiveSession)

            Group {
                if let resultText, !isActiveSession {
                    Text(resultText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !isActiveSession {
                    Text("Results appear here")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minHeight: 28, alignment: .topLeading)

            Button {
                Task { @MainActor in
                    if appState.isRecording || appState.appStatus == .recording {
                        await appState.stopRecordingAndTranscribe(injectResult: false)
                    } else {
                        appState.settingsTestResultText = nil
                        await appState.startRecording()
                    }
                }
            } label: {
                Label(
                    appState.isRecording || appState.appStatus == .recording ? "Stop Dictation" : "Test Dictation",
                    systemImage: appState.isRecording || appState.appStatus == .recording ? "stop.fill" : "mic.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .disabled(appState.isAutoPaused && !appState.isRecording)
        }
        .padding(12)
        .background(.bar)
    }

    private var statusLabel: String {
        if appState.isAutoPaused { return "Auto-paused" }
        switch appState.appStatus {
        case .idle: return "Ready"
        case .recording: return "Recording…"
        case .processing: return "Transcribing…"
        case .error: return appState.errorMessage ?? "Error"
        }
    }

    private var statusColor: Color {
        if appState.isAutoPaused { return .orange }
        switch appState.appStatus {
        case .idle: return .green
        case .recording: return Color(nsColor: BrandAssets.brandGreen)
        case .processing: return .purple
        case .error: return .orange
        }
    }
}

// MARK: - Dictation Settings

struct DictationSettingsPage: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("Activation Mode") {
                Picker("Mode", selection: $appState.activationMode) {
                    ForEach(ActivationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: appState.activationMode) {
                    appState.syncHotKeyConfiguration()
                }

                Text(appState.activationMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Hotkey") {
                HotKeySelectionControl(
                    pickerLabel: "Activation Key",
                    footerText: "Choose a preset or record a key. VocaMac reserves this key while running."
                )

                if appState.activationMode == .doubleTapToggle {
                    HStack {
                        Text("Double-tap speed")
                        Slider(
                            value: $appState.doubleTapThreshold,
                            in: 0.2...0.8,
                            step: 0.05,
                            onEditingChanged: { isEditing in
                                if !isEditing {
                                    appState.syncHotKeyConfiguration()
                                }
                            }
                        )
                        Text("\(String(format: "%.2f", appState.doubleTapThreshold))s")
                            .monospacedDigit()
                            .frame(width: 40)
                    }

                    Text("Shorter = faster double-tap required. Longer = more forgiving.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Output") {
                Toggle("Trailing Space After Dictation", isOn: $appState.appendTrailingSpace)

                Text("Adds a space after each utterance so the next dictation does not stick to the previous one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Auto-Capitalize Sentences", isOn: $appState.autoCapitalize)

                Text("Capitalizes the start of each utterance and letters after . ! or ?. Skips text that is already capitalized.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Application Settings

struct ApplicationSettingsPage: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("Behavior") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { appState.launchAtLogin },
                    set: { appState.setLaunchAtLogin($0) }
                ))

                Toggle("Preserve clipboard after text injection", isOn: $appState.preserveClipboard)

                Text("When enabled, your clipboard contents are restored after injecting text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        }
        .formStyle(.grouped)
    }
}

// MARK: - Speech Model Settings (catalog + language / translation / vocab)

struct SpeechModelSettingsPage: View {
    var body: some View {
        ModelSettingsTab(showsLanguageHints: true)
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
                    .foregroundStyle(.green)
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
        case .granted: return .green
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
                    .foregroundStyle(appState.whisperService.isModelLoaded ? .green : .orange)
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
                Toggle("Pause Dictation for Listed Apps", isOn: $appState.autoPauseEnabled)

                Text("When a listed app is running, VocaMac unloads the speech model and blocks dictation. The model reloads once none of those apps are still running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Group {
                    if appState.autoPauseApps.isEmpty {
                        Text("No apps in the list yet. Use Choose Running App… to add one.")
                            .foregroundStyle(.secondary)
                    } else {
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

                    Button("Choose Running App…") {
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
                Toggle("Unload Model When Idle", isOn: $appState.modelKeepAliveEnabled)

                Text("Unload the model after you stop dictating to free RAM. The next dictation reloads it, which can take a moment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
                if let current = appState.currentModel {
                    GroupBox {
                        HStack {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                                .font(.title3)
                            VStack(alignment: .leading) {
                                Text("Active Model: \(current.size.displayName)")
                                    .font(.callout)
                                    .fontWeight(.semibold)
                                Text("\(current.size.qualityDescription) quality • \(current.size.fileSizeDescription)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(4)
                    }
                }

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

                // Model list, grouped by engine
                ForEach(modelsByEngine, id: \.engine) { group in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 0) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(group.engine.displayName, systemImage: engineIconName(group.engine))
                                    .font(.headline)
                                Text(group.engine.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.bottom, 8)
                            .padding(.horizontal, 4)

                            ForEach(group.models) { model in
                                ModelRow(model: model, appState: appState)

                                if model.id != group.models.last?.id {
                                    Divider()
                                        .padding(.horizontal, 4)
                                }
                            }
                        }
                        .padding(4)
                    }
                }

                // Info text
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("Models are downloaded from HuggingFace and cached locally. Larger models produce better results but are slower and use more memory. Apple Speech assets are managed by macOS and may download language packs on first use.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let recommended = appState.deviceRecommendedModel,
                   let recommendedSize = appState.modelManager.modelSize(from: recommended) {
                    HStack {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Recommended for your device: **\(recommendedSize.displayName)**")
                                .font(.callout)
                            Text("Based on WhisperKit's tuned variants for your chip, not your RAM.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                HStack {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(.secondary)
                    Text("Model storage: \(appState.modelManager.diskUsageDescription())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if showsLanguageHints {
                    languageAndHintsSection
                }
            }
            .padding()
        }
    }

    private var languageAndHintsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Language & Hints", systemImage: "globe")
                    .font(.headline)

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

                if activeEngine?.supportsCustomVocabulary == true {
                    Divider()

                    Text("Custom Vocabulary")
                        .font(.subheadline.weight(.semibold))

                    TextEditor(text: $appState.customVocabulary)
                        .font(.body)
                        .frame(minHeight: 90)
                        .overlay(alignment: .topLeading) {
                            if appState.customVocabulary.isEmpty {
                                Text("kubectl, PostgreSQL, nginx, Grafana")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }

                    let count = WhisperService.vocabularyTerms(from: appState.customVocabulary).count
                    Text(count == 0
                         ? "Add names, jargon, or proper nouns (one per line or comma-separated) that get mis-transcribed."
                         : "\(count) term\(count == 1 ? "" : "s"). Keep the list short; the model can only use the first 50 to 100 words as a hint.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
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
            // Status icon
            Image(systemName: model.statusIconName)
                .foregroundStyle(model.isActive ? .green : .secondary)
                .frame(width: 20)

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
                                .background(.blue.opacity(0.2))
                                .foregroundStyle(.blue)
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
                    Text(model.size.fileSizeDescription)
                    Text("•")
                    Text(model.size.qualityDescription)
                    Text("•")
                    Text("~\(String(format: "%.0f", model.size.ramRequiredGB)) GB RAM")
                    Text("•")
                    Text("Speed: \(String(repeating: "⚡", count: max(1, 6 - model.size.relativeSpeed)))")
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
                    .foregroundStyle(.green)
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
            Section("Recording") {
                Picker("Max recording duration", selection: $appState.maxRecordingDuration) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("60 seconds").tag(60)
                    Text("120 seconds").tag(120)
                    Text("300 seconds (5 min)").tag(300)
                }
                .onChange(of: appState.maxRecordingDuration) {
                    appState.syncHotKeyConfiguration()
                }

                Text("Recording will automatically stop after this duration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Silence Detection") {
                HStack {
                    Text("Sensitivity")
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
                    Slider(
                        value: $appState.silenceDuration,
                        in: 0.5...5.0,
                        step: 0.5
                    )
                    Text("\(String(format: "%.1f", appState.silenceDuration))s")
                        .monospacedDigit()
                        .frame(width: 35)
                }

                Text("In double-tap mode, recording auto-stops after this duration of silence. In push-to-talk mode, you control when to stop by releasing the key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sound Effects") {
                Toggle("Enable sound effects", isOn: $appState.soundEffectsEnabled)

                Text("Play subtle audio cues when recording starts and stops.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Input Device") {
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
                }

                if audioDevices.isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("No audio input devices found")
                            .foregroundStyle(.secondary)
                    }
                } else if selectedAudioDeviceIsUnavailable {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("\(selectedAudioDeviceDisplayName) is unavailable. VocaMac will use System Default until it reconnects.")
                            .foregroundStyle(.secondary)
                    }
                } else if let selectedAudioDevice {
                    HStack {
                        Image(systemName: "mic.circle.fill")
                            .foregroundStyle(.blue)
                        Text("VocaMac will record from \(selectedAudioDevice.name) without changing macOS' system default input.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(systemDefaultInputDescription)
                        .foregroundStyle(.secondary)
                }

                Button("Refresh Devices") {
                    refreshAudioDevices()
                }
                .controlSize(.small)

                Text("Choose System Default to follow macOS, or pin VocaMac to a specific microphone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshAudioDevices()
        }
    }

    private var selectedAudioDevice: AudioDevice? {
        guard !appState.selectedAudioDeviceID.isEmpty else { return nil }
        return audioDevices.first { $0.id == appState.selectedAudioDeviceID }
    }

    private var selectedAudioDeviceIsUnavailable: Bool {
        !appState.selectedAudioDeviceID.isEmpty && selectedAudioDevice == nil
    }

    private var selectedAudioDeviceDisplayName: String {
        appState.selectedAudioDeviceName.isEmpty ? "Selected microphone" : appState.selectedAudioDeviceName
    }

    private var systemDefaultInputDescription: String {
        if let defaultDevice = audioDevices.first(where: { $0.isDefault }) {
            return "VocaMac will follow macOS' system default input: \(defaultDevice.name)."
        }
        return "VocaMac will follow macOS' system default input."
    }

    private func refreshAudioDevices() {
        audioDevices = AudioEngine.availableInputDevices()
        syncSelectedAudioDeviceName()
    }

    private func syncSelectedAudioDeviceName() {
        guard !appState.selectedAudioDeviceID.isEmpty else {
            appState.selectedAudioDeviceName = ""
            return
        }

        if let selectedAudioDevice {
            appState.selectedAudioDeviceName = selectedAudioDevice.name
        }
    }

    private var sensitivityLabel: String {
        if appState.silenceThreshold < 0.01 { return "High" }
        if appState.silenceThreshold < 0.03 { return "Medium" }
        return "Low"
    }
}

// MARK: - About Tab

struct AboutTab: View {
    @EnvironmentObject var appState: AppState
    @State private var showingUpdateSheet = false
    @State private var updateInfoForSheet: UpdateInfo?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                BrandLogoView(size: 64)

                Text("VocaMac")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Your voice, your Mac, your privacy.\nOpen-source dictation powered by AI.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Version \(appVersionDisplay) (\(buildChannelLabel))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Button {
                    Task { @MainActor in
                        await appState.updateChecker.checkForUpdates()
                        switch appState.updateChecker.updateState {
                        case .updateAvailable(let info), .updateAvailableViaHomebrew(let info, _):
                            updateInfoForSheet = info
                            showingUpdateSheet = true
                        default:
                            break
                        }
                    }
                } label: {
                    if case .checking = appState.updateChecker.updateState {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking for Updates...")
                        }
                        .font(.caption)
                    } else {
                        Label("Check for Updates...", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)

                Text(updateStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Divider()
                    .frame(width: 200)

                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        if let capabilities = appState.systemCapabilities {
                            InfoRow2(label: "Device", value: capabilities.processorName)
                            InfoRow2(label: "Architecture", value: capabilities.isAppleSilicon ? "Apple Silicon (ARM64)" : "Intel (x86_64)")
                            InfoRow2(label: "Neural Engine", value: capabilities.supportsMetalAcceleration ? "Available" : "Not Available")
                        }
                        InfoRow2(label: "Engine", value: activeEngineLabel)
                        InfoRow2(label: "Model", value: appState.whisperService.loadedModelName ?? "Not loaded")
                        InfoRow2(label: "Storage", value: appState.modelManager.diskUsageDescription())
                    }
                    .font(.caption)
                    .padding(4)
                }
                .frame(maxWidth: 340)

                Divider()
                    .frame(width: 200)

                HStack(spacing: 16) {
                    Link(destination: URL(string: "https://vocamac.com")!) {
                        Label("Website", systemImage: "globe")
                    }
                    Link(destination: URL(string: "https://github.com/VocaHQ/vocamac")!) {
                        Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Link(destination: URL(string: "https://github.com/argmaxinc/WhisperKit")!) {
                        Label("WhisperKit", systemImage: "waveform")
                    }
                }
                .font(.caption)

                Divider()
                    .frame(width: 200)

                Button {
                    NotificationCenter.default.post(name: .showOnboarding, object: nil)
                } label: {
                    Label("Show Setup Wizard…", systemImage: "wand.and.stars")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .help("Re-run the first-launch setup wizard")

                HStack(spacing: 0) {
                    Text("Made with ❤️ by ")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Link("Jatin Kumar Malik", destination: URL(string: "https://x.com/intent/user?screen_name=jatinkrmalik")!)
                        .font(.caption2)
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .sheet(isPresented: $showingUpdateSheet) {
            if let info = updateInfoForSheet {
                UpdateDetailView(info: info, isPresented: $showingUpdateSheet)
                    .environmentObject(appState)
            }
        }
    }

    private var activeEngineLabel: String {
        if let engine = appState.currentModel?.size.engine {
            return engine.displayName
        }
        if let name = appState.whisperService.loadedModelName,
           let size = appState.modelManager.modelSize(from: name) {
            return size.engine.displayName
        }
        return "-"
    }

    private var appVersionDisplay: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    private var buildChannelLabel: String {
        appVersionDisplay.contains("nightly") ? "Nightly" : "Beta"
    }

    private var updateStatusText: String {
        switch appState.updateChecker.updateState {
        case .upToDate:
            return "You are on the latest version."
        case .updateAvailable(let info):
            return "Update available: \(info.tagName)"
        case .updateAvailableViaHomebrew(_, let install):
            return "Update available via Homebrew. Run: \(install.upgradeCommand)"
        case .error(let message):
            return message
        case .downloading(let progress, _, _, _):
            return "Downloading update... \(Int(progress * 100))%"
        case .verifying:
            return "Verifying download integrity..."
        case .readyToInstall:
            return "Update downloaded. Open the DMG to install."
        case .checking:
            return "Checking for updates..."
        case .idle:
            return ""
        }
    }
}

// MARK: - Debug Tab

struct DebugTab: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var processMonitor = ProcessMonitor()
    @State private var logEntryCount: Int = VocaLogger.logEntryCount

    var body: some View {
        Form {
            if let capabilities = appState.systemCapabilities {
                Section("System Information") {
                    HStack(spacing: 16) {
                        SystemInfoPill(icon: "cpu", label: "CPU", value: capabilities.processorName)
                        SystemInfoPill(icon: "memorychip", label: "RAM", value: "\(capabilities.physicalMemoryGB) GB")
                        SystemInfoPill(
                            icon: "bolt.fill",
                            label: "Metal",
                            value: capabilities.supportsMetalAcceleration ? "Yes" : "No"
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
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

                Text("This is VocaMac's process usage, refreshed every few seconds. It is not a model-only VRAM or ANE reading.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Permissions
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
                    Text("Denied permissions must be enabled manually in System Settings → Privacy & Security.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Re-check Permissions") {
                        appState.checkPermissions()
                    }
                    .controlSize(.small)

                    Spacer()

                    Button(action: resetPermissions) {
                        Label("Reset All Permissions", systemImage: "arrow.counterclockwise")
                            .foregroundStyle(.red)
                    }
                    .controlSize(.small)
                    .help("Reset all TCC permissions for VocaMac. The app will quit and you'll need to re-grant permissions on next launch.")
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.caption)
                    Text("**Upgrading?** Permissions now persist across updates since VocaMac is signed with a Developer ID. If permissions ever appear stuck, use the Reset button above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Debug Logs
            Section("Debug Logs") {
                LabeledContent("Log File") {
                    Text(VocaLogger.logFileURL().lastPathComponent)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Log Entries") {
                    Text("\(logEntryCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button(action: copyDebugLogs) {
                        Label("Copy to Clipboard", systemImage: "doc.on.clipboard")
                    }
                    .help("Copy last 500 lines of logs to clipboard")

                    Spacer()

                    Button(action: exportDebugLogs) {
                        Label("Export to File…", systemImage: "square.and.arrow.up")
                    }
                    .help("Save debug logs to file and reveal in Finder")

                    Spacer()

                    Button(action: {
                        VocaLogger.clearLogs()
                        logEntryCount = VocaLogger.logEntryCount
                    }) {
                        Label("Clear", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .help("Clear all log entries")
                }

                Text("Copy or export recent application logs for troubleshooting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Application
            Section("Application") {
                HStack {
                    Button(action: restartApp) {
                        Label("Restart VocaMac", systemImage: "arrow.trianglehead.clockwise")
                    }
                    .help("Quit and relaunch VocaMac")

                    Spacer()

                    Button(role: .destructive, action: {
                        NSApplication.shared.terminate(nil)
                    }) {
                        Label("Quit VocaMac", systemImage: "power")
                    }
                    .help("Quit VocaMac")
                }

                Text("Restart can help resolve issues with permissions or audio devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

struct InfoRow2: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            Text(value)
                .fontWeight(.medium)
            Spacer()
        }
    }
}
