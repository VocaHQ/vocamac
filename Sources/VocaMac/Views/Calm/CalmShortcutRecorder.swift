// CalmShortcutRecorder.swift
// VocaMac
//
// The shortcut recorder (Dialogs board): one dialog for the dictation key,
// the hands-free shortcut, Paste last dictation and the Command Mode
// shortcut. States: waiting (accent ring, pulsing), captured, conflict
// (amber, Save disabled). Also the key box and the hidden key capture the
// saved-command dialog's inline recorder reuses.

import CoreGraphics
import SwiftUI

/// Which shortcut the recorder edits.
enum CalmShortcutTarget: String, Identifiable, Sendable {
    case dictationKey
    case handsFree
    case pasteLast
    /// Saving keys turns Command Mode on; Turn off clears them.
    case commandMode
    /// Saving keys turns Silent Mode on; Turn off clears them.
    case silentMode

    var id: String { rawValue }

    /// The secondary-shortcut action, nil for the dictation key.
    var action: HotKeyShortcutAction? {
        switch self {
        case .dictationKey: return nil
        case .handsFree: return .handsFreeToggle
        case .pasteLast: return .pasteLastDictation
        case .commandMode: return .commandMode
        case .silentMode: return .silentMode
        }
    }

    var title: String {
        switch self {
        case .dictationKey: return "Dictation key"
        case .handsFree: return "Hands-free shortcut"
        case .pasteLast: return "Paste last dictation"
        case .commandMode: return "Command Mode shortcut"
        case .silentMode: return "Silent Mode shortcut"
        }
    }
}

/// Records a shortcut. Opens waiting for keys; the dictation listener is
/// paused while it listens, so pressing the current key doesn't dictate.
struct CalmShortcutRecorderDialog: View {
    let target: CalmShortcutTarget

    @EnvironmentObject private var appState: AppState
    @Environment(\.calmDismissDialog) private var dismissDialog

    /// The keys to save: what was pressed, or the current shortcut.
    @State private var candidate: HotKeyCombo?
    @State private var mode: ActivationMode
    @State private var threshold: Double
    @State private var isWaiting: Bool
    /// Drives the hidden key capture; true while the recorder listens.
    @State private var isCapturing = false
    @State private var listenerWasRunning = false
    /// Whether a shortcut was saved when the dialog opened.
    private let hadShortcut: Bool

    /// - Parameters:
    ///   - current: The shortcut saved now (nil when unset).
    ///   - mode, threshold: How the dictation key starts (dictation key only).
    ///   - startsWaiting: Open listening for keys (the normal case).
    init(
        target: CalmShortcutTarget, current: HotKeyCombo?,
        mode: ActivationMode = CalmDictationKeyDefaults.mode,
        threshold: Double = CalmDictationKeyDefaults.doubleTapThreshold,
        startsWaiting: Bool = true
    ) {
        self.target = target
        _candidate = State(initialValue: current)
        _mode = State(initialValue: mode)
        _threshold = State(initialValue: threshold)
        _isWaiting = State(initialValue: startsWaiting)
        hadShortcut = current != nil
    }

    var body: some View {
        CalmDialog(target.title, description: description) {
            keyBox
            if let problem {
                CalmInlineNotice(problem, tone: .warning)
                    .padding(.top, -8)
            } else if !isWaiting, let candidate, let conflict = HotKeyComboRules.systemConflict(candidate) {
                CalmInlineNotice(conflict, tone: .info)
                    .padding(.top, -8)
            }
            if target == .dictationKey {
                startByRow
                if mode == .doubleTapToggle { speedRow }
            }
        } footer: {
            CalmDialogFooter(primaryTitle: "Save", isPrimaryEnabled: canSave, onPrimary: save) {
                leadingAction
            }
        }
        .background {
            CalmKeyCapture(isCapturing: $isCapturing, onCancel: captureCancelled, onCapture: captured)
        }
        .onAppear { if isWaiting { startWaiting() } }
        .onDisappear { stopCapture() }
    }

    // MARK: Copy

