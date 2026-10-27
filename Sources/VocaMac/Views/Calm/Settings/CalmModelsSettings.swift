// CalmModelsSettings.swift
// VocaMac
//
// Settings › Models: the Speech to text and Writing AI tabs (three pick
// cards each, the model in use, Browse all), and the All models sub-page
// with search, the language filter and family groups.

import SwiftUI

/// Settings › Models: the model picker. Its tab lives on the navigator
/// (`CalmNavigator.modelsTab`) so other pages can open Writing AI.
struct CalmModelsSettings: View {
    @EnvironmentObject private var appState: AppState
    @Environment(CalmNavigator.self) private var navigator

    var body: some View {
        @Bindable var navigator = navigator
        CalmPage(.sheet) {
            VStack(alignment: .leading, spacing: 18) {
                CalmPageHeader("Models")
                CalmTabs(selection: $navigator.modelsTab, tabs: CalmModelsTab.allCases.map { CalmOption($0, $0.title) })
            }
            switch navigator.modelsTab {
            case .speech: CalmSpeechModelsTab()
            case .writing: CalmWritingModelsTab()
            }
        }
        // “Choose a model that translates” lands on All models, searched.
        .onChange(of: appState.requestedSpeechModelSearch, initial: true) { _, search in
            guard search != nil else { return }
            navigator.modelsTab = .speech
            navigator.select(.allModels)
        }
    }
}

// MARK: - Speech to text

/// The Speech to text tab: three cards picked for the user's languages,
/// the model in use when it isn't one of them, and Browse all.
struct CalmSpeechModelsTab: View {
    @EnvironmentObject private var appState: AppState
    @Environment(CalmNavigator.self) private var navigator
    @State private var flow = CalmSpeechPickFlow()

    private var picker: CalmModelPicker { .shared }

