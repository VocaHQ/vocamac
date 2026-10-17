// CalmModelsDialogs.swift
// VocaMac
//
// Dialogs Settings › Models opens: model details, Remove model, the
// confirmations a pick can need (experimental model, stopping a download),
// Your own server (speech endpoint) and Where cleanup runs (cleanup endpoint).

import SwiftUI

// MARK: - Details

/// The model details dialog (Model chooser parts board): logo, name and
/// origin, then a two-column list of facts. 400 wide. Close, and Use this
/// model when it isn't the one in use.
struct CalmModelDetailsDialog: View {
    let logo: CalmLogoName
    let name: String
    let origin: String
    let facts: [(label: String, value: String)]
    let canUse: Bool
    let onUse: () -> Void

    var body: some View {
        CalmDialog(name, width: 400) {
            HStack(spacing: 12) {
                CalmLogo(logo, box: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(CalmFont.dialogTitle).foregroundStyle(CalmColor.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(origin).calmType(.description)
                }
            }
        } content: {
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                    GridRow {
                        Text(fact.label).foregroundStyle(CalmColor.muted).frame(width: 110, alignment: .leading)
                        Text(fact.value).foregroundStyle(CalmColor.ink).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .font(CalmFont.description)
        } footer: {
            if canUse {
                CalmDialogFooter(primaryTitle: "Use this model", cancelTitle: "Close", onPrimary: onUse)
            } else {
                CalmDialogFooter(primaryTitle: "Close", primaryKind: .secondary, cancelTitle: nil) {}
            }
        }
    }
}

extension CalmModelDetailsDialog {
    /// Details for a speech model.
    @MainActor
    init(speech size: ModelSize, appState: AppState, onUse: @escaping () -> Void) {
        let model = appState.availableModels.first { $0.size == size }
        var facts: [(String, String)] = [
            ("Languages", CalmModelText.languagesInDetail(
                size, spoken: appState.spokenLanguages, systemLanguages: appState.appleSpeechLanguages
            )),
            ("Download", CalmModelText.downloadSize(size)),
        ]
        if !size.isRemotelyHosted {
            var memory = "\(CalmModelText.memory(gb: size.ramRequiredGB)) while in use"
            if size.firstLoadRAMRequiredGB > size.ramRequiredGB {
                memory += ", \(CalmModelText.trimmed(size.firstLoadRAMRequiredGB, decimals: 1)) GB the first time it loads"
            }
            facts.append(("Memory", memory))
        }
        facts.append(("Speed", "\(CalmModelText.speed(size)), \(CalmModelText.accuracy(size))"))
        facts.append(("Translation", size.translatesToEnglish ? "Can translate into English" : "No"))
        if model?.isSupported == false {
            facts.append(("On this Mac", "Not verified on this chip. It may fail to load or run slower."))
        }
        let variant: String? = CalmModelText.variant(size, isBundled: appState.modelManager.bundledModelFolder(for: size) != nil)
        self.init(
            logo: CalmLogoName(engine: size.engine),
            name: [CalmModelText.name(size), variant].compactMap { $0 }.joined(separator: " "),
            origin: CalmModelText.origin(size),
            facts: facts,
            canUse: model.map { !$0.isActive && $0.downloadProgress == nil && !$0.isLoading } ?? false,
            onUse: onUse
        )
    }

    /// Details for a writing model.
    @MainActor
    init(writing kind: CleanupModelKind, appState: AppState, onUse: @escaping () -> Void) {
        let descriptor = kind.descriptor
        self.init(
            logo: kind == .ministral3_3b_q4_k_m ? .ministral : .qwen,
            name: CalmModelText.name(kind),
            origin: "\(kind.creator.displayName) · runs on this Mac",
            facts: [
                ("Good at", descriptor.summary),
                ("Jobs", kind.supportsCommandMode ? "Smart Cleanup and Command Mode" : "Smart Cleanup only"),
                ("Download", CalmModelText.downloadSize(kind)),
                ("Memory", "\(CalmModelText.memory(gb: descriptor.ramRequiredGB)) while in use"),
                ("Speed", CalmModelText.speed(kind)),
            ],
            canUse: appState.calmCleanupModelInUse != kind,
            onUse: onUse
        )
    }
}

// MARK: - Confirmations

/// A confirmation (Dialogs board): the title is a question, the
/// description says what goes and what stays, the button repeats the verb.
struct CalmConfirmDialog: View {
    let title: String
    let message: String
    let actionTitle: String
    var actionKind: CalmButtonKind = .destructive
    let onConfirm: () -> Void

    var body: some View {
        CalmDialog(title, description: message, width: CalmMetrics.confirmDialogWidth) {
            CalmDialogFooter(primaryTitle: actionTitle, primaryKind: actionKind, onPrimary: onConfirm)
        }
    }
}

// MARK: - Your own server (speech)

/// Your own server: where the Custom endpoint speech model sends audio.
/// Kind, address, model (OpenAI-compatible only) and an API key kept in
/// Keychain. Saving puts the server to work unless it already is.
struct CalmSpeechServerDialog: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.calmDismissDialog) private var dismiss

    @State private var kind: SpeechEndpointKind = .openAICompatible
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var keyProblem: String?
    @State private var didLoad = false

    private var draft: SpeechEndpointConfiguration {
        var configuration = appState.speechEndpoint
        configuration.kind = kind
        configuration.baseURL = baseURL
        configuration.model = model
        return configuration
    }

    private var isInUse: Bool {
        appState.availableModels.first { $0.size == .customEndpoint }?.isActive == true
    }

