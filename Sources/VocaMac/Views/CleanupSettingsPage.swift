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

    /// Seeded with something that exercises the behaviours the models differ
    /// on: fillers, a stutter, and dictated punctuation.
    static let sampleUtterance =
        "so um i was i was thinking we could ship it on friday comma "
        + "maybe after the review you know"

    var body: some View {
        Form {
            Section("Smart Cleanup") {
                Toggle("Clean Up After Transcription", isOn: $appState.transcriptCleanupEnabled)
                    .onChange(of: appState.transcriptCleanupEnabled) {
                        Task { @MainActor in
                            await appState.syncTranscriptCleanup()
                        }
                    }

                Text("Runs a small local language model after speech-to-text to drop filler words and false starts and to punctuate what you said. Nothing leaves your Mac. Models this size do not catch everything, and anything one rewrites badly is discarded in favour of the raw transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Setup state belongs here rather than in the paragraph above,
                // which kept telling people to download a model while the row
                // below reported one ready.
                if appState.transcriptCleanupEnabled && !appState.transcriptCleanup.isDownloaded(appState.selectedCleanupModelKind) {
                    Text("Cleanup is on, but the selected model is not downloaded yet. Dictation will inject the raw transcript until you download one.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !hasDownloadedModel {
                    Text("Off until a model is downloaded — pick one below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                statusRow
            }

            Section("Cleanup Model") {
                ForEach(CleanupModelKind.allCases) { kind in
                    CleanupModelRow(kind: kind)
                }
            }

            Section("Try It") {
                Text("Type what you would have said and run it through the model. Nothing here is injected anywhere — it just shows what cleanup would do to a dictation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $tryItInput)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 54)

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

            Section("Prompt") {
                Text("The model only sees this prompt plus the transcript. Leave the default unless you need a different voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // A long prompt eats the context the transcript needs, and the
                // result is cleanup that silently never runs. Say so here
                // rather than let it look like the feature is broken.
                if promptBudget <= 0 {
                    Text("This prompt fills the model's whole context, so cleanup will be skipped for every transcript. Shorten it.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if promptBudget < 1500 {
                    Text("This prompt leaves room for only about \(promptBudget) characters of speech — longer dictations will skip cleanup.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

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

    @ViewBuilder
    private func tryItOutput(_ result: CleanupAttempt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: result.didChangeText ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(result.didChangeText ? Color.green : .orange)
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
        CleanupModelKind.allCases.contains { appState.transcriptCleanup.isDownloaded($0) }
    }

    /// Characters of transcript that still fit alongside the drafted prompt.
    private var promptBudget: Int {
        let draft = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return appState.transcriptCleanup.inputBudget(
            forPrompt: draft.isEmpty ? TranscriptCleanup.defaultPrompt : draft
        )
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
