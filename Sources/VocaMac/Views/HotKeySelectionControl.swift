// HotKeySelectionControl.swift
// VocaMac
//
// Reusable hotkey picker with direct key recording for settings and onboarding.

import AppKit
import CoreGraphics
import SwiftUI

struct HotKeySelectionControl: View {
    @EnvironmentObject private var appState: AppState
    @State private var isRecording = false
    @State private var wasListeningBeforeRecording = false

    let pickerLabel: String
    let footerText: String?

    init(pickerLabel: String = "Preset", footerText: String? = nil) {
        self.pickerLabel = pickerLabel
        self.footerText = footerText
    }

    private var currentCombo: HotKeyCombo {
        HotKeyCombo(keyCode: appState.hotKeyCode, modifiers: appState.hotKeyModifiers)
    }

    /// A hotkey the presets do not cover still has to name itself in the
    /// button, the way the Picker's "Custom: …" row used to.
    private var currentDisplayName: String {
        let name = KeyCodeReference.displayName(for: currentCombo)
        return KeyCodeReference.isCommonHotKey(currentCombo) ? name : "Custom: \(name)"
    }

    private var comboBinding: Binding<HotKeyCombo> {
        Binding(
            get: { HotKeyCombo(keyCode: appState.hotKeyCode, modifiers: appState.hotKeyModifiers) },
            set: { newCombo in
                appState.hotKeyCode = newCombo.keyCode
                appState.hotKeyModifiers = newCombo.modifiers
                guard !isRecording else { return }
                appState.syncHotKeyConfiguration()
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(pickerLabel)

                // A Picker builds all 18 menu items up front, which measured
                // ~34ms of this page's load. A Menu builds them when it opens,
                // for ~9ms, and presents the same pull-down.
                Menu {
                    ForEach(KeyCodeReference.commonHotKeys, id: \.name) { hotKey in
                        let combo = HotKeyCombo(keyCode: hotKey.keyCode, modifiers: hotKey.modifiers)
                        Button {
                            comboBinding.wrappedValue = combo
                        } label: {
                            if combo == currentCombo {
                                Label(hotKey.name, systemImage: "checkmark")
                            } else {
                                Text(hotKey.name)
                            }
                        }
                    }
                } label: {
                    Text(currentDisplayName)
                }
                .fixedSize()
                .disabled(isRecording)
                .accessibilityLabel(pickerLabel)
                .accessibilityValue(currentDisplayName)

                HotKeyRecorderButton(
                    isRecording: $isRecording,
                    onStart: beginRecording,
                    onCancel: finishRecording,
                    onKeyRecorded: recordKey
                )
            }

            if isRecording {
                Label("Press a key, or press Escape to cancel", systemImage: "keyboard")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            } else if let footerText {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear {
            guard isRecording else { return }
            isRecording = false
            finishRecording()
        }
    }

    private func beginRecording() {
        wasListeningBeforeRecording = appState.hotKeyManager.isListening
        if wasListeningBeforeRecording {
            appState.hotKeyManager.stopListening()
        }
    }

    private func finishRecording() {
        if wasListeningBeforeRecording {
            restartHotKeyListener()
        }
        wasListeningBeforeRecording = false
    }

    private func recordKey(_ combo: HotKeyCombo) {
        appState.hotKeyCode = combo.keyCode
        appState.hotKeyModifiers = combo.modifiers
        appState.syncHotKeyConfiguration()
        finishRecording()
    }

    private func restartHotKeyListener() {
        appState.hotKeyManager.startListening(
            keyCode: appState.hotKeyCode,
            mode: appState.activationMode,
            doubleTapThreshold: appState.doubleTapThreshold,
            safetyTimeout: Double(appState.maxRecordingDuration) + 5.0,
            modifiers: appState.hotKeyModifiers
        )
    }
}

struct HotKeyRecorderButton: View {
    @Binding var isRecording: Bool

    let onStart: () -> Void
    let onCancel: () -> Void
    let onKeyRecorded: (HotKeyCombo) -> Void

    var body: some View {
        ZStack {
            Button {
                if isRecording {
                    isRecording = false
                    onCancel()
                } else {
                    onStart()
                    isRecording = true
                }
            } label: {
                Label(isRecording ? "Cancel" : "Record", systemImage: isRecording ? "xmark.circle" : "record.circle")
            }
            .controlSize(.small)

            if isRecording {
                HotKeyCaptureView(
                    onCapture: { combo in
                        isRecording = false
                        onKeyRecorded(combo)
                    },
                    onCancel: {
                        isRecording = false
                        onCancel()
                    }
                )
                .frame(width: 1, height: 1)
                .opacity(0)
                .accessibilityHidden(true)
            }
        }
    }
}

private struct HotKeyCaptureView: NSViewRepresentable {
    let onCapture: (HotKeyCombo) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> HotKeyCaptureNSView {
        let view = HotKeyCaptureNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: HotKeyCaptureNSView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
    }

    static func dismantleNSView(_ nsView: HotKeyCaptureNSView, coordinator: ()) {
        nsView.stopMonitoring()
    }
}

/// Thin lifecycle shell: starts the recorder while the (hidden) view is on
/// screen and cancels it if the settings window loses focus mid-recording.
private final class HotKeyCaptureNSView: NSView {
    var onCapture: ((HotKeyCombo) -> Void)? {
        get { recorder.onCapture }
        set { recorder.onCapture = newValue }
    }

    var onCancel: (() -> Void)? {
        get { recorder.onCancel }
        set { recorder.onCancel = newValue }
    }

    private let recorder = HotKeyComboRecorder()
    private var windowResignObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        recorder.start()
        installWindowObserver()
    }

    /// Silent teardown — used when SwiftUI removes the view (the parent's
    /// `onDisappear` already restores listener state), so it must not fire
    /// `onCancel` and double-report a completed capture.
    func stopMonitoring() {
        recorder.stop()

        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
            self.windowResignObserver = nil
        }
    }

