// CalmCleanupSettings.swift
// VocaMac
//
// Settings › Smart Cleanup: the switch in the header, how much to change
// (with a before / after example per level), the model it runs (picked in
// Models › Writing AI) and its status, skipping the model for clean
// dictations, Try it with your words, and custom instructions.

import SwiftUI

/// Settings › Smart Cleanup.
struct CalmCleanupSettings: View {
    @EnvironmentObject private var appState: AppState
    @Environment(CalmNavigator.self) private var navigator
    @State private var showsTry = false
    @State private var showsPrompt = false

    var body: some View {
        let isOn = appState.transcriptCleanupEnabled
        CalmPage(.sheet) {
            CalmPageHeader("Smart Cleanup", description: headerDescription) {
                CalmSwitch(isOn: enabled)
                    .accessibilityLabel("Smart Cleanup")
                    .padding(.trailing, 30)
            }
            .settingsTarget("cleanup")

            levelPanel(isOn: isOn)
                .settingsTarget("cleanup-level")

            CalmPanel {
                modelRow
                    .settingsTarget("cleanup-model")
                CalmToggleRow(
                    "Skip the model when there’s nothing to clean",
                    description: "Types a dictation that’s already clean straight away",
                    isOn: $appState.skipCleanDictations
                )
                .settingsTarget("cleanup-skip-clean")
            }
            .opacity(isOn ? 1 : 0.5)

            CalmPanel {
                CalmRow("Try it with your words", description: "See what VocaMac would type, before you dictate") {
                    Button("Try it") { showsTry = true }.calmButton(.secondary)
                }
                .settingsTarget("cleanup-try")
                CalmRow("Custom instructions", description: promptDescription) {
                    Button("Edit") { showsPrompt = true }.calmButton(.secondary)
                }
                .settingsTarget("cleanup-prompt")
            }
        }
        .calmDialog(isPresented: $showsTry) { CalmCleanupTryDialog() }
        .calmDialog(isPresented: $showsPrompt) { CalmCleanupPromptDialog() }
    }

    private var headerDescription: String {
        let endpoint = appState.cleanupEndpoint
        return endpoint.isLocal
            ? "Tidies what you said before it’s typed. Runs on this Mac."
            : "Tidies what you said before it’s typed. Runs on your \(endpoint.provider.displayName) server."
    }

    /// Turning cleanup on with the level at None would run nothing, so it
    /// starts at Medium.
    private var enabled: Binding<Bool> {
        Binding(
            get: { appState.transcriptCleanupEnabled },
            set: { isOn in
                appState.transcriptCleanupEnabled = isOn
                if isOn, appState.transcriptCleanupLevel == .none { appState.transcriptCleanupLevel = .medium }
                Task { await appState.syncTranscriptCleanup() }
            }
        )
    }

    private var promptDescription: String {
        let stored = appState.transcriptCleanupPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let isCustom = !stored.isEmpty
            && stored != TranscriptCleanup.defaultPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return isCustom ? "Using your own instructions" : "Using the built-in instructions"
    }

    // MARK: Level

    private func levelPanel(isOn: Bool) -> some View {
        let level = appState.transcriptCleanupLevel
        let example = CalmCleanupExample.example(for: level)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                CalmRowLabel(title: "How much to change") {
                    CalmRowDescription(text: example.summary)
                }
                CalmSegmentedControl(
                    selection: $appState.transcriptCleanupLevel,
                    options: CalmCleanupExample.levels(current: level).map { CalmOption($0, $0.displayName) },
                    accessibilityLabel: "Cleanup level"
                )
            }
            // Off, only the rule-based steps run, so the example would mislead.
            if isOn {
                CalmBeforeAfter(said: example.said, types: example.types)
            } else {
                CalmInlineNotice(level.withoutSmartCleanup, tone: .info)
            }
        }
        .padding(.vertical, 20)
        .padding(.horizontal, CalmMetrics.rowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .calmPanelBackground()
    }

    // MARK: Model

    private var modelRow: some View {
        CalmRow("Model") {
            VStack(alignment: .leading, spacing: 6) {
                CalmRowDescription(text: modelLine)
                CalmCleanupModelStatus()
            }
        } trailing: {
            Button("Change") {
                navigator.modelsTab = .writing
                navigator.select(.models)
            }
            .calmButton(.secondary)
        }
    }

    private var modelLine: String {
        let endpoint = appState.cleanupEndpoint
        guard endpoint.isLocal else {
            return "\(endpoint.provider.displayName) · \(endpoint.resolvedModel) · on your server"
        }
        let kind = appState.selectedCleanupModelKind
        var line = "\(CalmModelText.name(kind)) · "
        line += appState.transcriptCleanup.isDownloaded(kind) ? "on this Mac" : "not downloaded"
        if appState.sharesAIModel { line += " · shared with Command Mode" }
        return line
    }
}

