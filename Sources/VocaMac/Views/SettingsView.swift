// SettingsView.swift
// VocaMac
//
// Settings window for VocaMac configuration.
// Organized into tabs: General, Text, Models, Stats, Audio, Debug, About.

import SwiftUI

extension Notification.Name {
    static let showOnboarding = Notification.Name("com.vocamac.showOnboarding")
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            TextSettingsTab()
                .tabItem {
                    Label("Text", systemImage: "text.bubble")
                }

            ModelSettingsTab()
                .tabItem {
                    Label("Models", systemImage: "brain")
                }

            StatsSettingsTab()
                .tabItem {
                    Label("Stats", systemImage: "chart.xyaxis.line")
                }

            AudioSettingsTab()
                .tabItem {
                    Label("Audio", systemImage: "waveform")
                }

            DebugTab()
                .tabItem {
                    Label("Debug", systemImage: "ladybug")
                }

            AboutTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(minWidth: 620, minHeight: 560)
    }
}

// MARK: - General Settings

struct GeneralSettingsTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            // Activation Mode
            Section("Activation Mode") {
                Picker("Mode", selection: $appState.activationMode) {
                    ForEach(ActivationMode.allCases) { mode in
                        VStack(alignment: .leading) {
                            Text(mode.displayName)
                        }
                        .tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: appState.activationMode) { _ in
                    appState.syncHotKeyConfiguration()
                }

                Text(appState.activationMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Hotkey
            Section("Hotkey") {
                HotKeySelectionControl(
                    pickerLabel: "Activation Key",
                    footerText: "Choose a preset or record a key. VocaMac reserves this key while running."
                )

                if appState.activationMode == .doubleTapToggle {
                    HStack {
                        Text("Double-tap speed")
                        Slider(
                            value: $appState.doubleTapThreshold,
                            in: 0.2...0.8,
                            step: 0.05,
                            onEditingChanged: { isEditing in
                                if !isEditing {
                                    appState.syncHotKeyConfiguration()
                                }
                            }
                        )
                        Text("\(String(format: "%.2f", appState.doubleTapThreshold))s")
                            .monospacedDigit()
                            .frame(width: 40)
                    }

                    Text("Shorter = faster double-tap required. Longer = more forgiving.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Behavior") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { appState.launchAtLogin },
                    set: { appState.setLaunchAtLogin($0) }
                ))

                Toggle("Show mic indicator near cursor while recording", isOn: $appState.showCursorIndicator)
            }

        }
        .formStyle(.grouped)
    }
}

// MARK: - Text Settings

struct TextSettingsTab: View {
    @EnvironmentObject var appState: AppState

    private var selectedModel: LocalLLMModel {
        LocalLLMModel.model(for: appState.postProcessingModelID)
    }

    private var runnerReady: Bool {
        LocalLLMPostProcessor.runnerExists(at: appState.postProcessingRunnerPath)
    }

    private var brewAvailable: Bool {
        LocalLLMPostProcessor.detectedBrewPath() != nil
    }

    private var isPostProcessingSetupBusy: Bool {
        appState.isPreparingPostProcessingModel || appState.isInstallingLlamaCpp
    }