    private func installWindowObserver() {
        guard windowResignObserver == nil, let window else { return }
        windowResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.recorder.cancel()
        }
    }

    deinit {
        stopMonitoring()
    }
}

/// Captures a hotkey combo (required modifiers + base key) from real input.
///
/// Uses a `CGEventTap` rather than an `NSEvent` local monitor. A local
/// monitor only sees keystrokes macOS has already declined to handle itself,
/// so combos the system reserves never arrive — ⌃Space and ⌃⌥Space are bound
/// to input-source switching, ⌘Space to Spotlight — and ⌘-based combos are
/// routed to menu key equivalents first. That made whole categories of
/// shortcut unrecordable. A session tap inserted at the head of the queue —
/// the same mechanism `HotKeyManager` already uses at runtime — sees every
/// keystroke before the system does, so any combination can be recorded.
/// Key-down events are consumed while recording so the shortcut being
/// recorded doesn't also fire its normal action.
private final class HotKeyComboRecorder {
    var onCapture: ((HotKeyCombo) -> Void)?
    var onCancel: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fallbackMonitor: Any?
    private var didFinish = false

    /// Key code of a modifier pressed while it was the *only* modifier held —
    /// a candidate for a legacy lone-modifier hotkey. Cleared as soon as a
    /// second modifier joins it, so a chord is never mistaken for a tap.
    private var singleModifierCandidateKeyCode: Int?

    /// Modifier key codes currently held, tracked per *physical key* rather
    /// than per shared flag, so Left+Right Shift register as two distinct
    /// keys even though they set the same modifier bit.
    private var heldModifierKeyCodes: Set<Int> = []

    private static let modifierKeyCodes = [54, 55, 56, 58, 59, 60, 61, 62, 63]