/// The status under the cleanup model's name: a download in progress,
/// loading, a load error (with a smaller model to fall back to), a model
/// still to download, or a server that isn't set up.
struct CalmCleanupModelStatus: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let kind = appState.selectedCleanupModelKind
        if case .downloading(let active, let progress) = appState.transcriptCleanup.modelState {
            HStack(spacing: 12) {
                CalmProgressBar(
                    value: progress, title: "Downloading \(CalmModelText.name(active))",
                    detail: "\(Int((progress * 100).rounded()))%"
                )
                Button("Cancel") { CalmModelPicker.shared.cancelWritingDownload(appState: appState) }
                    .calmButton(.secondary, size: .small)
            }
            .padding(.top, 4)
        } else if !appState.cleanupEndpoint.isLocal {
            if let problem = appState.cleanupEndpoint.validationProblem() {
                CalmInlineNotice(problem, tone: .warning)
            }
        } else if appState.transcriptCleanupEnabled {
            switch appState.transcriptCleanup.modelState {
            case .loading(let loading):
                HStack(spacing: 6) {
                    CalmSpinner(size: 13, weight: 2.4)
                    Text("Loading \(CalmModelText.name(loading))…")
                }
                .font(CalmFont.note)
                .foregroundStyle(CalmColor.ink2)
            case .error(let message):
                VStack(alignment: .leading, spacing: 8) {
                    CalmInlineNotice(message, tone: .warning)
                    if let smaller = appState.smallerDownloadedCleanupModel {
                        Button("Use \(CalmModelText.name(smaller))") {
                            Task { await appState.useAIModel(smaller, for: .cleanup) }
                        }
                        .calmButton(.secondary, size: .small)
                        .help("Already downloaded and uses less memory")
                    }
                }
            case .idle where !appState.transcriptCleanup.isDownloaded(kind):
                VStack(alignment: .leading, spacing: 8) {
                    CalmInlineNotice("Not downloaded yet, so dictations are typed as spoken.", tone: .warning)
                    Button("Download \(CalmModelText.downloadSize(kind))") {
                        CalmModelPicker.shared.startWriting(kind, role: .cleanup, cancelling: nil, appState: appState)
                    }
                    .calmButton(.secondary, size: .small)
                }
            default:
                EmptyView()
            }
        }
    }
}

/// The before / after box: “You said” and “VocaMac types” on content,
/// r10, a 1 pt line, padding 16 / 18.
struct CalmBeforeAfter: View {
    let said: String
    let types: String
    var saidLabel = "You said"
    var typesLabel = "VocaMac types"

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                label(saidLabel)
                Text(said).foregroundStyle(CalmColor.ink2).fixedSize(horizontal: false, vertical: true)
            }
            GridRow {
                label(typesLabel)
                Text(types).fontWeight(.medium).foregroundStyle(CalmColor.ink).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(CalmFont.body)
        .lineSpacing(3)
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(CalmColor.content))
        .overlay(shape.strokeBorder(CalmColor.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(CalmFont.note)
            .foregroundStyle(CalmColor.muted)
            .padding(.top, 1)
            .frame(width: 110, alignment: .leading)
    }
}
