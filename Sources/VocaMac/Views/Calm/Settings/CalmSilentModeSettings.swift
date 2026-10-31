// CalmSilentModeSettings.swift
// VocaMac
//
// Settings › Silent Mode (alpha): the switch and shortcut in the header,
// a live look through the camera to check framing and sensitivity, the
// camera and how the overlay shows it, taught silent commands with a check
// that they can be told apart, and what the camera does and doesn't keep.

import SwiftUI

/// Settings › Silent Mode.
struct CalmSilentModeSettings: View {
    @EnvironmentObject private var appState: AppState
    @State private var showsRecorder = false
    @State private var teaching: CalmSilentTeachDraft?
    @State private var confirmsDeleteAll = false
    @State private var importProblem: String?

    var body: some View {
        let isOn = appState.isSilentModeOn
        CalmPage(.sheet) {
            header(isOn: isOn)
                .settingsTarget("silent-mode")

            CalmSilentPreviewPanel()
                .settingsTarget("silent-mode-preview")

            CalmPanel {
                speakingRow
                    .settingsTarget("silent-mode-reading")
                lipModelRow
                    .settingsTarget("silent-mode-lip-model")
            }

            CalmPanel {
                cameraAccessRow
                if appState.silentMode.cameras.count > 1 {
                    cameraRow
                }
                sensitivityRow
                    .settingsTarget("silent-mode-sensitivity")
                CalmToggleRow(
                    "Show the camera picture",
                    description: "Off, the overlay draws only your lips’ outline, so a shared screen never shows your face",
                    isOn: showsVideoBinding
                )
                .settingsTarget("silent-mode-video")
                CalmToggleRow(
                    "Dictation key records silently too",
                    description: isOn
                        ? "Every dictation reads your lips until you turn this off"
                        : "Applies once Silent Mode is on",
                    isOn: $appState.silentModeUsesDictationKey
                )
                .disabled(!isOn)
                .settingsTarget("silent-mode-dictation-key")
            }

            CalmSilentCommandsSection(
                onTeach: { teaching = CalmSilentTeachDraft(appState: appState) },
                onAddTakes: { teaching = CalmSilentTeachDraft(editing: $0) }
            )
            .settingsTarget("silent-mode-commands")

            privacyPanel
                .settingsTarget("silent-mode-privacy")
        }
        .calmDialog(isPresented: $showsRecorder) {
            CalmShortcutRecorderDialog(target: .silentMode, current: appState.shortcut(for: .silentMode))
        }
        .calmDialog(item: $teaching) { draft in
            CalmSilentTeachDialog(draft: draft)
        }
        .calmDialog(isPresented: $confirmsDeleteAll) {
            CalmDialog(
                "Delete taught commands?",
                description: "Removes every silent command and its takes from this Mac."
            ) {
                CalmDialogFooter(primaryTitle: "Delete", primaryKind: .destructive) {
                    appState.deleteAllSilentCommands()
                }
            }
        }
        .onAppear { appState.silentMode.refresh() }
    }

    // MARK: Header