    private var canPrepareModel: Bool {
        runnerReady &&
        !isPostProcessingSetupBusy &&
        (selectedModel.reference != nil || !appState.postProcessingModelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        Form {
            Section("Language") {
                Picker("Transcription Language", selection: $appState.selectedLanguage) {
                    Text("Auto-detect").tag("auto")
                    Divider()
                    Group {
                        Text("English").tag("en")
                        Text("Spanish").tag("es")
                        Text("French").tag("fr")
                        Text("German").tag("de")
                        Text("Italian").tag("it")
                        Text("Portuguese").tag("pt")
                        Text("Dutch").tag("nl")
                    }
                    Divider()
                    Group {
                        Text("Chinese").tag("zh")
                        Text("Japanese").tag("ja")
                        Text("Korean").tag("ko")
                        Text("Hindi").tag("hi")
                        Text("Arabic").tag("ar")
                        Text("Russian").tag("ru")
                        Text("Turkish").tag("tr")
                        Text("Polish").tag("pl")
                        Text("Swedish").tag("sv")
                        Text("Ukrainian").tag("uk")
                    }
                }

                Toggle("Translate speech", isOn: $appState.translationEnabled)
            }

            Section("Custom Vocabulary") {
                TextEditor(text: $appState.customVocabulary)
                    .font(.body)
                    .frame(minHeight: 90)
                    .overlay(alignment: .topLeading) {
                        if appState.customVocabulary.isEmpty {
                            Text("kubectl, PostgreSQL, nginx, Grafana")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }

                let count = WhisperService.vocabularyTerms(from: appState.customVocabulary).count
                Text(count == 0
                    ? "Add names, jargon, or proper nouns."
                    : "\(count) term\(count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("AI Rewrite") {
                Toggle("Rewrite text before pasting", isOn: $appState.postProcessingEnabled)

                Picker("Model", selection: $appState.postProcessingModelID) {
                    ForEach(LocalLLMModel.catalog) { model in
                        Text("\(model.displayName) - \(model.detail)").tag(model.id)
                    }
                }
                .disabled(isPostProcessingSetupBusy)

                if selectedModel.id == LocalLLMModel.customID {
                    HStack {
                        TextField("GGUF model path", text: $appState.postProcessingModelPath)
                            .textFieldStyle(.roundedBorder)
                            .disabled(isPostProcessingSetupBusy)
                        Button {
                            chooseFile { appState.postProcessingModelPath = $0 }
                        } label: {
                            Label("Choose", systemImage: "folder")
                        }
                        .disabled(isPostProcessingSetupBusy)
                    }
                }

                HStack {
                    TextField("llama-server path", text: $appState.postProcessingRunnerPath)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isPostProcessingSetupBusy)
                    Button {
                        chooseFile { appState.postProcessingRunnerPath = $0 }
                    } label: {
                        Label("Choose", systemImage: "folder")
                    }
                    .disabled(isPostProcessingSetupBusy)
                }

                HStack {
                    Label(runnerReady ? "llama-server ready" : "llama-server not found", systemImage: runnerReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(runnerReady ? .green : .orange)

                    Spacer()

                    if !runnerReady, brewAvailable {
                        Button {
                            Task { @MainActor in await appState.installLlamaCpp() }
                        } label: {
                            Label("Install llama.cpp", systemImage: "terminal")
                        }
                        .disabled(appState.isInstallingLlamaCpp)
                    } else if !runnerReady {
                        Button {
                            NSWorkspace.shared.open(LocalLLMPostProcessor.installURL)
                        } label: {
                            Label("Install llama.cpp", systemImage: "safari")
                        }
                    }
                }

                HStack {
                    Button {
                        Task { @MainActor in await appState.preparePostProcessingModel() }
                    } label: {
                        Label("Prepare Selected Model", systemImage: "arrow.down.circle")
                    }
                    .disabled(!canPrepareModel)

                    if isPostProcessingSetupBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let message = appState.postProcessingSetupMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextEditor(text: $appState.postProcessingInstructions)
                    .font(.body)
                    .frame(minHeight: 90)
                    .overlay(alignment: .topLeading) {
                        if appState.postProcessingInstructions.isEmpty {
                            Text("Keep my tone concise, warm, and direct.")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            }

            Section("Insertion") {
                Toggle("Preserve clipboard after text injection", isOn: $appState.preserveClipboard)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            appState.refreshPostProcessingRunner()
        }
    }

    private func chooseFile(_ update: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            update(url.path)
        }
    }
}

// MARK: - Permission Row

struct PermissionRow: View {
    let name: String
    let icon: String
    let status: PermissionStatus
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .frame(width: 16)
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(name)
            Spacer()
            switch status {
            case .granted:
                Text("Granted")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .notDetermined:
                Button("Grant") { action() }
                    .controlSize(.small)
            case .denied:
                Button("Open Settings") { action() }
                    .controlSize(.small)
            }
        }
    }

    private var statusIcon: String {
        switch status {
        case .granted: return "checkmark.circle.fill"
        case .notDetermined: return "questionmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch status {
        case .granted: return .green
        case .notDetermined: return .orange
        case .denied: return .red
        }
    }
}

// MARK: - Model Settings

struct ModelSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var processMonitor = ProcessMonitor()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // System info
                if let capabilities = appState.systemCapabilities {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("System Information", systemImage: "cpu")
                                .font(.headline)
                                .padding(.bottom, 4)

                            HStack(spacing: 24) {
                                SystemInfoPill(icon: "cpu", label: "CPU", value: capabilities.processorName)
                                SystemInfoPill(icon: "memorychip", label: "RAM", value: "\(capabilities.physicalMemoryGB) GB")
                                SystemInfoPill(icon: "bolt.fill", label: "Metal", value: capabilities.supportsMetalAcceleration ? "Yes" : "No")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                        }
                        .padding(4)
                    }
                }

                // Resource usage
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Resource Usage", systemImage: "gauge.with.dots.needle.bottom.50percent")
                            .font(.headline)
                            .padding(.bottom, 4)

                        HStack(spacing: 24) {
                            SystemInfoPill(
                                icon: "cpu",
                                label: "CPU",
                                value: String(format: "%.1f%%", processMonitor.cpuUsage)
                            )
                            SystemInfoPill(
                                icon: "memorychip",
                                label: "Memory",
                                value: processMonitor.memoryMB >= 1024
                                    ? String(format: "%.1f GB", processMonitor.memoryMB / 1024)
                                    : String(format: "%.0f MB", processMonitor.memoryMB)
                            )
                            SystemInfoPill(
                                icon: "chart.line.uptrend.xyaxis",
                                label: "Peak",
                                value: processMonitor.memoryPeakMB >= 1024
                                    ? String(format: "%.1f GB", processMonitor.memoryPeakMB / 1024)
                                    : String(format: "%.0f MB", processMonitor.memoryPeakMB)
                            )
                            SystemInfoPill(
                                icon: "arrow.triangle.branch",
                                label: "Threads",
                                value: "\(processMonitor.threadCount)"
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(4)
                }

                // Currently active model
                if let current = appState.currentModel {
                    GroupBox {
                        HStack {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                                .font(.title3)
                            VStack(alignment: .leading) {
                                Text("Active Model: \(current.size.displayName)")
                                    .font(.callout)
                                    .fontWeight(.semibold)
                                Text("\(current.size.qualityDescription) quality • \(current.size.fileSizeDescription)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(4)
                    }
                }

                if let errorMessage = appState.errorMessage {
                    GroupBox {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button {
                                appState.errorMessage = nil
                                appState.appStatus = .idle
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Dismiss")
                        }
                        .padding(4)
                    }
                }

                // Model list
                GroupBox {
                    VStack(alignment: .leading, spacing: 0) {
                        Label("Available Models", systemImage: "list.bullet")
                            .font(.headline)
                            .padding(.bottom, 8)
                            .padding(.horizontal, 4)

                        ForEach(appState.availableModels) { model in
                            ModelRow(model: model, appState: appState)

                            if model.id != appState.availableModels.last?.id {
                                Divider()
                                    .padding(.horizontal, 4)
                            }
                        }
                    }
                    .padding(4)
                }

                // Info text
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("Models are downloaded from HuggingFace and cached locally. Larger models produce better results but are slower and use more memory.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let recommended = appState.deviceRecommendedModel,
                   let recommendedSize = appState.modelManager.modelSize(from: recommended) {
                    HStack {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Recommended for your device: **\(recommendedSize.displayName)**")
                                .font(.callout)
                            Text("Based on WhisperKit's tuned variants for your chip — not your RAM.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                HStack {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(.secondary)
                    Text("Model storage: \(appState.modelManager.diskUsageDescription())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }
}

struct SystemInfoPill: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ModelRow: View {
    let model: WhisperModelInfo
    @ObservedObject var appState: AppState
    @State private var showForceDownloadAlert = false

    var body: some View {
        HStack {
            // Status icon
            Image(systemName: model.statusIconName)
                .foregroundStyle(model.isActive ? .green : .secondary)
                .frame(width: 20)

            // Model info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.size.displayName)
                        .font(.callout)
                        .fontWeight(model.isActive ? .semibold : .regular)

                    if model.isSupported,
                       let recommended = appState.deviceRecommendedModel {
                        if appState.modelManager.modelSize(from: recommended) == model.size {
                            Text("Recommended")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.blue.opacity(0.2))
                                .foregroundStyle(.blue)
                                .cornerRadius(4)
                        }
                    }

                    if !model.isSupported {
                        Text("Experimental")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.2))
                            .foregroundStyle(.orange)
                            .cornerRadius(4)
                            .help("WhisperKit hasn't verified this model on your chip family. It may fail to load, or it may run slower than tuned models.")
                    }
                }

                HStack(spacing: 4) {
                    Text(model.size.fileSizeDescription)
                    Text("•")
                    Text(model.size.qualityDescription)
                    Text("•")
                    Text("~\(String(format: "%.0f", model.size.ramRequiredGB)) GB RAM")
                    Text("•")
                    Text("Speed: \(String(repeating: "⚡", count: max(1, 6 - model.size.relativeSpeed)))")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Download progress or loading indicator
            if let progress = model.downloadProgress {
                VStack(spacing: 2) {
                    ProgressView(value: progress)
                        .frame(width: 60)
                        .controlSize(.small)
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if model.isLoading {
                VStack(spacing: 2) {
                    ProgressView()
                        .frame(width: 60)
                        .controlSize(.small)
                    Text(model.loadingStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Action button
            if model.isActive {
                Label("Active", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if !model.isSupported {
                if model.isLoading || model.downloadProgress != nil {
                    EmptyView()
                } else if model.isDownloaded {
                    Button("Load Anyway") {
                        showForceDownloadAlert = true
                    }
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                } else {
                    Button("Try Anyway") {
                        showForceDownloadAlert = true
                    }
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                }
            } else if model.isLoading || model.downloadProgress != nil {
                // Show nothing - progress indicator handles the feedback
                EmptyView()
            } else if model.isDownloaded {
                Button("Load") {
                    Task { @MainActor in await appState.loadModel(model.size) }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            } else {
                Button("Download & Load") {
                    Task { @MainActor in
                        await appState.downloadModel(model.size)
                        if appState.availableModels.first(where: { $0.size == model.size })?.isDownloaded == true {
                            await appState.loadModel(model.size)
                        }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .alert("Use Experimental Model?", isPresented: $showForceDownloadAlert) {
            Button("Cancel", role: .cancel) {}
            Button(model.isDownloaded ? "Load Anyway" : "Download & Load", role: .destructive) {
                Task { @MainActor in
                    if !model.isDownloaded {
                        await appState.downloadModel(model.size)
                    }
                    if model.isDownloaded || appState.availableModels.first(where: { $0.size == model.size })?.isDownloaded == true {
                        await appState.loadModel(model.size)
                    }
                }
            }
        } message: {
            Text("WhisperKit hasn't verified this model on your chip family. It may fail to load, or it may run slower than tuned models.")
        }
    }
}

// MARK: - Audio Settings

struct AudioSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var audioDevices: [AudioDevice] = []

    var body: some View {
        Form {
            Section("Recording") {
                Picker("Max recording duration", selection: $appState.maxRecordingDuration) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("60 seconds").tag(60)
                    Text("120 seconds").tag(120)
                    Text("300 seconds (5 min)").tag(300)
                }
                .onChange(of: appState.maxRecordingDuration) { _ in
                    appState.syncHotKeyConfiguration()
                }

                Text("Recording will automatically stop after this duration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Silence Detection") {
                HStack {
                    Text("Sensitivity")
                    Slider(
                        value: $appState.silenceThreshold,
                        in: 0.001...0.05,
                        step: 0.001
                    )
                    Text(sensitivityLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }

                HStack {
                    Text("Auto-stop after silence")
                    Slider(
                        value: $appState.silenceDuration,
                        in: 0.5...5.0,
                        step: 0.5
                    )
                    Text("\(String(format: "%.1f", appState.silenceDuration))s")
                        .monospacedDigit()
                        .frame(width: 35)
                }

                Text("In double-tap mode, recording auto-stops after this duration of silence. In push-to-talk mode, you control when to stop by releasing the key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sound Effects") {
                Toggle("Enable sound effects", isOn: $appState.soundEffectsEnabled)

                Text("Play subtle audio cues when recording starts and stops.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Input Device") {
                Picker("Microphone", selection: $appState.selectedAudioDeviceID) {
                    Text("System Default").tag("")
                    if selectedAudioDeviceIsUnavailable {
                        Text("\(selectedAudioDeviceDisplayName) (Unavailable)").tag(appState.selectedAudioDeviceID)
                    }
                    ForEach(audioDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .onChange(of: appState.selectedAudioDeviceID) { _ in
                    syncSelectedAudioDeviceName()
                }

                if audioDevices.isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("No audio input devices found")
                            .foregroundStyle(.secondary)
                    }
                } else if selectedAudioDeviceIsUnavailable {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("\(selectedAudioDeviceDisplayName) is unavailable. VocaMac will use System Default until it reconnects.")
                            .foregroundStyle(.secondary)
                    }
                } else if let selectedAudioDevice {
                    HStack {
                        Image(systemName: "mic.circle.fill")
                            .foregroundStyle(.blue)
                        Text("VocaMac will record from \(selectedAudioDevice.name) without changing macOS' system default input.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(systemDefaultInputDescription)
                        .foregroundStyle(.secondary)
                }

                Button("Refresh Devices") {
                    refreshAudioDevices()
                }
                .controlSize(.small)

                Text("Choose System Default to follow macOS, or pin VocaMac to a specific microphone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshAudioDevices()
        }
    }

    private var selectedAudioDevice: AudioDevice? {
        guard !appState.selectedAudioDeviceID.isEmpty else { return nil }
        return audioDevices.first { $0.id == appState.selectedAudioDeviceID }
    }

    private var selectedAudioDeviceIsUnavailable: Bool {
        !appState.selectedAudioDeviceID.isEmpty && selectedAudioDevice == nil
    }

    private var selectedAudioDeviceDisplayName: String {
        appState.selectedAudioDeviceName.isEmpty ? "Selected microphone" : appState.selectedAudioDeviceName
    }

    private var systemDefaultInputDescription: String {
        if let defaultDevice = audioDevices.first(where: { $0.isDefault }) {
            return "VocaMac will follow macOS' system default input: \(defaultDevice.name)."
        }
        return "VocaMac will follow macOS' system default input."
    }

    private func refreshAudioDevices() {
        audioDevices = AudioEngine.availableInputDevices()
        syncSelectedAudioDeviceName()
    }

    private func syncSelectedAudioDeviceName() {
        guard !appState.selectedAudioDeviceID.isEmpty else {
            appState.selectedAudioDeviceName = ""
            return
        }

        if let selectedAudioDevice {
            appState.selectedAudioDeviceName = selectedAudioDevice.name
        }
    }

    private var sensitivityLabel: String {
        if appState.silenceThreshold < 0.01 { return "High" }
        if appState.silenceThreshold < 0.03 { return "Medium" }
        return "Low"
    }
}

// MARK: - About Tab

struct AboutTab: View {
    @EnvironmentObject var appState: AppState
    @State private var showingUpdateSheet = false
    @State private var updateInfoForSheet: UpdateInfo?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            // App icon
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            // App name and version
            Text("VocaMac")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Your voice, your Mac, your privacy.\nOpen-source dictation powered by AI.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("Version \(appVersionDisplay) (\(buildChannelLabel))")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button {
                Task { @MainActor in
                    await appState.updateChecker.checkForUpdates()
                    switch appState.updateChecker.updateState {
                    case .updateAvailable(let info), .updateAvailableViaHomebrew(let info, _):
                        updateInfoForSheet = info
                        showingUpdateSheet = true
                    default:
                        break
                    }
                }
            } label: {
                if case .checking = appState.updateChecker.updateState {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking for Updates...")
                    }
                    .font(.caption)
                } else {
                    Label("Check for Updates...", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)

            Text(updateStatusText)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()
                .frame(width: 200)

            // Tech info
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    if let capabilities = appState.systemCapabilities {
                        InfoRow2(label: "Device", value: capabilities.processorName)
                        InfoRow2(label: "Architecture", value: capabilities.isAppleSilicon ? "Apple Silicon (ARM64)" : "Intel (x86_64)")
                        InfoRow2(label: "Neural Engine", value: capabilities.supportsMetalAcceleration ? "Available" : "Not Available")
                    }
                    InfoRow2(label: "Engine", value: "WhisperKit")
                    InfoRow2(label: "Model", value: appState.whisperService.loadedModelName ?? "Not loaded")
                    InfoRow2(label: "Storage", value: appState.modelManager.diskUsageDescription())
                }
                .font(.caption)
                .padding(4)
            }
            .frame(width: 300)

            Divider()
                .frame(width: 200)

            // Links
            HStack(spacing: 16) {
                Link(destination: URL(string: "https://vocamac.com")!) {
                    Label("Website", systemImage: "globe")
                }
                Link(destination: URL(string: "https://github.com/jatinkrmalik/vocamac")!) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://github.com/argmaxinc/WhisperKit")!) {
                    Label("WhisperKit", systemImage: "waveform")
                }
            }
            .font(.caption)

            Divider()
                .frame(width: 200)

            Button(action: {
                NotificationCenter.default.post(name: .showOnboarding, object: nil)
            }) {
                Label("Show Setup Wizard…", systemImage: "wand.and.stars")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .help("Re-run the first-launch setup wizard")

            Spacer()

            HStack(spacing: 0) {
                Text("Made with ❤️ by ")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Link("Jatin Kumar Malik", destination: URL(string: "https://x.com/intent/user?screen_name=jatinkrmalik")!)
                    .font(.caption2)
            }
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .sheet(isPresented: $showingUpdateSheet) {
            if let info = updateInfoForSheet {
                UpdateDetailView(info: info)
                    .environmentObject(appState)
            }
        }
    }

    private var appVersionDisplay: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    private var buildChannelLabel: String {
        appVersionDisplay.contains("nightly") ? "Nightly" : "Beta"
    }

    private var updateStatusText: String {
        switch appState.updateChecker.updateState {
        case .upToDate:
            return "You are on the latest version."
        case .updateAvailable(let info):
            return "Update available: \(info.tagName)"
        case .updateAvailableViaHomebrew(_, let install):
            return "Update available via Homebrew. Run: \(install.upgradeCommand)"
        case .error(let message):
            return message
        case .downloading(let progress, _, _, _):
            return "Downloading update... \(Int(progress * 100))%"
        case .verifying:
            return "Verifying download integrity..."
        case .readyToInstall:
            return "Update downloaded. Open the DMG to install."
        case .checking:
            return "Checking for updates..."
        case .idle:
            return ""
        }
    }
}

// MARK: - Debug Tab

struct DebugTab: View {
    @EnvironmentObject var appState: AppState
    @State private var logEntryCount: Int = VocaLogger.logEntryCount

    var body: some View {
        Form {
            // Permissions
            Section("Permissions") {
                PermissionRow(
                    name: "Microphone",
                    icon: "mic.fill",
                    status: appState.micPermission,
                    action: { appState.requestMicrophonePermission() }
                )

                PermissionRow(
                    name: "Accessibility",
                    icon: "accessibility",
                    status: appState.accessibilityPermission,
                    action: { appState.requestAccessibilityPermission() }
                )

                PermissionRow(
                    name: "Input Monitoring",
                    icon: "keyboard",
                    status: appState.inputMonitoringPermission,
                    action: { appState.requestInputMonitoringPermission() }
                )

                if appState.micPermission == .denied || appState.accessibilityPermission == .denied || appState.inputMonitoringPermission == .denied {
                    Text("Denied permissions must be enabled manually in System Settings → Privacy & Security.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Re-check Permissions") {
                        appState.checkPermissions()
                    }
                    .controlSize(.small)

                    Spacer()

                    Button(action: resetPermissions) {
                        Label("Reset All Permissions", systemImage: "arrow.counterclockwise")
                            .foregroundStyle(.red)
                    }
                    .controlSize(.small)
                    .help("Reset all TCC permissions for VocaMac. The app will quit and you'll need to re-grant permissions on next launch.")
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.caption)
                    Text("**Upgrading?** Permissions now persist across updates since VocaMac is signed with a Developer ID. If permissions ever appear stuck, use the Reset button above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Debug Logs
            Section("Debug Logs") {
                LabeledContent("Log File") {
                    Text(VocaLogger.logFileURL().lastPathComponent)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Log Entries") {
                    Text("\(logEntryCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button(action: copyDebugLogs) {
                        Label("Copy to Clipboard", systemImage: "doc.on.clipboard")
                    }
                    .help("Copy last 500 lines of logs to clipboard")

                    Spacer()

                    Button(action: exportDebugLogs) {
                        Label("Export to File…", systemImage: "square.and.arrow.up")
                    }
                    .help("Save debug logs to file and reveal in Finder")

                    Spacer()

                    Button(action: {
                        VocaLogger.clearLogs()
                        logEntryCount = VocaLogger.logEntryCount
                    }) {
                        Label("Clear", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .help("Clear all log entries")
                }

                Text("Copy or export recent application logs for troubleshooting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Application
            Section("Application") {
                HStack {
                    Button(action: restartApp) {
                        Label("Restart VocaMac", systemImage: "arrow.trianglehead.clockwise")
                    }
                    .help("Quit and relaunch VocaMac")

                    Spacer()

                    Button(role: .destructive, action: {
                        NSApplication.shared.terminate(nil)
                    }) {
                        Label("Quit VocaMac", systemImage: "power")
                    }
                    .help("Quit VocaMac")
                }

                Text("Restart can help resolve issues with permissions or audio devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Actions

    private func resetPermissions() {
        let alert = NSAlert()
        alert.messageText = "Reset All Permissions?"
        alert.informativeText = "This will clear all permission grants (Microphone, Accessibility, Input Monitoring) for VocaMac. The app will quit and you'll need to re-grant permissions on next launch.\n\nThis is useful when permissions appear stuck or aren't being recognized after an update."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset & Quit")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Run tccutil to reset all TCC permissions for this app
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = ["reset", "All", "com.vocamac.app"]
            try? task.run()
            task.waitUntilExit()

            VocaLogger.info(.general, "TCC permissions reset via tccutil")

            // Quit the app so permissions take effect on next launch
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func restartApp() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundlePath, "--args", "--restarted"]
        try? task.run()

        // Give the new instance a moment to start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Debug Log Actions

    private func copyDebugLogs() {
        let logs = VocaLogger.exportLogs(lastLines: 500)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(logs, forType: .string)
    }

    private func exportDebugLogs() {
        let logs = VocaLogger.exportLogs(lastLines: 1000)

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "VocaMac-Debug-\(ISO8601DateFormatter().string(from: Date()).prefix(19)).log"
        savePanel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        savePanel.begin { response in
            if response == .OK, let fileURL = savePanel.url {
                do {
                    try logs.write(to: fileURL, atomically: true, encoding: .utf8)
                    NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: fileURL.deletingLastPathComponent().path)
                } catch {
                    VocaLogger.error(.general, "Failed to export logs: \(error)")
                }
            }
        }
    }
}

struct InfoRow2: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            Text(value)
                .fontWeight(.medium)
            Spacer()
        }
    }
}
