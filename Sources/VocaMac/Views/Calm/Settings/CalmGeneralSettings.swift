// CalmGeneralSettings.swift
// VocaMac
//
// Settings › General: how dictation starts (dictation key, hands-free,
// Escape, paste last, mouse button), what it hears (microphone,
// languages), what shows while you talk, and a test dictation that keeps
// its result in the window.

import SwiftUI

/// Settings › General.
struct CalmGeneralSettings: View {
    @EnvironmentObject private var appState: AppState
    @Environment(CalmNavigator.self) private var navigator: CalmNavigator?

    @State private var recorder: CalmShortcutTarget?
    @State private var showsMicrophone = false
    @State private var showsOverlay = false
    @State private var audioDevices: [AudioDevice] = []

    var body: some View {
        CalmPage(.sheet) {
            CalmPageHeader("General")

            CalmPanel {
                dictationKeyRow
                    .settingsTarget("hotkey", aliases: ["activation-mode"])
                handsFreeRow
                    .settingsTarget("hands-free-shortcut")
                microphoneRow
                    .settingsTarget("microphone", aliases: ["closed-lid-microphone"])
                CalmValueRow("Languages", value: appState.calmLanguageSummary) {
                    navigator?.select(.languages)
                }
                CalmValueRow(
                    "While you talk",
                    value: CalmSettingsSummary.overlay(style: appState.overlayStyle, position: appState.overlayPosition)
                ) {
                    showsOverlay = true
                }
                .settingsTarget("cursor-overlay")
            }

            CalmPanel {
                CalmToggleRow("Escape cancels dictation", isOn: escapeBinding)
                    .settingsTarget("escape-cancel")
                shortcutRow(.pasteLast, title: "Paste last dictation")
                    .settingsTarget("paste-last-shortcut")
                CalmRow("Mouse button", description: "Start dictation with an extra mouse button") {
                    CalmDropdown(
                        selection: mouseBinding,
                        options: MouseTriggerButton.allCases.map { CalmOption($0, $0.displayName) }
                    )
                }
                .settingsTarget("mouse-trigger")
            }

            CalmPanel {
                CalmTestDictationRow()
            }
        }
        .calmDialog(item: $recorder) { target in
            recorderDialog(for: target)
        }
        .calmDialog(isPresented: $showsMicrophone) {
            CalmMicrophoneDialog(devices: audioDevices)
        }
        .calmDialog(isPresented: $showsOverlay) {
            CalmOverlayDialog()
        }
        .onAppear(perform: refreshDevices)
        .onReceive(NotificationCenter.default.publisher(for: .vocaAudioDevicesChanged)) { _ in refreshDevices() }
        .onChange(of: showsMicrophone) { _, isShowing in if !isShowing { refreshDevices() } }
    }

    // MARK: Rows

    private var dictationCombo: HotKeyCombo {
        HotKeyCombo(keyCode: appState.hotKeyCode, modifiers: appState.hotKeyModifiers)
    }

    private var dictationKeyRow: some View {
        let caps = CalmKeyCaps.labels(for: dictationCombo)
        let parts: [CalmKeyedPart] = appState.activationMode == .pushToTalk
            ? [.text("Hold"), .keys(caps), .text("and speak. Let go to type it.")]
            : [.text("Double-tap"), .keys(caps), .text("to start, again to stop.")]
        return CalmRow("Dictation key") {
            CalmKeyedLine(parts)
        } trailing: {
            Button("Change") { recorder = .dictationKey }.calmButton(.secondary)
        }
    }

    private var handsFreeRow: some View {
        shortcutRow(.handsFree, title: "Hands-free") { combo in
            CalmKeyedLine([.text("Press"), .keys(CalmKeyCaps.labels(for: combo)), .text("to start, again to stop")], spacing: 4)
        }
    }

    /// A secondary shortcut: its keys (or “Not set”) and Change / Set shortcut.
    private func shortcutRow<Line: View>(
        _ target: CalmShortcutTarget, title: String, @ViewBuilder line: @escaping (HotKeyCombo) -> Line
    ) -> some View {
        let combo = target.action.flatMap { appState.shortcut(for: $0) }
        return CalmRow(title) {
            if let combo {
                line(combo)
            } else {
                CalmRowDescription(text: "Not set")
            }
        } trailing: {
            Button(combo == nil ? "Set shortcut" : "Change") { recorder = target }.calmButton(.secondary)
        }
    }

    private func shortcutRow(_ target: CalmShortcutTarget, title: String) -> some View {
        shortcutRow(target, title: title) { combo in
            CalmKeyedLine([.text("Press"), .keys(CalmKeyCaps.labels(for: combo))], spacing: 4)
        }
    }

