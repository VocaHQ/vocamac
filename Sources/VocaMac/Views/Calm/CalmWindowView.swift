// CalmWindowView.swift
// VocaMac
//
// The v3 window shell: frame-coloured sidebar (brand, six everyday pages,
// live status card, Settings, Help) beside the inset content area, and
// the Settings sheet that opens over the whole window with the scrim.

import AppKit
import SwiftUI

/// The root view of VocaMac's window.
struct CalmWindowView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settingsWindowManager: SettingsWindowManager

    @State private var navigator: CalmNavigator
    @AppStorage(CalmWindowView.lastMainPageKey) private var lastMainPage = CalmMainPage.home.rawValue
    @State private var isDialogPresented = false
    @FocusState private var isSearchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the last sidebar page is remembered.
    static let lastMainPageKey = "calm.lastMainPage"

    /// - Parameter navigator: A navigator to start from (previews, tests).
    ///   By default the window reopens on the last sidebar page.
    init(navigator: CalmNavigator? = nil) {
        let stored = UserDefaults.standard.string(forKey: Self.lastMainPageKey).flatMap(CalmMainPage.init(rawValue:))
        _navigator = State(initialValue: navigator ?? CalmNavigator(mainPage: stored ?? .home))
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                CalmSidebar()
                    .frame(width: CalmMetrics.sidebarWidth)
                    .layoutPriority(1)
                contentArea
            }
            // Behind the Settings sheet, Tab and full keyboard access stay
            // in the sheet: the sidebar and page don't take focus or
            // VoiceOver. The scrim already dims them.
            .disabled(navigator.isSettingsPresented)
            .environment(\.calmDimsWhenDisabled, false)
            .accessibilityHidden(navigator.isSettingsPresented)
            if navigator.isSettingsPresented {
                settingsLayer
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.18), value: navigator.isSettingsPresented)
        // Behind a dialog, nothing answers Tab, VoiceOver or a click: the
        // scrim only stopped the mouse, so a row under the dialog could
        // still be focused or pressed and open a second dialog. The scrim
        // already dims it, so skip the controls' own disabled dimming.
        .disabled(isDialogPresented)
        .environment(\.calmDimsWhenDisabled, !isDialogPresented)
        .accessibilityHidden(isDialogPresented)
        .calmDialogHost()
        .onPreferenceChange(CalmDialogPresenceKey.self) { isDialogPresented = $0 }
        .background(CalmColor.frame)
        .background { shortcuts }
        .ignoresSafeArea()
        .environment(navigator)
        .environment(\.settingsSearchTarget, navigator.searchTarget)
        .tint(CalmColor.accent)
        .frame(minWidth: CalmMetrics.windowMinSize.width, minHeight: CalmMetrics.windowMinSize.height)
        .onAppear(perform: consumeRequests)
        .onChange(of: appState.requestedSettingsPage) { consumeRequests() }
        .onChange(of: settingsWindowManager.requestedPage) { _, page in
            if page != nil { consumeRequests() }
        }
        .onChange(of: navigator.mainPage) { _, page in lastMainPage = page.rawValue }
    }

    // MARK: Content

    private var contentArea: some View {
        let shape = RoundedRectangle(cornerRadius: CalmMetrics.Radius.content, style: .continuous)
        // minWidth 0: the content area takes the width left beside the
        // sidebar and never grows to fit a page, so a wide page can't push
        // the sidebar off the window.
        return CalmMainPageView(page: navigator.mainPage)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .background(CalmColor.content)
            .clipShape(shape)
            .overlay(shape.strokeBorder(CalmColor.line, lineWidth: 1))
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if !navigator.isSettingsPresented { CalmSearchHintBanner() }
                    UndoToastView(undoCenter: appState.undoCenter)
                }
            }
            .padding(.vertical, CalmMetrics.contentInset)
            .padding(.trailing, CalmMetrics.contentInset)
    }

    private var settingsLayer: some View {
        GeometryReader { proxy in
            ZStack {
                CalmColor.scrim
                    .contentShape(Rectangle())
                    .onTapGesture { navigator.closeSettings() }
                    .accessibilityHidden(true)
                // 1000 × 680, or smaller in a window too small for that.
                CalmSettingsSheet(
                    size: SettingsWindowGeometry.sheetSize(in: proxy.size),
                    isDialogPresented: isDialogPresented, isSearchFocused: $isSearchFocused
                )
            }
        }
    }

    /// Window-wide shortcuts: ⌘, opens Settings, ⌘F focuses its search.
    /// Neither works while a dialog is up.
    private var shortcuts: some View {
        ZStack {
            Button("Settings") { navigator.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(isDialogPresented)
            Button("Search Settings") { isSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!navigator.isSettingsPresented || isDialogPresented)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Requests

    /// Honour a page another part of the app asked for (menu bar, deep
    /// links, error fixes, first open), once.
    private func consumeRequests() {
        if let page = settingsWindowManager.consumeRequestedPage() {
            navigator.open(page)
        }
        if let page = appState.requestedSettingsPage {
            navigator.open(page)
            appState.requestedSettingsPage = nil
        }
    }
}

// MARK: - Page switch

/// The sidebar page in the content area.
struct CalmMainPageView: View {
    let page: CalmMainPage

    var body: some View {
        switch page {
        case .home: CalmHomePage()
        case .insights: CalmInsightsPage()
        case .dictionary: CalmDictionaryPage()
        case .snippets: CalmSnippetsPage()
        case .styles: CalmStylesPage()
        case .commands: CalmCommandsPage()
        }
    }
}

/// The Settings page in the sheet body.
struct CalmSettingsPageView: View {
    let destination: CalmSettingsDestination

    var body: some View {
        switch destination {
        case .general: CalmGeneralSettings()
        case .languages: CalmLanguagesSettings()
        case .system: CalmSystemSettings()
        case .models: CalmModelsSettings()
        case .allModels: CalmAllModelsSettings()
        case .cleanup: CalmCleanupSettings()
        case .privacy: CalmPrivacySettings()
        case .advanced: CalmAdvancedSettings()
        case .gateway: CalmGatewaySettings()
        case .about: CalmAboutSettings()
        }
    }
}

// MARK: - Sidebar

/// The window sidebar: brand · six pages · spacer · status card · divider
/// · Settings · Help.
struct CalmSidebar: View {
    @Environment(CalmNavigator.self) private var navigator
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: CalmMetrics.trafficLightReserve)
            HStack(spacing: 10) {
                CalmBrandMark(size: 28)
                Text("VocaMac")
                    .font(CalmFont.brand)
                    .tracking(-0.16)
                    .foregroundStyle(CalmColor.ink)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 20)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            VStack(spacing: CalmMetrics.navItemSpacing) {
                ForEach(CalmMainPage.allCases) { page in
                    CalmNavItem(
                        title: page.title, icon: page.icon,
                        isSelected: !navigator.isSettingsPresented && navigator.mainPage == page
                    ) {
                        navigator.show(page)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Main")

            Spacer(minLength: 16)

            // 10 below the card, plus the sidebar column's 2-point gap.
            CalmSidebarStatusCard()
                .padding(.bottom, 12)

            VStack(spacing: CalmMetrics.navItemSpacing) {
                CalmNavItem(title: "Settings", icon: .settings, isSelected: navigator.isSettingsPresented) {
                    navigator.openSettings()
                }
                CalmNavItem(title: "Help", icon: .help, isSelected: false) {
                    if let url = CalmNavigation.helpURL { openURL(url) }
                }
            }
            .padding(.top, 8)
            .overlay(alignment: .top) { Rectangle().fill(CalmColor.line).frame(height: 1) }
        }
        .padding(CalmMetrics.sidebarPadding)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A sidebar or Settings-menu item: 17-point ink2 icon, SF 14 label, r9;
/// panel2 when hovered or selected (selected is 600).
struct CalmNavItem: View {
    let title: String
    let icon: CalmIconName
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: CalmMetrics.navIconGap) {
                CalmIcon(icon, size: CalmMetrics.navIconSize)
                    .foregroundStyle(CalmColor.ink2)
                Text(title)
                    .font(isSelected ? CalmFont.navSelected : CalmFont.nav)
                    .foregroundStyle(CalmColor.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(CalmMetrics.navItemPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(CalmNavItemStyle(isSelected: isSelected))
        .focusEffectDisabled()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct CalmNavItemStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        CalmNavItemBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct CalmNavItemBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool

    @Environment(\.isFocused) private var focusedForReal
    @Environment(\.calmPreviewInteraction) private var forced
    @Environment(\.colorScheme) private var scheme
    @State private var hoveredForReal = false

    private var isHovered: Bool { hoveredForReal || forced == .hover }
    private var isFocused: Bool { focusedForReal || forced == .focus }

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: CalmMetrics.Radius.nav, style: .continuous)
                    .fill(isSelected || isHovered ? CalmColor.panel2 : .clear)
            )
            .calmPressed(configuration.isPressed, scheme: scheme)
            .calmFocusRing(isFocused, radius: CalmMetrics.Radius.nav)
            .onHover { hoveredForReal = $0 }
    }
}

// MARK: - Status card

/// The app's one live status, in six states (Patterns board).
enum CalmSidebarStatus: Equatable {
    /// A speech model downloading in the background while dictation keeps
    /// using the current one (Model chooser behaviour 3).
    struct Download: Equatable {
        /// The model's name, when known.
        var model: String?
        var progress: Double

        /// “Downloading Parakeet v3”.
        var title: String { model.map { "Downloading \($0)" } ?? "Downloading a model" }
        /// “42%”.
        var percent: String { CalmSidebarStatus.percent(progress) }
    }

    /// Ready to dictate. `paused` while auto-paused for an app; `download`
    /// while a newly picked model downloads.
    case ready(verb: String, keys: [String], detail: String, paused: Bool, download: Download? = nil)
    /// Recording.
    case listening(keys: [String], isToggle: Bool, escapeCancels: Bool)
    /// Transcribing or cleaning up.
    case working(title: String, detail: String?)
    /// A speech model is downloading or loading.
    case loadingModel(title: String, detail: String?, progress: Double?)
    /// A permission is missing.
    case needsAccess(message: String)
    /// Something failed; `actionTitle` names the fix.
    case error(title: String, message: String, actionTitle: String)

    /// The inputs the card reads from `AppState`, gathered so the mapping can be tested.
    struct Inputs: Equatable {
        var status: AppStatus
        var readiness: DictationReadiness
        var isAutoPaused = false
        var isToggleActivation = false
        var keys: [String]
        var modelName: String?
        var isRemote = false
        var escapeCancels = true
        var processingText = "Transcribing…"
        var preparingModelName: String?
        var isDownloading = false
        var downloadProgress: Double?
        var errorMessage: String?
        var errorActionTitle: String?
    }

    /// The model line without where it runs: “Parakeet Unified · on this
    /// Mac” → “Parakeet Unified”, for a card too narrow for both.
    static func shortModelLine(_ line: String) -> String {
        guard let range = line.range(of: " · ", options: .backwards) else { return line }
        return String(line[..<range.lowerBound])
    }

    /// A download's progress as the card writes it: “42%”.
    static func percent(_ progress: Double) -> String {
        "\(Int((min(max(progress, 0), 1) * 100).rounded(.down)))%"
    }

    /// Picks the state to show. Activity (recording, processing, an error)
    /// wins over readiness.
    static func resolve(_ inputs: Inputs) -> CalmSidebarStatus {
        let model = inputs.modelName.map { "\($0) · \(inputs.isRemote ? "on your server" : "on this Mac")" }
        switch inputs.status {
        case .recording:
            return .listening(keys: inputs.keys, isToggle: inputs.isToggleActivation, escapeCancels: inputs.escapeCancels)
        case .processing:
            return .working(title: inputs.processingText, detail: inputs.modelName)
        case .error:
            return .error(
                title: "Something went wrong",
                message: inputs.errorMessage ?? "The last dictation didn’t finish.",
                actionTitle: inputs.errorActionTitle ?? "Try again"
            )
        case .idle:
            break
        }
        switch inputs.readiness {
        case .needsMicrophone:
            return .needsAccess(message: "Microphone access is off, so VocaMac can’t hear you.")
        case .needsInputMonitoring:
            return .needsAccess(message: "Input Monitoring is off, so the dictation key can’t be heard.")
        case .needsAccessibility:
            return .needsAccess(message: "Accessibility is off, so VocaMac can’t type for you.")
        case .preparingModel:
            let name = inputs.preparingModelName ?? inputs.modelName
            let percentSuffix = inputs.downloadProgress.map { " · \(Self.percent($0))" } ?? ""
            return .loadingModel(
                title: inputs.isDownloading ? "Downloading model" : "Loading model",
                detail: name.map { inputs.isDownloading ? $0 + percentSuffix : $0 },
                progress: inputs.downloadProgress
            )
        case .needsModel:
            return .error(
                title: "Choose a speech model",
                message: "No speech model is on this Mac yet.",
                actionTitle: "Choose a model"
            )
        case .ready:
            if inputs.isAutoPaused {
                return .ready(verb: "Paused", keys: [], detail: "Auto-paused while an app you chose is open.", paused: true)
            }
            let download = inputs.isDownloading
                ? inputs.downloadProgress.map { Download(model: inputs.preparingModelName, progress: $0) }
                : nil
            return .ready(
                verb: inputs.isToggleActivation ? "Double-tap" : "Hold",
                keys: inputs.keys, detail: model ?? "On this Mac", paused: false, download: download
            )
        }
    }
}

/// The status card at the bottom of the sidebar.
struct CalmSidebarStatusCard: View {
    @EnvironmentObject private var appState: AppState
    @Environment(CalmNavigator.self) private var navigator

    private var inputs: CalmSidebarStatus.Inputs {
        let preparing = appState.availableModels.first { $0.isLoading || $0.downloadProgress != nil }
        return CalmSidebarStatus.Inputs(
            status: appState.appStatus,
            readiness: appState.dictationReadiness,
            isAutoPaused: appState.isAutoPaused,
            isToggleActivation: appState.activationMode == .doubleTapToggle,
            keys: CalmKeyCaps.labels(for: HotKeyCombo(keyCode: appState.hotKeyCode, modifiers: appState.hotKeyModifiers)),
            modelName: appState.calmLoadedSpeechModelName ?? ModelSize(rawValue: appState.selectedModelSize).map(CalmModelText.name),
            isRemote: appState.speechProcessingIsRemote,
            escapeCancels: appState.escapeCancelsDictation,
            processingText: appState.processingStatusText,
            preparingModelName: preparing.map { CalmModelText.name($0.size) },
            isDownloading: preparing?.downloadProgress != nil,
            downloadProgress: preparing?.downloadProgress,
            errorMessage: appState.errorNotice?.message ?? appState.errorMessage,
            errorActionTitle: appState.errorNotice?.action?.title
        )
    }

    var body: some View {
        CalmStatusCardContent(
            status: CalmSidebarStatus.resolve(inputs),
            meter: appState.audioMeter,
            onGrantAccess: { navigator.openSettings(.advanced, target: "permissions") },
            onFix: fixError
        )
    }

    private func fixError() {
        if appState.appStatus == .error {
            if let fix = appState.errorNotice?.action {
                appState.performErrorFix(fix) { navigator.open($0) }
            } else {
                appState.dismissErrorNotice()
            }
        } else {
            navigator.open(.speechModel)
        }
    }
}

/// Draws one `CalmSidebarStatus` (panel, padding 14, gap 8).
struct CalmStatusCardContent: View {
    let status: CalmSidebarStatus
    let meter: AudioMeterState
    var onGrantAccess: () -> Void = {}
    var onFix: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            detail
            action
        }
        .padding(14)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .calmPanelBackground()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 9) {
            switch status {
            case .ready(let verb, _, _, let paused, _):
                CalmStatusDot(tone: paused ? .warning : .success)
                Text(paused ? verb : "Ready")
            case .listening:
                CalmListeningBars(meter: meter)
                Text("Listening")
            case .working(let title, _):
                CalmSpinner(size: 14, weight: 2.4)
                Text(title)
            case .loadingModel(let title, _, _):
                CalmSpinner(size: 14, weight: 2.4)
                Text(title)
            case .needsAccess:
                CalmStatusDot(tone: .warning)
                Text("Needs access")
            case .error(let title, _, _):
                CalmStatusDot(tone: .warning)
                Text(title).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(CalmFont.statusTitle)
        .foregroundStyle(CalmColor.ink)
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch status {
            case .ready(let verb, let keys, let detail, let paused, let download):
                if !paused { keyedLine(verb, keys: keys, rest: "and speak.") }
                if paused { statusText(detail) } else { modelLine(detail) }
                if let download {
                    CalmProgressBar(value: download.progress, title: download.title, detail: download.percent)
                        .padding(.top, 8)
                        .accessibilityElement(children: .combine)
                }
            case .listening(let keys, let isToggle, let escapeCancels):
                if isToggle {
                    keyedLine("Press", keys: keys, rest: "again to type it.")
                } else {
                    keyedLine("Let go of", keys: keys, rest: "to type it.")
                }
                if escapeCancels { statusText("Esc to cancel") }
            case .working(_, let detail):
                if let detail { statusText(detail) }
            case .loadingModel(_, let detail, let progress):
                if let detail { statusText(detail) }
                if let progress {
                    CalmProgressBar(value: progress).padding(.top, 6)
                }
            case .needsAccess(let message), .error(_, let message, _):
                statusText(message)
            }
        }
    }

    @ViewBuilder
    private var action: some View {
        switch status {
        case .needsAccess:
            Button("Grant access", action: onGrantAccess)
                .calmButton(.primary, size: .small)
        case .error(_, _, let actionTitle):
            Button(actionTitle, action: onFix).calmButton(.secondary, size: .small)
        default:
            EmptyView()
        }
    }

    /// “Parakeet Unified · on this Mac” on one line: without “· on this
    /// Mac” when the whole line doesn't fit, then truncated.
    private func modelLine(_ text: String) -> some View {
        ViewThatFits(in: .horizontal) {
            Text(text).lineLimit(1).fixedSize()
            Text(CalmSidebarStatus.shortModelLine(text)).lineLimit(1).truncationMode(.tail)
        }
        .font(CalmFont.note)
        .foregroundStyle(CalmColor.muted)
        .help(text)
        .accessibilityLabel(text)
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(CalmFont.note)
            .foregroundStyle(CalmColor.muted)
            .lineSpacing(2.5)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// “Hold [Right ⌥] and speak.”, wrapping the trailing words under the
    /// caps when a long shortcut doesn't fit the card.
    private func keyedLine(_ lead: String, keys: [String], rest: String) -> some View {
        ViewThatFits(in: .horizontal) {
            // About a word space, as in the design's inline caps.
            CalmKeyedLine([.text(lead), .keys(keys), .text(rest)], spacing: 3, capSize: .inline, font: CalmFont.note)
            VStack(alignment: .leading, spacing: 2) {
                CalmKeyedLine([.text(lead), .keys(keys)], spacing: 3, capSize: .inline, font: CalmFont.note)
                statusText(rest)
            }
        }
    }
}

/// The 7-point status dot with its 3-point soft ring.
struct CalmStatusDot: View {
    var tone: CalmTone = .success

    var body: some View {
        Circle()
            .fill(tone == .warning ? CalmColor.amber : CalmColor.accent)
            .frame(width: 7, height: 7)
            .background(Circle().fill(tone == .warning ? CalmColor.amberSoft : CalmColor.accentSoft).frame(width: 13, height: 13))
            .frame(width: 13, height: 13)
            .accessibilityHidden(true)
    }
}

/// Six accent bars that follow the microphone level while listening.
struct CalmListeningBars: View {
    @ObservedObject var meter: AudioMeterState

    var body: some View {
        let scale = 0.45 + 0.55 * CGFloat(min(max(meter.level * 2.5, 0), 1))
        HStack(spacing: 2) {
            ForEach(Array([5, 9, 13, 8, 11, 6].enumerated()), id: \.offset) { _, height in
                RoundedRectangle(cornerRadius: 1)
                    .fill(CalmColor.accent)
                    .frame(width: 2, height: CGFloat(height) * scale)
            }
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.1), value: meter.level)
        .accessibilityHidden(true)
    }
}

// MARK: - Settings sheet

/// The Settings sheet: 1000 × 680 (smaller in a small window), r16, a
/// 236-wide menu on frame with the search field on top, and the page body
/// on content.
struct CalmSettingsSheet: View {
    var size: CGSize = CalmMetrics.sheetSize
    let isDialogPresented: Bool
    var isSearchFocused: FocusState<Bool>.Binding

    @Environment(CalmNavigator.self) private var navigator

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CalmMetrics.Radius.sheet, style: .continuous)
        HStack(spacing: 0) {
            CalmSettingsMenu(isSearchFocused: isSearchFocused)
                .frame(width: CalmMetrics.sheetMenuWidth)
                .frame(maxHeight: .infinity)
                .background(CalmColor.frame)
            body(for: navigator)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(CalmColor.content)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(CalmColor.line2, lineWidth: 1))
        .background(shape.fill(CalmColor.content).shadow(color: .black.opacity(0.28), radius: 40, y: 30))
        .onExitCommand { if !isDialogPresented { navigator.closeSettings() } }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Settings")
    }

    private func body(for navigator: CalmNavigator) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if navigator.isSearching {
                    CalmSettingsSearchResults(query: navigator.settingsSearchText)
                } else {
                    CalmSettingsPageView(destination: navigator.settingsDestination)
                        .id(navigator.settingsDestination)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .bottom) { CalmSearchHintBanner() }

            Button { navigator.closeSettings() } label: {
                CalmIcon(.close, size: 16)
            }
            .calmIconButton()
            // While the search field has text, Esc clears it first (the
            // field's own exit command); a dialog takes Esc for itself.
            .keyboardShortcut(isDialogPresented || !navigator.settingsSearchText.isEmpty ? nil : .cancelAction)
            .padding(14)
            .accessibilityLabel("Close settings")
        }
    }
}

