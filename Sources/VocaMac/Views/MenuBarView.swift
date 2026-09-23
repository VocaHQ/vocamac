// MenuBarView.swift
// VocaMac
//
// The popover view shown when clicking the menu bar icon.
// Displays current status, audio level, last transcription, and quick actions.

import SwiftUI

// MARK: - Process Monitor

/// Polls the current process for CPU and memory usage every 5 seconds.
final class ProcessMonitor: ObservableObject {
    @Published var cpuUsage: Double = 0       // percentage (0–100+)
    @Published var memoryMB: Double = 0       // resident memory in MB
    @Published var memoryPeakMB: Double = 0   // peak memory seen
    @Published var threadCount: Int = 0       // active thread count

    private var timer: Timer?

    init(useTimer: Bool = true) {
        if useTimer {
            start()
        }
    }

    deinit { timer?.invalidate() }

    /// Poll only while a resource-usage view is visible.
    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One-shot resident memory sample for the current process (MB).
    static func currentResidentMemoryMB() -> Double {
        var taskInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(taskInfo.resident_size) / (1024 * 1024)
    }

    func refresh() {
        // --- Memory via mach_task_basic_info ---
        var taskInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let mb = Double(taskInfo.resident_size) / (1024 * 1024)
            DispatchQueue.main.async {
                self.memoryMB = mb
                self.memoryPeakMB = max(self.memoryPeakMB, mb)
            }
        }

        // --- CPU via task_threads + thread_basic_info ---
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let threadKr = task_threads(mach_task_self_, &threadList, &threadCount)
        guard threadKr == KERN_SUCCESS, let threads = threadList else { return }

        var totalCPU: Double = 0
        for i in 0..<Int(threadCount) {
            var threadInfo = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
            let infoKr = withUnsafeMutablePointer(to: &threadInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            if infoKr == KERN_SUCCESS && threadInfo.flags != TH_FLAGS_IDLE {
                totalCPU += Double(threadInfo.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
            // task_threads gives the caller a send right for every thread.
            // Releasing only the array leaks one right per sampled thread.
            mach_port_deallocate(mach_task_self_, threads[i])
        }

        let count2 = Int(threadCount)
        // Deallocate the thread list
        let size = vm_size_t(MemoryLayout<thread_t>.stride * Int(threadCount))
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), size)

        DispatchQueue.main.async {
            self.cpuUsage = totalCPU
            self.threadCount = count2
        }
    }
}

struct MenuBarView: View {
    /// Confirmation text after binding or clearing a style, if any.
    @State private var bindNotice: String?

    @EnvironmentObject var appState: AppState
    @ObservedObject var settingsManager: SettingsWindowManager
    @ObservedObject private var gateway = GatewayEmbedController.shared
    @ObservedObject var updateWindowManager: UpdateWindowManager
    @ObservedObject var fileTranscriptionManager: FileTranscriptionWindowManager
    @ObservedObject var scratchpadManager: ScratchpadWindowManager
    @ObservedObject var meetingCaptureManager: MeetingCaptureWindowManager
    @StateObject private var processMonitor = ProcessMonitor(useTimer: false)
    @State private var audioDevices: [AudioDevice] = []
    @State private var availableHeight: CGFloat = 640
    /// Measured heights of the scrolling middle and the pinned top and bottom.
    @State private var contentHeight: CGFloat = 0
    @State private var chromeHeight: CGFloat = 0

    /// MenuBarExtra sizes its window to the view's ideal size, and a
    /// ScrollView has no ideal height of its own — left flexible it collapses
    /// to nothing, and pinned to the screen it leaves dead space under short
    /// content. Give it exactly its content's height, capped so the whole
    /// panel still fits on the display.
    private var scrollHeight: CGFloat {
        max(0, min(contentHeight, availableHeight - chromeHeight))
    }

    private var contentOverflows: Bool {
        contentHeight > availableHeight - chromeHeight + 0.5
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                headerSection
                statusSection.menuPanelCard()
            }
            .padding([.horizontal, .top], MenuPanelMetrics.inset)
            .padding(.bottom, 10)
            .fixedSize(horizontal: false, vertical: true)
            .measureHeight(MenuChromeHeightKey.self)

            ScrollView {
                supplementaryContent
                    .padding(.horizontal, MenuPanelMetrics.inset)
                    .padding(.bottom, 10)
                    .measureHeight(MenuContentHeightKey.self)
            }
            .scrollIndicators(contentOverflows ? .automatic : .never)
            .frame(height: scrollHeight)

