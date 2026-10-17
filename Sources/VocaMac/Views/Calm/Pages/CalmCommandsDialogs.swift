// CalmCommandsDialogs.swift
// VocaMac
//
// The Commands page's dialogs: New / Edit command (with its own inline
// shortcut recorder and a delete confirmation step, since a dialog can't
// open another), the Shortcuts allow-list for voice actions, How it works,
// and Try it out. The Command Mode shortcut uses the shared recorder
// (`CalmShortcutRecorderDialog`).

import SwiftUI

// MARK: - New / Edit command

/// New command or Edit command: name, instruction and an optional
/// shortcut recorded in place. Editing adds Delete far left; deleting a
/// command with a shortcut asks first, in the same dialog.
struct CalmSavedCommandDialog: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.calmDismissDialog) private var dismissDialog

    @State private var draft: CalmSavedCommandDraft
    @State private var isConfirmingDelete: Bool
    @State private var isRecording = false
    @State private var listenerWasRunning = false
    @FocusState private var isNameFocused: Bool
    private let startsRecording: Bool

    init(draft: CalmSavedCommandDraft, startsConfirmingDelete: Bool = false, startsRecording: Bool = false) {
        _draft = State(initialValue: draft)
        _isConfirmingDelete = State(initialValue: startsConfirmingDelete)
        self.startsRecording = startsRecording
    }

    var body: some View {
        Group {
            if isConfirmingDelete {
                confirmation
            } else {
                editor
            }
        }
        .background {
            CalmKeyCapture(isCapturing: $isRecording, onCancel: recordingCancelled, onCapture: recorded)
        }
        .onAppear {
            if startsRecording {
                startRecording()
            } else if draft.isNew {
                DispatchQueue.main.async { isNameFocused = true }
            }
        }
        .onDisappear { stopRecording() }
    }

    // MARK: Editor

    private var editor: some View {
        let commands = appState.savedCommands
        return CalmDialog(draft.isNew ? "New command" : "Edit command", description: "Saved commands run on selected text.") {
            CalmTextField(
                "Name", text: $draft.name, prompt: "e.g. Shorter",
                error: draft.nameProblem(in: commands), focus: $isNameFocused
            )
            CalmTextEditor(
                "Instruction", text: $draft.instruction,
                prompt: "e.g. Cut this to half the length without losing facts."
            )
            shortcutRow
        } footer: {
            CalmDialogFooter(
                primaryTitle: draft.isNew ? "Create" : "Save",
                isPrimaryEnabled: canSave(commands),
                onPrimary: { appState.saveCommandDraft(draft) },
                leading: {
                    if !draft.isNew {
                        Button("Delete", action: delete).calmButton(.quietAmber)
                    }
                }
            )
        }
    }

    private func canSave(_ commands: [SavedCommand]) -> Bool {
        draft.isValid(in: commands) && !isRecording && shortcutProblem == nil
    }

    private var shortcutProblem: String? {
        guard let combo = draft.shortcut else { return nil }
        return ShortcutValidation.problem(with: combo, action: .savedCommand(draft.id), appState: appState)
    }

    private var shortcutRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shortcut").calmType(.rowTitle).foregroundStyle(CalmColor.ink)
                    Text(draft.shortcut == nil && !isRecording ? "Optional" : "Runs it without speaking")
                        .calmType(.description)
                        .foregroundStyle(CalmColor.muted)
                }
                Spacer(minLength: 0)
                shortcutControl
                    .fixedSize()
            }
            if let shortcutProblem, !isRecording {
                CalmInlineNotice(shortcutProblem, tone: .warning)
            }
        }
    }

    @ViewBuilder
    private var shortcutControl: some View {
        if isRecording {
            HStack(spacing: 8) {
                CalmRecordingKeyCap()
                Button("Cancel", action: stopRecording).calmButton(.quiet, size: .small)
            }
        } else if let combo = draft.shortcut {
            HStack(spacing: 8) {
                Button(action: startRecording) { CalmKeyCombo(combo: combo) }
                    .buttonStyle(CalmPlainFocusStyle(radius: 8))
                    .focusEffectDisabled()
                    .help("Record different keys")
                    .accessibilityLabel("Shortcut \(KeyCodeReference.displayName(for: combo)). Change")
                Button("Remove") { draft.shortcut = nil }
                    .calmButton(.quiet, size: .small)
            }
        } else {
            Button("Record shortcut", action: startRecording).calmButton(.secondary)
        }
    }

    // MARK: Delete

    private var savedCommand: SavedCommand? { appState.savedCommands.first { $0.id == draft.id } }

    private var confirmation: some View {
        let name = savedCommand.map(CalmCommandsText.commandName) ?? CalmCommandsText.commandName(
            SavedCommand(name: draft.name, instruction: draft.instruction)
        )
        let keys = savedCommand.flatMap { HotKeyCombo(storageString: $0.shortcut) }
            .map(CalmCommandsText.keys)
        let description = keys.map { "Its shortcut \($0) stops working. Your other commands are kept." }
            ?? "Your other commands are kept."
        return CalmDialog("Delete “\(name)”?", description: description) {
            CalmDialogFooter(
                primaryTitle: "Delete", primaryKind: .destructive,
                onCancel: { isConfirmingDelete = false },
                onPrimary: { appState.deleteSavedCommand(draft.id) }
            )
        }
    }

    /// Delete straight away, unless the command has a shortcut someone may
    /// rely on without looking.
    private func delete() {
        stopRecording()
        if let savedCommand, HotKeyCombo(storageString: savedCommand.shortcut) != nil {
            isConfirmingDelete = true
        } else {
            appState.deleteSavedCommand(draft.id)
            dismissDialog?()
        }
    }

    // MARK: Recording

    private func startRecording() {
        guard !isRecording else { return }
        listenerWasRunning = appState.beginShortcutCapture()
        isRecording = true
    }

    private func stopRecording() {
        guard isRecording || appState.isCapturingShortcut else { return }
        isRecording = false
        appState.endShortcutCapture(restartListener: listenerWasRunning)
        listenerWasRunning = false
    }

    private func recorded(_ combo: HotKeyCombo) {
        draft.shortcut = combo
        appState.endShortcutCapture(restartListener: listenerWasRunning)
        listenerWasRunning = false
    }

    /// Escape or a lost focus only stops recording; the dialog stays.
    private func recordingCancelled() {
        appState.endShortcutCapture(restartListener: listenerWasRunning)
        listenerWasRunning = false
    }
}