/// The sheet menu: search, SETTINGS and DATA groups, and the version
/// footer with its update button.
struct CalmSettingsMenu: View {
    var isSearchFocused: FocusState<Bool>.Binding

    @EnvironmentObject private var appState: AppState
    @Environment(CalmNavigator.self) private var navigator

    var body: some View {
        @Bindable var navigator = navigator
        VStack(alignment: .leading, spacing: CalmMetrics.navItemSpacing) {
            CalmSearchField(text: $navigator.settingsSearchText, prompt: "Search settings", focus: isSearchFocused) {
                if let first = CalmNavigation.searchGroups(for: navigator.settingsSearchText).first?.entries.first {
                    navigator.open(first)
                }
            }
            .padding(.bottom, 18)

            ForEach(CalmSettingsMenuGroup.allCases) { group in
                CalmCaption(group.title)
                    .padding(.horizontal, 10)
                    .padding(.top, group == .settings ? 0 : 18)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) {
                        if group != .settings { Rectangle().fill(CalmColor.line).frame(height: 1) }
                    }
                    .padding(.top, group == .settings ? 0 : 10)
                ForEach(group.items) { item in
                    CalmNavItem(
                        title: item.title, icon: item.icon,
                        isSelected: !navigator.isSearching && navigator.settingsDestination.menuItem == item
                    ) {
                        navigator.select(item)
                    }
                }
            }

            Spacer(minLength: 12)

            HStack {
                Button("VocaMac \(Self.appVersion)") { navigator.select(.about) }
                    .calmLink(muted: true, font: CalmFont.note)
                    .fontWeight(.regular)
                    .accessibilityLabel("About VocaMac \(Self.appVersion)")
                Spacer(minLength: 8)
                updateButton
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
        }
        .padding(CalmMetrics.sheetMenuPadding)
    }