            VStack(spacing: 0) {
                Divider()
                    .padding(.horizontal, MenuPanelMetrics.inset)
                actionsSection
                    .padding(.horizontal, MenuPanelMetrics.inset - 6)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
            }
            .fixedSize(horizontal: false, vertical: true)
            .measureHeight(MenuChromeHeightKey.self)
        }
        .frame(width: MenuPanelMetrics.width)
        .background(MenuPanelWindowSizer(height: chromeHeight + scrollHeight))
        .onPreferenceChange(MenuContentHeightKey.self) { contentHeight = $0 }
        .onPreferenceChange(MenuChromeHeightKey.self) { chromeHeight = $0 }
        .tint(VocaDesign.accent)
        .onAppear {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            availableHeight = min(720, (screen?.visibleFrame.height ?? 760) - 40)
            processMonitor.start()
            bindNotice = nil
            appState.refreshActiveWritingStyle()
            Task { await gateway.refreshStatus() }
        }
        .onDisappear { processMonitor.stop() }
        // A "saved for Ghostty" notice is wrong once the user is in Discord.
        .onChange(of: appState.activeWritingTargetName) { _, _ in bindNotice = nil }
    }

    private var supplementaryContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let info = appState.updateChecker.activeUpdateInfo {
                UpdateBannerView(info: info, updateWindowManager: updateWindowManager)
                    .menuPanelCard()
            }

            // Setup problems come first: nothing else works until they are fixed.
            if appState.micPermission != .granted || appState.accessibilityPermission != .granted || appState.inputMonitoringPermission != .granted {
                permissionsSection
                    .menuPanelCard(padding: 0)
            }

            // A dictation that failed or was interrupted, with its audio saved
            if let entry = appState.recoverableHistoryEntry {
                recoverySection(entry)
                    .menuPanelCard()
            }

            // Microphone and writing style for the next dictation
            recordingOptionsSection
                .menuPanelCard(padding: 0)

            // A spelling the user fixed, offered for the dictionary
            if let suggestion = appState.dictionarySuggestions.first {
                suggestionSection(suggestion)
                    .menuPanelCard(padding: 10)
            }

            // Last Command Mode edit, which replaces the dictation card until
            // the next dictation so its original stays one click away.
            if let edit = appState.lastCommandEdit {
                commandEditSection(edit)
                    .menuPanelCard()
            } else if let transcription = appState.lastTranscription {
                transcriptionSection(transcription, output: appState.lastOutput)
                    .menuPanelCard()
            }

            if let held = appState.heldOutput {
                heldOutputSection(held)
                    .menuPanelCard()
            }
        }
    }

    private func heldOutputSection(_ held: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Saved dictation", systemImage: "tray.and.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                MenuPanelIconButton(systemImage: "doc.on.doc", help: "Copy saved dictation") {
                    appState.copyHeldOutput()
                }
            }
            Text("The destination changed before it could be typed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(held)
                .font(.callout)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Recording Options

    /// Microphone and writing style as one grouped list, the way System
    /// Settings lays out related choices.
    private var recordingOptionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            microphoneRow

            if appState.writingStyleEnabled {
                MenuPanelRowDivider()
                writingStyleRow
                // Only shown while a one-off override is waiting, so it can
                // be seen and cancelled.
                if appState.nextWritingProfile != nil {
                    MenuPanelRowDivider()
                    nextDictationRow
                }
            }

            if let notice = recordingOptionsNotice {
                MenuPanelRowDivider()
                notice
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
    }

    /// The one line of follow-up the rows above need, if any.
    private var recordingOptionsNotice: AnyView? {
        if let fallbackNotice = appState.inputDeviceFallbackNotice {
            return AnyView(Label(fallbackNotice, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange))
        }
        if appState.isSecureInputActive, appState.hotKeyIsKeyed {
            return AnyView(Label("Secure keyboard entry is on in another app. Your shortcut still works through a fallback.",
                                 systemImage: "lock.fill").foregroundStyle(.secondary))
        }
        if appState.isRecording {
            return AnyView(Text("Stop recording before changing the microphone.").foregroundStyle(.secondary))
        }
        if let bindNotice {
            return AnyView(Label(bindNotice, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary))
        }
        return nil
    }

    // MARK: - Writing Style

    /// A pending one-off override, with a way to cancel it. Choosing one lives
    /// in the Style menu, so this row only exists while one is waiting.
    private var nextDictationRow: some View {
        MenuPanelRow(
            title: "Next dictation only",
            systemImage: "forward.frame",
            tint: .indigo
        ) {
            HStack(spacing: 6) {
                Text(appState.nextWritingProfile.map(nextProfileLabel) ?? "")
                    .foregroundStyle(.secondary)
                Button {
                    appState.nextWritingProfile = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Cancel and use the app's usual style")
            }
        }
    }

    /// Which style dictation into the app in front will use. Picking a style
    /// remembers it for that app; the submenu applies one just once.
    private var writingStyleRow: some View {
        let appName = appState.activeWritingTargetName
        return MenuPanelRow(
            title: appName.map { "Style in \($0)" } ?? "Style",
            systemImage: appState.activeWritingStyle.style.systemImage,
            tint: .orange
        ) {
            Menu {
                Section(appName.map { "Always use in \($0)" } ?? "Always use") {
                    ForEach(WritingStyle.allCases) { style in
                        VocaMenuChoice(
                            title: style.displayName,
                            isSelected: style == appState.activeWritingStyle.style
                        ) {
                            bindNotice = appState.bindFrontmostApp(to: style)
                                .map { "\(style.displayName) style saved for \($0)" }
                        }
                    }
                }

                if appState.activeWritingStyle.matchedAppName != nil {
                    Button("Use My Default Style (\(appState.writingStyleDefault.displayName))") {
                        bindNotice = appState.unbindFrontmostApp()
                            .map { "\($0) now uses your default style" }
                    }
                }

                Divider()

                Menu("Just for the Next Dictation") {
                    Section("Style") {
                        ForEach(WritingStyle.allCases) { style in
                            Button(style.displayName) { appState.useNextWritingFormat(style) }
                        }
                    }
                    if appState.writingRewriteEnabled {
                        Section("Tone") {
                            ForEach(WritingIntent.allCases) { intent in
                                Button(intent.displayName) { appState.useNextWritingIntent(intent) }
                            }
                        }
                    }
                    Divider()
                    Button("Exactly as Transcribed") { appState.useRawForNextDictation() }
                }

                Divider()

                Button("Writing Style Settings…") {
                    appState.requestSettingsPage(.writingStyles)
                    settingsManager.open(appState: appState)
                }
            } label: {
                Text(writingStyleLabel)
            }
            .menuPanelValueMenu()
            .help("How text is formatted when you dictate into this app")
        }
    }

    private var writingStyleLabel: String {
        let resolved = appState.activeWritingStyle
        var style = resolved.style.displayName
        if appState.writingRewriteEnabled,
           resolved.profile.allowsRewrite,
           resolved.intent != .preserve {
            style += " · \(resolved.intent.displayName)"
        }
        return style
    }

    private func nextProfileLabel(_ profile: WritingProfile) -> String {
        guard profile.cleanup != .raw else { return "Exactly as transcribed" }
        guard appState.writingRewriteEnabled,
              profile.format.supportsWording,
              profile.intent != .preserve,
              profile.cleanup == .inherit else {
            return profile.format.displayName
        }
        return "\(profile.format.displayName) · \(profile.intent.displayName)"
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            BrandLogoView(size: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text("VocaMac")
                    .font(.system(size: 14, weight: .semibold))

                if let model = appState.currentModel {
                    Text(model.size.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if appState.whisperService.isModelLoaded {
                    Text("Model: \(appState.whisperService.loadedModelName ?? "Loaded")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if let downloadingModel = appState.availableModels.first(where: { $0.downloadProgress != nil }),
                          let progress = downloadingModel.downloadProgress {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Downloading \(downloadingModel.size.displayName)… \(Int(progress * 100))%")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.orange)
                    }
                } else if let loadingModel = appState.availableModels.first(where: { $0.isLoading }) {
                    Text("Loading \(loadingModel.size.displayName)…")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                } else if appState.isAutoPaused {
                    Text(appState.autoPauseTriggerDisplayName.map { "Unloaded (paused for \($0))" }
                         ?? "Unloaded (auto-paused)")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                } else if appState.lastModelUnloadReason == .idleKeepAlive {
                    Text("Unloaded (idle timeout)")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                } else {
                    Text("No model loaded")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 8)

            // CPU & RAM usage display (whole VocaMac process, not model-only)
            HStack(spacing: 2) {
                ResourceBadge(
                    icon: "cpu",
                    value: String(format: "%.0f%%", processMonitor.cpuUsage),
                    details: [
                        ("App CPU", String(format: "%.1f%%", processMonitor.cpuUsage)),
                        ("Threads", "\(processMonitor.threadCount)"),
                        ("Cores", "\(ProcessInfo.processInfo.activeProcessorCount)"),
                    ]
                )

                ResourceBadge(
                    icon: "memorychip",
                    value: formattedMemory(processMonitor.memoryMB),
                    details: [
                        ("App Memory (RSS)", String(format: "%.1f MB", processMonitor.memoryMB)),
                        ("Peak RSS (this session)", String(format: "%.1f MB", processMonitor.memoryPeakMB)),
                        ("System", "\(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)) GB"),
                    ]
                )
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                MenuPanelStatusDot(
                    color: statusColor,
                    isActive: appState.appStatus == .recording || appState.appStatus == .processing
                )

                Text(statusText)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    MenuPanelShortcutHint(verb: activationModeHint.verb, keys: activationModeHint.keys)
                    if appState.appStatus == .idle,
                       let combo = appState.shortcut(for: .commandMode) {
                        MenuPanelShortcutHint(
                            verb: "Edit",
                            keys: KeyCodeReference.displayName(for: combo),
                            tint: VocaDesign.command
                        )
                        .help("Select text in any app, press this, and say how to change it")
                    }
                }
            }

            if let unloadMessage = appState.modelUnloadStatusMessage,
               appState.appStatus == .idle || appState.isAutoPaused {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: appState.isAutoPaused ? "pause.circle.fill" : "memorychip")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(unloadMessage)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let freed = appState.approximateMemoryFreedMB {
                            Text(String(format: "About %.0f MB of process memory was released.", freed))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if let session = appState.commandModeSession {
                commandSessionCard(session)
            }

            // Audio level indicator (visible during recording)
            if appState.appStatus == .recording {
                ObservedAudioLevelView(
                    meter: appState.audioMeter,
                    tint: appState.commandModeSession == nil ? nil : VocaDesign.command
                )
                .frame(height: 6)

                if !appState.liveTranscript.isEmpty {
                    Text(appState.liveTranscript)
                        .font(.callout)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Live transcript")
                }

                // Stop/recovery button — visible during recording so the user
                // can unstick the app if the hotkey isn't responding
                Button {
                    Task { @MainActor in
                        await appState.stopRecordingAndTranscribe()
                    }
                } label: {
                    if appState.commandModeSession != nil {
                        Label("Finish Instruction", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(VocaDesign.command)
                    } else {
                        Label("Stop Recording", systemImage: "stop.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
                .buttonStyle(.plain)
            }

            // Processing indicator
            if appState.appStatus == .processing {
                if appState.commandModeSession != nil {
                    HStack {
                        ProgressView().controlSize(.small).tint(VocaDesign.command)
                        Spacer()
                        Button("Cancel Edit") {
                            Task { @MainActor in await appState.cancelDictation() }
                        }
                        .controlSize(.small)
                        .help("Leave the selection unchanged (Esc)")
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            // Force recovery button — visible in error state
            if appState.appStatus == .error {
                Button {
                    appState.forceRecovery()
                } label: {
                    Label("Reset to Idle", systemImage: "arrow.counterclockwise.circle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Microphone

    /// Provides a quick microphone switcher without requiring the Settings window.
    /// The selected device is persisted by AppState and takes effect on the next
    /// recording; it does not change macOS's global input-device selection.
    private var microphoneRow: some View {
        MenuPanelRow(title: "Microphone", systemImage: "mic.fill", tint: VocaDesign.accentSolid) {
            Menu {
                VocaMenuChoice(title: "System Default", isSelected: appState.selectedAudioDeviceID.isEmpty) {
                    appState.selectAudioDevice(nil)
                }

                if selectedAudioDeviceIsUnavailable {
                    Divider()
                    Text(selectedAudioDeviceDisplayName)
                }

                if !audioDevices.isEmpty {
                    Divider()
                }

                ForEach(audioDevices) { device in
                    VocaMenuChoice(title: device.name, isSelected: appState.selectedAudioDeviceID == device.id) {
                        appState.selectAudioDevice(device)
                    }
                }

                if audioDevices.isEmpty {
                    Text("No audio input devices found")
                }

                Divider()
                Button("Refresh List") { refreshAudioDevices() }
            } label: {
                Text(selectedAudioDeviceDisplayName)
            }
            .menuPanelValueMenu()
            .disabled(appState.isRecording)
            .help("Applies to the next recording. Does not change macOS's system default.")
        }
        .onAppear {
            refreshAudioDevices()
        }
        .onReceive(NotificationCenter.default.publisher(for: .vocaAudioDevicesChanged)) { _ in
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
        if appState.selectedAudioDeviceID.isEmpty {
            return "System Default"
        }
        if let selectedAudioDevice {
            return selectedAudioDevice.name
        }
        let storedName = appState.selectedAudioDeviceName.isEmpty
            ? "Selected microphone"
            : appState.selectedAudioDeviceName
        return "\(storedName) (Unavailable)"
    }

    private func refreshAudioDevices() {
        audioDevices = AudioEngine.availableInputDevices()
        if let selectedAudioDevice {
            appState.selectedAudioDeviceName = selectedAudioDevice.name
        }
    }

    // MARK: - Transcription

    private func transcriptionSection(
        _ result: VocaTranscription,
        output: DictationOutputResult?
    ) -> some View {
        // Other workflows (for example Command Mode and history retry) can
        // update lastOutput without producing a new lastTranscription. Only
        // pair an output with the raw transcript it was actually derived from.
        let matchingOutput = output?.original == result.text ? output : nil
        let displayedText = matchingOutput?.text ?? result.text
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Last Dictation")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                MenuPanelIconButton(systemImage: "doc.on.doc", help: "Copy to clipboard") {
                    copyToPasteboard(displayedText)
                }
            }

            Text(displayedText)
                .font(.callout)
                .lineLimit(4)
                .lineSpacing(1.5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let matchingOutput {
                Text(matchingOutput.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text([
                "\(String(format: "%.1f", result.audioLengthSeconds))s audio",
                "\(String(format: "%.1f", result.duration))s to transcribe",
                result.detectedLanguage.uppercased(),
            ].joined(separator: "  ·  "))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Finish Setting Up")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if appState.micPermission != .granted {
                MenuPanelRowDivider()
                permissionRow(
                    title: "Microphone",
                    detail: appState.micPermission == .denied
                        ? "Denied. Turn it on in Privacy & Security."
                        : "Captures your voice for transcription.",
                    systemImage: "mic.fill",
                    isDenied: appState.micPermission == .denied,
                    action: { appState.requestMicrophonePermission() }
                )
            }

            if appState.accessibilityPermission != .granted {
                MenuPanelRowDivider()
                permissionRow(
                    title: "Accessibility",
                    detail: "Needed for global hotkeys and typing text.",
                    systemImage: "accessibility",
                    isDenied: appState.accessibilityPermission == .denied,
                    action: { appState.requestAccessibilityPermission() }
                )
            }

            if appState.inputMonitoringPermission != .granted {
                MenuPanelRowDivider()
                permissionRow(
                    title: "Input Monitoring",
                    detail: "Needed to detect the hotkey in every app.",
                    systemImage: "keyboard",
                    isDenied: appState.inputMonitoringPermission == .denied,
                    action: { appState.requestInputMonitoringPermission() }
                )
            }
        }
        .padding(.bottom, 4)
    }

    /// A missing permission with its reason and one button to fix it.
    private func permissionRow(
        title: String,
        detail: String,
        systemImage: String,
        isDenied: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            MenuPanelSymbolTile(systemImage: systemImage, tint: isDenied ? .red : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(isDenied ? "Open…" : "Allow…", action: action)
                .controlSize(.small)
                .vocaGlassButton()
                .help(isDenied ? "Open System Settings" : "Ask macOS for access")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: - Recovery and Suggestions

    private func recoverySection(_ entry: DictationHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(recoveryTitle(entry), systemImage: "exclamationmark.arrow.circlepath")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("The \(String(format: "%.0f", entry.audioSeconds))-second recording is saved. Retry transcribes it again and copies the text\(pasteShortcutHint).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if appState.retryingHistoryEntryID == entry.id {
                    ProgressView().controlSize(.small)
                    Text("Transcribing…").font(.caption)
                } else {
                    Button("Retry") {
                        Task { await appState.retryHistoryEntry(entry.id) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(appState.retryingHistoryEntryID != nil)
                }
                Button("Dismiss") { appState.dismissRecovery(entry.id) }
                    .controlSize(.small)
                Spacer()
                Button("History…") { openHistory() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private func recoveryTitle(_ entry: DictationHistoryEntry) -> String {
        switch entry.status {
        case .interrupted: return "Your last dictation was interrupted"
        case .cancelled: return "Your last dictation was cancelled"
        default: return "Your last dictation failed"
        }
    }

    private var pasteShortcutHint: String {
        guard let combo = appState.shortcut(for: .pasteLastDictation) else { return "" }
        return " — then press \(KeyCodeReference.displayName(for: combo)) to paste it"
    }

    private func suggestionSection(_ suggestion: CorrectionSuggestion) -> some View {
        HStack(spacing: 10) {
            MenuPanelSymbolTile(systemImage: "character.book.closed", tint: VocaDesign.accentSolid)
            (Text("Spell it ") + Text(suggestion.corrected).fontWeight(.semibold) + Text(" next time?"))
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 6)
            Button("Add") { appState.acceptDictionarySuggestion(suggestion) }
                .controlSize(.small)
                .vocaGlassButton()
            MenuPanelIconButton(systemImage: "xmark", help: "Dismiss") {
                appState.dismissDictionarySuggestion(suggestion)
            }
            .accessibilityLabel("Dismiss suggestion")
        }
    }

    private func openHistory() {
        appState.requestSettingsPage(.history)
        settingsManager.open(appState: appState)
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(spacing: 1) {
            // One row for the three utility windows, so the tools don't push
            // History, Settings, and Quit down the menu.
            HStack(spacing: 8) {
                toolButton("Scratchpad", systemImage: "note.text",
                           help: "A floating note to dictate into") {
                    scratchpadManager.open(appState: appState)
                }
                toolButton("Transcribe File", systemImage: "waveform",
                           help: "Transcribe an audio or video file") {
                    fileTranscriptionManager.open(appState: appState)
                }
                toolButton("System Audio", systemImage: "speaker.wave.2.fill",
                           help: "Transcribe what this Mac is playing") {
                    meetingCaptureManager.open(appState: appState)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)

            menuRow("History", systemImage: "clock.arrow.circlepath",
                    shortcut: appState.shortcut(for: .pasteLastDictation)
                        .map { "Paste Last  \(KeyCodeReference.displayName(for: $0))" }) {
                openHistory()
            }
            menuRow("Settings…", systemImage: "gearshape", shortcut: "⌘,", keyEquivalent: ",") {
                settingsManager.open(appState: appState)
            }
            if gateway.status.allowsPairing {
                menuRow("Pair phone…", systemImage: "qrcode", shortcut: nil) {
                    settingsManager.open(appState: appState, page: .gateway, showPairing: true)
                }
            }
            menuRow("Quit VocaMac", systemImage: "power", shortcut: "⌘Q", keyEquivalent: "q") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    /// A full-width row that highlights like a native menu item. With a
    /// `keyEquivalent`, ⌘ plus that key triggers the row while the menu is
    /// open, so the shortcut it shows actually works.
    @ViewBuilder
    private func menuRow(
        _ title: String,
        systemImage: String,
        shortcut: String?,
        keyEquivalent: KeyEquivalent? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let row = menuRowButton(title, systemImage: systemImage, shortcut: shortcut, action: action)
        if let keyEquivalent {
            row.keyboardShortcut(keyEquivalent, modifiers: .command)
        } else {
            row
        }
    }

    private func menuRowButton(
        _ title: String,
        systemImage: String,
        shortcut: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.body)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    /// Shown while Command Mode listens or rewrites: what is being edited,
    /// where, and how to back out.
    private func commandSessionCard(_ session: CommandModeSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(VocaDesign.command)
                Text(session.phase == .rewriting
                     ? "Rewriting with \(session.engineName)"
                     : "Say how to change the selection")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 0)
            }
            if session.phase == .rewriting, let instruction = session.instruction, !instruction.isEmpty {
                Text("“\(instruction)”")
                    .font(.caption)
                    .lineLimit(2)
            }
            Text("Editing “\(session.selectionPreview)”")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(commandSessionDetail(session))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VocaDesign.command.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(VocaDesign.command.opacity(0.35))
        )
        .accessibilityElement(children: .combine)
    }

    private func commandSessionDetail(_ session: CommandModeSession) -> String {
        var parts = ["\(session.characterCount) characters"]
        if let app = session.appName, !app.isEmpty { parts[0] += " in \(app)" }
        parts.append("Esc leaves it unchanged")
        return parts.joined(separator: " · ")
    }

    private func commandEditSection(_ edit: CommandModeEdit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Last Edit", systemImage: "wand.and.stars")
                    .font(.subheadline)
                    .foregroundStyle(VocaDesign.command)
                Spacer()
                Text(edit.engineName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("“\(edit.instruction)”")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(edit.replacement.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.callout)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("Copy Original") { copyToPasteboard(edit.original) }
                    .help("Copy the text as it was before the edit")
                Button("Copy Result") { copyToPasteboard(edit.replacement) }
                Spacer()
            }
            .controlSize(.small)
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Helpers

    private func toolButton(
        _ title: String,
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(VocaDesign.accent)
                    // Symbols differ in height; a fixed box keeps the three
                    // titles on one baseline.
                    .frame(height: 18)
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: MenuPanelMetrics.tileRadius, style: .continuous))
        }
        .buttonStyle(MenuPanelTileButtonStyle())
        .help(help)
        .accessibilityLabel(title)
    }

    private var statusText: String {
        if let session = appState.commandModeSession {
            switch (appState.appStatus, session.phase) {
            case (.recording, _): return "Command Mode — listening"
            case (_, .rewriting): return "Rewriting selection…"
            default: return "Transcribing instruction…"
            }
        }
        if appState.isAutoPaused {
            return appState.autoPauseTriggerDisplayName.map { "Paused (\($0))" } ?? "Auto-paused"
        }
        switch appState.appStatus {
        case .idle:       return "Ready"
        case .recording:  return "Recording..."
        case .processing: return "Transcribing..."
        case .error:      return appState.errorMessage ?? "Error"
        }
    }

    private var statusColor: Color {
        if appState.commandModeSession != nil { return VocaDesign.command }
        if appState.isAutoPaused { return .orange }
        switch appState.appStatus {
        case .idle:       return VocaDesign.success
        case .recording:  return Color(nsColor: BrandAssets.brandGreen)
        case .processing: return .yellow
        case .error:      return .orange
        }
    }

    private var activationModeHint: (verb: String, keys: String) {
        let keyName = KeyCodeReference.displayName(for: HotKeyCombo(keyCode: appState.hotKeyCode, modifiers: appState.hotKeyModifiers))
        switch appState.activationMode {
        case .pushToTalk:
            return ("Hold", keyName)
        case .doubleTapToggle:
            return ("Double-tap", keyName)
        }
    }

    /// Formats memory in MB to a compact human-readable string
    private func formattedMemory(_ mb: Double) -> String {
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }
}

// MARK: - Menu Row Button Style

/// A button style that highlights on hover, matching native macOS menu behavior.
struct MenuRowButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : isHovered ? 0.08 : 0))
            )
            .onHover { isHovered = $0 }
    }
}

// MARK: - Menu Panel Components

enum MenuPanelMetrics {
    static let width: CGFloat = 380
    static let inset: CGFloat = 12
    static let cardRadius: CGFloat = 14
    static let tileRadius: CGFloat = 11
}

/// Keeps the MenuBarExtra window exactly as tall as the panel.
///
/// `.menuBarExtraStyle(.window)` sizes its window when it opens but does not
/// follow later changes — shrinking in particular. The panel then sat at the
/// bottom of a taller window, leaving a strip of the window's glass and
/// shadow showing above it. Resize the window ourselves, pinned to its top
/// edge under the menu bar, and rebuild the shadow for the new shape.
private struct MenuPanelWindowSizer: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> SizerView { SizerView() }

    func updateNSView(_ view: SizerView, context: Context) {
        view.targetHeight = height
    }

    final class SizerView: NSView {
        var targetHeight: CGFloat = 0 {
            didSet { if abs(targetHeight - oldValue) > 0.5 { scheduleResize() } }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleResize()
        }

        private func scheduleResize() {
            // Resizing inside SwiftUI's layout pass re-enters it; wait a turn.
            DispatchQueue.main.async { [weak self] in self?.resizeWindow() }
        }

        private func resizeWindow() {
            guard let window, targetHeight > 1 else { return }
            let current = window.frame
            let contentRect = window.contentRect(forFrameRect: current)
            let desired = window.frameRect(forContentRect: NSRect(
                x: contentRect.minX,
                y: contentRect.maxY - targetHeight,
                width: contentRect.width,
                height: targetHeight
            ))
            guard abs(desired.height - current.height) > 0.5 else { return }
            window.setFrame(desired, display: true)
            window.invalidateShadow()
        }
    }
}

private struct MenuContentHeightKey: SwiftUI.PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Summed across the pinned top and bottom of the panel.
private struct MenuChromeHeightKey: SwiftUI.PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

private extension View {
    func measureHeight<Key: SwiftUI.PreferenceKey>(_ key: Key.Type) -> some View where Key.Value == CGFloat {
        background(GeometryReader { proxy in
            Color.clear.preference(key: key, value: proxy.size.height)
        })
    }
}

/// The grouped surface every section of the panel sits on. The panel's own
/// material shows through, so cards read as layers rather than grey boxes.
private struct MenuPanelCard: ViewModifier {
    var padding: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: MenuPanelMetrics.cardRadius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.055), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.07)))
    }
}

extension View {
    fileprivate func menuPanelCard(padding: CGFloat = 12) -> some View {
        modifier(MenuPanelCard(padding: padding))
    }

    /// A pull-down that shows its current value at the trailing edge of a row.
    fileprivate func menuPanelValueMenu() -> some View {
        self
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.secondary)
            .tint(.secondary)
            .font(.body)
    }
}

/// A System Settings–style list row: tinted symbol, title, trailing control.
private struct MenuPanelRow<Accessory: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            MenuPanelSymbolTile(systemImage: systemImage, tint: tint)
            Text(title)
                .font(.body)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 12)
            accessory
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
    }
}

/// A small filled rounded square holding a white symbol.
private struct MenuPanelSymbolTile: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Hairline between rows, inset past the symbol tile like a grouped list.
private struct MenuPanelRowDivider: View {
    var body: some View {
        Divider().padding(.leading, 44)
    }
}

private struct MenuPanelStatusDot: View {
    let color: Color
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.22))
                .frame(width: 18, height: 18)
                .scaleEffect(isActive && pulse ? 1.25 : 1)
                .opacity(isActive && pulse ? 0.35 : 1)
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .frame(width: 20, height: 20)
        .onAppear { startPulse() }
        .onChange(of: isActive) { startPulse() }
        .accessibilityHidden(true)
    }

    private func startPulse() {
        guard isActive, !reduceMotion else {
            pulse = false
            return
        }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

/// "Hold ⌥ Space" with the keys drawn as a keycap.
private struct MenuPanelShortcutHint: View {
    let verb: String
    let keys: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 5) {
            Text(verb)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(keys)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint == .secondary ? Color.primary : tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10))
                )
        }
        .accessibilityElement(children: .combine)
    }
}

