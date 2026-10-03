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
    @EnvironmentObject var settingsWindowManager: SettingsWindowManager

    @State private var selectedPage: SettingsPage? = .dictation
    @State private var searchText = ""
    @State private var selectedSearchEntryID: String?
    @State private var pageBeforeSearch: SettingsPage = .dictation
    @AppStorage("settings.lastPage") private var lastPage = SettingsPage.dictation.rawValue
    @AppStorage("settings.sidebarVisible") private var sidebarVisible = true
    @State private var didRestore = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasSearchQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        // A paper sidebar beside a page that opens on a full-bleed scene,
        // both running up under the transparent title bar like onboarding.
        HStack(spacing: 0) {
            if sidebarVisible {
                settingsSidebar
                    .frame(width: 236)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            settingsPage
        }
        .ignoresSafeArea()
        .onChange(of: searchText) { _, newValue in
            selectedSearchEntryID = nil
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                selectedPage = pageBeforeSearch
            }
        }
        .onChange(of: selectedSearchEntryID) { _, id in
            guard let id, let entry = SettingsSearchIndex.entries.first(where: { $0.id == id }) else { return }
            selectedPage = entry.page
            // Following a result is a move, not a peek: clearing the search
            // afterwards must not send the reader back where they started.
            pageBeforeSearch = entry.page
            lastPage = entry.page.rawValue
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
                didRestore = true
            }
            showRequestedPage()
            applyWindowRequestedPage()
        }
        .onChange(of: appState.requestedSettingsPage) { showRequestedPage() }
        .onChange(of: settingsWindowManager.requestedPage) { _, page in
            guard page != nil else { return }
            applyWindowRequestedPage()
        }
        .frame(minWidth: 760, minHeight: 580)
        .tint(VocaDesign.accentSolid)
        .groupBoxStyle(VocaGroupBoxStyle())
    }

    /// Jump to a page another part of the app asked for (e.g. History from
    /// the menu bar), once.
    private func showRequestedPage() {
        guard let page = appState.requestedSettingsPage else { return }
        // Clear search only after remembering the destination. An empty query
        // restores `pageBeforeSearch`, which would otherwise undo this jump.
        pageBeforeSearch = page
        searchText = ""
        selectedPage = page
        appState.requestedSettingsPage = nil
    }

    /// Honor a page recorded on the window manager (Pair phone, first open).
    private func applyWindowRequestedPage() {
        guard let page = settingsWindowManager.consumeRequestedPage() else { return }
        pageBeforeSearch = page
        searchText = ""
        selectedPage = page
    }

    private var settingsPage: some View {
        VStack(spacing: 0) {
            // Title only: the sidebar already says where you are, and a
            // tagline under every page was one more line to read past.
            // The scene is the group's time of day.
            let page = selectedPage ?? .dictation
            SettingsSceneHeader(
                title: page.title,
                mood: SettingsSection.containing(page).mood,
                leadingInset: sidebarVisible ? 18 : 84,
                isSidebarVisible: sidebarVisible
            ) {
                withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9)) { sidebarVisible.toggle() }
            }
            if let entry = SettingsSearchIndex.entries.first(where: { $0.id == selectedSearchEntryID }),
               let hint = entry.navigationHint {
                Label(hint, systemImage: "arrow.turn.down.right")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.top, 12)
            }
            ScrollViewReader { proxy in
                settingsDetail
                    .environment(\.settingsSearchTarget, selectedSearchEntryID)
                    // Paper outline buttons wherever a page didn't choose a
                    // style, in place of the grey system bezel.
                    .buttonStyle(VocaOutlineButtonStyle())
                    // Grouped forms draw their own gray backdrop; let the
                    // paper canvas show through on every page.
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                    .task(id: selectedSearchEntryID) {
                        guard let id = selectedSearchEntryID else { return }
                        // Give a newly selected page and any revealed disclosure
                        // one layout pass before scrolling to its control.
                        do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                        guard !Task.isCancelled else { return }
                        proxy.scrollTo(id, anchor: .center)
                    }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .vocaPaperBackground()
        .overlay(alignment: .bottom) { UndoToastView(undoCenter: appState.undoCenter) }
    }

    private var settingsSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VocaMarkView(size: 26)
                Text("VocaMac").font(VocaDesign.display(20))
                Spacer()
            }
            .padding(.horizontal, 18)
            // Clear of the window controls above.
            .padding(.top, 46)
            .padding(.bottom, 14)
            SettingsSidebarSearchField(text: $searchText)
                .onSubmit {
                    selectedSearchEntryID = SettingsSearchResults.groups(for: searchText).first?.entries.first?.id
                }
                .padding(.horizontal, 12)

            if hasSearchQuery {
                SettingsSearchResults(query: searchText, selection: $selectedSearchEntryID)
            } else {
                SettingsSidebarList(selection: $selectedPage)
            }
            Rectangle().fill(VocaDesign.line).frame(height: 1)
            SettingsSidebarFooter()
                .padding(12)
        }
        .background {
            ZStack {
                VocaDesign.sidebar
                PaperGrainOverlay()
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(VocaDesign.line).frame(width: 1)
        }
    }

    @ViewBuilder
    private var settingsDetail: some View {
        Group {
            switch selectedPage ?? .dictation {
            case .dictation:
                DictationSettingsPage()
            case .formatting:
                FormattingSettingsPage()
            case .language:
                LanguageSettingsPage()
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
            case .commandMode:
                CommandModeSettingsPage()
            case .speechModel:
                SpeechModelSettingsPage()
            case .audio:
                AudioSettingsTab()
            case .performance:
                PerformanceSettingsTab()
            case .application:
                ApplicationSettingsPage()
            case .stats:
                StatsSettingsTab().settingsTarget("stats")
            case .advanced:
                PermissionsLogsTab()
            case .gateway:
                GatewaySettingsTab()
            case .about:
                AboutTab()
            }
        }
    }
}

// MARK: - Sidebar Search (System Settings style)

/// The settings that match a search, under the page each lives on. Picking
/// one opens its page and scrolls to the control.
struct SettingsSearchResults: View {
    let query: String
    @Binding var selection: String?

