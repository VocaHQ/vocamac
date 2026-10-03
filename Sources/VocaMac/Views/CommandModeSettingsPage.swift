// CommandModeSettingsPage.swift
// VocaMac
//
// Settings for Command Mode: editing selected text, or writing new text, by
// voice. Smart Cleanup has its own page; the two only meet when they share
// a model.

import SwiftUI

struct CommandModeSettingsPage: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VocaSettingsPageContent {
            VocaSettingsGroup("Command Mode") {
                AIFeatureRow(
                    title: "Edit by voice",
                    detail: "Select text in any app, press the shortcut, and say what to change. With nothing selected, say what to write.",
                    systemImage: "wand.and.stars",
                    tint: VocaDesign.command
                ) {
                    AIModelMenu(role: .commandMode)
                } status: {
                    status
                }
                .settingsTarget("command-mode-model")

                CommandModeExamples()

                Divider()

                ShortcutRecorderRow(
                    action: .commandMode,
                    detail: "Press once, speak, and press again — or hold it while speaking.",
                    title: "Shortcut"
                )
                .settingsTarget("command-mode-shortcut")

                if appState.cleanupEndpoint.isLocal {
                    Divider()
                    SettingsToggleRow(
                        title: "Use the Smart Cleanup model",
                        detail: sharingDetail,
                        isOn: Binding(
                            get: { appState.sharesAIModel },
                            set: { shared in
                                Task { @MainActor in await appState.setSharesAIModel(shared) }
                            }
                        )
                    )
                    .disabled(isDownloading)
                    .settingsTarget("command-mode-share")
                }

                AIModelDownloadProgress()
            }

            VocaSettingsGroup("Editing") {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Review edits before replacing")
                        Text("Shows what changed and waits. Press the Command Mode shortcut to replace, or Esc to discard.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    Picker("Review edits before replacing", selection: $appState.commandModeReview) {
                        ForEach(CommandReviewMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .settingsTarget("command-mode-review")

                Divider()

                SettingsToggleRow(
                    title: "Copy the selection when an app hides it",
                    detail: "For terminals and editors that don't share selected text.",
                    isOn: $appState.commandModeClipboardFallback
                )
                .help("VocaMac copies the selection with ⌘C and puts your clipboard back right away. Clipboard managers may briefly see the selected text.")
                .settingsTarget("command-mode-clipboard")
            }

            VocaSettingsGroup("Saved Commands") {
                SavedCommandsEditor()
            }
            .settingsTarget("command-mode-saved")

            VocaSettingsGroup("Voice Actions") {
                SettingsToggleRow(
                    title: "Voice actions",
                    detail: "Say “open Safari”, “search the web for…”, “remind me to…”, or “run the shortcut…”. Only what you say starts an action, never the selected text.",
                    isOn: $appState.voiceActionsEnabled
                )
                if appState.voiceActionsEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Shortcuts VocaMac may run")
                            .font(.caption)
                        TextEditor(text: $appState.voiceActionShortcuts)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 54)
                            .vocaTextEditor()
                            .accessibilityLabel("Shortcuts VocaMac may run, one per line")
                        Text("One name per line, as it appears in the Shortcuts app. A shortcut that isn't listed never runs. Selected text is passed to the shortcut as its input.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .settingsTarget("command-mode-actions")

            AIModelLibrary(role: .commandMode)
                .settingsTarget("command-mode-models")
        }
        .toggleStyle(.switch)
    }

    private var isDownloading: Bool {
        if case .downloading = appState.transcriptCleanup.modelState { return true }
        return false
    }

    /// Says in one sentence what sharing, or not sharing, means right now.
    private var sharingDetail: String {
        let cleanup = appState.selectedCleanupModelKind.descriptor.displayName
        if appState.sharesAIModel {
            return "\(cleanup) does both: one download, one model in memory."
        }
        switch appState.commandModeEngine {
        case .local(let kind) where kind == appState.selectedCleanupModelKind:
            return "Both use \(cleanup) for now, but choosing a model here won't change Smart Cleanup."
        case .local(let kind):
            if appState.usesSeparateCommandSlot(for: kind) {
                return "Smart Cleanup uses \(cleanup). This Mac has the memory to keep both loaded, so neither waits for the other."
            }
            return "Smart Cleanup uses \(cleanup). The two take turns in memory, so an edit starts slower. Turn this on to run both with one model."
        case .appleIntelligence, .endpoint:
            return "Off while Command Mode runs with \(appState.commandModeEngine.displayName)."
        }
    }

    @ViewBuilder
    private var status: some View {
        let engine = appState.commandModeEngine
        if appState.shortcut(for: .commandMode) == nil {
            // The Shortcut row below offers a suggested shortcut.
            AIStatusLine(text: "Off until it has a shortcut. Set one below.", systemImage: "keyboard", color: VocaDesign.warning)
        } else if case .local(let kind) = engine, !appState.transcriptCleanup.isDownloaded(kind) {
            HStack(spacing: 8) {
                AIStatusLine(text: "\(kind.descriptor.displayName) isn't downloaded yet.", systemImage: "arrow.down.circle", color: VocaDesign.warning)
                Button("Download \(kind.descriptor.sizeDescription)") {
                    Task { @MainActor in await appState.useAIModel(kind, for: .commandMode) }
                }
                .controlSize(.small)
                .disabled(isDownloading)
            }
        } else if let problem = appState.commandModeProblem(for: engine) {
            AIStatusLine(text: problem, systemImage: "exclamationmark.triangle.fill", color: VocaDesign.warning)
        } else if let combo = appState.shortcut(for: .commandMode) {
            AIStatusLine(
                text: "Ready. Select text, press \(KeyCodeReference.displayName(for: combo)), and say the edit.",
                systemImage: "checkmark.circle.fill",
                color: VocaDesign.command
            )
        }
    }
}

/// The user's saved Command Mode instructions: a name, the instruction, and
/// an optional shortcut each.
private struct SavedCommandsEditor: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let commands = appState.savedCommands
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Instructions you use often. Say a command's name in Command Mode, or give it a shortcut to run it on the selection without speaking.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                Button("Add") {
                    appState.savedCommands = commands + [SavedCommand(name: "", instruction: "")]
                }
                .controlSize(.small)
            }
            if commands.isEmpty {
                Button("Add “Fix grammar”, “Shorter”, and “More formal”") {
                    appState.savedCommands = SavedCommand.starters
                }
                .controlSize(.small)
            }
            ForEach(commands) { command in
                SavedCommandRow(command: command)
            }
        }
    }
}

