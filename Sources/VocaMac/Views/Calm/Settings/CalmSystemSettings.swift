// CalmSystemSettings.swift
// VocaMac
//
// Settings › System: how the app behaves (login, processing while you
// speak, the clipboard), sound and recording, and performance (pausing
// for heavy apps, unloading models when idle).

import SwiftUI

/// Settings › System.
struct CalmSystemSettings: View {
    @EnvironmentObject private var appState: AppState

    @State private var showsSilence = false
    @State private var showsAutoPause = false

    private static let recordingLimits: [CalmOption<Int>] = [
        CalmOption(15, "15 seconds"), CalmOption(30, "30 seconds"), CalmOption(60, "1 minute"),
        CalmOption(120, "2 minutes"), CalmOption(300, "5 minutes"), CalmOption(600, "10 minutes"),
        CalmOption(1200, "20 minutes"),
    ]

    private static let idleTimeouts: [CalmOption<Double>] = [
        CalmOption(60, "1 minute"), CalmOption(120, "2 minutes"), CalmOption(300, "5 minutes"),
        CalmOption(600, "10 minutes"), CalmOption(900, "15 minutes"), CalmOption(1800, "30 minutes"),
    ]

    var body: some View {
        CalmPage(.sheet) {
            CalmPageHeader("System")

            CalmGroup("App") {
                CalmPanel {
                    CalmToggleRow("Open at login", isOn: launchAtLoginBinding)
                        .settingsTarget("launch-at-login")
                    CalmToggleRow(
                        "Process while speaking",
                        description: "Long dictations paste sooner. Paused in Low Power Mode.",
                        isOn: $appState.processWhileSpeaking
                    )
                    .settingsTarget("process-while-speaking")
                    CalmToggleRow(
                        "Restore clipboard after typing",
                        description: "Puts back what you had copied",
                        isOn: $appState.preserveClipboard
                    )
                    .settingsTarget("clipboard")
                }
            }

            CalmGroup("Sound and recording") {
                CalmPanel {
                    soundRow
                        .settingsTarget("sound-effects")
                    CalmToggleRow("Mute other audio while dictating", isOn: $appState.duckOtherAudioEnabled)
                        .settingsTarget("other-audio")
                    // Pausing Spotify takes AppleScript, which the App Store build leaves out.
                    if AppDistribution.hasAppleScriptControl {
                        CalmToggleRow(
                            "Pause Spotify while dictating",
                            description: "Also reaches Spotify on other speakers. Asks permission the first time.",
                            isOn: $appState.pauseSpotifyEnabled
                        )
                        .settingsTarget("spotify-pause")
                    }
                    CalmRow("Longest recording", description: "Stops on its own after this long") {
                        CalmDropdown(selection: $appState.maxRecordingDuration, options: Self.recordingLimits)
                    }
                }
            }

            // Silence gets its own panel: a panel holds at most five rows.
            CalmGroup("Pauses") {
                CalmPanel {
                    CalmToggleRow(
                        "Skip silence",
                        description: "Cuts out pauses first, so it’s faster and quiet stretches don’t turn into made-up words",
                        isOn: $appState.skipSilence
                    )
                    .settingsTarget("skip-silence")
                    CalmValueRow(
                        "Silence",
                        value: CalmSettingsSummary.silence(
                            threshold: appState.silenceThreshold, duration: appState.silenceDuration
                        )
                    ) {
                        showsSilence = true
                    }
                    .settingsTarget("silence")
                }
            }

            CalmGroup("Performance") {
                CalmPanel {
                    autoPauseRow
                        .settingsTarget("auto-pause")
                    CalmToggleRow(
                        "Unload models when idle",
                        description: "Frees memory, Smart Cleanup’s model too. The next dictation starts a little later.",
                        isOn: $appState.modelKeepAliveEnabled
                    )
                    .settingsTarget("idle-unload")
                    if appState.modelKeepAliveEnabled {
                        CalmRow("After") {
                            CalmDropdown(selection: $appState.modelKeepAliveIdleTimeoutSeconds, options: Self.idleTimeouts)
                        }
                    }
                }
            }
        }
        .onChange(of: appState.maxRecordingDuration) { appState.syncHotKeyConfiguration() }
        .calmDialog(isPresented: $showsSilence) { CalmSilenceDialog() }
        .calmDialog(isPresented: $showsAutoPause) { CalmAutoPauseDialog() }
    }

    // MARK: Rows

    private var soundRow: some View {
        CalmRow("Start and stop sound") {
            HStack(spacing: 16) {
                Button {
                    Task { @MainActor in await appState.previewDictationTone() }
                } label: {
                    CalmIcon(.play, size: 15)
                }
                .calmIconButton()
                .disabled(appState.soundCue == .off)
                .help("Play")
                .accessibilityLabel("Play sound")
                CalmDropdown(
                    selection: $appState.soundCue,
                    options: DictationTone.allCases.map { CalmOption($0, $0.displayName) }
                )
            }
        }
    }

    private var autoPauseRow: some View {
        CalmRow("Pause for apps") {
            VStack(alignment: .leading, spacing: 4) {
                CalmRowDescription(
                    text: CalmSettingsSummary.autoPause(
                        isEnabled: appState.autoPauseEnabled, appNames: appState.autoPauseApps.map(\.displayName)
                    )
                )
                if appState.isAutoPaused {
                    CalmInlineNotice(CalmAutoPauseDialog.pausedNotice(trigger: appState.autoPauseTriggerDisplayName))
                }
            }
        } trailing: {
            Button("Change") { showsAutoPause = true }.calmButton(.secondary)
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { appState.launchAtLogin },
            set: { appState.setLaunchAtLogin($0) }
        )
    }
}