    /// Matches grouped by page, pages in sidebar order.
    static func groups(for query: String) -> [(page: SettingsPage, entries: [SettingsSearchEntry])] {
        let matches = SettingsSearchIndex.matches(query: query)
        return SettingsSection.allCases.flatMap(\.pages).compactMap { page in
            let entries = matches.filter { $0.page == page }
            return entries.isEmpty ? nil : (page, entries)
        }
    }

    var body: some View {
        let groups = Self.groups(for: query)
        List(selection: $selection) {
            ForEach(groups, id: \.page) { group in
                Section {
                    ForEach(group.entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                            if let subtitle = entry.subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 2)
                        .tag(entry.id)
                        .accessibilityLabel("\(entry.title), \(group.page.title)")
                    }
                } header: {
                    Label(group.page.title, systemImage: group.page.systemImage)
                        .symbolRenderingMode(.monochrome)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .overlay {
            if groups.isEmpty { ContentUnavailableView.search(text: query) }
        }
    }
}

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
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(VocaDesign.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(VocaDesign.line)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

// MARK: - Sidebar Footer

struct SettingsSidebarFooter: View {
    @EnvironmentObject var appState: AppState
    @State private var isResultExpanded = false
    @State private var isResultTruncated = false

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
                        .foregroundStyle(VocaDesign.warning)
                }
            }

            if isActiveSession {
                ObservedAudioLevelView(meter: appState.audioMeter, tint: VocaDesign.accent)
                    .frame(height: 5)
            }
            if needsModel {
                Button("Choose a Speech Model…") {
                    appState.requestSettingsPage(.speechModel)
                }
                .buttonStyle(.vocaLink)
                .font(.caption)
            }
            if let resultText, !isActiveSession {
                // A test dictation is often longer than three sidebar lines. Ask
                // the layout whether it was cut off: a character count cannot
                // tell, since the sidebar's width and the words vary.
                TruncationAwareText(
                    text: resultText, lineLimit: isResultExpanded ? nil : 3, isTruncated: $isResultTruncated
                )
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                // A new result starts collapsed again.
                Color.clear.frame(height: 0)
                    .onChange(of: resultText) { isResultExpanded = false }
                if isResultExpanded || isResultTruncated {
                    Button(isResultExpanded ? "Show Less" : "Show More") {
                        isResultExpanded.toggle()
                    }
                    .buttonStyle(.vocaLink)
                    .font(.caption)
                }
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
            .buttonStyle(VocaPrimaryButtonStyle())
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

    private var isLoadingModel: Bool {
        appState.availableModels.contains { $0.isLoading || $0.downloadProgress != nil }
    }

    /// The chosen model is not on this Mac. One that is only unloaded (idle
    /// timeout, auto-pause) reloads on the next dictation, so it is not missing.
    private var needsModel: Bool { appState.needsSpeechModel }

    private var statusLabel: String {
        if appState.isAutoPaused { return "Auto-paused" }
        switch appState.appStatus {
        case .idle:
            guard appState.isDictationReady else { return appState.dictationReadinessTitle }
            return appState.cleanupReadinessLabel.map { "Dictation ready · \($0)" } ?? "Dictation ready"
        case .recording: return "Recording…"
        case .processing: return "Transcribing…"
        case .error: return appState.errorMessage ?? "Error"
        }
    }

    private var statusColor: Color {
        if appState.isAutoPaused { return VocaDesign.warning }
        switch appState.appStatus {
        case .idle:
            return appState.isDictationReady && appState.cleanupReadinessLabel == nil
                ? VocaDesign.success : VocaDesign.warning
        case .recording: return VocaDesign.clay
        // Matches MenuBarView.statusColor; the same state must not change hue
        // between the menu bar and the settings footer.
        case .processing: return VocaDesign.busy
        case .error: return VocaDesign.warning
        }
    }
}

/// Caption text with a line limit that reports whether the limit cut it off.
///
/// The text is measured with AppKit at the width it was given, rather than
/// guessed from its length: the sidebar's width and the words both vary, so a
/// character count cannot say whether the third line ran out.
struct TruncationAwareText: View {
    let text: String
    let lineLimit: Int?
    @Binding var isTruncated: Bool

    var textStyle: NSFont.TextStyle = .caption1
    /// Set the text in the serif, as transcripts are elsewhere.
    var serif = false
    private var font: NSFont {
        let base = NSFont.preferredFont(forTextStyle: textStyle)
        guard serif, let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }

    var body: some View {
        Text(text)
            .font(Font(font))
            .lineLimit(lineLimit)
            // Without this a tight parent squeezes the text below its line
            // limit, leaving one ellipsized line under a "Show More" button.
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { measure(width: proxy.size.width) }
                        .onChange(of: proxy.size.width) { _, width in measure(width: width) }
                        .onChange(of: text) { measure(width: proxy.size.width) }
                }
            )
    }

    private func measure(width: CGFloat) {
        // Expanded text is never cut; keep the last verdict so "Show Less" stays.
        guard let lineLimit, width > 0 else { return }
        let needed = height(of: text, width: width)
        let allowed = lineHeight * CGFloat(lineLimit)
        let truncated = needed > allowed + 1
        if truncated != isTruncated { isTruncated = truncated }
    }

    private var lineHeight: CGFloat {
        NSLayoutManager().defaultLineHeight(for: font)
    }