private struct SavedCommandRow: View {
    @EnvironmentObject var appState: AppState
    let command: SavedCommand

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Name", text: binding(\.name))
                    .textFieldStyle(.voca)
                    .frame(width: 130)
                    .accessibilityLabel("Command name")
                TextField("Instruction, e.g. “fix grammar and spelling”", text: binding(\.instruction))
                    .textFieldStyle(.voca)
                    .accessibilityLabel("Instruction")
                Button {
                    appState.savedCommands = appState.savedCommands.filter { $0.id != command.id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this command")
                .accessibilityLabel("Delete \(command.name.isEmpty ? "command" : command.name)")
            }
            ShortcutRecorderRow(
                action: .savedCommand(command.id),
                detail: "Runs it on the selected text.",
                title: "Shortcut"
            )
            .font(.caption)
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func binding(_ keyPath: WritableKeyPath<SavedCommand, String>) -> Binding<String> {
        Binding(
            get: { appState.savedCommands.first { $0.id == command.id }?[keyPath: keyPath] ?? "" },
            set: { value in
                var commands = appState.savedCommands
                guard let index = commands.firstIndex(where: { $0.id == command.id }) else { return }
                commands[index][keyPath: keyPath] = value
                appState.savedCommands = commands
            }
        )
    }
}

/// Instructions that show the range of what Command Mode can do.
private struct CommandModeExamples: View {
    private static let phrases = [
        "make this shorter", "fix grammar and spelling", "make it more formal",
        "turn this into bullet points", "translate to Spanish", "write a polite reply",
        "uppercase", "sort these lines", "shorter still", "undo that",
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
        .padding(.leading, 42)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Example instructions: " + Self.phrases.joined(separator: ", "))
    }
}
