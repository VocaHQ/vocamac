// CalmCleanupDialogs.swift
// VocaMac
//
// The dialogs Settings › Smart Cleanup opens: Try it with your words, and
// Custom instructions (the cleanup prompt, with the room it leaves for
// speech and Reset to default).

import SwiftUI

// MARK: - Try it

/// Run the user's own words through the same cleanup a dictation gets,
/// and show what would be typed.
struct CalmCleanupTryDialog: View {
    /// Fillers, a stutter and dictated punctuation: what the models differ on.
    static let sample = "so um i was i was thinking we could ship it on friday comma maybe after the review you know"

    @EnvironmentObject private var appState: AppState
    @State private var text = CalmCleanupTryDialog.sample
    @State private var result: CleanupTryResult?
    @State private var isRunning = false

    var body: some View {
        CalmDialog(
            "Try it with your words",
            description: "Type or paste something as you’d say it. VocaMac cleans it up the way it would a dictation.",
            width: CalmMetrics.dialogListWidth
        ) {
            VStack(alignment: .leading, spacing: 14) {
                CalmTextEditor(nil, text: $text, prompt: "um so I think we should…", maxHeight: 160)
                if isRunning {
                    HStack(spacing: 6) {
                        CalmSpinner(size: 14, weight: 2.4)
                        Text("Cleaning up…")
                    }
                    .font(CalmFont.note)
                    .foregroundStyle(CalmColor.ink2)
                } else if let result {
                    CalmBeforeAfter(
                        said: result.input,
                        types: result.text.isEmpty ? "Nothing would be typed." : result.text
                    )
                    CalmInlineNotice(
                        "\(result.summary) · \(String(format: "%.1f", result.duration)) s",
                        tone: result.changedText ? .success : .info
                    )
                }
            }
        } footer: {
            CalmDialogFooter(
                primaryTitle: "Clean up",
                isPrimaryEnabled: !isRunning && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                cancelTitle: "Close", dismissesOnPrimary: false, onPrimary: run
            ) {
                Button("Reset") {
                    text = Self.sample
                    result = nil
                }
                .calmButton(.quiet)
                .disabled(text == Self.sample && result == nil)
            }
        }
    }

    private func run() {
        let input = text
        let prompt = appState.effectiveCleanupPrompt
        isRunning = true
        Task { @MainActor in
            result = await appState.tryCleanup(input, prompt: prompt)
            isRunning = false
        }
    }
}

// MARK: - Custom instructions

/// The cleanup prompt: the only thing the model sees besides the
/// transcript. Saved as you type (debounced), on Done and on close; a
/// prompt that matches the default is stored empty so it follows future
/// defaults.
struct CalmCleanupPromptDialog: View {
    @EnvironmentObject private var appState: AppState
    @State private var draft = ""
    @State private var didLoad = false
    @State private var commit: Task<Void, Never>?

    var body: some View {
        let budget = promptBudget
        CalmDialog(
            "Custom instructions",
            description: "The only thing the model sees besides your words. The level you pick is added to it.",
            width: CalmMetrics.dialogListWidth + 80
        ) {
            VStack(alignment: .leading, spacing: 10) {
                // A long prompt eats the room the transcript needs, and cleanup
                // then silently never runs. Say so here.
                if budget <= 0 {
                    CalmInlineNotice(
                        "These instructions may leave too little room for speech. Shorten them; the exact limit depends on the model and language.",
                        tone: .warning
                    )
                } else if budget < 1500 {
                    CalmInlineNotice(
                        "About \(budget) English characters fit per pass. Long dictations may need several passes; oversized sentences stay as spoken.",
                        tone: .warning
                    )
                }
                CalmTextEditor(nil, text: $draft, prompt: "Instructions for the cleanup model", minHeight: 160, maxHeight: 260)
                Text("About \(max(0, budget)) English characters of speech fit per pass")
                    .font(CalmFont.note)
                    .foregroundStyle(CalmColor.muted)
                    .monospacedDigit()
            }
        } footer: {
            CalmDialogFooter(primaryTitle: "Done", cancelTitle: nil, onPrimary: { save(draft) }, leading: {
                Button("Reset to default", action: resetToDefault)
                    .calmButton(.quiet)
                    .disabled(!isCustomised)
            })
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            draft = appState.effectiveCleanupPrompt
        }
        .onChange(of: draft) { _, value in
            guard didLoad else { return }
            // Writing the stored prompt republishes AppState and redraws
            // Settings, so wait for typing to settle first.
            commit?.cancel()
            commit = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                save(value)
            }
        }
        .onDisappear {
            commit?.cancel()
            if didLoad { save(draft) }
        }
    }

    private func resetToDefault() {
        commit?.cancel()
        draft = TranscriptCleanup.defaultPrompt
        appState.transcriptCleanupPrompt = ""
    }

    private var isCustomised: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
            != TranscriptCleanup.defaultPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Characters of transcript that still fit alongside the drafted prompt.
    private var promptBudget: Int {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = trimmed.isEmpty ? TranscriptCleanup.defaultPrompt : trimmed
        if !appState.cleanupEndpoint.isLocal { return max(0, 64_000 - prompt.count) }
        return appState.transcriptCleanup.inputBudget(forPrompt: prompt, model: appState.selectedCleanupModelKind)
    }

    private func save(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDefault = trimmed == TranscriptCleanup.defaultPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = isDefault || trimmed.isEmpty ? "" : value
        if appState.transcriptCleanupPrompt != stored { appState.transcriptCleanupPrompt = stored }
    }
}
