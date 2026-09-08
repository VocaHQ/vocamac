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

    var body: some View {
        Form {
            Section("Smart Cleanup") {
                Toggle("Clean Up After Transcription", isOn: $appState.transcriptCleanupEnabled)
                    .onChange(of: appState.transcriptCleanupEnabled) {
                        Task { @MainActor in
                            await appState.syncTranscriptCleanup()
                        }
                    }

                Text("Runs a small local language model after speech-to-text to drop filler words and false starts and to add punctuation. Nothing leaves your Mac. Off by default — download the model first. A model this size will not catch everything, and anything it rewrites badly is discarded in favour of the raw transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.transcriptCleanupEnabled && !appState.transcriptCleanup.isDownloaded(appState.selectedCleanupModelKind) {
                    Text("Cleanup is on, but the selected model is not downloaded yet. Dictation will inject the raw transcript until you download one.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                statusRow
            }

            Section("Cleanup Model") {
                ForEach(CleanupModelKind.allCases) { kind in
                    CleanupModelRow(kind: kind)
                }
            }

            Section("Prompt") {
                Text("The model only sees this prompt plus the transcript. Leave the default unless you need a different voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $promptDraft)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 160)
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

                HStack {
                    Button("Reset to Default") {
                        promptCommit?.cancel()
                        promptDraft = TranscriptCleanup.defaultPrompt
                        appState.transcriptCleanupPrompt = ""
                    }
                    .disabled(promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        == TranscriptCleanup.defaultPrompt.trimmingCharacters(in: .whitespacesAndNewlines))
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if !didLoadPrompt {
                promptDraft = appState.effectiveCleanupPrompt
                didLoadPrompt = true
            }
        }
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
                .foregroundStyle(.green)
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
            Image(systemName: isSelected && appState.transcriptCleanup.modelState == .ready ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected && appState.transcriptCleanup.modelState == .ready ? .green : .secondary)
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
                if isSelected, appState.transcriptCleanup.modelState == .ready {
                    Label("Active", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.green)
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
        case .recommended: return .blue
        case .quality: return .purple
        }
    }
}