    private func header(isOn: Bool) -> some View {
        let caps = appState.shortcut(for: .silentMode).map(CalmKeyCaps.labels(for:)) ?? []
        return VStack(alignment: .leading, spacing: 10) {
            CalmFeatureHeader(
                "Silent Mode",
                isOn: Binding(
                    get: { appState.isSilentModeOn },
                    set: { isOn in
                        if !appState.setSilentModeOn(isOn) { showsRecorder = true }
                    }
                ),
                shortcut: caps.isEmpty ? nil : caps,
                shortcutCaption: isOn ? "to dictate silently" : nil,
                onShortcutTap: { showsRecorder = true }
            )
            HStack(spacing: 8) {
                CalmTag("Alpha", tone: .label)
                CalmTag("English only", tone: .neutral)
                Text("Mouth or whisper your words while the camera reads your lips. Only what your lips say is typed.")
                    .calmType(.description)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Rows

    private var speakingRow: some View {
        CalmRow(
            "How you’ll speak",
            description: appState.silentModeReadsLips
                ? "Mouth the words with no sound, as clearly as if you were speaking, facing the camera. The lip-reading model reads them."
                : "Whisper. The speech model decodes it, and the camera keeps out other voices."
        ) {
            CalmSegmentedControl(
                selection: $appState.silentModeReadsLips,
                options: [CalmOption(true, "Mouth"), CalmOption(false, "Whisper")],
                accessibilityLabel: "How you’ll speak"
            )
        }
    }

    @ViewBuilder
    private var lipModelRow: some View {
        if appState.isLipReadingModelInstalled {
            CalmStatusRow(
                "Lip-reading model",
                description: "Auto-AVSR, English. Its weights are for research and non-commercial use only.",
                tone: .success
            ) {
                Button("Remove") { try? appState.removeLipReadingModel() }.calmButton(.quietDestructive)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                CalmStatusRow(
                    "Lip-reading model",
                    description: appState.silentModeReadsLips
                        ? "Not installed, so mouthed words can’t be read yet; Silent Mode decodes a whisper instead. Build it with “make lip-reading-model” in VocaMac’s source folder; it installs itself."
                        : "Not installed. Needed only for mouthing without sound.",
                    tone: appState.silentModeReadsLips ? .warning : .neutral
                ) {
                    Button("Import…", action: importModel).calmButton(.primary)
                }
                if let importProblem {
                    CalmInlineNotice(importProblem, tone: .warning)
                        .padding(.horizontal, CalmMetrics.rowInset)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    private func importModel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose the folder with LipReader.mlpackage and tokens.json"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            try appState.installLipReadingModel(from: folder)
            importProblem = nil
        } catch {
            importProblem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @ViewBuilder
    private var cameraAccessRow: some View {
        switch appState.silentMode.cameraPermission {
        case .granted:
            CalmStatusRow("Camera", description: "Turns on only while Silent Mode records", tone: .success) {
                CalmAllowedLabel()
            }
        case .notDetermined:
            CalmStatusRow("Camera", description: "To read your lips", tone: .warning) {
                Button("Allow") { Task { await appState.silentMode.requestPermission() } }
                    .calmButton(.primary)
            }
        case .denied:
            CalmStatusRow("Camera", description: "Access is off. Turn it on for VocaMac in System Settings.", tone: .warning) {
                Button("Open System Settings") { CalmSilentModeLinks.openCameraPrivacy() }
                    .calmButton(.secondary)
            }
        }
    }

    private var cameraRow: some View {
        CalmRow("Camera to use") {
            CalmDropdown(
                selection: $appState.silentModeCameraID,
                options: [CalmOption("", "Built-in camera")]
                    + appState.silentMode.cameras.map { CalmOption($0.id, $0.name) }
            )
            .accessibilityLabel("Camera to use")
        }
    }

    private var sensitivityRow: some View {
        CalmRow(
            "Sensitivity",
            description: "Higher catches subtle mouthing; lower ignores small movements like chewing"
        ) {
            HStack(spacing: 10) {
                CalmSlider(
                    value: sensitivityBinding, in: ArticulationSensitivity.range, step: 0.1,
                    label: "Sensitivity", valueText: CalmSilentModeText.sensitivity(appState.silentModeSensitivity)
                )
                .frame(width: 140)
                Text(CalmSilentModeText.sensitivity(appState.silentModeSensitivity))
                    .font(CalmFont.note)
                    .foregroundStyle(CalmColor.muted)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }

    private var privacyPanel: some View {
        CalmPanel {
            CalmRow(
                "What the camera keeps",
                description: "Nothing. Each frame is reduced to your lips’ outline and, for lip reading, a small grayscale picture of your mouth, held in memory until it is read and then dropped. No picture is saved, logged or sent anywhere, and the camera is off unless Silent Mode is recording, this page’s preview is on, or you are teaching a command."
            )
            CalmRow(
                "Taught commands",
                description: "Saved as lip measurements in VocaMac’s folder on this Mac. They are left out of settings exports."
            ) {
                if !appState.silentCommands.isEmpty {
                    Button("Delete all") { confirmsDeleteAll = true }.calmButton(.quietDestructive)
                }
            }
        }
    }

    // MARK: Bindings

    private var sensitivityBinding: Binding<Double> {
        Binding(
            get: { appState.silentModeSensitivity },
            set: {
                appState.silentModeSensitivity = ArticulationSensitivity.clamped($0)
                appState.syncSilentModeSettings()
            }
        )
    }

    private var showsVideoBinding: Binding<Bool> {
        Binding(
            get: { appState.silentModeShowsVideo },
            set: {
                appState.silentModeShowsVideo = $0
                appState.syncSilentModeSettings()
            }
        )
    }
}

// MARK: - Preview

/// A look through the camera: the same tile the overlay shows, larger, with
/// what Silent Mode sees. The camera runs only while the preview is on and
/// the page is showing.
struct CalmSilentPreviewPanel: View {
    @EnvironmentObject private var appState: AppState
    @State private var isPreviewing = false

    private var showsCrop: Bool { appState.silentModeReadsLips && appState.isLipReadingModelInstalled }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            SilentFaceTile(live: appState.silentMode.live, cornerRadius: 12)
                .frame(width: 240, height: 180)
                .environment(\.colorScheme, .dark)
            if showsCrop {
                CalmSilentCropPreview(live: appState.silentMode.live)
            }
            CalmSilentPreviewStatus(live: appState.silentMode.live, isPreviewing: isPreviewing) {
                toggle()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .calmPanelBackground()
        .onDisappear(perform: stop)
    }

    private func toggle() {
        if isPreviewing {
            stop()
        } else {
            isPreviewing = true
            appState.syncSilentModeSettings()
            appState.silentMode.setPreviewShowsCrops(showsCrop)
            Task { await appState.silentMode.begin(.preview) }
        }
    }

    private func stop() {
        guard isPreviewing else { return }
        isPreviewing = false
        appState.silentMode.end(.preview)
    }
}

/// What the lip reader is given: the 88×88 mouth crop, enlarged. A mouth
/// centred and level here reads best.
private struct CalmSilentCropPreview: View {
    @ObservedObject var live: SilentLiveState

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(SilentPalette.tile)
                if let crop = live.mouthCrop {
                    Image(decorative: crop, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .frame(width: 120, height: 120)
            Text("What the lip reader sees")
                .font(CalmFont.note)
                .foregroundStyle(CalmColor.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The mouth picture the lip reader reads")
    }
}

/// The preview's text: what the camera sees, the level, and the button.
private struct CalmSilentPreviewStatus: View {
    @ObservedObject var live: SilentLiveState
    let isPreviewing: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Check your framing").calmType(.rowTitle)
            Text(isPreviewing ? live.phase.title : "Your mouth should be in view, facing the camera.")
                .font(CalmFont.body)
                .foregroundStyle(isProblem ? CalmColor.amber : CalmColor.ink)
            Text(isPreviewing ? live.phase.detail : "The bar fills when your lips move enough to count as speech.")
                .calmType(.description)
                .fixedSize(horizontal: false, vertical: true)
            SilentLevelBar(level: live.phase.hasFace ? live.level : 0)
                .frame(maxWidth: 220)
                .padding(.vertical, 4)
            Button(isPreviewing ? "Stop preview" : "Start preview", action: onToggle)
                .calmButton(isPreviewing ? .secondary : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isProblem: Bool {
        if case .unavailable = live.phase { return true }
        return false
    }
}

// MARK: - Commands

/// Taught silent commands: title, Teach a command, the list, and whether
/// they can be told apart.
struct CalmSilentCommandsSection: View {
    let onTeach: () -> Void
    let onAddTakes: (SilentCommand) -> Void

    @EnvironmentObject private var appState: AppState
    @State private var evaluation: LipCommandEvaluation?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                CalmSectionTitle("Silent commands")
                Spacer(minLength: 0)
                Button(action: onTeach) { CalmButtonLabel("Teach a command", icon: .plus) }
                    .calmButton(.primary)
                    .disabled(appState.untaughtSilentActions.isEmpty)
            }
            Text("Mouth one short word, like “send”, and VocaMac presses the key for it. A word it isn’t sure of is typed as dictation instead.")
                .calmType(.description)
                .fixedSize(horizontal: false, vertical: true)
            if appState.silentCommands.isEmpty {
                CalmPanel {
                    CalmRow("No commands yet", description: "Teach one by mouthing its word three times.")
                }
            } else {
                CalmPanel {
                    ForEach(appState.silentCommands) { command in
                        row(command)
                    }
                }
                verdict
            }
        }
        .task(id: appState.silentCommands) { await evaluate() }
    }

    private func row(_ command: SilentCommand) -> some View {
        CalmRow(command.action.title, description: CalmSilentModeText.commandLine(command)) {
            HStack(spacing: 8) {
                if !command.isReady {
                    CalmTag("Needs \(SilentCommand.minimumTakes - command.takes.count) more", tone: .warning)
                }
                Button("Add takes") { onAddTakes(command) }.calmButton(.secondary)
                Button {
                    appState.deleteSilentCommand(command.id)
                } label: {
                    CalmIcon(.trash, size: 15)
                }
                .calmIconButton()
                .help("Delete this command")
                .accessibilityLabel("Delete \(command.action.title)")
            }
        }
    }

    @ViewBuilder
    private var verdict: some View {
        if let evaluation {
            CalmInlineNotice(
                CalmSilentModeText.verdict(evaluation),
                tone: evaluation.isReliable ? .success : .warning
            )
        } else if appState.silentCommands.count < 2 {
            CalmInlineNotice("Teach a second command to check they can be told apart.", tone: .info)
        } else {
            CalmInlineNotice("Give each command three takes to check they can be told apart.", tone: .info)
        }
    }

    private func evaluate() async {
        let commands = appState.silentCommands
        evaluation = await Task.detached(priority: .utility) {
            LipCommandEvaluation.run(commands: commands)
        }.value
    }
}

// MARK: - Text

enum CalmSilentModeText {
    static func sensitivity(_ value: Double) -> String {
        switch ArticulationSensitivity.clamped(value) {
        case ..<0.8: return "Low"
        case ..<1.25: return "Normal"
        case ..<1.6: return "High"
        default: return "Highest"
        }
    }

    /// "Mouth “send” · 4 takes · Presses Return"
    static func commandLine(_ command: SilentCommand) -> String {
        let word = command.word.trimmingCharacters(in: .whitespacesAndNewlines)
        let takes = command.takes.count == 1 ? "1 take" : "\(command.takes.count) takes"
        let mouth = word.isEmpty ? nil : "Mouth “\(word)”"
        return [mouth, takes, command.action.detail].compactMap { $0 }.joined(separator: " · ")
    }

    static func verdict(_ evaluation: LipCommandEvaluation) -> String {
        let accuracy = Int((evaluation.accuracy * 100).rounded())
        let chance = Int((evaluation.chance * 100).rounded())
        let base = "In a self-test, \(accuracy)% of your \(evaluation.takeCount) takes matched the right command (guessing would get \(chance)%)."
        return evaluation.isReliable
            ? base
            : base + " Add takes, or pick words that look more different on the lips."
    }
}

enum CalmSilentModeLinks {
    @MainActor
    static func openCameraPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
}
