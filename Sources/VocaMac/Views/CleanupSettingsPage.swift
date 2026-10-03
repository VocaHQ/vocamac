// CleanupSettingsPage.swift
// VocaMac
//
// Settings for Smart Cleanup, the optional pass that tidies each dictation.
// Command Mode has its own page; the two only meet when they share a model.

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
                AIFeatureRow(
                    title: "Tidy every dictation",
                    detail: "Removes filler words, fixes punctuation, and keeps your corrections, before the text is typed.",
                    systemImage: "sparkles",
                    tint: VocaDesign.accentSolid
                ) {
                    AIModelMenu(role: .cleanup)
                    Toggle("Smart Cleanup", isOn: $appState.transcriptCleanupEnabled)
                        .labelsHidden()
                } status: {
                    VStack(alignment: .leading, spacing: 4) {
                        cleanupStatus
                        if appState.sharesAIModel {
                            AIStatusLine(
                                text: "Command Mode uses this model too. Change that on the Command Mode page.",
                                systemImage: "link",
                                color: .secondary
                            )
                        }
                    }
                }
                AIModelDownloadProgress()
            }
            .settingsTarget("cleanup")

            VocaSettingsGroup("Cleanup Level") {
                Picker("Cleanup level", selection: $appState.transcriptCleanupLevel) {
                    ForEach(CleanupLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                Text(appState.transcriptCleanupLevel.summary)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("More about \(appState.transcriptCleanupLevel.displayName)") {
                    Text(appState.transcriptCleanupLevel.detail)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
                .disclosureGroupStyle(VocaDisclosureGroupStyle())
                Divider()
                SettingsToggleRow(
                    title: "Skip the model when there's nothing to clean",
                    detail: "A dictation that is already punctuated, with no filler or repeated words, is typed straight away instead of waiting for the model to hand it back unchanged.",
                    isOn: $appState.skipCleanDictations
                )
                .settingsTarget("cleanup-skip-clean")
            }
            .settingsTarget("cleanup-level")

            VocaSettingsGroup("Try It") {
                Text("See what cleanup would type for a sample.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $tryItInput)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 76)
                    .vocaTextEditor()

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
                    .buttonStyle(.vocaLink)
                }

                if let result = tryItResult {
                    tryItOutput(result)
                }
            }
            .settingsTarget("cleanup-try")

            AIModelLibrary(role: .cleanup)
                .settingsTarget("cleanup-model")

            VocaDisclosureCard(
                title: "Where Cleanup Runs",
                subtitle: "On this Mac, or a server you choose such as Ollama or LM Studio.",
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
                        .textFieldStyle(.voca)
                    TextField("Model", text: endpointModel)
                        .textFieldStyle(.voca)
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
                            .foregroundStyle(VocaDesign.warning)
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
            .revealSettingsTargets(["cleanup-provider"], expanded: $isInferenceExpanded)
            .settingsTarget("cleanup-provider")

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
                            "This prompt may leave too little room for speech. Shorten it; the exact limit depends on the model and language.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(VocaDesign.warning)
                    } else if promptBudget < 1500 {
                        Label(
                            "About \(promptBudget) English characters fit per pass. Long dictations may need multiple passes; oversized sentences stay as spoken.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(VocaDesign.warning)
                    }

                    TextEditor(text: $promptDraft)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 190)
                        .vocaTextEditor()
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
                        Text("About \(max(0, promptBudget)) English characters per pass")
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
                .revealSettingsTargets(["cleanup-prompt"], expanded: $isPromptExpanded)
                .settingsTarget("cleanup-prompt")
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
                    .foregroundStyle(result.changedText ? VocaDesign.success : VocaDesign.warning)
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

            TranscriptComparisonView(original: result.input, final: result.text.isEmpty ? "Nothing would be typed." : result.text)
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

    /// Characters of transcript that still fit alongside the drafted prompt.
    private var isPromptCustomised: Bool {
        promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            != TranscriptCleanup.defaultPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var promptBudget: Int {
        let draft = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = draft.isEmpty ? TranscriptCleanup.defaultPrompt : draft
        if !appState.cleanupEndpoint.isLocal { return max(0, 64_000 - prompt.count) }
        return appState.transcriptCleanup.inputBudget(forPrompt: prompt, model: appState.selectedCleanupModelKind)
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
    private var cleanupStatus: some View {
        let kind = appState.selectedCleanupModelKind
        if !appState.cleanupEndpoint.isLocal {
            if let problem = appState.cleanupEndpoint.validationProblem() {
                AIStatusLine(text: problem, systemImage: "exclamationmark.triangle.fill", color: VocaDesign.warning)
            } else {
                AIStatusLine(
                    text: "Runs with \(appState.cleanupEndpoint.provider.displayName) · \(appState.cleanupEndpoint.resolvedModel), set in Where Cleanup Runs below.",
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
                    AIStatusLine(text: message, systemImage: "exclamationmark.triangle.fill", color: VocaDesign.warning)
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
                            color: VocaDesign.warning
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
}