    private var description: String {
        switch target {
        case .dictationKey:
            return mode == .pushToTalk
                ? "Hold this key to talk. Pick one you don’t use for anything else."
                : "Double-tap this key to talk. Pick one you don’t use for anything else."
        case .handsFree: return "Press once to start, again to stop."
        case .pasteLast: return "Types your last dictation again."
        case .commandMode: return "Press it once, speak, and press it again. Or hold it while you speak."
        case .silentMode: return "Hold it while you whisper or mouth your words, or press it once and again to finish."
        }
    }

    private var waitingText: String {
        target == .dictationKey ? "Press the key you want…" : "Press the keys you want…"
    }

    // MARK: Validation

    /// Why the candidate can't be saved, or nil.
    private var problem: String? {
        guard !isWaiting, let candidate else { return nil }
        if let action = target.action {
            return ShortcutValidation.problem(with: candidate, action: action, appState: appState)
        }
        return ShortcutValidation.dictationHotKeyProblem(with: candidate, appState: appState)
    }

    private var canSave: Bool { !isWaiting && candidate != nil && problem == nil }

    // MARK: Pieces

    private var ringColor: Color {
        if isWaiting { return CalmColor.accent }
        return problem == nil ? CalmColor.line2 : CalmColor.amber
    }

    /// The 96-point key box. Clicking it when it isn't listening listens again.
    private var keyBox: some View {
        Button(action: startWaiting) {
            CalmKeyBox(ring: ringColor, isPulsing: isWaiting) {
                if isWaiting {
                    Text(waitingText).font(.system(size: 14)).foregroundStyle(CalmColor.muted)
                } else if let candidate {
                    CalmKeyCombo(combo: candidate, size: .large)
                    if problem == nil {
                        Text("Press again to change").font(.system(size: 12)).foregroundStyle(CalmColor.muted)
                    }
                } else {
                    Text("No shortcut yet").font(.system(size: 14)).foregroundStyle(CalmColor.muted)
                    Text("Click to record one").font(.system(size: 12)).foregroundStyle(CalmColor.muted)
                }
            }
        }
        .buttonStyle(CalmPlainFocusStyle(radius: 12))
        .focusEffectDisabled()
        .accessibilityLabel(isWaiting ? waitingText : "Record \(target.title.lowercased())")
        .accessibilityValue(candidate.map { CalmKeyCaps.labels(for: $0).joined(separator: " ") } ?? "None")
    }

    private var startByRow: some View {
        HStack(spacing: 16) {
            Text("Start by").calmType(.rowTitle)
            Spacer(minLength: 0)
            CalmSegmentedControl(
                selection: $mode,
                options: [CalmOption(.pushToTalk, "Holding it"), CalmOption(.doubleTapToggle, "Double-tapping")],
                accessibilityLabel: "Start by"
            )
        }
    }