    var body: some View {
        let problem = draft.validationProblem()
        CalmDialog(
            "Your own server",
            description: "VocaMac sends recorded audio to this address. Only you can see the key.",
            width: CalmMetrics.dialogListWidth - 40
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Server type").font(CalmFont.fieldLabel).foregroundStyle(CalmColor.ink)
                    Spacer()
                    CalmDropdown(selection: $kind, options: SpeechEndpointKind.allCases.map { CalmOption($0, $0.displayName) })
                }
                CalmTextField(
                    "Address", text: $baseURL, prompt: "https://whisper.home.lan",
                    error: baseURL.isEmpty ? nil : problem
                )
                if kind == .openAICompatible {
                    CalmTextField("Model", text: $model, prompt: "whisper-1")
                }
                CalmTextField(
                    "API key", text: $apiKey,
                    prompt: appState.speechEndpointHasAPIKey ? "Saved in Keychain" : "Optional",
                    error: keyProblem, isSecure: true
                )
                CalmInlineNotice(
                    "Each recording is uploaded as a WAV file while this server is the selected model. "
                        + "Use HTTPS unless the server is on this Mac or your local network. "
                        + "Server settings and keys are never exported.",
                    tone: .info
                )
            }
        } footer: {
            CalmDialogFooter(
                primaryTitle: isInUse ? "Save" : "Use this server",
                isPrimaryEnabled: problem == nil, dismissesOnPrimary: false, onPrimary: save
            ) {
                if appState.speechEndpointHasAPIKey {
                    Button("Remove key", action: removeKey).calmButton(.quietAmber)
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        let configuration = appState.speechEndpoint
        kind = configuration.kind
        baseURL = configuration.baseURL
        model = configuration.model
    }

    /// The key first: if Keychain refuses it, nothing is saved, so the
    /// server in use never points at an address without its key.
    private func save() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            do {
                try appState.saveSpeechEndpointAPIKey(key)
            } catch {
                keyProblem = "Couldn’t save the key: \(error.localizedDescription)"
                return
            }
        }
        appState.speechEndpoint = draft
        if !isInUse {
            CalmModelPicker.shared.startSpeech(.customEndpoint, cancelling: nil, appState: appState)
        }
        dismiss?()
    }

    private func removeKey() {
        do {
            try appState.deleteSpeechEndpointAPIKey()
            keyProblem = nil
        } catch {
            keyProblem = "Couldn’t remove the key: \(error.localizedDescription)"
        }
    }
}

// MARK: - Where cleanup runs

/// Where cleanup runs: on this Mac, or a server (Ollama, LM Studio,
/// OpenAI-compatible) with its address, model and an API key in Keychain.
struct CalmCleanupServerDialog: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.calmDismissDialog) private var dismiss

    @State private var provider: CleanupProvider = .local
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var keyProblem: String?
    @State private var didLoad = false

    private var draft: CleanupEndpointConfiguration {
        var configuration = appState.cleanupEndpoint
        configuration.provider = provider
        configuration.baseURL = baseURL
        configuration.model = model
        return configuration
    }

    var body: some View {
        let problem = draft.validationProblem()
        CalmDialog(
            "Where cleanup runs",
            description: "On this Mac, or a server you choose such as Ollama or LM Studio.",
            width: CalmMetrics.dialogListWidth - 40
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Run cleanup with").font(CalmFont.fieldLabel).foregroundStyle(CalmColor.ink)
                    Spacer()
                    CalmDropdown(selection: providerBinding, options: CleanupProvider.allCases.map { CalmOption($0, $0.displayName) })
                }
                if provider == .local {
                    CalmInlineNotice("Cleanup runs on this Mac with the model picked under Writing AI.", tone: .info)
                } else {
                    CalmTextField("Address", text: $baseURL, prompt: provider.defaultBaseURL, error: baseURL.isEmpty ? nil : problem)
                    CalmTextField("Model", text: $model, prompt: provider.defaultModel)
                    CalmTextField(
                        "API key", text: $apiKey,
                        prompt: appState.cleanupEndpointHasAPIKey ? "Saved in Keychain" : "Optional for servers on this Mac",
                        error: keyProblem, isSecure: true
                    )
                    CalmInlineNotice(
                        "Only the cleanup instructions and your words are sent. Use HTTPS unless the server is on this Mac "
                            + "or your local network. Server settings and keys are never exported.",
                        tone: .info
                    )
                }
            }
        } footer: {
            CalmDialogFooter(
                primaryTitle: "Save", isPrimaryEnabled: problem == nil, dismissesOnPrimary: false, onPrimary: save
            ) {
                if provider != .local, appState.cleanupEndpointHasAPIKey {
                    Button("Remove key", action: removeKey).calmButton(.quietAmber)
                }
            }
        }
        .onAppear(perform: load)
    }

    /// Switching provider fills in its default address and model when the
    /// fields still hold the previous provider's defaults.
    private var providerBinding: Binding<CleanupProvider> {
        Binding(
            get: { provider },
            set: { next in
                let previous = provider
                if baseURL.isEmpty || baseURL == previous.defaultBaseURL { baseURL = next.defaultBaseURL }
                if model.isEmpty || model == previous.defaultModel { model = next.defaultModel }
                provider = next
            }
        )
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        let configuration = appState.cleanupEndpoint
        provider = configuration.provider
        baseURL = configuration.baseURL
        model = configuration.model
    }

    private func save() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider != .local, !key.isEmpty {
            do {
                try appState.saveCleanupAPIKey(key)
            } catch {
                keyProblem = "Couldn’t save the key: \(error.localizedDescription)"
                return
            }
        }
        appState.cleanupEndpoint = draft
        Task { await appState.syncTranscriptCleanup() }
        dismiss?()
    }

    private func removeKey() {
        do {
            try appState.deleteCleanupAPIKey()
            keyProblem = nil
        } catch {
            keyProblem = "Couldn’t remove the key: \(error.localizedDescription)"
        }
    }
}