    private func height(of text: String, width: CGFloat) -> CGFloat {
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return ceil(rect.height)
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
                .settingsTarget("activation-mode")
                Divider()
                HotKeySelectionControl(
                    pickerLabel: "Shortcut",
                    footerText: "Reserved while VocaMac is running."
                )
                .settingsTarget("hotkey")
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

            ShortcutSettingsGroup()

            // Here rather than under Cleanup: it speeds up transcription with
            // Smart Cleanup off too.
            VocaSettingsGroup("Speed") {
                SettingsToggleRow(
                    title: "Process while speaking",
                    detail: "Transcribes each sentence as you finish it, so long dictations paste sooner.",
                    isOn: $appState.processWhileSpeaking
                )
                .settingsTarget("process-while-speaking")
                .help("Cleans each sentence up too when Smart Cleanup is on. Your Mac works while you talk, "
                    + "which uses more battery, and that work is wasted if you cancel. Not used for dictations "
                    + "started in Low Power Mode or while your Mac runs hot. Command Mode and previews are unaffected.")
                Text("Uses more battery while you talk. Skipped in Low Power Mode and when your Mac runs hot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Formatting Settings

/// Rules that shape the typed text everywhere. Per-app overrides live in
/// Writing Styles.
struct FormattingSettingsPage: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VocaSettingsPageContent {
            VocaSettingsGroup("Typed Text") {
                SettingsToggleRow(
                    title: "Add a trailing space",
                    detail: "Keeps dictations from running together.",
                    isOn: $appState.appendTrailingSpace
                )
                .settingsTarget("trailing-space")
                Divider()
                SettingsToggleRow(
                    title: "Capitalize sentences",
                    detail: "Starts each sentence with a capital letter.",
                    isOn: $appState.autoCapitalize
                )
                .settingsTarget("auto-capitalize")
                Divider()
                SettingsToggleRow(
                    title: "Write numbers as digits",
                    detail: "“six pm” becomes “6 pm”. English only.",
                    isOn: $appState.numbersAsDigits
                )
                .settingsTarget("numbers-as-digits")
                Divider()
                SettingsToggleRow(
                    title: "Use symbols and ordinals",
                    detail: appState.numbersAsDigits
                        ? "“fifty percent” becomes “50%”, “five dollars” “$5”, and “June twenty second” “June 22”."
                        : "Turn on “Write numbers as digits” to use this.",
                    isOn: $appState.numberSymbols
                )
                .settingsTarget("number-symbols")
                .disabled(!appState.numbersAsDigits)
                Divider()
                SettingsToggleRow(
                    title: "Spoken emoji",
                    detail: "Say “party emoji” to type 🎉.",
                    isOn: $appState.spokenEmoji
                )
                .settingsTarget("spoken-emoji")
            }
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

/// A label-plus-explanation row with any control on the trailing edge, the
/// same shape as `SettingsToggleRow`.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            control
        }
    }
}

// MARK: - Application Settings

struct ApplicationSettingsPage: View {
    @EnvironmentObject var appState: AppState
    @State private var backupNotice: String?

    var body: some View {
        VocaSettingsPageContent {
            VocaSettingsGroup("Behavior") {
                SettingsToggleRow(
                    title: "Launch at Login",
                    detail: "Opens VocaMac in the menu bar when you sign in.",
                    isOn: Binding(
                        get: { appState.launchAtLogin },
                        set: { appState.setLaunchAtLogin($0) }
                    )
                )
                .settingsTarget("launch-at-login")
                Divider()
                SettingsToggleRow(
                    title: "Restore clipboard after typing",
                    detail: "Puts your clipboard back after VocaMac types text.",
                    isOn: $appState.preserveClipboard
                )
                .settingsTarget("clipboard")
            }

            VocaSettingsGroup(
                "Recording Overlay",
                subtitle: "What appears on screen while you dictate."
            ) {
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
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Picker("Position", selection: $appState.overlayPosition) {
                    ForEach(OverlayPosition.allCases) { position in
                        Text(position.displayName).tag(position)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(appState.overlayStyle == .off)

                if appState.overlayStyle == .off {
                    Text("Choose a style above to place the overlay.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    appState.overlayPreview.start(style: appState.overlayStyle, position: appState.overlayPosition)
                } label: {
                    Label("Preview Overlay", systemImage: "play.circle")
                }
                .disabled(appState.overlayStyle == .off || appState.appStatus != .idle)
                .help("Shows the overlay for a few seconds with sample words.")
            }
            .settingsTarget("cursor-overlay")

            VocaSettingsGroup("Settings Backup") {
                HStack {
                    Button("Export Settings…", action: exportSettings)
                    Button("Import Settings…", action: importSettings)
                }
                .help("Includes preferences, shortcuts, rules, snippets, and dictionary. Not history, stats, models, cleanup endpoints, custom endpoint settings, or API keys.")
                Text("Includes preferences, shortcuts, rules, snippets, and dictionary. Not history, stats, models, cleanup endpoints, custom endpoint settings, or API keys.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let backupNotice {
                    Text(backupNotice).font(.caption).foregroundStyle(.secondary)
                }
            }
            .settingsTarget("settings-backup")
        }
        .onDisappear { appState.overlayPreview.stop() }
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.title = "Export VocaMac Settings"
        panel.nameFieldStringValue = "vocamac-settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SettingsArchiveService.encode().write(to: url, options: .atomic)
            backupNotice = "Settings exported. Cleanup endpoints, custom endpoint settings, and API keys were not included."
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
            backupNotice = "Settings imported. The existing cleanup endpoint and API key were left unchanged. Custom Endpoint was not selected from the file."
        } catch {
            backupNotice = "Could not import settings: \(error.localizedDescription)"
        }
    }
}

// MARK: - Speech Model Settings (catalog + language / translation / vocab)

struct SpeechModelSettingsPage: View {
    var body: some View {
        ModelSettingsTab()
    }
}

// MARK: - Snippets Settings

struct SnippetsSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var showingAddSnippet = false
    @State private var query = ""

    private var filteredSnippets: [Snippet] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return appState.snippets }
        return appState.snippets.filter {
            $0.trigger.localizedCaseInsensitiveContains(trimmed)
                || $0.expansion.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VocaSettingsPageContent {
            VocaSettingsGroup(
                "Custom Snippets",
                subtitle: "Say a short phrase, get the full text."
            ) {
                if appState.snippets.isEmpty {
                    VocaEmptyState(
                        title: "No snippets yet",
                        message: "Save an email address, a sign-off or a link, and say its trigger phrase to type it.",
                        systemImage: "text.quote",
                        actionTitle: "Add Snippet…"
                    ) { showingAddSnippet = true }
                } else {
                    if appState.snippets.count > 5 {
                        TextField("Search snippets", text: $query)
                            .textFieldStyle(.voca)
                    }
                    ForEach(filteredSnippets) { snippet in
                        SnippetRow(snippet: snippet)
                        if snippet.id != filteredSnippets.last?.id { Divider() }
                    }
                    if filteredSnippets.isEmpty {
                        Text("No snippets match “\(query)”.")
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    Button("Add Snippet…") { showingAddSnippet = true }
                }
            }
            .settingsTarget("snippets")
        }
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
                    .textFieldStyle(.voca)
                TextField("Expansion", text: $editedExpansion, prompt: Text("e.g. me@example.com"))
                    .textFieldStyle(.voca)

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
                    .buttonStyle(VocaPrimaryButtonStyle())
                    .disabled(!isEditValid)
                }
            }
            .padding(.vertical, 4)
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snippet.trigger)
                    Text(snippet.expansion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    appState.removeSnippet(snippet)
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
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

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
                .buttonStyle(VocaPrimaryButtonStyle())
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
        case .notDetermined: return VocaDesign.warning
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
        VocaSettingsPageContent {
            VocaSettingsGroup("Speech Model") {
                HStack(spacing: 10) {
                    Image(systemName: isLoaded ? "checkmark.circle.fill" : "moon.zzz")
                        .font(.system(size: 18))
                        .foregroundStyle(isLoaded ? VocaDesign.success : .secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isLoaded ? (appState.loadedModelDisplayName ?? "Model loaded") : "Not loaded")
                            .font(.headline)
                        Text(statusDetail)
                            .font(.caption)
                            .foregroundStyle(statusIsWarning ? VocaDesign.warning : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }

                if isLoaded {
                    Divider()
                    HStack(spacing: 12) {
                        if let estimate = estimatedModelRAMLabel {
                            MemoryFigure(title: "Model needs about", value: estimate)
                        }
                        MemoryFigure(
                            title: "VocaMac is using",
                            value: String(format: "%.0f MB", ProcessMonitor.currentResidentMemoryMB())
                        )
                    }
                }
            }
            .settingsTarget("model-status")

            VocaSettingsGroup("Auto-Pause for Apps") {
                SettingsToggleRow(
                    title: "Pause dictation while these apps run",
                    detail: "Frees the speech model's memory for games and other heavy apps, and loads it again when they quit.",
                    isOn: $appState.autoPauseEnabled
                )

                if appState.autoPauseEnabled {
                    ForEach(appState.autoPauseApps) { app in
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.displayName)
                                if let detail = app.bundleIdentifier ?? app.processName {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                appState.removeAutoPauseApp(app)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Remove \(app.displayName)")
                            .accessibilityLabel("Remove \(app.displayName)")
                        }
                    }
                    Button("Add App…") {
                        showingAppPicker = true
                    }
                }

                if appState.isAutoPaused {
                    Label(
                        appState.autoPauseTriggerDisplayName.map { "Paused while \($0) is running." }
                            ?? "Dictation is currently paused by a listed app.",
                        systemImage: "pause.circle.fill"
                    )
                    .foregroundStyle(VocaDesign.warning)
                    .font(.caption)
                }
            }
            .settingsTarget("auto-pause")

            VocaSettingsGroup("Unload When Idle") {
                SettingsToggleRow(
                    title: "Unload models when idle",
                    detail: "Frees memory, including Smart Cleanup and Command Mode models. The next dictation takes a moment longer to start.",
                    isOn: $appState.modelKeepAliveEnabled
                )
                if appState.modelKeepAliveEnabled {
                    Divider()
                    SettingsRow(title: "After") {
                        Picker("Idle timeout", selection: $appState.modelKeepAliveIdleTimeoutSeconds) {
                            ForEach(idleTimeoutChoices, id: \.seconds) { choice in
                                Text(choice.label).tag(choice.seconds)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
            .settingsTarget("idle-unload")
        }
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

    private var isLoaded: Bool { appState.whisperService.isModelLoaded }

    private var statusIsWarning: Bool {
        !isLoaded && appState.modelUnloadStatusMessage != nil
    }

    /// One line on why the model is or isn't in memory.
    private var statusDetail: String {
        if isLoaded { return "Loaded and ready, so dictation starts right away." }
        if let message = appState.modelUnloadStatusMessage {
            if let freed = appState.approximateMemoryFreedMB {
                return message + String(format: " About %.0f MB was freed.", freed)
            }
            return message
        }
        return "It loads when you next dictate."
    }

    private var estimatedModelRAMLabel: String? {
        let size = appState.currentModel?.size
            ?? ModelSize(rawValue: appState.selectedModelSize)
        guard let size else { return nil }
        return String(format: "~%.1f GB", size.ramRequiredGB)
    }
}

/// One memory number with its label above it.
private struct MemoryFigure: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
    @State private var isEndpointSectionExpanded = false
    @State private var endpointAPIKeyDraft = ""
    @State private var endpointNotice: String?
    @State private var scope: ModelPickerScope = .forYou
    @State private var modelSearch = ""
    @State private var showsAllSuggestions = false

    /// For You rows listed before the rest wait behind "Show more".
    private static let forYouShown = 5

    private var spokenLanguagesBinding: Binding<[String]> {
        Binding(
            get: { appState.spokenLanguages },
            set: { appState.spokenLanguages = $0 }
        )
    }

    private var recommendedModel: ModelSize? {
        appState.speechModelRecommendation?.model
    }

    private func models(in scope: ModelPickerScope, search: String = "") -> [ModelSize] {
        ModelPickerCatalog.models(
            in: scope,
            from: appState.availableModels,
            spokenLanguages: appState.spokenLanguages,
            search: search,
            recommended: recommendedModel,
            systemLanguages: appState.appleSpeechLanguages
        )
    }

    private var isSearching: Bool {
        !modelSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let spoken = appState.spokenLanguages
        let listed = models(in: scope, search: modelSearch)
        // Worked out once per render and handed to the rows, not once per row.
        let recommendation = appState.speechModelRecommendation
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Download and delete failures set only the message, not the
                // error status, so gate on the message alone.
                if let errorMessage = appState.errorMessage {
                    GroupBox {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(VocaDesign.warning)
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button {
                                appState.errorMessage = nil
                                if appState.appStatus == .error {
                                    appState.appStatus = .idle
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Dismiss")
                            .accessibilityLabel("Dismiss")
                        }
                        .padding(4)
                    }
                }

                ModelPickerHeader(
                    languages: spokenLanguagesBinding,
                    // A model mid-load is where dictation is heading, so it
                    // wins over the one it replaces.
                    current: appState.availableModels.first(where: \.isLoading)
                        ?? appState.availableModels.first(where: \.isActive),
                    systemLanguages: appState.appleSpeechLanguages,
                    onShowSuggestions: {
                        scope = .forYou
                        modelSearch = ""
                    }
                )
                .settingsTarget("spoken-languages")

                VStack(alignment: .leading, spacing: 10) {
                    // Search moves under the tabs when the window is narrow.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            scopePicker
                            Spacer(minLength: 8)
                            ModelSearchField(search: $modelSearch)
                                .frame(minWidth: 160, maxWidth: 220)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            scopePicker
                            ModelSearchField(search: $modelSearch)
                        }
                    }

                    Text(scopeCaption(spoken: spoken, recommendation: recommendation))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)

                    VStack(alignment: .leading, spacing: 0) {
                        if listed.isEmpty {
                            Text(emptyMessage)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        } else {
                            // English alone matches most of the catalog, so the
                            // best few lead and the rest wait behind a row.
                            let collapses = scope == .forYou && !isSearching && !showsAllSuggestions
                                && listed.count > Self.forYouShown + 1
                            let shown = collapses ? Array(listed.prefix(Self.forYouShown)) : listed
                            modelRows(shown, spoken: spoken, bestFit: recommendation?.model)
                            if collapses {
                                Divider()
                                Button {
                                    showsAllSuggestions = true
                                } label: {
                                    Text("Show \(listed.count - shown.count) more")
                                        .font(.callout.weight(.medium))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(VocaDisclosureHeaderButtonStyle())
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .vocaCard()
                }

                Label("Models download from Hugging Face and stay on this Mac · \(appState.modelManager.diskUsageDescription()) used",
                      systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Larger models are more accurate but slower and use more memory. Accuracy and speed ratings are catalog estimates and vary by language and Mac. Apple Speech assets are managed by macOS.")

                customEndpointSection
            }
            .padding()
        }
        .task {
            await appState.refreshAppleSpeechLanguages()
        }
        .onChange(of: appState.requestedSpeechModelSearch, initial: true) { _, search in
            guard let search else { return }
            scope = .all
            modelSearch = search
            appState.requestedSpeechModelSearch = nil
        }
    }

    /// Where the Custom Endpoint model sends recordings: the same two
    /// contracts VocaLinux offers, configured the same way cleanup's
    /// endpoint is.
    private var customEndpointSection: some View {
        VocaDisclosureCard(
            title: "Custom Endpoint",
            subtitle: "Send dictation to a Whisper-compatible server instead of a model on this Mac.",
            systemImage: "network",
            badge: appState.speechEndpoint.kind.displayName,
            isExpanded: $isEndpointSectionExpanded
        ) {
            Picker("Endpoint kind", selection: endpointKind) {
                ForEach(SpeechEndpointKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }

            TextField("Base URL", text: endpointBaseURL)
                .textFieldStyle(.voca)

            if appState.speechEndpoint.kind == .openAICompatible {
                TextField("Model", text: endpointModel)
                    .textFieldStyle(.voca)
            }

            SecureField(
                appState.speechEndpointHasAPIKey
                    ? "API key saved in Keychain"
                    : "API key (optional)",
                text: $endpointAPIKeyDraft
            )
            HStack {
                Button("Save API Key") {
                    do {
                        try appState.saveSpeechEndpointAPIKey(endpointAPIKeyDraft)
                        endpointAPIKeyDraft = ""
                        endpointNotice = "API key saved in Keychain."
                    } catch {
                        endpointNotice = "Could not save the key: \(error.localizedDescription)"
                    }
                }
                .disabled(endpointAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if appState.speechEndpointHasAPIKey {
                    Button("Remove Key", role: .destructive) {
                        do {
                            try appState.deleteSpeechEndpointAPIKey()
                            endpointNotice = "API key removed."
                        } catch {
                            endpointNotice = "Could not remove the key: \(error.localizedDescription)"
                        }
                    }
                }
                Spacer()
            }

            if let problem = appState.speechEndpoint.validationProblem() {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(VocaDesign.warning)
            }

            Text("Each recording is uploaded as a WAV file while Custom Endpoint is the selected model. Use HTTPS unless the server is on this Mac or your local network. Endpoint settings and API keys are never exported.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let endpointNotice {
                Text(endpointNotice).font(.caption).foregroundStyle(.secondary)
            }
        }
        .settingsTarget("custom-endpoint")
        .revealSettingsTargets(["custom-endpoint"], expanded: $isEndpointSectionExpanded)
    }

    private var endpointKind: Binding<SpeechEndpointKind> {
        Binding(
            get: { appState.speechEndpoint.kind },
            set: { kind in
                var configuration = appState.speechEndpoint
                configuration.kind = kind
                appState.speechEndpoint = configuration
            }
        )
    }

    private var endpointBaseURL: Binding<String> {
        Binding(
            get: { appState.speechEndpoint.baseURL },
            set: { value in
                var configuration = appState.speechEndpoint
                configuration.baseURL = value
                appState.speechEndpoint = configuration
            }
        )
    }

    private var endpointModel: Binding<String> {
        Binding(
            get: { appState.speechEndpoint.model },
            set: { value in
                var configuration = appState.speechEndpoint
                configuration.model = value
                appState.speechEndpoint = configuration
            }
        )
    }

    private var scopePicker: some View {
        Picker("Show", selection: $scope) {
            ForEach(ModelPickerScope.allCases) { scope in
                Text("\(scope.title) (\(models(in: scope).count))").tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .settingsTarget("models")
    }

    @ViewBuilder
    private func modelRows(_ sizes: [ModelSize], spoken: [String], bestFit: ModelSize?) -> some View {
        let models = sizes.compactMap { size in appState.availableModels.first { $0.size == size } }
        ForEach(models) { model in
            ModelRow(
                model: model,
                appState: appState,
                spokenLanguages: spoken,
                systemLanguages: appState.appleSpeechLanguages,
                isBestFit: model.isSupported && model.size == bestFit
            )
            if model.id != models.last?.id {
                Divider()
            }
        }
    }

    private func scopeCaption(spoken: [String], recommendation: OnboardingModelRecommendation?) -> String {
        switch scope {
        case .forYou:
            // Say why the first row is the best fit, where the reader is
            // already looking.
            if let recommendation, !spoken.isEmpty {
                return "Best fit for \(SpokenLanguages.list(spoken)): \(recommendation.model.displayName). "
                    + recommendation.explanation
            }
            return spoken.isEmpty
                ? "Every model, best first. Add your languages above to narrow the list."
                : "Models that understand \(SpokenLanguages.list(spoken)), best first."
        case .downloaded:
            return "Models already on this Mac. Switching between them needs no download."
        case .all:
            return "The whole catalog, best fit for your languages first."
        }
    }

    private var emptyMessage: String {
        if isSearching { return "No models match “\(modelSearch)”." }
        switch scope {
        case .forYou:     return "No model understands all of these languages. Try removing one, or look in All Models."
        case .downloaded: return "Nothing downloaded yet. Pick a model from For You."
        case .all:        return "No models are available on this Mac."
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
    /// Languages the user speaks; a row that misses one says so.
    var spokenLanguages: [String] = []
    /// Apple Speech's languages on this Mac, when known.
    var systemLanguages: Set<String>?
    /// The model suggested for the user's languages and preference.
    var isBestFit = false
    @State private var showForceDownloadAlert = false
    @State private var showRemoteEndpointAlert = false
    @State private var showDeleteAlert = false

    /// Apple Speech models are managed by the OS, not stored by the app, so there's nothing to
    /// delete. A model that's mid-load or mid-download is also excluded so its files aren't
    /// removed out from under an in-flight read.
    private var canDelete: Bool {
        model.isDownloaded && !model.isActive && !model.size.isSystemManaged
            && !model.isLoading && model.downloadProgress == nil
    }

    /// "Doesn't understand Hindi" when the model misses a language the user speaks.
    private var missingLanguagesNote: String? {
        let fit = ModelPickerCatalog.fit(of: model.size, for: spokenLanguages, systemLanguages: systemLanguages)
        guard !fit.coversAll else { return nil }
        return "Doesn't understand \(SpokenLanguages.list(fit.missing))"
    }

    @ViewBuilder
    private var ratings: some View {
        ModelRating(
            title: "Accuracy",
            value: model.size.accuracyScore,
            accessibilityValue: accuracyRating
        )
        .help("Accuracy: \(accuracyRating)")
        ModelRating(
            title: "Speed",
            value: model.size.speedScore,
            accessibilityValue: speedRating
        )
        .help("Speed: \(speedRating)")
    }

    private var factsText: some View {
        Text(facts)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(ModelLanguageBadge.tooltip(for: model.size, systemLanguages: systemLanguages)
                  + "\n" + ramHelp)
    }

    /// Estimated RAM for the facts line: "~2.0 GB RAM".
    private var ramLabel: String {
        "~\(String(format: "%.1f", model.size.ramRequiredGB)) GB RAM"
    }

    /// Estimated RAM for the row's help, with the first-load peak when a
    /// model needs more while macOS prepares it for the Neural Engine.
    private var ramHelp: String {
        let inUse = "~\(String(format: "%.1f", model.size.ramRequiredGB)) GB RAM while in use"
        guard model.size.firstLoadRAMRequiredGB > model.size.ramRequiredGB else { return inUse }
        return inUse + ", ~\(String(format: "%.1f", model.size.firstLoadRAMRequiredGB)) GB "
            + "the first time it loads"
    }

    /// Accuracy as its label and the dots the row shows: "Great, 3.5 of 5".
    private var accuracyRating: String {
        "\(model.size.qualityDescription), \(ModelRating.describe(model.size.accuracyScore))"
    }

    /// Speed as the dots the row shows, for help and VoiceOver.
    private var speedRating: String {
        ModelRating.describe(model.size.speedScore)
    }

    /// Languages, translation, size and estimated RAM, in one plain line.
    private var facts: String {
        var parts = [ModelLanguageBadge.label(for: model.size, systemLanguages: systemLanguages)]
        if model.size.translatesToEnglish { parts.append("Translates to English") }
        parts.append(model.size.fileSizeDescription)
        parts.append(ramLabel)
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Who made it; the check marks the model in use.
            ModelCreatorMark(creator: model.size.creator, isActive: model.isActive)
                .help(model.size.creator.displayName)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.size.displayName)
                        .font(.callout.weight(model.isActive ? .semibold : .medium))
                    if model.size.isRemotelyHosted {
                        ModelTag(text: "Remote", systemImage: "network")
                    } else if model.isDownloaded && !model.isActive {
                        ModelTag(
                            text: model.size.isSystemManaged ? "Built In" : "Downloaded",
                            systemImage: "checkmark"
                        )
                    }
                    if isBestFit {
                        ModelTag(text: "Best fit", tint: VocaDesign.accent)
                    }
                    if !model.isSupported {
                        ModelTag(text: "Experimental", tint: VocaDesign.warning)
                            .help("WhisperKit hasn't verified this model on your chip family. It may fail to load, or it may run slower than tuned models.")
                    }
                }

                Text(model.size.pickerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Facts drop to their own line rather than wrap mid-list.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        ratings
                        factsText
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 16) { ratings }
                        factsText
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

                if let missing = missingLanguagesNote {
                    Label(missing, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(VocaDesign.warning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // "Download & Use" is wider than the old fixed column; let the
            // action take the room it needs rather than truncate.
            action
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 116, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
        .background {
            // The model in use stands out where it ranks, instead of being
            // listed a second time somewhere else.
            if model.isActive {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(VocaDesign.accent.opacity(0.08))
            }
        }
        .alert("Use Experimental Model?", isPresented: $showForceDownloadAlert) {
            Button("Cancel", role: .cancel) {}
            Button(model.isDownloaded ? "Use Anyway" : "Download & Use", role: .destructive) {
                Task { @MainActor in
                    if !model.isDownloaded {
                        await appState.downloadModel(model.size)
                    }
                    if model.isDownloaded || appState.availableModels.first(where: { $0.size == model.size })?.isDownloaded == true {
                        if model.size.isRemotelyHosted {
                            showRemoteEndpointAlert = true
                        } else {
                            await appState.loadModel(model.size)
                        }
                    }
                }
            }
        } message: {
            Text("WhisperKit hasn't verified this model on your chip family. It may fail to load, or it may run slower than tuned models.")
        }
        .alert("Use Remote Endpoint?", isPresented: $showRemoteEndpointAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Use Remote Endpoint", role: .destructive) {
                Task { @MainActor in await appState.loadModel(model.size) }
            }
        } message: {
            Text("Each recording is uploaded as a WAV file to the configured server. Audio leaves this Mac while Custom Endpoint is selected.")
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

    /// One control per state, so a row always says whether the model is in
    /// use, ready on this Mac, or still to download.
    @ViewBuilder
    private var action: some View {
        if let progress = model.downloadProgress {
            HStack(spacing: 6) {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: progress)
                        .frame(width: 60)
                        .controlSize(.small)
                    Text("Downloading \(Int(progress * 100))%")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Downloading \(model.size.displayName)")
                .accessibilityValue("\(Int(progress * 100)) percent")

                if progress < 1.0 {
                    Button {
                        appState.modelManager.cancelDownload(for: model.size)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Cancel download")
                    .accessibilityLabel("Cancel downloading \(model.size.displayName)")
                }
            }
        } else if model.isLoading {
            VStack(alignment: .trailing, spacing: 2) {
                ProgressView()
                    .controlSize(.small)
                Text(model.loadingStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .help(model.loadingStatus == ModelSize.firstLoadStatus ? ModelSize.firstLoadExplanation : "")
        } else if model.isActive {
            Label("In Use", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(VocaDesign.success)
        } else if model.isDownloaded {
            HStack(spacing: 6) {
                if canDelete {
                    Button {
                        showDeleteAlert = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Delete from this Mac")
                    .accessibilityLabel("Delete \(model.size.displayName)")
                }
                Button(model.isSupported ? "Use" : "Use Anyway") {
                    if model.size.isRemotelyHosted {
                        showRemoteEndpointAlert = true
                    } else if model.isSupported {
                        Task { @MainActor in await appState.loadModel(model.size) }
                    } else {
                        showForceDownloadAlert = true
                    }
                }
                .buttonStyle(VocaPrimaryButtonStyle())
                .help(model.size.isRemotelyHosted
                      ? "Transcribed by your endpoint"
                      : model.size.isSystemManaged ? "Built into macOS" : "Downloaded to this Mac")
            }
        } else {
            Button {
                if model.isSupported {
                    Task { @MainActor in
                        await appState.downloadModel(model.size)
                        if appState.availableModels.first(where: { $0.size == model.size })?.isDownloaded == true {
                            await appState.loadModel(model.size)
                        }
                    }
                } else {
                    showForceDownloadAlert = true
                }
            } label: {
                Label(model.isSupported ? "Download & Use" : "Try Anyway", systemImage: "arrow.down.circle")
            }
            .help("Download \(model.size.fileSizeDescription), then switch to it")
        }
    }
}

// MARK: - Audio Settings

struct AudioSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var audioDevices: [AudioDevice] = []

    var body: some View {
        VocaSettingsPageContent {
            inputDeviceSection

            VocaSettingsGroup("Recording and Silence") {
                SettingsRow(title: "Longest recording", detail: "A recording stops on its own after this long.") {
                    Picker("Max recording duration", selection: $appState.maxRecordingDuration) {
                        Text("15 seconds").tag(15)
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                        Text("2 minutes").tag(120)
                        Text("5 minutes").tag(300)
                        Text("10 minutes").tag(600)
                        Text("20 minutes").tag(1200)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .onChange(of: appState.maxRecordingDuration) {
                    appState.syncHotKeyConfiguration()
                }

                Divider()

                SettingsToggleRow(
                    title: "Skip silence before transcribing",
                    detail: "Cuts pauses out first, so transcription is faster and quiet stretches don't turn into made-up words.",
                    isOn: $appState.skipSilence
                )
                .settingsTarget("skip-silence")

                Divider()

                SettingsRow(title: "Silence sensitivity", detail: "How quiet counts as silence.") {
                    HStack(spacing: 8) {
                        Slider(value: $appState.silenceThreshold, in: 0.001...0.05, step: 0.001)
                            .frame(width: 160)
                            .accessibilityLabel("Silence sensitivity")
                        Text(sensitivityLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                Divider()

                SettingsRow(title: "Stop after silence", detail: "Hands-free and double-tap only. Push to talk stops when you let go.") {
                    HStack(spacing: 6) {
                        TextField(
                            "Seconds",
                            value: silenceDurationBinding,
                            format: .number.precision(.fractionLength(0...1))
                        )
                        .labelsHidden()
                        .textFieldStyle(.voca)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 64)
                        Text("seconds")
                            .foregroundStyle(.secondary)
                    }
                }
                .help("Between 0.5 and 300 seconds.")
            }
            .settingsTarget("silence")

            VocaSettingsGroup("Sounds") {
                SettingsToggleRow(
                    title: "Play start and stop sounds",
                    detail: "A short tone when the microphone opens and closes.",
                    isOn: $appState.soundEffectsEnabled
                )
                .settingsTarget("sound-effects")

                Divider()

                SettingsRow(title: "Dictation tone") {
                    HStack(spacing: 6) {
                        Picker("Dictation tone", selection: $appState.dictationTone) {
                            ForEach(DictationTone.allCases) { tone in
                                Text(tone.displayName).tag(tone)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
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
                }

                Divider()

                SettingsToggleRow(
                    title: "Mute other audio while dictating",
                    detail: "Only when something is playing.",
                    isOn: $appState.duckOtherAudioEnabled
                )
                .settingsTarget("other-audio")

                Divider()

                SettingsToggleRow(
                    title: "Pause Spotify while dictating",
                    detail: "Also reaches Spotify Connect on other speakers, which muting can't. Asks for permission the first time.",
                    isOn: $appState.pauseSpotifyEnabled
                )
                .settingsTarget("spotify-pause")
            }
        }
        .onAppear {
            refreshAudioDevices()
        }
        .onReceive(NotificationCenter.default.publisher(for: .vocaAudioDevicesChanged)) { _ in
            refreshAudioDevices()
        }
    }

    private var inputDeviceSection: some View {
        VocaSettingsGroup("Microphone") {
            SettingsRow(title: "Microphone", detail: "System Default follows macOS. Choosing one here never changes macOS's own setting.") {
                HStack(spacing: 6) {
                    Picker("Microphone", selection: $appState.selectedAudioDeviceID) {
                        Text("System Default").tag("")
                        if selectedAudioDeviceIsUnavailable {
                            Text("\(selectedAudioDeviceDisplayName) (Unavailable)").tag(appState.selectedAudioDeviceID)
                        }
                        ForEach(audioDevices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
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
            }

            if activeInputChannelCount > 1 {
                Divider()
                SettingsRow(title: "Input channel", detail: "The interface input your microphone is plugged into.") {
                    Picker("Input channel", selection: selectedAudioChannelBinding) {
                        ForEach(0..<activeInputChannelCount, id: \.self) { channel in
                            Text("Channel \(channel + 1)").tag(channel)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            // Only say something when there is a problem to act on.
            if audioDevices.isEmpty {
                Label("No audio input devices found", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(VocaDesign.warning)
            } else if selectedAudioDeviceIsUnavailable {
                Label("\(selectedAudioDeviceDisplayName) is unavailable. Using System Default until it reconnects.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(VocaDesign.warning)
            }

            if let fallbackNotice = appState.inputDeviceFallbackNotice {
                Label(fallbackNotice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(VocaDesign.warning)
            }

            Divider()

            SettingsToggleRow(
                title: "Use an external microphone when the lid is closed",
                detail: "Your saved choice comes back when you open the lid.",
                isOn: $appState.externalMicWhenLidClosed
            )
            .settingsTarget("closed-lid-microphone")
        }
        .settingsTarget("microphone")
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

struct PermissionsLogsTab: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var processMonitor = ProcessMonitor(useTimer: false)
    @State private var logEntryCount: Int = VocaLogger.logEntryCount

    var body: some View {
        // Permissions first: they are why most people open this page. The
        // device details that used to lead it are already under About.
        Form {
            Section {
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
            } header: {
                VocaFormSectionHeader("Permissions")
            }
            .settingsTarget("permissions")

            Section {
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
            } header: {
                VocaFormSectionHeader("Debug Logs")
            }
            .settingsTarget("logs")

            Section {
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
            } header: {
                VocaFormSectionHeader("Resource Usage")
            }
            .settingsTarget("resources")
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

// MARK: - Sidebar list

/// The page list: tracked group labels and rows that fill with ink when
/// chosen. Up and down arrows move through it as they did through the
/// system list it replaces.
struct SettingsSidebarList: View {
    @Binding var selection: SettingsPage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let order = SettingsSection.allCases.flatMap(\.pages)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsSection.allCases) { section in
                        Text(section.title.uppercased())
                            .font(.system(size: 10.5, weight: .semibold))
                            .tracking(1.3)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 10)
                            .padding(.top, 16)
                            .padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.pages) { page in
                            SettingsSidebarRow(page: page, isSelected: selection == page) {
                                selection = page
                            }
                            .id(page)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(by: 1) }
            .onKeyPress(.upArrow) { move(by: -1) }
            // Arrow keys can choose a row scrolled out of a short window.
            .onChange(of: selection) { _, page in
                guard let page else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(page) }
            }
        }
    }

    private func move(by offset: Int) -> KeyPress.Result {
        let current = selection.flatMap { Self.order.firstIndex(of: $0) } ?? 0
        let next = min(max(current + offset, 0), Self.order.count - 1)
        selection = Self.order[next]
        return .handled
    }
}

private struct SettingsSidebarRow: View {
    let page: SettingsPage
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: page.systemImage)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? VocaDesign.onInk : Color.secondary)
                Text(page.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? VocaDesign.onInk : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? VocaDesign.ink : Color.primary.opacity(isHovered ? 0.05 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Page header

/// The top of every settings page: the group's scene running edge to edge
/// and up under the title bar, with the page title set on it.
struct SettingsSceneHeader: View {
    let title: String
    let mood: SceneMood
    var leadingInset: CGFloat = 18
    let isSidebarVisible: Bool
    let toggleSidebar: () -> Void

    @State private var isMoving = true

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            VocaScene(mood: mood, animated: isMoving, framing: .horizon)
            Text(title)
                .font(VocaDesign.display(38))
                .foregroundStyle(Color(nsColor: VocaPalette.ivory))
                .shadow(color: .black.opacity(0.28), radius: 12, y: 1)
                .padding(.leading, 28)
                .padding(.bottom, 20)
                .id(title)
                .riseIn(distance: 8)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(height: 164)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(alignment: .topLeading) {
            Button(action: toggleSidebar) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(nsColor: VocaPalette.ivory).opacity(0.9))
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
            .accessibilityLabel(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
            .padding(.leading, leadingInset)
            .padding(.top, 9)
        }
        .task(id: title) {
            // Move for a few seconds when a page opens, then hold still, so
            // an open Settings window costs nothing while it sits there.
            isMoving = true
            // A cancelled task (another page opened) must not stop the new one.
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            isMoving = false
        }
    }
}