    @ViewBuilder
    private var updateButton: some View {
        if appState.updateChecker.updateState == .checking {
            CalmSpinner(size: 15)
                .frame(width: 28, height: 28)
        } else {
            Button {
                navigator.select(.about)
                Task { await appState.updateChecker.checkForUpdates() }
            } label: {
                CalmIcon(.update, size: 15)
            }
            .calmIconButton(size: 28)
            .accessibilityLabel("Check for updates")
            .help("Check for updates")
        }
    }

    /// The app's version, as the About page shows it.
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}

// MARK: - Search results

/// Settings search results in the sheet body, grouped by destination.
/// Picking one goes there and flashes the control.
struct CalmSettingsSearchResults: View {
    let query: String

    @Environment(CalmNavigator.self) private var navigator

    var body: some View {
        let groups = CalmNavigation.searchGroups(for: query)
        CalmPage(.sheet) {
            CalmPageHeader("Search", description: summary(count: groups.reduce(0) { $0 + $1.entries.count }))
            if groups.isEmpty {
                CalmNoResults(message: "No settings match “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”.") {
                    navigator.settingsSearchText = ""
                }
            } else {
                ForEach(groups, id: \.destination) { group in
                    CalmGroup(groupTitle(group.destination)) {
                        CalmPanel {
                            ForEach(group.entries) { entry in
                                CalmSearchResultRow(entry: entry) { navigator.open(entry) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func summary(count: Int) -> String {
        count == 1 ? "1 result" : "\(count) results"
    }

    private func groupTitle(_ destination: CalmDestination) -> String {
        switch destination {
        case .main(let page): return page.title
        case .settings(let page):
            guard let parent = page.parent else { return page.title }
            return "\(parent.title) › \(page.title)"
        }
    }
}

private struct CalmSearchResultRow: View {
    let entry: SettingsSearchEntry
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: CalmMetrics.rowSpacing) {
                CalmRowLabel(title: entry.title) {
                    if let subtitle = entry.subtitle {
                        Text(subtitle).calmType(.description).lineLimit(2)
                    }
                }
                CalmIcon(.chevRight, size: 14).foregroundStyle(isHovered ? CalmColor.ink : CalmColor.muted)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, CalmMetrics.rowInset)
            .contentShape(Rectangle())
        }
        .buttonStyle(CalmPlainFocusStyle(radius: CalmMetrics.Radius.panel))
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .accessibilityLabel(entry.subtitle.map { "\(entry.title), \($0)" } ?? entry.title)
    }
}

/// The hint some search results leave behind (“Choose an app under …”).
private struct CalmSearchHintBanner: View {
    @Environment(CalmNavigator.self) private var navigator

    var body: some View {
        if let hint = navigator.searchHint {
            HStack(spacing: 10) {
                CalmInlineNotice(hint, tone: .info)
                Button { navigator.dismissSearchHint() } label: { CalmIcon(.close, size: 12, weight: 2) }
                    .calmIconButton(size: 24)
                    .accessibilityLabel("Dismiss hint")
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(Capsule().fill(CalmColor.content).shadow(color: .black.opacity(0.12), radius: 10, y: 4))
            .overlay(Capsule().strokeBorder(CalmColor.line2, lineWidth: 1))
            .padding(.bottom, 18)
            .transition(.opacity)
        }
    }
}