    var body: some View {
        let picks = appState.calmSpeechPicks
        let inUse = appState.calmSpeechModelInUse
        let selected = picker.pendingSpeech ?? inUse?.size
        VStack(alignment: .leading, spacing: CalmMetrics.sheetGap) {
            if let message = appState.errorMessage {
                CalmErrorNotice(message: message) { appState.calmDismissError() }
            }
            intro
            HStack(alignment: .top, spacing: 12) {
                ForEach(picks, id: \.self) { pick in
                    card(pick, picks: picks, isSelected: selected == pick.model)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .settingsTarget("models")
            if let selected, !picks.contains(where: { $0.model == selected }),
               let model = appState.availableModels.first(where: { $0.size == selected }) {
                inUseRow(model)
            }
            CalmPanel {
                CalmLinkRow(title: "Browse all \(appState.availableModels.count) models") {
                    navigator.select(.allModels)
                }
            }
            CalmModelsOnThisMac(tab: .speech(flow))
        }
        .calmSpeechPickDialogs(flow)
        .task { await appState.refreshAppleSpeechLanguages() }
    }

    private var intro: some View {
        let spoken = appState.spokenLanguages
        return HStack(spacing: 4) {
            Text(spoken.isEmpty ? "Picked for this Mac." : "Picked for \(SpokenLanguages.list(spoken)).")
                .foregroundStyle(CalmColor.ink2)
            Button { navigator.select(.languages) } label: {
                Text(spoken.isEmpty ? "Choose your languages" : "Change languages").underline()
            }
            .buttonStyle(CalmPlainFocusStyle(radius: 4))
            .focusEffectDisabled()
            .foregroundStyle(CalmColor.muted)
        }
        .font(CalmFont.body)
    }

    private func card(_ pick: CalmModelPick<ModelSize>, picks: [CalmModelPick<ModelSize>], isSelected: Bool) -> some View {
        let size = pick.model
        let model = appState.availableModels.first { $0.size == size }
        let state = model.map {
            CalmSpeechModelState(model: $0, failed: picker.failedSpeech == size, endpointIsValid: appState.calmSpeechEndpointIsValid)
        } ?? .needsDownload
        return CalmPickCard(
            kind: pick.slot.title,
            name: CalmModelText.name(size),
            variant: CalmModelText.variant(size, isBundled: appState.modelManager.bundledModelFolder(for: size) != nil),
            logo: CalmLogoName(engine: size.engine),
            reason: CalmModelPicks.reason(for: pick, among: picks, languages: appState.spokenLanguages),
            footer: Self.footer(for: state, size: size),
            isSelected: isSelected,
            onPick: { flow.pick(size, appState: appState) },
            onCancel: { picker.cancelSpeechDownload(size, appState: appState) },
            onRetry: { flow.pick(size, appState: appState) }
        )
        .contextMenu { CalmSpeechModelMenu(size: size, flow: flow) }
    }

    static func footer(for state: CalmSpeechModelState, size: ModelSize) -> CalmPickCardFooter {
        switch state {
        case .downloading(let progress): return .downloading(progress)
        case .loading(let status): return .loading(CalmSpeechModelsTab.loadingText(status))
        case .failed: return .failed
        case .needsDownload: return .downloadsWhenPicked(size: CalmModelText.downloadSize(size))
        case .inUse, .onThisMac, .needsSetup, .server:
            return size.isSystemManaged ? .builtIn : .onThisMac(size: CalmModelText.downloadSize(size))
        }
    }

    /// “Getting ready…”, or the first-load warning when macOS compiles the model.
    static func loadingText(_ status: String) -> String {
        status == ModelSize.firstLoadStatus ? "First load, can take minutes…" : "Getting ready…"
    }

    private func inUseRow(_ model: WhisperModelInfo) -> some View {
        let state = CalmSpeechModelState(model: model, failed: false, endpointIsValid: appState.calmSpeechEndpointIsValid)
        let name = CalmModelText.name(model.size)
        switch state {
        case .downloading(let progress):
            return CalmInUseRow(name: name, state: "Downloading \(Int((progress * 100).rounded()))%", isLoading: true)
        case .loading(let status):
            return CalmInUseRow(name: name, state: Self.loadingText(status), isLoading: true)
        default:
            return CalmInUseRow(name: name)
        }
    }
}

/// The menu on a speech card or row: Use, Show details, Remove from this Mac.
struct CalmSpeechModelMenu: View {
    let size: ModelSize
    let flow: CalmSpeechPickFlow

    @EnvironmentObject private var appState: AppState

    var body: some View {
        let model = appState.availableModels.first { $0.size == size }
        Button { flow.pick(size, appState: appState) } label: { Label("Use this model", systemImage: "checkmark") }
            .disabled(model?.isActive == true || model?.downloadProgress != nil)
        if size.isRemotelyHosted {
            Button { flow.showsServer = true } label: { Label("Server settings…", systemImage: "server.rack") }
        }
        Button { flow.prompt = .details(size) } label: { Label("Show details", systemImage: "info.circle") }
        // From the files, not the picker entry: an older download the
        // picker no longer lists still has a folder to show.
        if let folder = CalmModelFiles.location(of: .speech(size), appState: appState) {
            Button { CalmModelFiles.reveal(folder) } label: { Label("Show in Finder", systemImage: "folder") }
        }
        if model?.downloadProgress != nil {
            Button { CalmModelPicker.shared.cancelSpeechDownload(size, appState: appState) } label: {
                Label("Cancel download", systemImage: "xmark")
            }
        }
        if let model, CalmSpeechPickFlow.canRemove(model) {
            Divider()
            Button(role: .destructive) { flow.prompt = .remove(size) } label: {
                Label("Remove from this Mac  \(CalmModelText.downloadSize(size))", systemImage: "trash")
            }
        }
    }
}

// MARK: - Writing AI

/// The Writing AI tab: three cards over the cleanup and Command Mode
/// models, what Command Mode uses, sharing, Browse all, and where
/// cleanup runs.
struct CalmWritingModelsTab: View {
    @EnvironmentObject private var appState: AppState
    @Environment(CalmNavigator.self) private var navigator
    @State private var flow = CalmWritingPickFlow()

    private var picker: CalmModelPicker { .shared }

    private var isDownloading: Bool {
        if case .downloading = appState.transcriptCleanup.modelState { return true }
        return false
    }

    var body: some View {
        let picks = appState.calmWritingPicks
        let isLocal = appState.cleanupEndpoint.isLocal
        let selected = picker.pendingWriting ?? appState.calmCleanupModelInUse
        VStack(alignment: .leading, spacing: CalmMetrics.sheetGap) {
            Text(isLocal
                 ? "Used by Smart Cleanup and Command Mode. Runs on this Mac."
                 : "Smart Cleanup runs on your \(appState.cleanupEndpoint.provider.displayName) server. These models run on this Mac.")
                .font(CalmFont.body)
                .foregroundStyle(CalmColor.ink2)
            HStack(alignment: .top, spacing: 12) {
                ForEach(picks, id: \.self) { pick in
                    card(pick, isSelected: selected == pick.model)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .settingsTarget("command-mode-models")
            if !isLocal, picker.pendingWriting == nil {
                CalmInUseRow(
                    name: "your \(appState.cleanupEndpoint.provider.displayName) server",
                    detail: "Set under Where cleanup runs"
                )
            } else if let selected, !picks.contains(where: { $0.model == selected }) {
                CalmInUseRow(name: CalmModelText.name(selected))
            }
            // Browse all belongs to the cards, as on the Speech to text tab.
            CalmPanel {
                CalmLinkRow(title: "Browse all \(CleanupModelKind.cleanupChoices.count) models") {
                    navigator.modelsTab = .writing
                    navigator.select(.allModels)
                }
            }
            CalmPanel {
                commandModeRow
                if appState.calmCommandModeChoice == .own || appState.calmCommandModeChoice == .onThisMac {
                    commandModeModelRow
                }
                if appState.suggestsSharingAIModel {
                    sharingSuggestion
                }
            }
            CalmPanel {
                CalmRow("Where cleanup runs") {
                    if let problem = appState.cleanupEndpoint.validationProblem() {
                        CalmInlineNotice(problem, tone: .warning)
                    } else {
                        CalmRowDescription(text: whereCleanupRuns)
                    }
                } trailing: {
                    Button("Change") { flow.showsCleanupServer = true }.calmButton(.secondary)
                }
                .settingsTarget("cleanup-provider")
            }
            CalmModelsOnThisMac(tab: .writing(flow))
        }
        .calmWritingPickDialogs(flow)
    }

    private func card(_ pick: CalmModelPick<CleanupModelKind>, isSelected: Bool) -> some View {
        let kind = pick.model
        let state = CalmWritingModelState(kind: kind, appState: appState, failed: picker.failedWriting == kind)
        let size = CalmModelText.downloadSize(kind)
        let footer: CalmPickCardFooter
        switch state {
        case .downloading(let progress): footer = .downloading(progress)
        case .loading: footer = .loading("Getting ready…")
        case .failed: footer = .failed
        case .needsDownload: footer = .downloadsWhenPicked(size: size)
        case .inUse, .commandModeOnly, .onThisMac: footer = .onThisMac(size: size)
        }
        return CalmPickCard(
            kind: pick.slot.title,
            name: CalmModelText.name(kind),
            // No variant: the reason already starts “Cleanup only”.
            logo: kind == .ministral3_3b_q4_k_m ? .ministral : .qwen,
            reason: CalmModelPicks.reason(for: kind, languages: appState.spokenLanguages),
            footer: footer,
            isSelected: isSelected,
            onPick: { flow.pick(kind, appState: appState) },
            onCancel: { picker.cancelWritingDownload(appState: appState) },
            onRetry: { flow.pick(kind, appState: appState) }
        )
        .contextMenu { CalmWritingModelMenu(kind: kind, flow: flow) }
    }

    private var whereCleanupRuns: String {
        let endpoint = appState.cleanupEndpoint
        return endpoint.isLocal ? "On this Mac" : "\(endpoint.provider.displayName) · \(endpoint.resolvedModel)"
    }

    // MARK: Command Mode

    private var commandModeRow: some View {
        let options = appState.calmCommandModeOptions
        let provider = appState.cleanupEndpoint.provider
        // The choices sit under the note, not beside it: three labels like
        // “Apple Intelligence” don't fit next to a two-line note and were
        // truncated to “Apple Intel…”.
        return CalmRow("Command Mode uses") {
            VStack(alignment: .leading, spacing: 12) {
                CalmRowDescription(text: commandModeNote)
                if options.count > 1 {
                    CalmSegmentedControl(
                        selection: Binding(
                            get: { appState.calmCommandModeChoice },
                            set: { choice in Task { await appState.selectCalmCommandModeChoice(choice) } }
                        ),
                        options: options.map { CalmOption($0, $0.title(provider: provider)) },
                        accessibilityLabel: "Command Mode uses"
                    )
                    .fixedSize()
                    .disabled(isDownloading)
                }
            }
        } trailing: {
            EmptyView()
        }
        .settingsTarget("command-mode-share", aliases: ["command-mode-model"])
    }

    /// One sentence on what Command Mode runs now.
    private var commandModeNote: String {
        let cleanupName = CalmModelText.name(appState.selectedCleanupModelKind)
        switch appState.calmCommandModeChoice {
        case .same:
            return "\(cleanupName) does both jobs"
        case .own:
            guard case .local(let kind) = appState.commandModeEngine else { return "" }
            if kind == appState.selectedCleanupModelKind {
                return "Both use \(cleanupName) for now. Picking a model for one won’t change the other."
            }
            return appState.usesSeparateCommandSlot(for: kind)
                ? "\(CalmModelText.name(kind)). This Mac has room to keep both loaded."
                : "\(CalmModelText.name(kind)). The two take turns in memory, so an edit starts slower."
        case .onThisMac:
            return "\(CalmModelText.name(appState.calmCommandModeLocalCandidate)) on this Mac"
        case .appleIntelligence:
            return "Built into macOS. No download."
        case .server:
            return "Your \(appState.cleanupEndpoint.provider.displayName) server, like Smart Cleanup"
        }
    }

    private var commandModeModelRow: some View {
        let current = appState.calmCommandModeLocalCandidate
        let isMissing = !appState.transcriptCleanup.isDownloaded(current)
        return CalmRow("Model for Command Mode", description: commandModeModelNote(current)) {
            HStack(spacing: 8) {
                // The dropdown can't re-pick the model it shows, so a
                // missing one gets its own way to download.
                if isMissing && !isDownloading {
                    Button("Download") { flow.pick(current, role: .commandMode, appState: appState) }
                        .calmButton(.secondary)
                        .fixedSize()
                        .help("Download \(CalmModelText.name(current)) (\(CalmModelText.downloadSize(current))) for Command Mode")
                }
                CalmDropdown(
                    selection: Binding(
                        get: { current },
                        set: { kind in flow.pick(kind, role: .commandMode, appState: appState) }
                    ),
                    // Names only: the note under the row gives a missing
                    // model's size, and a long label squeezed Download away.
                    options: CleanupModelKind.commandModeChoices.map { CalmOption($0, CalmModelText.name($0)) }
                )
                .disabled(isDownloading)
            }
        }
    }

    private func commandModeModelNote(_ kind: CleanupModelKind) -> String? {
        if picker.pendingCommandMode != nil, case .downloading(let active, let progress) = appState.transcriptCleanup.modelState {
            return "Downloading \(CalmModelText.name(active)) · \(Int((progress * 100).rounded()))%"
        }
        if !appState.transcriptCleanup.isDownloaded(kind) {
            return "Not downloaded yet (\(CalmModelText.downloadSize(kind))). Command Mode can’t edit until it is."
        }
        return nil
    }

    private var sharingSuggestion: some View {
        let kind = appState.sharedAIModelCandidate
        return CalmStatusRow("One model can do both", description: sharingDetail(for: kind), tone: .info) {
            HStack(spacing: 6) {
                Button("Keep separate") { Task { await appState.setSharesAIModel(false) } }
                    .calmButton(.quiet, size: .small)
                Button("Use for both") { Task { await appState.setSharesAIModel(true) } }
                    .calmButton(.secondary, size: .small)
            }
            .disabled(isDownloading)
        }
    }

    /// What sharing saves, and what it costs when the shared model is
    /// slower at cleanup than the one in use.
    private func sharingDetail(for kind: CleanupModelKind) -> String {
        var text = "\(CalmModelText.name(kind)) could run Smart Cleanup and Command Mode: one download, one model in memory."
        let current = appState.selectedCleanupModelKind
        if kind != current, kind.isSlowForCleanup || kind.descriptor.ramRequiredGB > current.descriptor.ramRequiredGB {
            text += " Cleanup takes a little longer per dictation."
        }
        if !appState.transcriptCleanup.isDownloaded(kind) {
            text += " Downloads \(CalmModelText.downloadSize(kind))."
        }
        return text
    }
}

/// The menu on a writing card or row.
struct CalmWritingModelMenu: View {
    let kind: CleanupModelKind
    let flow: CalmWritingPickFlow

    @EnvironmentObject private var appState: AppState

    private var isDownloading: Bool {
        if case .downloading = appState.transcriptCleanup.modelState { return true }
        return false
    }

    var body: some View {
        let downloaded = appState.transcriptCleanup.isDownloaded(kind)
        Button { flow.pick(kind, appState: appState) } label: { Label("Use this model", systemImage: "checkmark") }
            .disabled(CalmWritingPickFlow.isInUse(kind, role: .cleanup, appState: appState))
        if appState.sharesAIModel, kind.supportsCommandMode {
            Button { flow.pick(kind, role: .cleanupOnly, appState: appState) } label: {
                Label("Use for Smart Cleanup only", systemImage: "sparkles")
            }
        }
        if kind.supportsCommandMode, !CalmWritingPickFlow.isInUse(kind, role: .commandMode, appState: appState) {
            Button { flow.pick(kind, role: .commandMode, appState: appState) } label: {
                Label("Use for Command Mode only", systemImage: "wand.and.stars")
            }
        }
        if !downloaded {
            Button { CalmModelPicker.shared.downloadWritingOnly(kind, appState: appState) } label: {
                Label("Download only  \(CalmModelText.downloadSize(kind))", systemImage: "arrow.down")
            }
            .disabled(isDownloading)
        }
        Button { flow.prompt = .details(kind) } label: { Label("Show details", systemImage: "info.circle") }
        if let file = CalmModelFiles.location(of: .writing(kind), appState: appState) {
            Button { CalmModelFiles.reveal(file) } label: { Label("Show in Finder", systemImage: "folder") }
        }
        if case .downloading(let active, _) = appState.transcriptCleanup.modelState, active == kind {
            Button { CalmModelPicker.shared.cancelWritingDownload(appState: appState) } label: {
                Label("Cancel download", systemImage: "xmark")
            }
        }
        if CalmWritingPickFlow.canRemove(kind, appState: appState) {
            Divider()
            Button(role: .destructive) { flow.prompt = .remove(kind) } label: {
                Label("Remove from this Mac  \(CalmModelText.downloadSize(kind))", systemImage: "trash")
            }
        }
    }
}

// MARK: - All models

/// Settings › Models › All models (sub-page): every speech or writing
/// model, by the tab it was opened from.
struct CalmAllModelsSettings: View {
    @Environment(CalmNavigator.self) private var navigator

    var body: some View {
        switch navigator.modelsTab {
        case .speech: CalmAllSpeechModels()
        case .writing: CalmAllWritingModels()
        }
    }
}

/// All speech models: search, the “Only for my languages” filter (on by
/// default), and one panel with a group per family.
struct CalmAllSpeechModels: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.settingsSearchTarget) private var searchTarget
    @State private var search = ""
    @State private var onlyMine = true
    @State private var onlyDownloaded = false
    @State private var flow = CalmSpeechPickFlow()
    /// Measured off the main thread when the page opens.
    @State private var storage: CalmModelStorage?

    private var picker: CalmModelPicker { .shared }

    var body: some View {
        let spoken = appState.spokenLanguages
        let selected = picker.pendingSpeech ?? appState.calmSpeechModelInUse?.size
        let groups = CalmSpeechFamily.groups(listed(spoken: spoken, selected: selected))
        VStack(alignment: .leading, spacing: CalmMetrics.sheetGap) {
            CalmSubPageHeader("All speech models")
            if let message = appState.errorMessage {
                CalmErrorNotice(message: message) { appState.calmDismissError() }
            }
            HStack(spacing: 16) {
                CalmSearchField(text: $search, prompt: "Search models")
                if !spoken.isEmpty {
                    CalmFilterSwitch(title: "Works with \(SpokenLanguages.list(spoken))", isOn: $onlyMine)
                        .accessibilityLabel("Only models that work with my languages")
                }
                CalmFilterSwitch(title: "Downloaded", isOn: $onlyDownloaded)
                    .accessibilityLabel("Only models on this Mac")
            }
            if groups.isEmpty {
                CalmNoResults(message: noResults) { search = ""; onlyDownloaded = false }
                    .calmPanelBackground()
            } else {
                list(groups, spoken: spoken, selected: selected)
            }
            Text("Models download from Hugging Face and stay on this Mac" + (storage.map { " · \(CalmModelText.size(bytes: $0.totalBytes)) used" } ?? ""))
                .font(CalmFont.note)
                .foregroundStyle(CalmColor.muted)
        }
        .padding(CalmMetrics.sheetBodyPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .calmSpeechPickDialogs(flow)
        .task { await appState.refreshAppleSpeechLanguages() }
        .task(id: appState.calmDownloadedSpeechModels) { storage = await appState.calmMeasureModelStorage() }
        .onChange(of: appState.requestedSpeechModelSearch, initial: true) { _, request in
            guard let request else { return }
            search = request
            onlyMine = false
            appState.requestedSpeechModelSearch = nil
        }
    }

    private var noResults: String {
        if search.isEmpty { return "No downloaded models match these filters." }
        return "No models match “\(search)”."
    }

    private func listed(spoken: [String], selected: ModelSize?) -> [ModelSize] {
        let downloaded = Set(appState.calmDownloadedSpeechModels)
        return appState.availableModels.map(\.size).filter { size in
            guard ModelPickerCatalog.matches(size, search: search, systemLanguages: appState.appleSpeechLanguages) else { return false }
            guard !onlyDownloaded || downloaded.contains(size) || size == selected else { return false }
            guard onlyMine, size != selected else { return true }
            return ModelPickerCatalog.fit(of: size, for: spoken, systemLanguages: appState.appleSpeechLanguages).coversAll
        }
    }

    private func list(_ groups: [(family: CalmSpeechFamily, models: [ModelSize])], spoken: [String], selected: ModelSize?) -> some View {
        let shape = RoundedRectangle(cornerRadius: CalmMetrics.Radius.panel, style: .continuous)
        return ScrollViewReader { proxy in
            // Hug short lists; scroll inside the panel when they run long.
            CalmFittingScrollView { rows(groups, spoken: spoken, selected: selected) }
                .scrollContentBackground(.hidden)
            .task(id: searchTarget) {
                guard searchTarget == "custom-endpoint" else { return }
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo("custom-endpoint", anchor: .center) }
            }
        }
        .background(shape.fill(CalmColor.panel))
        .clipShape(shape)
    }

    private func rows(_ groups: [(family: CalmSpeechFamily, models: [ModelSize])], spoken: [String], selected: ModelSize?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.family) { index, group in
                CalmFamilyBlock(
                    logo: CalmLogoName(engine: group.models[0].engine),
                    title: group.family.title, blurb: group.family.blurb, isFirst: index == 0
                ) {
                    ForEach(group.models, id: \.self) { size in
                        row(size, spoken: spoken, isSelected: selected == size)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ size: ModelSize, spoken: [String], isSelected: Bool) -> some View {
        if let model = appState.availableModels.first(where: { $0.size == size }) {
            let state = CalmSpeechModelState(
                model: model, failed: picker.failedSpeech == size, endpointIsValid: appState.calmSpeechEndpointIsValid
            )
            let modelRow = CalmModelRow(
                name: CalmModelText.name(size),
                variant: CalmModelText.variant(size, isBundled: appState.modelManager.bundledModelFolder(for: size) != nil),
                meta: CalmModelText.meta(size, systemLanguages: appState.appleSpeechLanguages),
                warning: CalmModelText.misfit(size, spoken: spoken, systemLanguages: appState.appleSpeechLanguages)
                    ?? fitWarning(size, isDownloaded: model.isDownloaded),
                tag: model.isSupported ? nil : "Experimental",
                isSelected: isSelected,
                trailing: Self.trailing(for: state, size: size),
                onPick: { flow.pick(size, appState: appState) },
                onCancel: { picker.cancelSpeechDownload(size, appState: appState) },
                menu: { CalmSpeechModelMenu(size: size, flow: flow) }
            )
            if size.isRemotelyHosted {
                modelRow.settingsTarget("custom-endpoint")
            } else {
                modelRow
            }
        }
    }

    /// Memory first (it can't be fixed), then room for a download.
    private func fitWarning(_ size: ModelSize, isDownloaded: Bool) -> String? {
        if let memory = appState.calmMemoryFit(size)?.warning(requiredGB: size.firstLoadRAMRequiredGB, memoryGB: appState.calmMemoryGB) {
            return memory
        }
        guard !isDownloaded, let free = storage?.freeBytes else { return nil }
        return CalmModelText.diskWarning(required: ModelManager.requiredDownloadBytes(for: size), free: free)
    }

    static func trailing(for state: CalmSpeechModelState, size: ModelSize) -> CalmModelRowTrailing {
        switch state {
        case .inUse: return .inUse()
        case .loading(let status): return .loading(CalmSpeechModelsTab.loadingText(status))
        case .downloading(let progress): return .downloading(progress)
        case .failed: return .failed
        case .onThisMac: return .text(size.isSystemManaged ? "Built into macOS" : "On this Mac")
        case .needsDownload: return .download(size: CalmModelText.downloadSize(size))
        case .needsSetup: return .setUp("Set up")
        case .server: return .setUp("Change")
        }
    }
}

/// All writing models: search and one panel of the on-device models.
struct CalmAllWritingModels: View {
    @EnvironmentObject private var appState: AppState
    @State private var search = ""
    @State private var onlyDownloaded = false
    @State private var flow = CalmWritingPickFlow()
    @State private var freeBytes: Int64?

    private var picker: CalmModelPicker { .shared }

    var body: some View {
        let kinds = CleanupModelKind.cleanupChoices.filter { matches($0) && (!onlyDownloaded || appState.transcriptCleanup.isDownloaded($0)) }
        let selected = picker.pendingWriting ?? appState.calmCleanupModelInUse
        VStack(alignment: .leading, spacing: CalmMetrics.sheetGap) {
            CalmSubPageHeader("All writing models")
            HStack(spacing: 16) {
                CalmSearchField(text: $search, prompt: "Search models")
                CalmFilterSwitch(title: "Downloaded", isOn: $onlyDownloaded)
                    .accessibilityLabel("Only models on this Mac")
            }
            if kinds.isEmpty {
                CalmNoResults(message: search.isEmpty ? "No writing models are downloaded yet." : "No models match “\(search)”.") {
                    search = ""
                    onlyDownloaded = false
                }
                    .calmPanelBackground()
            } else {
                CalmFittingScrollView { family(kinds, selected: selected) }
                    .scrollContentBackground(.hidden)
                    .calmPanelBackground()
                .clipShape(RoundedRectangle(cornerRadius: CalmMetrics.Radius.panel, style: .continuous))
            }
            Text("Models download from Hugging Face and stay on this Mac. Smart Cleanup and Command Mode can share one.")
                .font(CalmFont.note)
                .foregroundStyle(CalmColor.muted)
            Spacer(minLength: 0)
        }
        .padding(CalmMetrics.sheetBodyPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .calmWritingPickDialogs(flow)
        .task { freeBytes = await appState.calmMeasureModelStorage().freeBytes }
    }

    private func family(_ kinds: [CleanupModelKind], selected: CleanupModelKind?) -> some View {
        CalmFamilyBlock(logo: .qwen, title: "Qwen and Ministral", blurb: "Run on this Mac", isFirst: true) {
            ForEach(kinds) { kind in
                row(kind, isSelected: selected == kind)
            }
        }
    }

    private func matches(_ kind: CleanupModelKind) -> Bool {
        let words = search.lowercased().split(whereSeparator: \.isWhitespace)
        let fields = [CalmModelText.name(kind), kind.creator.displayName, kind.descriptor.summary].map { $0.lowercased() }
        // Every word somewhere (“qwen 4b”), as speech model search does.
        return words.allSatisfy { word in fields.contains { $0.contains(word) } }
    }

    private func row(_ kind: CleanupModelKind, isSelected: Bool) -> some View {
        let state = CalmWritingModelState(kind: kind, appState: appState, failed: picker.failedWriting == kind)
        let trailing: CalmModelRowTrailing
        switch state {
        case .inUse: trailing = .inUse(appState.sharesAIModel ? "In use for both" : "In use")
        case .commandModeOnly: trailing = .text("Used by Command Mode")
        case .loading: trailing = .loading("Getting ready…")
        case .downloading(let progress): trailing = .downloading(progress)
        case .failed: trailing = .failed
        case .onThisMac: trailing = .text("On this Mac")
        case .needsDownload: trailing = .download(size: CalmModelText.downloadSize(kind))
        }
        let downloadWarning = state == .needsDownload
            ? freeBytes.flatMap { CalmModelText.diskWarning(required: kind.descriptor.expectedByteCount + 200_000_000, free: $0) }
            : nil
        return CalmModelRow(
            name: CalmModelText.name(kind),
            variant: CalmModelText.variant(kind),
            meta: CalmModelText.meta(kind),
            warning: appState.calmMemoryFit(kind).warning(requiredGB: kind.descriptor.ramRequiredGB, memoryGB: appState.calmMemoryGB)
                ?? downloadWarning,
            isSelected: isSelected,
            trailing: trailing,
            onPick: { flow.pick(kind, appState: appState) },
            onCancel: { picker.cancelWritingDownload(appState: appState) },
            menu: { CalmWritingModelMenu(kind: kind, flow: flow) }
        )
    }
}

/// A filter label and switch beside a search field.
struct CalmFilterSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(CalmFont.description)
                .foregroundStyle(CalmColor.ink2)
                .lineLimit(1)
            CalmSwitch(isOn: $isOn)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