// MARK: - Shortcuts VocaMac may run

/// The voice-action allow-list: Shortcuts names, one per line.
struct CalmVoiceShortcutsDialog: View {
    @EnvironmentObject private var appState: AppState
    @State private var text: String

    init(text: String) {
        _text = State(initialValue: text)
    }

    var body: some View {
        CalmDialog(
            "Shortcuts VocaMac may run",
            description: "One name per line, as it appears in the Shortcuts app. A shortcut that isn’t listed never runs. Selected text is passed to it as its input."
        ) {
            CalmTextEditor(nil, text: $text, prompt: "Morning routine\nLog water", minHeight: 120)
                .accessibilityLabel("Shortcuts VocaMac may run, one per line")
        } footer: {
            CalmDialogFooter(primaryTitle: "Save") {
                appState.voiceActionShortcuts = SavedCommandStore.shortcutNames(from: text).joined(separator: "\n")
            }
        }
    }
}

// MARK: - How it works

/// How Command Mode works, step by step, with the wider set of examples.
struct CalmCommandsHowItWorksDialog: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let caps = appState.shortcut(for: .commandMode).map(CalmKeyCaps.labels(for:))
        CalmDialog("How Command Mode works", width: CalmMetrics.dialogListWidth) {
            VStack(alignment: .leading, spacing: 14) {
                step(1) {
                    Text("Select text in any app.")
                }
                step(2) {
                    if let caps {
                        CalmKeyedLine(
                            [.text("Press"), .keys(caps), .text("once, or hold it while you speak.")],
                            spacing: 5, capSize: .inline, font: CalmFont.body, color: CalmColor.ink
                        )
                    } else {
                        Text("Press the Command Mode shortcut once, or hold it while you speak. Set one in the page header.")
                    }
                }
                step(3) {
                    Text("Say what to change. With nothing selected, say what to write and it’s typed where the cursor is.")
                }
                step(4) {
                    Text(reviewLine)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Things to try").calmType(.caption).foregroundStyle(CalmColor.muted)
                FlowLayout(spacing: 6) {
                    ForEach(CalmCommandsText.moreExamples, id: \.self) { example in
                        Text("“\(example)”")
                            .font(CalmFont.description.italic())
                            .foregroundStyle(CalmColor.ink2)
                            .fixedSize()
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(CalmColor.panel2))
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } footer: {
            CalmDialogFooter(primaryTitle: "Done", cancelTitle: nil) {}
        }
    }

    private var reviewLine: String {
        switch appState.commandModeReview {
        case .never:
            return "The selection is replaced straight away. Saying “undo” puts your text back."
        case .longSelections:
            return "Long edits show a preview first: press the shortcut again to replace, or Esc to discard. Saying “undo” puts your text back."
        case .always:
            return "Every edit shows a preview first: press the shortcut again to replace, or Esc to discard. Saying “undo” puts your text back."
        }
    }

    private func step<Content: View>(_ number: Int, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(CalmFont.sf(12, weight: 650))
                .foregroundStyle(CalmColor.ink2)
                .frame(width: 22, height: 22)
                .background(Circle().fill(CalmColor.panel2))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            content()
                .font(CalmFont.body)
                .foregroundStyle(CalmColor.ink)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Try it out

/// Practice text to edit by voice, right here.
struct CalmCommandsTryDialog: View {
    let onSetShortcut: () -> Void

    @EnvironmentObject private var appState: AppState
    @State private var text = CalmCommandsTryDialog.sample

    static let sample = "hey team so basically the launch is moving to thursday because the build wasnt ready and we want more time to test it properly, sorry for the late notice"

    var body: some View {
        let combo = appState.shortcut(for: .commandMode)
        CalmDialog("Try it out") {
            if let combo {
                VStack(alignment: .leading, spacing: 6) {
                    CalmKeyedLine(
                        [.text("Select some of the text below, press"), .keys(CalmKeyCaps.labels(for: combo)), .text("and say")],
                        spacing: 5, capSize: .inline
                    )
                    Text("“make this shorter” or “fix the grammar”.").calmType(.description).foregroundStyle(CalmColor.muted)
                }
            } else {
                CalmInlineNotice("Command Mode needs a shortcut first.", tone: .warning)
            }
            CalmTextEditor(nil, text: $text, minHeight: 110)
                .accessibilityLabel("Practice text")
        } footer: {
            CalmDialogFooter(primaryTitle: "Done", cancelTitle: nil, onPrimary: {}, leading: {
                if combo == nil {
                    Button("Set shortcut", action: onSetShortcut).calmButton(.quiet)
                } else if text != Self.sample {
                    Button("Start over") { text = Self.sample }.calmButton(.quiet)
                }
            })
        }
    }
}