/// A borderless symbol button with a hover highlight.
private struct MenuPanelIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Utility tile: a card that brightens on hover and dims when pressed.
private struct MenuPanelTileButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: MenuPanelMetrics.tileRadius, style: .continuous)
        configuration.label
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.13 : isHovered ? 0.09 : 0.055),
                in: shape
            )
            .overlay(shape.strokeBorder(Color.primary.opacity(0.07)))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

// MARK: - Resource Badge

/// A compact CPU/RAM badge that shows a detail popover on hover.
struct ResourceBadge: View {
    let icon: String
    let value: String
    let details: [(String, String)]

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .popover(isPresented: $isHovered, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.subheadline)
                        .foregroundStyle(VocaDesign.accent)
                    Text(value)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }

                Divider()

                ForEach(details, id: \.0) { label, val in
                    HStack {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(val)
                            .font(.caption)
                            .monospacedDigit()
                    }
                }
            }
            .padding(10)
            .frame(width: 160)
        }
    }
}

// MARK: - Audio Level View

/// A simple horizontal bar that visualizes the current audio input level
struct AudioLevelView: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.2))

                // Level indicator
                RoundedRectangle(cornerRadius: 2)
                    .fill(levelColor)
                    .frame(width: max(0, geometry.size.width * CGFloat(level)))
                    .animation(.easeOut(duration: 0.1), value: level)
            }
        }
    }

    private var levelColor: Color {
        if level > 0.8 { return .red }
        if level > 0.5 { return .orange }
        return .green
    }
}
