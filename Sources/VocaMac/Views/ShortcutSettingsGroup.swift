// ShortcutSettingsGroup.swift
// VocaMac
//
// Settings for the shortcuts beyond the activation hotkey: paste the last
// dictation, hands-free dictation, Escape to cancel, and a mouse button.

import SwiftUI

struct ShortcutSettingsGroup: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VocaSettingsGroup("Shortcuts") {
            ShortcutRecorderRow(
                action: .pasteLastDictation,
                detail: "Type your last dictation again at the cursor — handy when it landed in the wrong place."
            )
            Divider()
            ShortcutRecorderRow(
                action: .handsFreeToggle,
                detail: "Press once to start and again to stop, without holding anything. Silence ends it too, per Settings → Audio."
            )
            Divider()
            ShortcutRecorderRow(
                action: .commandMode,
                detail: "Select text in another app, then press once, speak an edit, and press again. You can also hold the shortcut while speaking."
            )
            Divider()
            SettingsToggleRow(
                title: "Escape cancels dictation",
                detail: "Press Escape while recording or transcribing to throw the dictation away. A dictation cancelled while transcribing stays in History to retry.",
                isOn: Binding(
                    get: { appState.escapeCancelsDictation },
                    set: { appState.escapeCancelsDictation = $0; appState.syncShortcutConfiguration() }
                )
            )
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mouse button")
                    Text("Use an extra mouse button like the hotkey: hold it to talk, or double-click it in Double-Tap mode.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Picker("Mouse button", selection: Binding(
                    get: { MouseTriggerButton.resolved(stored: appState.mouseTriggerButton) },
                    set: { appState.mouseTriggerButton = $0.rawValue; appState.syncShortcutConfiguration() }
                )) {
                    ForEach(MouseTriggerButton.allCases) { button in
                        Text(button.displayName).tag(button)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

/// One shortcut: its current keys, a Record button, and a Clear button.
struct ShortcutRecorderRow: View {
    @EnvironmentObject var appState: AppState
    let action: HotKeyShortcutAction
    let detail: String

    @State private var isRecording = false
    @State private var wasListeningBeforeRecording = false
    @State private var problem: String?

    private var combo: HotKeyCombo? { appState.shortcut(for: action) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(action.displayName)
                    Text(detail)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Text(combo.map { KeyCodeReference.displayName(for: $0) } ?? "None")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(combo == nil ? .secondary : .primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("\(action.displayName) shortcut")
                    .accessibilityValue(combo.map { KeyCodeReference.displayName(for: $0) } ?? "None")
                HotKeyRecorderButton(
                    isRecording: $isRecording,
                    onStart: beginRecording,
                    onCancel: finishRecording,
                    onKeyRecorded: record
                )
                if combo != nil {
                    Button("Clear") { appState.setShortcut(nil, for: action) }
                        .controlSize(.small)
                        .disabled(isRecording)
                }
            }
            if isRecording {
                Label("Press the keys, or press Escape to cancel", systemImage: "keyboard")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            } else if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onDisappear {
            guard isRecording else { return }
            isRecording = false
            finishRecording()
        }
    }

    private func beginRecording() {
        problem = nil
        wasListeningBeforeRecording = appState.hotKeyManager.isListening
        if wasListeningBeforeRecording {
            appState.hotKeyManager.stopListening()
        }
    }

    private func finishRecording() {
        if wasListeningBeforeRecording {
            appState.hotKeyManager.startListening(
                keyCode: appState.hotKeyCode,
                mode: appState.activationMode,
                doubleTapThreshold: appState.doubleTapThreshold,
                safetyTimeout: Double(appState.maxRecordingDuration) + 5.0,
                modifiers: appState.hotKeyModifiers
            )
            appState.syncShortcutConfiguration()
        }
        wasListeningBeforeRecording = false
    }

    private func record(_ newCombo: HotKeyCombo) {
        defer { finishRecording() }
        if let reason = ShortcutValidation.problem(with: newCombo, action: action, appState: appState) {
            problem = reason
            return
        }
        appState.setShortcut(newCombo, for: action)
    }
}

/// Rules a secondary shortcut has to follow.
@MainActor
enum ShortcutValidation {
    /// Function keys are fine alone; anything else needs a modifier, or
    /// typing that letter anywhere would trigger the shortcut.
    static func problem(with combo: HotKeyCombo, action: HotKeyShortcutAction, appState: AppState) -> String? {
        if KeyCodeReference.isModifierKeyCode(combo.keyCode) {
            return "Use a key with modifiers, like ⌃⌘V. A modifier on its own is reserved for the dictation hotkey."
        }
        if combo.modifiers.isEmpty && !isFunctionKey(combo.keyCode) {
            return "Add ⌘, ⌃, or ⌥ so the shortcut doesn't fire while you type."
        }
        if combo == HotKeyCombo(keyCode: appState.hotKeyCode, modifiers: appState.hotKeyModifiers) {
            return "That's your dictation hotkey. Pick different keys."
        }
        for other in HotKeyShortcutAction.allCases where other != action && appState.shortcut(for: other) == combo {
            return "That's already the \(other.displayName.lowercased()) shortcut."
        }
        return nil
    }

    static func isFunctionKey(_ keyCode: Int) -> Bool {
        [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90].contains(keyCode)
    }
}