    private var microphoneRow: some View {
        let summary = CalmSettingsSummary.microphone(
            selectedID: appState.selectedAudioDeviceID,
            selectedName: appState.selectedAudioDeviceName,
            devices: audioDevices
        )
        return CalmRow("Microphone") {
            if summary.isUnavailable {
                CalmInlineNotice(summary.text, tone: .warning)
            } else {
                CalmRowDescription(text: summary.text)
            }
        } trailing: {
            HStack(spacing: 16) {
                CalmMicLevelMeter(meter: appState.audioMeter)
                Button("Change") { showsMicrophone = true }.calmButton(.secondary)
            }
        }
    }

    // MARK: Dialogs

    @ViewBuilder
    private func recorderDialog(for target: CalmShortcutTarget) -> some View {
        switch target {
        case .dictationKey:
            // Opens showing the current key, so changing only “Start by” or
            // the double-tap speed can be saved; click the key box to record.
            CalmShortcutRecorderDialog(
                target: target, current: dictationCombo,
                mode: appState.activationMode, threshold: appState.doubleTapThreshold,
                startsWaiting: false
            )
        case .handsFree, .pasteLast, .commandMode:
            CalmShortcutRecorderDialog(target: target, current: target.action.flatMap { appState.shortcut(for: $0) })
        }
    }

    // MARK: Bindings

    private var escapeBinding: Binding<Bool> {
        Binding(
            get: { appState.escapeCancelsDictation },
            set: {
                appState.escapeCancelsDictation = $0
                appState.syncShortcutConfiguration()
            }
        )
    }

    private var mouseBinding: Binding<MouseTriggerButton> {
        Binding(
            get: { MouseTriggerButton.resolved(stored: appState.mouseTriggerButton) },
            set: {
                appState.mouseTriggerButton = $0.rawValue
                appState.syncShortcutConfiguration()
            }
        )
    }

    private func refreshDevices() {
        audioDevices = appState.availableInputDevices()
    }
}

// MARK: - Test dictation

/// “Test dictation”: start and stop a dictation whose result stays here
/// instead of being typed. Replaces the old sidebar button.
struct CalmTestDictationRow: View {
    @EnvironmentObject private var appState: AppState

    private var result: String? {
        let text = appState.settingsTestResultText?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    var body: some View {
        CalmRow("Test dictation") {
            VStack(alignment: .leading, spacing: 10) {
                status
                if let result, !appState.isPracticeRecording, appState.appStatus != .processing {
                    CalmClampedText(text: result, lineLimit: 3)
                }
            }
        } trailing: {
            Button(appState.isPracticeRecording ? "Stop" : "Try it") {
                Task { @MainActor in await appState.toggleSettingsTestDictation() }
            }
            .calmButton(appState.isPracticeRecording ? .primary : .secondary)
            .disabled(!appState.canToggleSettingsTestDictation)
        }
        .onDisappear {
            Task { @MainActor in await appState.stopSettingsTestDictation() }
        }
    }

    @ViewBuilder
    private var status: some View {
        if appState.isPracticeRecording {
            HStack(spacing: 10) {
                CalmMicLevelMeter(meter: appState.audioMeter)
                CalmRowDescription(text: "Listening. Press Stop when you’re done.")
            }
        } else if appState.appStatus == .processing && appState.settingsTestResultText == nil {
            HStack(spacing: 8) {
                CalmSpinner(size: 14)
                CalmRowDescription(text: appState.processingStatusText)
            }
        } else if appState.isDictatingOutsideSettingsTest {
            CalmRowDescription(text: "Dictation is running elsewhere. Finish it with your shortcut first.")
        } else if appState.isAutoPaused {
            CalmRowDescription(text: "Dictation is paused while a listed app is open.")
        } else {
            CalmRowDescription(text: "Say something to check it works. Nothing is typed; the result shows here.")
        }
    }
}

/// Body text clamped to a few lines, with Show more / Show less when it is
/// actually cut off (measured, not guessed from its length).
struct CalmClampedText: View {
    let text: String
    var lineLimit = 3

    @State private var isExpanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var clampedHeight: CGFloat = 0

    private var isTruncated: Bool { fullHeight > clampedHeight + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .calmType(.body)
                .lineLimit(isExpanded ? nil : lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { if !isExpanded { clampedHeight = proxy.size.height } }
                            .onChange(of: proxy.size.height) { _, height in if !isExpanded { clampedHeight = height } }
                    }
                }
                .background(alignment: .topLeading) {
                    // The whole text, unseen, to learn how tall it would be.
                    Text(text)
                        .calmType(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .background {
                            GeometryReader { proxy in
                                Color.clear
                                    .onAppear { fullHeight = proxy.size.height }
                                    .onChange(of: proxy.size.height) { _, height in fullHeight = height }
                            }
                        }
                        .accessibilityHidden(true)
                }
            if isExpanded || isTruncated {
                Button(isExpanded ? "Show less" : "Show more") { isExpanded.toggle() }
                    .calmLink()
            }
        }
        .onChange(of: text) { isExpanded = false }
    }
}