    func start() {
        guard eventTap == nil, fallbackMonitor == nil else { return }
        didFinish = false
        seedHeldModifiers()

        if installEventTap() { return }

        // No Accessibility permission — fall back to a local monitor. Ordinary
        // combos still record; macOS-reserved ones can't reach us this way.
        VocaLogger.warning(.hotKeyManager, "Recorder event tap unavailable — falling back to local monitor")
        fallbackMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let consumed: Bool
            switch event.type {
            case .keyDown:
                consumed = self.processKeyDown(
                    keyCode: Int(event.keyCode),
                    modifiers: HotKeyModifiers(nsFlags: event.modifierFlags),
                    isRepeat: event.isARepeat
                )
            case .flagsChanged:
                consumed = self.processFlagsChanged(keyCode: Int(event.keyCode))
            default:
                consumed = false
            }
            return consumed ? nil : event
        }
    }

    /// Tear down without reporting anything.
    func stop() {
        didFinish = true
        teardown()
    }

    /// Tear down and report the recording as cancelled (once).
    func cancel() {
        guard !didFinish else { return }
        didFinish = true
        teardown()
        DispatchQueue.main.async { [weak self] in
            self?.onCancel?()
        }
    }

    /// Reads actual physical key state so a modifier already held before the
    /// user clicks "Record" is known from the start rather than assumed absent.
    private func seedHeldModifiers() {
        let held = Self.modifierKeyCodes.filter {
            CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0))
        }
        heldModifierKeyCodes = Set(held)
        singleModifierCandidateKeyCode = held.count == 1 ? held[0] : nil
    }

    private func installEventTap() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let recorder = Unmanaged<HotKeyComboRecorder>.fromOpaque(userInfo).takeUnretainedValue()
                return recorder.handleTapEvent(type: type, event: event)
                    ? nil
                    : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        return true
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return false
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        switch type {
        case .keyDown:
            return processKeyDown(
                keyCode: keyCode,
                modifiers: HotKeyModifiers(cgEventFlags: event.flags),
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            )
        case .flagsChanged:
            return processFlagsChanged(keyCode: keyCode)
        default:
            return false
        }
    }

    /// A non-modifier key press finalizes immediately, using whatever
    /// modifiers are held at that moment (possibly none).
    private func processKeyDown(keyCode: Int, modifiers: HotKeyModifiers, isRepeat: Bool) -> Bool {
        guard !didFinish else { return false }
        guard !isRepeat else { return true }

        if keyCode == KeyCodeReference.escapeKeyCode {
            cancel()
            return true
        }

        finish(with: HotKeyCombo(keyCode: keyCode, modifiers: modifiers))
        return true
    }

    /// Modifier presses accumulate into a chord; a lone modifier pressed and
    /// released with nothing else joining it records as a single-key hotkey.
    /// Never consumes the event — modifiers must keep flowing to the system.
    private func processFlagsChanged(keyCode: Int) -> Bool {
        guard !didFinish, KeyCodeReference.isModifierKeyCode(keyCode) else { return false }

        if heldModifierKeyCodes.remove(keyCode) != nil {
            // This physical key was released.
            guard heldModifierKeyCodes.isEmpty else { return false }
            if singleModifierCandidateKeyCode == keyCode {
                finish(with: HotKeyCombo(keyCode: keyCode, modifiers: []))
            } else {
                singleModifierCandidateKeyCode = nil
            }
            return false
        }

        // Pressed. Only a press from zero-held is a lone-modifier candidate;
        // anything joining an existing hold is building a chord.
        singleModifierCandidateKeyCode = heldModifierKeyCodes.isEmpty ? keyCode : nil
        heldModifierKeyCodes.insert(keyCode)
        return false
    }

    private func finish(with combo: HotKeyCombo) {
        didFinish = true
        teardown()
        DispatchQueue.main.async { [weak self] in
            self?.onCapture?(combo)
        }
    }

    private func teardown() {
        if let fallbackMonitor {
            NSEvent.removeMonitor(fallbackMonitor)
            self.fallbackMonitor = nil
        }

        guard let tap = eventTap else { return }

        // Disable synchronously so no further callbacks can reach this object,
        // but defer removing the run loop source so the run loop is never
        // mutated from inside its own source callback.
        CGEvent.tapEnable(tap: tap, enable: false)
        let source = runLoopSource
        eventTap = nil
        runLoopSource = nil

        DispatchQueue.main.async {
            if let source {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
    }

    deinit {
        stop()
    }
}

// MARK: - HotKeyModifiers Conversion

extension HotKeyModifiers {
    /// Maps the 5 relevant NSEvent.ModifierFlags bits (Control/Option/Shift/
    /// Command/Fn) into our own canonical representation.
    init(nsFlags flags: NSEvent.ModifierFlags) {
        var result: HotKeyModifiers = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.function) { result.insert(.function) }
        self = result
    }
}
