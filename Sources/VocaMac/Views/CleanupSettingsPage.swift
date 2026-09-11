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
    @State private var tryItResult: CleanupAttempt?
    @State private var tryItRunning = false
    @State private var isPromptExpanded = false
    @State private var apiKeyDraft = ""
    @State private var endpointNotice: String?

    /// Seeded with something that exercises the behaviours the models differ
    /// on: fillers, a stutter, and dictated punctuation.
    static let sampleUtterance =
        "so um i was i was thinking we could ship it on friday comma "
        + "maybe after the review you know"

    var body: some View {
        VocaSettingsPageContent {
            VocaSettingsGroup("Smart Cleanup") {
                SettingsToggleRow(
                    title: "Clean up after transcription",
                    detail: "Remove filler words, false starts, and tidy punctuation on this Mac. If cleanup cannot produce a usable result, VocaMac keeps the original transcript.",
                    isOn: $appState.transcriptCleanupEnabled
                )
                .onChange(of: appState.transcriptCleanupEnabled) {
                    Task { @MainActor in
                        await appState.syncTranscriptCleanup()
                    }
                }

                // Setup state belongs here rather than in the paragraph above,
                // which kept telling people to download a model while the row
                // below reported one ready.
                if appState.cleanupEndpoint.isLocal {
                    if appState.transcriptCleanupEnabled,
                       !appState.transcriptCleanup.isDownloaded(appState.selectedCleanupModelKind) {
                        Text("Cleanup is on, but the selected model is not downloaded yet. Dictation will inject the raw transcript until you download one.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if !hasDownloadedModel {
                        Text("Off until a model is downloaded — pick one below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if appState.cleanupEndpoint.isLocal {
                    statusRow
                } else if appState.cleanupEndpoint.validationProblem() == nil {
                    Label("Endpoint configured", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(VocaDesign.success)
                }

                Picker("Cleanup level", selection: $appState.transcriptCleanupLevel) {
                    ForEach(CleanupLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                Text(appState.transcriptCleanupLevel.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VocaSettingsGroup("Inference") {
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
                    Text("The bundled GGUF model runs entirely on this Mac. This remains the default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let endpointNotice {
                    Text(endpointNotice).font(.caption).foregroundStyle(.secondary)
                }
            }

            if appState.cleanupEndpoint.isLocal {
                VocaSettingsGroup("Cleanup Model") {
                    ForEach(CleanupModelKind.cleanupChoices) { kind in
                        CleanupModelRow(kind: kind)
                        if kind != CleanupModelKind.cleanupChoices.last { Divider() }
                    }
                }
            }

            CommandModeSettingsGroup()

            VocaSettingsGroup("Try It") {
                Text("Try a sample transcript. The result stays in this window.")
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

            VocaSettingsGroup("Advanced") {
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
    private func tryItOutput(_ result: CleanupAttempt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: result.didChangeText ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(result.didChangeText ? VocaDesign.success : .orange)
                Text(result.summary)
                    .font(.caption)
                    .foregroundStyle(result.didChangeText ? .primary : .secondary)
                Spacer()
                Text(String(format: "%.1fs", result.duration))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Text(result.output)
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
            let result = await appState.previewCleanup(input, prompt: prompt)
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

    @ViewBuilder
    private var statusRow: some View {
        switch appState.transcriptCleanup.modelState {
        case .idle:
            EmptyView()
        case .downloading(let kind, let progress):
            HStack {
                ProgressView(value: progress)
                Text("Downloading \(kind.descriptor.displayName) — \(Int(progress * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Cancel") {
                    appState.cancelCleanupDownload()
                }
                .controlSize(.small)
            }
        case .loading:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Loading cleanup model…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label("Cleanup model ready", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(VocaDesign.success)
        case .error(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

struct CleanupModelRow: View {
    let kind: CleanupModelKind
    @EnvironmentObject var appState: AppState
    @State private var showDeleteAlert = false

    private var descriptor: CleanupModelDescriptor { kind.descriptor }
    private var isDownloaded: Bool { appState.transcriptCleanup.isDownloaded(kind) }
    private var isSelected: Bool { appState.selectedCleanupModelKind == kind }
    /// Selected for cleanup and actually resident — Command Mode may have
    /// borrowed the model slot for a larger model.
    private var isActive: Bool {
        isSelected && appState.transcriptCleanup.modelState == .ready
            && (appState.transcriptCleanup.loadedKind ?? kind) == kind
    }

    private var isBusy: Bool {
        switch appState.transcriptCleanup.modelState {
        case .downloading(let active, _), .loading(let active):
            return active == kind
        case .idle, .ready, .error:
            return false
        }
    }

    var body: some View {
        HStack {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? VocaDesign.success : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(descriptor.displayName)
                        .font(.callout)
                        .fontWeight(isSelected ? .semibold : .regular)

                    Text(descriptor.recommendation.badge)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(badgeColor.opacity(0.2))
                        .foregroundStyle(badgeColor)
                        .cornerRadius(4)
                }

                HStack(spacing: 4) {
                    Text(descriptor.sizeDescription)
                    Text("•")
                    Text("~\(String(format: "%.1f", descriptor.ramRequiredGB)) GB RAM")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                Text(descriptor.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if case .downloading(let active, let progress) = appState.transcriptCleanup.modelState,
               active == kind {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(width: 70)
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("Cancel") {
                        appState.cancelCleanupDownload()
                    }
                    .controlSize(.small)
                }
            } else if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else if isDownloaded {
                if isActive {
                    Label("Active", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(VocaDesign.success)
                } else {
                    Button("Load") {
                        Task { @MainActor in
                            await appState.loadCleanupModel(kind)
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Button("Download") {
                    Task { @MainActor in
                        await appState.downloadCleanupModel(kind)
                    }
                }
                .controlSize(.small)
            }

            if isDownloaded && !isBusy {
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
        .padding(.vertical, 6)
        .alert("Delete \(descriptor.displayName)?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                appState.deleteCleanupModel(kind)
            }
        } message: {
            Text("Removes \(descriptor.sizeDescription) from disk. You can download it again later.")
        }
    }

    private var badgeColor: Color {
        switch descriptor.recommendation {
        case .compact: return .secondary
        case .recommended: return VocaDesign.accent
        case .quality: return .primary
        }
    }
}

// MARK: - Command Mode

/// Command Mode's shortcut and the model that runs its edits, chosen
/// separately from the dictation cleanup model above.
struct CommandModeSettingsGroup: View {
    @EnvironmentObject var appState: AppState

    private var engine: CommandModeEngine { appState.commandModeEngine }

    var body: some View {
        VocaSettingsGroup("Command Mode") {
            CommandModeReadinessBanner()

            Text("Select text in any app, use the shortcut, and say what to change. Works with Smart Cleanup on or off, and the original stays in the menu bar to copy back.")
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

            Text("Model for edits")
                .font(.subheadline.weight(.medium))

            CommandEngineRow(
                engine: .appleIntelligence,
                title: "Apple Intelligence",
                detail: "Built into macOS 26. No download, runs on this Mac.",
                problem: appState.appleIntelligenceAvailable()
                    ? nil : AppleIntelligenceTextService.availabilityProblem()
            )

            if !appState.cleanupEndpoint.isLocal {
                Divider()
                CommandEngineRow(
                    engine: .endpoint,
                    title: "\(appState.cleanupEndpoint.provider.displayName) · \(appState.cleanupEndpoint.resolvedModel)",
                    detail: "The cleanup endpoint above. The selection and your instruction are sent to it.",
                    problem: appState.cleanupEndpoint.validationProblem()
                )
            }

            ForEach(CleanupModelKind.commandModeChoices) { kind in
                Divider()
                CommandLocalModelRow(kind: kind)
            }

            // Apple Intelligence and endpoint rows already explain their own
            // problems; only a missing download needs saying here.
            if case .local(let kind) = engine, !appState.transcriptCleanup.isDownloaded(kind) {
                Label(
                    "Download \(kind.descriptor.displayName) above to use Command Mode, or choose another model.",
                    systemImage: "arrow.down.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }
}

private struct CommandEngineRow: View {
    @EnvironmentObject var appState: AppState
    let engine: CommandModeEngine
    let title: String
    let detail: String
    let problem: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            CommandEngineSelectionMark(isSelected: appState.commandModeEngine == engine)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                Text(problem ?? detail)
                    .font(.caption2)
                    .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if appState.commandModeEngine == engine {
                Text("In use").font(.caption).foregroundStyle(VocaDesign.command)
            } else {
                Button("Use") { appState.commandModeEngine = engine }
                    .controlSize(.small)
                    .disabled(problem != nil)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CommandLocalModelRow: View {
    @EnvironmentObject var appState: AppState
    @State private var showDeleteAlert = false
    let kind: CleanupModelKind

    private var descriptor: CleanupModelDescriptor { kind.descriptor }
    private var isDownloaded: Bool { appState.transcriptCleanup.isDownloaded(kind) }
    private var isSelected: Bool { appState.commandModeEngine == .local(kind) }
    /// Deleting the cleanup model from here would surprise; that row owns it.
    private var isCleanupModel: Bool { appState.selectedCleanupModelKind == kind }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            CommandEngineSelectionMark(isSelected: isSelected)
            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.displayName).font(.callout)
                Text("\(descriptor.sizeDescription) • ~\(String(format: "%.1f", descriptor.ramRequiredGB)) GB RAM")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(descriptor.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
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
        if case .downloading(let active, let progress) = appState.transcriptCleanup.modelState, active == kind {
            HStack(spacing: 8) {
                ProgressView(value: progress).frame(width: 70)
                Text("\(Int(progress * 100))%")
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                Button("Cancel") { appState.cancelCleanupDownload() }
                    .controlSize(.small)
            }
        } else if !isDownloaded {
            Button("Download") {
                Task { @MainActor in await appState.downloadCommandModeModel(kind) }
            }
            .controlSize(.small)
            .disabled(isDownloadingAnotherModel)
        } else {
            HStack(spacing: 8) {
                if isSelected {
                    Text("In use").font(.caption).foregroundStyle(VocaDesign.command)
                } else {
                    Button("Use") { appState.commandModeEngine = .local(kind) }
                        .controlSize(.small)
                }
                if !isCleanupModel {
                    Button { showDeleteAlert = true } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Delete downloaded model")
                }
            }
        }
    }

    private var isDownloadingAnotherModel: Bool {
        if case .downloading = appState.transcriptCleanup.modelState { return true }
        return false
    }
}

private struct CommandEngineSelectionMark: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
            .foregroundStyle(isSelected ? VocaDesign.command : .secondary)
            .frame(width: 20)
            .accessibilityLabel(isSelected ? "Selected" : "Not selected")
    }
}

/// One line that says whether Command Mode will work right now, and if not,
/// the single thing to do about it. Without a shortcut the feature is
/// invisible, so that case leads.
private struct CommandModeReadinessBanner: View {
    @EnvironmentObject var appState: AppState

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let (symbol, message, color) = state
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(colorScheme == .dark ? 0.2 : 0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var state: (String, String, Color) {
        let engine = appState.commandModeEngine
        guard let combo = appState.shortcut(for: .commandMode) else {
            return ("keyboard", "Command Mode is off. Record a shortcut below to turn it on.", .orange)
        }
        if let problem = appState.commandModeProblem(for: engine) {
            return ("exclamationmark.triangle.fill", problem, .orange)
        }
        let keys = KeyCodeReference.displayName(for: combo)
        return (
            "wand.and.stars",
            "Ready — select text, press \(keys), and speak. Edits run with \(engine.displayName).",
            VocaDesign.command
        )
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