    private var speedRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Double-tap speed").calmType(.rowTitle)
                Text("Longer is more forgiving").font(CalmFont.description).foregroundStyle(CalmColor.muted)
            }
            Spacer(minLength: 0)
            CalmSlider(
                value: $threshold, in: 0.2...0.8, step: 0.05,
                label: "Double-tap speed", valueText: String(format: "%.2f seconds", threshold)
            )
            .frame(width: 140)
            Text(String(format: "%.2f s", threshold))
                .font(CalmFont.note)
                .foregroundStyle(CalmColor.muted)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var leadingAction: some View {
        switch target {
        case .dictationKey:
            Button("Use default", action: useDefault).calmButton(.quiet)
        case .handsFree, .pasteLast:
            if let action = target.action, appState.shortcut(for: action) != nil {
                Button("Clear") {
                    appState.setShortcut(nil, for: action)
                    dismissDialog?()
                }
                .calmButton(.quiet)
            } else if target == .pasteLast {
                Button("Use default") {
                    stopCapture()
                    isWaiting = false
                    candidate = HotKeyCombo.defaultPasteLast
                }
                .calmButton(.quiet)
            }
        case .commandMode:
            if hadShortcut {
                Button("Turn off") {
                    stopCapture()
                    appState.setCommandModeOn(false)
                    dismissDialog?()
                }
                .calmButton(.quiet)
                .help("Clears the shortcut. The switch puts it back.")
            } else if let suggestion = ShortcutValidation.suggestion(for: .commandMode, appState: appState),
                      suggestion != candidate {
                Button("Use \(CalmCommandsText.keys(suggestion))") {
                    stopCapture()
                    isWaiting = false
                    candidate = suggestion
                }
                .calmButton(.quiet)
                .help("Three modifiers, which other apps rarely use")
            }
        case .silentMode:
            if hadShortcut {
                Button("Turn off") {
                    stopCapture()
                    appState.setSilentModeOn(false)
                    dismissDialog?()
                }
                .calmButton(.quiet)
                .help("Clears the shortcut. The switch puts it back.")
            } else if let suggestion = ShortcutValidation.suggestion(for: .silentMode, appState: appState),
                      suggestion != candidate {
                Button("Use \(CalmCommandsText.keys(suggestion))") {
                    stopCapture()
                    isWaiting = false
                    candidate = suggestion
                }
                .calmButton(.quiet)
                .help("Three modifiers, which other apps rarely use")
            }
        }
    }

    // MARK: Actions

    private func startWaiting() {
        guard !isCapturing else { return }
        isWaiting = true
        listenerWasRunning = appState.beginShortcutCapture()
        isCapturing = true
    }

    /// Stop listening without reporting anything.
    private func stopCapture() {
        guard isCapturing || appState.isCapturingShortcut else { return }
        isCapturing = false
        appState.endShortcutCapture(restartListener: listenerWasRunning)
        listenerWasRunning = false
    }

    private func captured(_ combo: HotKeyCombo) {
        candidate = combo
        isWaiting = false
        appState.endShortcutCapture(restartListener: listenerWasRunning)
        listenerWasRunning = false
    }

    /// The recorder stopped without keys: Escape, Tab, or the window lost
    /// focus. Escape closes the dialog, as it does everywhere else; the
    /// others leave it open showing the last keys.
    private func captureCancelled() {
        appState.endShortcutCapture(restartListener: listenerWasRunning)
        listenerWasRunning = false
        isWaiting = false
        if CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(KeyCodeReference.escapeKeyCode)) {
            dismissDialog?()
        }
    }

    private func useDefault() {
        stopCapture()
        isWaiting = false
        candidate = CalmDictationKeyDefaults.combo
        mode = CalmDictationKeyDefaults.mode
        threshold = CalmDictationKeyDefaults.doubleTapThreshold
    }

    private func save() {
        guard let candidate, problem == nil else { return }
        if let action = target.action {
            appState.setShortcut(candidate, for: action)
        } else {
            appState.applyDictationKey(candidate, mode: mode, doubleTapThreshold: threshold)
        }
    }
}

/// The recorder's key box: 96 high, r12, panel fill, a 1.5 pt ring, and a
/// soft accent halo that pulses every 1.2 s while it listens.
struct CalmKeyBox<Content: View>: View {
    let ring: Color
    var isPulsing = false
    let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    init(ring: Color, isPulsing: Bool = false, @ViewBuilder content: () -> Content) {
        self.ring = ring
        self.isPulsing = isPulsing
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 8) { content }
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .background(shape.fill(CalmColor.panel))
            .overlay(shape.strokeBorder(ring, lineWidth: 1.5))
            .overlay {
                if isPulsing {
                    RoundedRectangle(cornerRadius: 15.5, style: .continuous)
                        .strokeBorder(CalmColor.accentSoft, lineWidth: 3.5)
                        .padding(-3.5)
                        .opacity(pulse ? 0.2 : 1)
                        .onAppear {
                            guard !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { pulse = true }
                        }
                        .onDisappear { pulse = false }
                        .allowsHitTesting(false)
                }
            }
            .contentShape(shape)
    }
}

/// The hidden key capture behind a recorder: an event tap while
/// `isCapturing` is on (see `HotKeyRecorderButton`).
struct CalmKeyCapture: View {
    @Binding var isCapturing: Bool
    let onCancel: () -> Void
    let onCapture: (HotKeyCombo) -> Void

    var body: some View {
        HotKeyRecorderButton(isRecording: $isCapturing, onStart: {}, onCancel: onCancel, onKeyRecorded: onCapture)
            .frame(width: 0, height: 0)
            .opacity(0)
            .disabled(true)
            .accessibilityHidden(true)
    }
}
