// CleanupSettingsPage.swift
// VocaMac
//
// Settings for optional on-device transcript cleanup.

import SwiftUI

struct CleanupSettingsPage: View {
    @EnvironmentObject var appState: AppState
    @State private var promptDraft: String = ""
    @State private var didLoadPrompt = false

    var body: some View {
        Form {
            Section("Smart Cleanup") {
                Toggle("Clean Up After Transcription", isOn: $appState.transcriptCleanupEnabled)
                    .onChange(of: appState.transcriptCleanupEnabled) {
                        Task { @MainActor in
                            await appState.syncTranscriptCleanup()
                        }
                    }

                Text("Runs a local language model after speech-to-text to drop filler words, fix punctuation, and honor “scratch that”. Nothing leaves your Mac. Off by default — download a model first.")
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
                        let trimmed = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed == TranscriptCleanup.defaultPrompt.trimmingCharacters(in: .whitespacesAndNewlines) {
                            appState.transcriptCleanupPrompt = ""
                        } else {
                            appState.transcriptCleanupPrompt = promptDraft
                        }
                    }

                HStack {
                    Button("Reset to Default") {
                        promptDraft = TranscriptCleanup.defaultPrompt
                        appState.transcriptCleanupPrompt = ""
                    }
                    .disabled(appState.transcriptCleanupPrompt.isEmpty)
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

    @ViewBuilder
    private var statusRow: some View {
        switch appState.transcriptCleanup.modelState {
        case .idle:
            EmptyView()
        case .downloading(_, let progress):
            HStack {
                ProgressView(value: progress)
                Text("Downloading \(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            if isBusy {
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
                            appState.transcriptCleanupEnabled = true
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
