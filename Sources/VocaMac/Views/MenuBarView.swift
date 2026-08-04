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

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit { timer?.invalidate() }

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
    @EnvironmentObject var appState: AppState
    @ObservedObject var settingsManager: SettingsWindowManager
    @StateObject private var processMonitor = ProcessMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let info = appState.updateChecker.activeUpdateInfo {
                UpdateBannerView(info: info)
                Divider()
            }

            // Header
            headerSection

            Divider()

            // Status & Recording
            statusSection

            // Last Transcription
            if let transcription = appState.lastTranscription {
                Divider()
                transcriptionSection(transcription)
            }

            // Permissions Warning
            if appState.micPermission != .granted || appState.accessibilityPermission != .granted || appState.inputMonitoringPermission != .granted {
                Divider()
                permissionsSection
            }

            Divider()

            // Quick Actions
            actionsSection
        }
        .padding(20)
        .frame(width: 380)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Image(systemName: "mic.fill")
                .font(.title)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 3) {
                Text("VocaMac")
                    .font(.title3)
                    .fontWeight(.semibold)

                if let model = appState.currentModel {
                    // Model is loaded and ready
                    Text("Model: \(model.size.displayName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if appState.whisperService.isModelLoaded {
                    // Loaded but currentModel wasn't set (shouldn't happen, but safety net)
                    Text("Model: \(appState.whisperService.loadedModelName ?? "Loaded")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if let downloadingModel = appState.availableModels.first(where: { $0.downloadProgress != nil }),
                          let progress = downloadingModel.downloadProgress {
                    // A model is being downloaded — show progress
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Downloading \(downloadingModel.size.displayName)… \(Int(progress * 100))%")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.orange)
                    }
                } else if let loadingModel = appState.availableModels.first(where: { $0.isLoading }) {
                    // A model is being loaded (already downloaded, now initializing)
                    Text("Loading \(loadingModel.size.displayName)…")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                } else {
                    // Fallback: no model loaded and nothing actively in progress
                    Text("No model loaded")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            // CPU & RAM usage display
            HStack(spacing: 10) {
                ResourceBadge(
                    icon: "cpu",
                    value: String(format: "%.0f%%", processMonitor.cpuUsage),
                    details: [
                        ("CPU Usage", String(format: "%.1f%%", processMonitor.cpuUsage)),
                        ("Threads", "\(processMonitor.threadCount)"),
                        ("Cores", "\(ProcessInfo.processInfo.activeProcessorCount)"),
                    ]
                )

                ResourceBadge(
                    icon: "memorychip",
                    value: formattedMemory(processMonitor.memoryMB),
                    details: [
                        ("Resident", String(format: "%.1f MB", processMonitor.memoryMB)),
                        ("Peak", String(format: "%.1f MB", processMonitor.memoryPeakMB)),
                        ("System", "\(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)) GB"),
                    ]
                )
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)

                Text(statusText)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(statusColor)

                Spacer()

                Text(activationModeHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Audio level indicator (visible during recording)
            if appState.appStatus == .recording {
                AudioLevelView(level: appState.audioLevel)
                    .frame(height: 6)

                // Stop/recovery button — visible during recording so the user
                // can unstick the app if the hotkey isn't responding
                Button {
                    Task { @MainActor in
                        await appState.stopRecordingAndTranscribe()
                    }
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }

            // Processing indicator
            if appState.appStatus == .processing {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
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

    // MARK: - Transcription

    private func transcriptionSection(_ result: VocaTranscription) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last Transcription")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")
            }

            Text(result.text)
                .font(.body)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)

            HStack {
                Text("\(String(format: "%.1f", result.audioLengthSeconds))s audio")
                Text("•")
                Text("\(String(format: "%.1f", result.duration))s to transcribe")
                Text("•")
                Text(result.detectedLanguage)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions Required")
                .font(.subheadline)
                .foregroundStyle(.orange)

            if appState.micPermission != .granted {
                permissionButton(
                    label: appState.micPermission == .denied ? "Open Microphone Settings" : "Grant Microphone Access",
                    icon: "mic.badge.xmark",
                    isDenied: appState.micPermission == .denied,
                    action: { appState.requestMicrophonePermission() }
                )

                Text(appState.micPermission == .denied
                     ? "Denied. Enable in System Settings → Privacy & Security → Microphone."
                     : "Required to capture your voice for transcription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if appState.accessibilityPermission != .granted {
                permissionButton(
                    label: "Grant Accessibility Access",
                    icon: "lock.shield",
                    isDenied: appState.accessibilityPermission == .denied,
                    action: { appState.requestAccessibilityPermission() }
                )

                Text("Required for global hotkeys and text injection. Opens System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if appState.inputMonitoringPermission != .granted {
                permissionButton(
                    label: "Grant Input Monitoring",
                    icon: "keyboard",
                    isDenied: appState.inputMonitoringPermission == .denied,
                    action: { appState.requestInputMonitoringPermission() }
                )

                Text("Required to detect hotkey presses system-wide. Enable VocaMac in the list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Reusable permission button that shows different styling for denied vs not determined
    private func permissionButton(label: String, icon: String, isDenied: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Label(label, systemImage: icon)
                .font(.callout)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isDenied ? .red : .orange)
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(spacing: 2) {
            Button {
                settingsManager.open(appState: appState)
            } label: {
                HStack {
                    Image(systemName: "gear")
                    Text("Settings")
                    Spacer()
                    Text("⌘,")
                        .foregroundStyle(.secondary)
                }
                .font(.body)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.0001))
                )
            }
            .buttonStyle(MenuRowButtonStyle())

            Button {
                NotificationCenter.default.post(name: .showOnboarding, object: nil)
            } label: {
                HStack {
                    Image(systemName: "wand.and.stars")
                    Text("Setup Wizard")
                    Spacer()
                }
                .font(.body)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.0001))
                )
            }
            .buttonStyle(MenuRowButtonStyle())

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack {
                    Image(systemName: "power")
                    Text("Quit VocaMac")
                    Spacer()
                    Text("⌘Q")
                        .foregroundStyle(.secondary)
                }
                .font(.body)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.0001))
                )
            }
            .buttonStyle(MenuRowButtonStyle())
        }
        .padding(.horizontal, -8)
    }

    // MARK: - Helpers

    private var statusText: String {
        switch appState.appStatus {
        case .idle:       return appState.errorMessage ?? "Ready"
        case .recording:  return "Recording..."
        case .processing: return "Transcribing..."
        case .error:      return appState.errorMessage ?? "Error"
        }
    }

    private var statusColor: Color {
        switch appState.appStatus {
        case .idle:       return appState.errorMessage == nil ? .green : .yellow
        case .recording:  return .red
        case .processing: return .orange
        case .error:      return .yellow
        }
    }

    private var activationModeHint: String {
        let keyName = KeyCodeReference.displayName(for: appState.hotKeyCode)
        switch appState.activationMode {
        case .pushToTalk:
            return "Hold \(keyName)"
        case .doubleTapToggle:
            return "Double-tap \(keyName)"
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
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.primary.opacity(0.1) : Color.clear)
            )
            .onHover { hovering in
                isHovered = hovering
            }
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
                        .foregroundStyle(.blue)
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
