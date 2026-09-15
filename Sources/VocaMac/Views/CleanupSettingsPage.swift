// CleanupSettingsPage.swift
// VocaMac
//
// Settings for optional on-device transcript cleanup.

import SwiftUI

struct CleanupSettingsPage: View {
    @EnvironmentObject var appState: AppState
    @State private var promptDraft: String = ""
    @State private var didLoadPrompt = false
    @State private var promptCommit: Task<Void, Never>?
    @State private var tryItInput = CleanupSettingsPage.sampleUtterance
    @State private var tryItResult: CleanupTryResult?
    @State private var tryItRunning = false
    @State private var isPromptExpanded = false
    @State private var isInferenceExpanded = false
    @State private var isCommandModeExpanded = false
    @State private var isMoreModelsExpanded = false
    @State private var apiKeyDraft = ""
    @State private var endpointNotice: String?

    /// Seeded with something that exercises the behaviours the models differ
    /// on: fillers, a stutter, and dictated punctuation.
    static let sampleUtterance =
        "so um i was i was thinking we could ship it on friday comma "
        + "maybe after the review you know"

    var body: some View {
        VocaSettingsPageContent {
            // The two features, what each one runs, and whether it's ready.
            // People used to piece this together from two separate model
            // lists, and assumed a model picked for one also ran the other.
            VocaSettingsGroup("Cleanup and Command Mode") {
                AIFeatureRow(
                    title: "Smart Cleanup",
                    detail: "Tidies every dictation after it's transcribed.",
                    systemImage: "sparkles",
                    tint: VocaDesign.accentSolid
                ) {
                    AIModelMenu(role: .cleanup)
                    Toggle("Smart Cleanup", isOn: $appState.transcriptCleanupEnabled)
                        .labelsHidden()
                } status: {
                    cleanupStatus
                }

                Divider()

                AIFeatureRow(
                    title: "Command Mode",
                    detail: "Edits text you select, when you ask.",
                    systemImage: "wand.and.stars",
                    tint: VocaDesign.command
                ) {
                    AIModelMenu(role: .commandMode)
                } status: {
                    commandStatus
                }

                if appState.cleanupEndpoint.isLocal {
                    Divider()
                    SettingsToggleRow(
                        title: "Use one model for both",
                        detail: sharingDetail,
                        isOn: Binding(
                            get: { appState.sharesAIModel },
                            set: { shared in
                                Task { @MainActor in await appState.setSharesAIModel(shared) }
                            }
                        )
                    )
                    .disabled(isDownloading)
                }

                downloadProgressLine
            }

            VocaSettingsGroup("Cleanup Level") {
                Picker("Cleanup level", selection: $appState.transcriptCleanupLevel) {
                    ForEach(CleanupLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                Text(appState.transcriptCleanupLevel.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            modelLibrary

            VocaDisclosureCard(
                title: "Inference",
                subtitle: "Where cleanup runs: on this Mac or an endpoint you choose.",
                systemImage: "cpu",
                badge: appState.cleanupEndpoint.provider.displayName,
                isExpanded: $isInferenceExpanded
            ) {
                Picker("Run cleanup with", selection: endpointProvider) {
                    ForEach(CleanupProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                if !appState.cleanupEndpoint.isLocal {
                    TextField("Base URL", text: endpointBaseURL)
                        .textFieldStyle(.roundedBorder)
                    TextField("Model", text: endpointModel)
                        .textFieldStyle(.roundedBorder)
                    SecureField(
                        appState.cleanupEndpointHasAPIKey ? "API key saved in Keychain" : "API key (optional for local servers)",
                        text: $apiKeyDraft
                    )
                    HStack {
                        Button("Save API Key") {
                            do {
                                try appState.saveCleanupAPIKey(apiKeyDraft)
                                apiKeyDraft = ""
                                endpointNotice = "API key saved in Keychain."
                            } catch {
                                endpointNotice = "Could not save the key: \(error.localizedDescription)"
                            }
                        }
                        .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if appState.cleanupEndpointHasAPIKey {
                            Button("Remove Key", role: .destructive) {
                                do {
                                    try appState.deleteCleanupAPIKey()
                                    endpointNotice = "API key removed."
                                } catch {
                                    endpointNotice = "Could not remove the key: \(error.localizedDescription)"
                                }
                            }
                        }
                        Spacer()
                    }
                    if let problem = appState.cleanupEndpoint.validationProblem() {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("Only the cleanup prompt and transcript text are sent when this provider is selected. Use HTTPS whenever the endpoint is not on this Mac. Cleanup endpoint settings and API keys are never exported.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Cleanup runs on this Mac with the model chosen above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let endpointNotice {
                    Text(endpointNotice).font(.caption).foregroundStyle(.secondary)
                }
            }

            VocaDisclosureCard(
                title: "Command Mode Options",
                subtitle: "Shortcut, examples, and apps that hide selections.",
                systemImage: "wand.and.stars",
                isExpanded: $isCommandModeExpanded
            ) {
                CommandModeSettingsGroup(embedded: true)
            }

            VocaSettingsGroup("Try It") {
                Text("See what cleanup would type for a sample.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $tryItInput)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 76)
                    .padding(8)
                    .background(VocaDesign.canvas, in: RoundedRectangle(cornerRadius: 8))

                HStack {
                    Button(tryItRunning ? "Cleaning…" : "Clean Up Sample") {
                        runTryIt()
                    }
                    .disabled(tryItRunning || tryItInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if tryItRunning {
                        ProgressView().controlSize(.small)
                    }

                    Spacer()

                    Button("Reset") {
                        tryItInput = Self.sampleUtterance
                        tryItResult = nil
                    }
                    .buttonStyle(.link)
                }

                if let result = tryItResult {
                    tryItOutput(result)
                }
            }

            // The disclosure card is its own surface; wrapping it in a group
            // card would draw a card inside a card.
            VStack(alignment: .leading, spacing: 8) {
                VocaSectionHeader(title: "Advanced")
                VocaDisclosureCard(
                    title: "Cleanup prompt",
                    subtitle: "The only thing the model sees besides your transcript.",
                    systemImage: "text.quote",
                    badge: isPromptCustomised ? "Customised" : "Default",
                    isExpanded: $isPromptExpanded
                ) {
                    // A long prompt eats the context the transcript needs, and
                    // the result is cleanup that silently never runs. Say so
                    // here rather than let it look like the feature is broken.
                    if promptBudget <= 0 {
                        Label(
                            "This prompt fills the model's whole context, so cleanup will be skipped for every transcript. Shorten it.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    } else if promptBudget < 1500 {
                        Label(
                            "This prompt leaves room for only about \(promptBudget) characters of speech — longer dictations will skip cleanup.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }

                    TextEditor(text: $promptDraft)
                        .font(.system(.caption, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(height: 190)
                        .padding(8)
                        .background(VocaDesign.canvas, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(VocaDesign.line))
                        .onChange(of: promptDraft) {
                            // Writing @AppStorage on every keystroke republishes
                            // AppState and re-renders the whole settings tree for
                            // a ~2 KB string. Settle first, then persist once.
                            promptCommit?.cancel()
                            let draft = promptDraft
                            promptCommit = Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(400))
                                guard !Task.isCancelled else { return }
                                commitPrompt(draft)
                            }
                        }
                        .onDisappear {
                            promptCommit?.cancel()
                            commitPrompt(promptDraft)
                        }

                    HStack(spacing: 12) {
                        Text("Room for about \(max(0, promptBudget)) characters of speech")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer(minLength: 8)
                        Button("Reset to Default") {
                            promptCommit?.cancel()
                            promptDraft = TranscriptCleanup.defaultPrompt
                            appState.transcriptCleanupPrompt = ""
                        }
                        .controlSize(.small)
                        .disabled(!isPromptCustomised)
                    }
                }
            }
        }
        .toggleStyle(.switch)
        .onChange(of: appState.transcriptCleanupEnabled) {
            Task { @MainActor in
                await appState.syncTranscriptCleanup()
            }
        }
        .onAppear {
            if !didLoadPrompt {
                promptDraft = appState.effectiveCleanupPrompt
                didLoadPrompt = true
            }
        }
    }

    private var endpointProvider: Binding<CleanupProvider> {
        Binding(
            get: { appState.cleanupEndpoint.provider },
            set: { provider in
                var configuration = appState.cleanupEndpoint
                let previous = configuration.provider
                configuration.provider = provider
                if configuration.baseURL.isEmpty || configuration.baseURL == previous.defaultBaseURL {
                    configuration.baseURL = provider.defaultBaseURL
                }
                if configuration.model.isEmpty || configuration.model == previous.defaultModel {
                    configuration.model = provider.defaultModel
                }
                appState.cleanupEndpoint = configuration
                Task { await appState.syncTranscriptCleanup() }
            }
        )
    }

    private var endpointBaseURL: Binding<String> {
        Binding(
            get: { appState.cleanupEndpoint.baseURL },
            set: { value in
                var configuration = appState.cleanupEndpoint
                configuration.baseURL = value
                appState.cleanupEndpoint = configuration
            }
        )
    }

    private var endpointModel: Binding<String> {
        Binding(
            get: { appState.cleanupEndpoint.model },
            set: { value in
                var configuration = appState.cleanupEndpoint
                configuration.model = value
                appState.cleanupEndpoint = configuration
            }
        )
    }

    @ViewBuilder
    private func tryItOutput(_ result: CleanupTryResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: result.changedText ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(result.changedText ? VocaDesign.success : .orange)
                Text(result.summary)
                    .font(.caption)
                    .foregroundStyle(result.changedText ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(String(format: "%.1fs", result.duration))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Text(result.text.isEmpty ? "Nothing would be typed." : result.text)
                .font(.system(.callout, design: .default))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.vertical, 2)
    }

    private func runTryIt() {
        // Use the prompt as it currently reads in the editor, not the saved
        // one, so an edit can be tried before it is committed.
        let draft = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = draft.isEmpty ? TranscriptCleanup.defaultPrompt : draft
        let input = tryItInput
        tryItRunning = true
        Task { @MainActor in
            let result = await appState.tryCleanup(input, prompt: prompt)
            tryItResult = result
            tryItRunning = false
        }
    }

    /// Whether any cleanup model is on disk, not just the selected one.
    private var hasDownloadedModel: Bool {
        CleanupModelKind.cleanupChoices.contains { appState.transcriptCleanup.isDownloaded($0) }
    }

    /// Characters of transcript that still fit alongside the drafted prompt.
    private var isPromptCustomised: Bool {
        promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            != TranscriptCleanup.defaultPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var promptBudget: Int {
        let draft = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = draft.isEmpty ? TranscriptCleanup.defaultPrompt : draft
        if !appState.cleanupEndpoint.isLocal { return max(0, 64_000 - prompt.count) }
        return appState.transcriptCleanup.inputBudget(forPrompt: prompt)
    }

    /// An empty stored prompt means "use the default", so a draft that matches
    /// the default is stored as empty and follows future default changes.
    private func commitPrompt(_ draft: String) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDefault = trimmed == TranscriptCleanup.defaultPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        appState.transcriptCleanupPrompt = isDefault ? "" : draft
    }

    private var isDownloading: Bool {
        if case .downloading = appState.transcriptCleanup.modelState { return true }
        return false
    }

    /// Rows that stay visible: anything downloaded, in use, downloading, or
    /// suggested for this Mac. The rest wait behind one disclosure row.
    private func isProminentModel(_ kind: CleanupModelKind) -> Bool {
        if case .downloading(let active, _) = appState.transcriptCleanup.modelState, active == kind {
            return true
        }
        let suggestion = appState.cleanupModelSuggestion
        return appState.transcriptCleanup.isDownloaded(kind)
            || appState.selectedCleanupModelKind == kind
            || appState.commandModeEngine == .local(kind)
            || suggestion.cleanup == kind
            || suggestion.commandMode == kind
    }

    private var modelLibrary: some View {
        let prominent = CleanupModelKind.allCases.filter(isProminentModel)
        let more = CleanupModelKind.allCases.filter { !isProminentModel($0) }
        return VocaSettingsGroup("On-Device Models", subtitle: "Download a model once and use it for either feature.") {
            ForEach(prominent) { kind in
                AIModelLibraryRow(kind: kind)
                if kind != prominent.last || !more.isEmpty {
                    Divider()
                }
            }
            if !more.isEmpty {
                DisclosureGroup(isExpanded: $isMoreModelsExpanded) {
                    ForEach(more) { kind in
                        AIModelLibraryRow(kind: kind)
                        if kind != more.last {
                            Divider()
                        }
                    }
                } label: {
                    Text("\(more.count) more \(more.count == 1 ? "model" : "models")")
                }
                .disclosureGroupStyle(VocaDisclosureGroupStyle())
            }
        }
    }

    /// Says in one sentence what running one or two models means right now.
    private var sharingDetail: String {
        let cleanup = appState.selectedCleanupModelKind.descriptor.displayName
        if appState.sharesAIModel {
            return "\(cleanup) does both: one download, one model in memory."
        }
        switch appState.commandModeEngine {
        case .local(let kind) where kind == appState.selectedCleanupModelKind:
            return "Both use \(cleanup) for now, but choosing a model for one won't change the other."
        case .local(let kind):
            return "\(cleanup) cleans up and \(kind.descriptor.displayName) edits. They take turns in memory, so an edit starts slower."
        case .appleIntelligence, .endpoint:
            return "Command Mode runs with \(appState.commandModeEngine.displayName), so it needs no model here."
        }
    }

    @ViewBuilder
    private var cleanupStatus: some View {
        let kind = appState.selectedCleanupModelKind
        if !appState.cleanupEndpoint.isLocal {
            if let problem = appState.cleanupEndpoint.validationProblem() {
                AIStatusLine(text: problem, systemImage: "exclamationmark.triangle.fill", color: .orange)
            } else {
                AIStatusLine(
                    text: "Runs with \(appState.cleanupEndpoint.provider.displayName) · \(appState.cleanupEndpoint.resolvedModel), set in Inference below.",
                    systemImage: "network",
                    color: .secondary
                )
            }
        } else if appState.transcriptCleanupEnabled {
            switch appState.transcriptCleanup.modelState {
            case .downloading, .ready:
                EmptyView()
            case .loading(let loading):
                AIStatusLine(text: "Loading \(loading.descriptor.displayName)…", systemImage: "hourglass", color: .secondary)
            case .error(let message):
                HStack(spacing: 8) {
                    AIStatusLine(text: message, systemImage: "exclamationmark.triangle.fill", color: .orange)
                    if let smaller = appState.smallerDownloadedCleanupModel {
                        Button("Use \(smaller.descriptor.displayName)") {
                            Task { @MainActor in await appState.useAIModel(smaller, for: .cleanup) }
                        }
                        .controlSize(.small)
                        .help("Already downloaded and uses less memory")
                    }
                }
            case .idle:
                if !appState.transcriptCleanup.isDownloaded(kind) {
                    HStack(spacing: 8) {
                        AIStatusLine(
                            text: "Not downloaded yet, so dictations are typed as spoken.",
                            systemImage: "arrow.down.circle",
                            color: .orange
                        )
                        Button("Download \(kind.descriptor.sizeDescription)") {
                            Task { @MainActor in await appState.useAIModel(kind, for: .cleanup) }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var commandStatus: some View {
        let engine = appState.commandModeEngine
        if appState.shortcut(for: .commandMode) == nil {
            HStack(spacing: 8) {
                AIStatusLine(text: "Off until it has a shortcut.", systemImage: "keyboard", color: .orange)
                if let suggested = ShortcutValidation.suggestion(for: .commandMode, appState: appState) {
                    Button("Use \(KeyCodeReference.displayName(for: suggested))") {
                        appState.setShortcut(suggested, for: .commandMode)
                    }
                    .controlSize(.small)
                    .help("Three modifiers, rarely used by other apps")
                }
            }
        } else if case .local(let kind) = engine, !appState.transcriptCleanup.isDownloaded(kind) {
            HStack(spacing: 8) {
                AIStatusLine(text: "\(kind.descriptor.displayName) isn't downloaded yet.", systemImage: "arrow.down.circle", color: .orange)
                Button("Download \(kind.descriptor.sizeDescription)") {
                    Task { @MainActor in await appState.useAIModel(kind, for: .commandMode) }
                }
                .controlSize(.small)
                .disabled(isDownloading)
            }
        } else if let problem = appState.commandModeProblem(for: engine) {
            AIStatusLine(text: problem, systemImage: "exclamationmark.triangle.fill", color: .orange)
        } else if let combo = appState.shortcut(for: .commandMode) {
            AIStatusLine(
                text: "Ready. Select text, press \(KeyCodeReference.displayName(for: combo)), and say the edit.",
                systemImage: "checkmark.circle.fill",
                color: VocaDesign.command
            )
        }
    }

    /// One download runs at a time, whichever feature asked for it.
    @ViewBuilder
    private var downloadProgressLine: some View {
        if case .downloading(let kind, let progress) = appState.transcriptCleanup.modelState {
            Divider()
            HStack(spacing: 10) {
                ProgressView(value: progress)
                    .frame(width: 110)
                Text("Downloading \(kind.descriptor.displayName) — \(Int(progress * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    appState.cancelCleanupDownload()
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Command Mode

/// Command Mode's shortcut and options. Its model is chosen at the top of
/// the page, next to the cleanup model.
struct CommandModeSettingsGroup: View {
    @EnvironmentObject var appState: AppState

    /// Inside a disclosure card that already names the group, draw only the
    /// rows — a second titled card would repeat the heading one level down.
    var embedded = false

    var body: some View {
        if embedded {
            VStack(alignment: .leading, spacing: 12) { rows }
        } else {
            VocaSettingsGroup("Command Mode") { rows }
        }
    }

    @ViewBuilder
    private var rows: some View {
        Text("Select text in any app, press the shortcut, and say what to change. The original stays in the menu bar so you can copy it back.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        CommandModeExamples()

        ShortcutRecorderRow(
            action: .commandMode,
            detail: "Press once, speak, and press again — or hold it while speaking.",
            title: "Shortcut"
        )

        Divider()

        SettingsToggleRow(
            title: "Copy the selection when an app hides it",
            detail: "For terminals and editors that don't share selected text.",
            isOn: $appState.commandModeClipboardFallback
        )
        .help("VocaMac copies the selection with ⌘C and puts your clipboard back right away. Clipboard managers may briefly see the selected text.")
    }
}

/// Instructions that show the range of what Command Mode can do.
private struct CommandModeExamples: View {
    private static let phrases = [
        "make this shorter", "fix grammar and spelling", "make it more formal",
        "turn this into bullet points", "translate to Spanish", "write a polite reply",
    ]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)],
                  alignment: .leading, spacing: 6) {
            ForEach(Self.phrases, id: \.self) { phrase in
                Text("“\(phrase)”")
                    .font(.caption)
                    .foregroundStyle(VocaDesign.command)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(VocaDesign.command.opacity(0.10), in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Example instructions: " + Self.phrases.joined(separator: ", "))
    }
}

private struct RecommendedBadge: View {
    let reason: String

    var body: some View {
        Text("Recommended")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(VocaDesign.accent.opacity(0.12))
            .foregroundStyle(VocaDesign.accent)
            .cornerRadius(4)
            .help("Recommended for your Mac. \(reason)")
    }
}

// MARK: - Model Choice Components

/// One of the two AI features: what it does, the model it runs, and a status
/// line only when there is something to know.
private struct AIFeatureRow<Trailing: View, Status: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let status: Status

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                trailing
            }
            status
                .padding(.leading, 40)
        }
    }
}

private struct AIStatusLine: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Pick the model for one feature. Undownloaded models say so and download
/// when chosen.
private struct AIModelMenu: View {
    @EnvironmentObject var appState: AppState
    let role: AIModelRole

    var body: some View {
        Menu {
            ForEach(localChoices) { kind in
                VocaMenuChoice(title: menuTitle(kind), isSelected: isSelected(kind)) {
                    Task { @MainActor in await appState.useAIModel(kind, for: role) }
                }
            }
            if !otherEngines.isEmpty {
                Divider()
                ForEach(otherEngines) { engine in
                    VocaMenuChoice(title: engine.displayName, isSelected: appState.commandModeEngine == engine) {
                        appState.selectCommandModeEngine(engine)
                    }
                }
            }
        } label: {
            Text(currentName)
        }
        .fixedSize()
        .disabled(isUnavailable)
        .help(role == .cleanup ? "The model that cleans up dictations" : "What runs Command Mode edits")
    }

    private var localChoices: [CleanupModelKind] {
        role == .cleanup ? CleanupModelKind.cleanupChoices : CleanupModelKind.commandModeChoices
    }

    private var otherEngines: [CommandModeEngine] {
        guard role == .commandMode else { return [] }
        var engines: [CommandModeEngine] = []
        if appState.appleIntelligenceAvailable() || appState.commandModeEngine == .appleIntelligence {
            engines.append(.appleIntelligence)
        }
        if !appState.cleanupEndpoint.isLocal, appState.cleanupEndpoint.validationProblem() == nil {
            engines.append(.endpoint)
        }
        return engines
    }

    private func isSelected(_ kind: CleanupModelKind) -> Bool {
        role == .cleanup
            ? appState.selectedCleanupModelKind == kind
            : appState.commandModeEngine == .local(kind)
    }

    private func menuTitle(_ kind: CleanupModelKind) -> String {
        var title = kind.descriptor.displayName
        if role == .cleanup, appState.sharesAIModel, !kind.supportsCommandMode {
            title += " (cleanup only)"
        }
        if !appState.transcriptCleanup.isDownloaded(kind) {
            title += " — download \(kind.descriptor.sizeDescription)"
        }
        return title
    }

    private var currentName: String {
        switch role {
        case .cleanup:
            return appState.cleanupEndpoint.isLocal
                ? appState.selectedCleanupModelKind.descriptor.displayName
                : appState.cleanupEndpoint.provider.displayName
        case .commandMode, .both:
            return appState.commandModeEngine.displayName
        }
    }

    private var isUnavailable: Bool {
        if case .downloading = appState.transcriptCleanup.modelState { return true }
        return role == .cleanup && !appState.cleanupEndpoint.isLocal
    }
}

/// One downloadable model: who made it, what it can do, which feature uses
/// it, and one control to download or use it.
private struct AIModelLibraryRow: View {
    @EnvironmentObject var appState: AppState
    let kind: CleanupModelKind
    @State private var showDeleteAlert = false

    private var descriptor: CleanupModelDescriptor { kind.descriptor }
    private var isDownloaded: Bool { appState.transcriptCleanup.isDownloaded(kind) }
    private var usedForCleanup: Bool {
        appState.cleanupEndpoint.isLocal && appState.selectedCleanupModelKind == kind
    }
    private var usedForCommands: Bool { appState.commandModeEngine == .local(kind) }
    private var isInUse: Bool { usedForCleanup || usedForCommands }
    /// Already doing every job it can, so there is nothing left to choose.
    private var hasNothingToChoose: Bool {
        isDownloaded && usedForCleanup && (usedForCommands || !kind.supportsCommandMode)
    }
    private var isSuggested: Bool {
        let suggestion = appState.cleanupModelSuggestion
        return suggestion.cleanup == kind || suggestion.commandMode == kind
    }
    private var downloadProgress: Double? {
        if case .downloading(let active, let progress) = appState.transcriptCleanup.modelState, active == kind {
            return progress
        }
        return nil
    }
    private var isDownloadingAnother: Bool {
        if case .downloading(let active, _) = appState.transcriptCleanup.modelState { return active != kind }
        return false
    }

    var body: some View {
        HStack(spacing: 10) {
            ModelCreatorMark(creator: kind.creator, isActive: isInUse && isDownloaded)
                .padding(.trailing, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(descriptor.displayName)
                        .font(.callout)
                        .fontWeight(isInUse ? .semibold : .regular)
                    if isSuggested {
                        RecommendedBadge(reason: appState.cleanupModelSuggestion.reason)
                    }
                }
                HStack(spacing: 4) {
                    Text(kind.creator.displayName)
                    Text("•")
                    Text(descriptor.sizeDescription)
                    Text("•")
                    Text("~\(String(format: "%.1f", descriptor.ramRequiredGB)) GB RAM")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                // What it can do, in the features' own colours; a check marks
                // the feature using it right now.
                HStack(spacing: 4) {
                    ModelRolePill(title: "Smart Cleanup", color: VocaDesign.success, isInUse: usedForCleanup)
                    if kind.supportsCommandMode {
                        ModelRolePill(title: "Command Mode", color: VocaDesign.command, isInUse: usedForCommands)
                    }
                }
            }
            .help(descriptor.summary)

            Spacer(minLength: 8)

            trailing
        }
        .padding(.vertical, 4)
        .alert("Delete \(descriptor.displayName)?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { appState.deleteCleanupModel(kind) }
        } message: {
            Text("Removes \(descriptor.sizeDescription) from disk. You can download it again later.")
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let progress = downloadProgress {
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .frame(width: 60)
                Text("\(Int(progress * 100))%")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 8) {
                if !hasNothingToChoose {
                    useControl
                        .disabled(isDownloadingAnother)
                }
                if isDownloaded && !isInUse {
                    Button {
                        showDeleteAlert = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Delete download")
                }
            }
        }
    }

    /// A model that can only clean up, or one used while both features share
    /// a model, has a single thing to do. A model that could serve either
    /// feature asks which.
    @ViewBuilder
    private var useControl: some View {
        let title = isDownloaded ? "Use" : "Download"
        if !kind.supportsCommandMode {
            Button(title) { use(.cleanup) }
                .controlSize(.small)
                .help("Use for Smart Cleanup")
        } else if appState.sharesAIModel {
            Button(title) { use(.both) }
                .controlSize(.small)
                .help("Use for Smart Cleanup and Command Mode")
        } else {
            Menu(title) {
                Button("For Both") { use(.both) }
                Button("For Smart Cleanup") { use(.cleanup) }
                    .disabled(usedForCleanup && isDownloaded)
                Button("For Command Mode") { use(.commandMode) }
                    .disabled(usedForCommands && isDownloaded)
                if !isDownloaded {
                    Divider()
                    Button("Download Only") {
                        Task { @MainActor in await appState.downloadAIModel(kind) }
                    }
                }
            }
            .controlSize(.small)
            .fixedSize()
        }
    }

    private func use(_ role: AIModelRole) {
        Task { @MainActor in await appState.useAIModel(kind, for: role) }
    }
}

/// A feature a model can run, checked and stronger when it is running it.
private struct ModelRolePill: View {
    let title: String
    let color: Color
    var isInUse = false

    var body: some View {
        HStack(spacing: 3) {
            if isInUse {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
            }
            Text(title)
        }
        .font(.caption2.weight(isInUse ? .semibold : .medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(color.opacity(isInUse ? 0.24 : 0.10), in: Capsule())
        .foregroundStyle(color.opacity(isInUse ? 1 : 0.8))
        .help(isInUse ? "Running \(title)" : "Can run \(title)")
        .accessibilityLabel(isInUse ? "\(title), in use" : "Can run \(title)")
    }
}
