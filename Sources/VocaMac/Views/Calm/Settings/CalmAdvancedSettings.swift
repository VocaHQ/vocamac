// CalmAdvancedSettings.swift
// VocaMac
//
// Settings › Advanced (permissions, the phone gateway, logs, model memory,
// resource usage) and its Phone gateway sub-page, which runs the local
// VocaGateway companion and pairs a phone with it.

import AppKit
import SwiftUI

/// Settings › Advanced: permissions, phone gateway, logs, model memory, resource usage.
struct CalmAdvancedSettings: View {
    @EnvironmentObject private var appState: AppState
    @Environment(CalmNavigator.self) private var navigator: CalmNavigator?
    @ObservedObject private var gateway = GatewayEmbedController.shared
    @StateObject private var processMonitor = ProcessMonitor(useTimer: false)

    @State private var logEntryCount = VocaLogger.logEntryCount
    @State private var confirmsResetPermissions = false
    @State private var confirmsClearLogs = false
    @State private var copiedLogs = false

    var body: some View {
        CalmPage(.sheet) {
            CalmPageHeader("Advanced")

            CalmGroup("Permissions") {
                CalmPanel {
                    permissionRow(
                        "Microphone", purpose: "To hear you", status: appState.micPermission,
                        request: appState.requestMicrophonePermission
                    )
                    permissionRow(
                        "Accessibility", purpose: "To type into other apps", status: appState.accessibilityPermission,
                        request: appState.requestAccessibilityPermission
                    )
                    permissionRow(
                        "Input Monitoring", purpose: "To notice when you press the dictation key",
                        status: appState.inputMonitoringPermission,
                        request: appState.requestInputMonitoringPermission
                    )
                    // Only Silent Mode uses the camera; without it the row would
                    // read as something VocaMac needs.
                    if appState.isSilentModeOn {
                        permissionRow(
                            "Camera", purpose: "For Silent Mode, to read your lips",
                            status: appState.silentMode.cameraPermission,
                            request: requestCamera
                        )
                        .onAppear { appState.silentMode.refresh() }
                    }
                    CalmRow(
                        "Still shows as off?",
                        description: CalmAdvancedSummary.recheckDescription(mayNeedRelaunch: appState.permissionsMayNeedRelaunch)
                    ) {
                        HStack(spacing: 8) {
                            Button("Re-check") { appState.checkPermissions() }.calmButton(.secondary)
                            Button("Restart VocaMac") { appState.relaunch() }
                                .calmButton(.secondary)
                                .help("Quit and reopen. Can fix stuck permissions or audio devices.")
                        }
                    }
                    // Resetting runs tccutil, which the App Store build can't start.
                    if AppDistribution.canResetPermissions {
                        CalmRow("Reset permissions", description: "Clears every grant. VocaMac quits and asks again when it opens.") {
                            Button("Reset…") { confirmsResetPermissions = true }.calmButton(.quietDestructive)
                        }
                    }
                }
            }
            .settingsTarget("permissions")

            CalmGroup("More") {
                CalmPanel {
                    if AppDistribution.hasPhoneGateway {
                        CalmRow(
                            "Phone gateway",
                            description: CalmAdvancedSummary.gatewayRow(status: gateway.status, isReady: gateway.isReady)
                        ) {
                            Button(gateway.isLive ? "Open" : "Set up") { navigator?.select(.gateway) }
                                .calmButton(.secondary)
                        }
                    }
                    logsRow
                        .settingsTarget("logs")
                }
            }

            CalmGroup("Model memory") {
                modelMemoryPanel
            }
            .settingsTarget("model-status")

            CalmGroup("Resource usage") {
                VStack(alignment: .leading, spacing: 10) {
                    CalmPanel {
                        readOnlyRow("App CPU", value: CalmAdvancedSummary.cpu(processMonitor.cpuUsage))
                        readOnlyRow("Memory", value: CalmAdvancedSummary.memory(processMonitor.memoryMB))
                        readOnlyRow("Peak memory", value: CalmAdvancedSummary.memory(processMonitor.memoryPeakMB))
                        readOnlyRow("Threads", value: "\(processMonitor.threadCount)")
                    }
                    Text("All of VocaMac, refreshed every 5 seconds while this page is open. Not a model-only, GPU or Neural Engine reading.")
                        .font(CalmFont.note)
                        .lineSpacing(2.5)
                        .foregroundStyle(CalmColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 2)
                }
            }
            .settingsTarget("resources")
        }
        .onAppear {
            processMonitor.start()
            logEntryCount = VocaLogger.logEntryCount
        }
        .onDisappear { processMonitor.stop() }
        .calmDialog(isPresented: $confirmsResetPermissions) {
            CalmDialog(
                "Reset all permissions?",
                description: "This clears Microphone, Accessibility and Input Monitoring for VocaMac, then quits. Grant them again when it opens. Useful when a permission seems stuck after an update."
            ) {
                CalmDialogFooter(primaryTitle: "Reset and quit", primaryKind: .destructive) {
                    appState.resetAllPermissionsAndQuit()
                }
            }
        }
        .calmDialog(isPresented: $confirmsClearLogs) {
            CalmDialog(
                "Clear the logs?",
                description: "This deletes \(logEntryCount.formatted()) log entries from this Mac. Your settings and history are kept."
            ) {
                CalmDialogFooter(primaryTitle: "Clear", primaryKind: .destructive) {
                    VocaLogger.clearLogs()
                    logEntryCount = VocaLogger.logEntryCount
                }
            }
        }
    }

    // MARK: Rows

    private func requestCamera() {
        if appState.silentMode.cameraPermission == .denied {
            CalmSilentModeLinks.openCameraPrivacy()
        } else {
            Task { await appState.silentMode.requestPermission() }
        }
    }

    @ViewBuilder
    private func permissionRow(
        _ title: String, purpose: String, status: PermissionStatus, request: @escaping () -> Void
    ) -> some View {
        let description = CalmAdvancedSummary.permissionDescription(purpose: purpose, status: status)
        if let action = CalmAdvancedSummary.permissionAction(status) {
            CalmStatusRow(title, description: description, tone: .warning) {
                Button(action, action: request).calmButton(.primary)
            }
        } else {
            CalmStatusRow(title, description: description, tone: .success) { CalmAllowedLabel() }
        }
    }

    private var logsRow: some View {
        CalmRow("Logs", description: CalmAdvancedSummary.logs(entryCount: logEntryCount)) {
            HStack(spacing: 8) {
                Button(copiedLogs ? "Copied" : "Copy", action: copyLogs)
                    .calmButton(.secondary)
                    .help("Copy the last 500 lines")
                Button("Export…", action: exportLogs)
                    .calmButton(.secondary)
                    .help("Save the logs to a file and show it in Finder")
                Button("Clear") { confirmsClearLogs = true }
                    .calmButton(.quietDestructive)
                    .disabled(logEntryCount == 0)
            }
        }
        .help(VocaLogger.logFileURL().lastPathComponent)
    }

    private var modelMemoryPanel: some View {
        let isLoaded = appState.whisperService.isModelLoaded
        return CalmPanel {
            CalmRow(
                isLoaded ? (appState.calmLoadedSpeechModelName ?? "Speech model") : "Speech model",
                description: CalmAdvancedSummary.modelStatus(
                    isLoaded: isLoaded, unloadMessage: appState.modelUnloadStatusMessage,
                    freedMB: appState.approximateMemoryFreedMB
                )
            ) {
                CalmTag(isLoaded ? "Loaded" : "Not loaded", tone: isLoaded ? .success : .neutral)
            }
            // What VocaMac uses now is under Resource usage, refreshed every
            // 5 seconds; a second, unrefreshed reading here disagreed with it.
            if isLoaded, let estimate = estimatedModelRAM {
                readOnlyRow("Memory it needs", value: estimate)
            }
        }
    }

    /// A read-only fact: title left, value right in muted digits.
    private func readOnlyRow(_ title: String, value: String) -> some View {
        CalmRow(title) {
            Text(value)
                .font(CalmFont.description)
                .foregroundStyle(CalmColor.muted)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private var estimatedModelRAM: String? {
        guard let size = appState.currentModel?.size ?? ModelSize(rawValue: appState.selectedModelSize) else { return nil }
        return String(format: "About %.1f GB", size.ramRequiredGB)
    }

    // MARK: Log actions

    private func copyLogs() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(VocaLogger.exportLogs(lastLines: 500), forType: .string)
        copiedLogs = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copiedLogs = false
        }
    }

    private func exportLogs() {
        let logs = VocaLogger.exportLogs(lastLines: 1000)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "VocaMac-Debug-\(ISO8601DateFormatter().string(from: Date()).prefix(19)).log"
        // In the sandbox the home folder is the app's container, so the App
        // Store build lets the panel pick its usual starting folder.
        if !AppDistribution.isAppStore {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        }
        panel.begin { response in
            guard response == .OK, let fileURL = panel.url else { return }
            do {
                try logs.write(to: fileURL, atomically: true, encoding: .utf8)
                NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: fileURL.deletingLastPathComponent().path)
            } catch {
                VocaLogger.error(.general, "Failed to export logs: \(error)")
            }
        }
    }
}

// MARK: - Phone gateway

/// Settings › Advanced › Phone gateway (sub-page): run VocaGateway, pair a
/// phone with a QR code, Docker fallback links when the native binary is
/// missing, and Gateway's own logs.
struct CalmGatewaySettings: View {
    @ObservedObject private var gateway = GatewayEmbedController.shared
    @ObservedObject private var windowManager = SettingsWindowManager.shared

    @State private var showsPairing: Bool
    @State private var copiedURL = false

    /// - Parameter showsPairing: Open with the pairing dialog showing (renders).
    init(showsPairing: Bool = false) {
        _showsPairing = State(initialValue: showsPairing)
    }

    var body: some View {
        CalmPage(.sheet) {
            CalmSubPageHeader(
                "Phone gateway",
                description: "An optional companion that lets your phone and other devices use speech on this Mac. It isn’t a VocaMac speech engine and doesn’t replace your models."
            )

            CalmGroup("Status") {
                VStack(alignment: .leading, spacing: 10) {
                    statusPanel
                    // The status row already says the error; repeat only a
                    // different, newer one.
                    if case .error(let shown) = gateway.status, let message = gateway.lastErrorMessage, message != shown {
                        CalmInlineNotice(message).padding(.leading, 2)
                    }
                }
            }
            .settingsTarget("gateway", aliases: gateway.isBinaryAvailable ? ["gateway-docker"] : [])

            CalmGroup("Pair a phone") {
                pairingPanel
            }
            .settingsTarget("gateway-pair")

            if !gateway.isBinaryAvailable {
                CalmGroup("Install") {
                    CalmPanel {
                        CalmRow(
                            "Install VocaGateway",
                            description: "The native vocagateway program is the best way to run it."
                        ) {
                            HStack(spacing: 8) {
                                Button("Install guide") { NSWorkspace.shared.open(GatewayPaths.docsURL) }
                                    .calmButton(.secondary)
                                Button("GitHub") { NSWorkspace.shared.open(GatewayPaths.githubURL) }
                                    .calmButton(.secondary)
                            }
                        }
                        CalmRow(
                            "Use Docker instead",
                            description: "A fallback only. Docker images don’t include MLX or Apple Silicon engines."
                        ) {
                            Button(gateway.isDockerAvailable ? "Docker guide" : "Get Docker Desktop") {
                                gateway.openDockerFallbackDocs()
                            }
                            .calmButton(.secondary)
                        }
                    }
                }
                .settingsTarget("gateway-docker")
            }
        }
        .task {
            await gateway.refreshStatus()
            presentPendingPairing()
        }
        .onAppear(perform: presentPendingPairing)
        .onChange(of: windowManager.pendingPairingPresentation) { _, pending in
            if pending { presentPendingPairing() }
        }
        .onChange(of: gateway.status) { _, status in
            if status.allowsPairing { presentPendingPairing() }
        }
        .calmDialog(isPresented: $showsPairing) {
            CalmGatewayPairDialog(
                payload: gateway.pairingPayload?.qrPayloadString,
                url: gateway.pairingPayload?.url,
                onCopyURL: gateway.copyPairingURLToPasteboard
            )
        }
    }

    // MARK: Status

    private var statusPanel: some View {
        let tag = CalmAdvancedSummary.gatewayTag(gateway.status)
        return CalmPanel {
            CalmRow(
                "VocaGateway",
                description: CalmAdvancedSummary.gatewayStatusDetail(
                    status: gateway.status, isLive: gateway.isLive, isReady: gateway.isReady
                )
            ) {
                HStack(spacing: 8) {
                    CalmTag(tag.text, tone: tag.tone)
                    Button {
                        Task { await gateway.refreshStatus() }
                    } label: {
                        CalmIcon(.update, size: 15)
                    }
                    .calmIconButton()
                    .help("Refresh")
                    .accessibilityLabel("Refresh status")
                    if canStop {
                        Button("Stop") { Task { await gateway.stop() } }.calmButton(.secondary)
                    } else {
                        Button("Start") { Task { await gateway.start() } }
                            .calmButton(.primary)
                            .disabled(gateway.status == .starting || !gateway.isBinaryAvailable || gateway.isLive)
                    }
                }
            }
            if let path = gateway.binaryPath {
                CalmRow("Program") {
                    Text(path)
                        .font(CalmFont.description)
                        .foregroundStyle(CalmColor.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 360, alignment: .trailing)
                        .help(path)
                }
            } else {
                CalmStatusRow(
                    "VocaGateway isn’t installed",
                    description: gateway.isLive
                        ? "A gateway is already reachable; only the program VocaMac starts is missing."
                        : "Install it to pair a phone or share speech with other devices. See Install below.",
                    tone: .warning
                ) { EmptyView() }
            }
            CalmRow("Web page", description: "Gateway’s own page, in your browser") {
                Button("Open WebUI") { gateway.openWebUI() }
                    .calmButton(.secondary)
                    .disabled(!gateway.isLive)
            }
            CalmRow("Gateway logs", description: "Gateway keeps its own logs and settings in ~/.config/vocagateway") {
                Button("Open logs") { gateway.openGatewayLogs() }.calmButton(.secondary)
            }
        }
    }

    private var canStop: Bool {
        switch gateway.status {
        case .stopped: return gateway.hasManagedProcess
        case .error: return gateway.isLive || gateway.hasManagedProcess
        case .starting, .pairable, .ready: return true
        }
    }

    // MARK: Pairing

    private var pairingPanel: some View {
        CalmPanel {
            VStack(alignment: .leading, spacing: 12) {
                CalmRowLabel(title: "Address phones use") {
                    CalmRowDescription(
                        text: "Needed when Gateway only finds localhost: your LAN or Tailscale address. Sets VOCAGATEWAY_PUBLIC_URL when VocaMac starts Gateway."
                    )
                }
                HStack(spacing: 8) {
                    CalmTextField(nil, text: $gateway.publicURLOverride, prompt: "http://192.168.x.x:8765")
                        .onSubmit { Task { await gateway.fetchPairing() } }
                    Button("Apply") { Task { await gateway.fetchPairing() } }
                        .calmButton(.secondary)
                        .disabled(!gateway.isLive)
                }
            }
            .padding(.vertical, CalmMetrics.rowVerticalPadding)
            .padding(.horizontal, CalmMetrics.rowInset)

            pairRow
        }
    }

    @ViewBuilder
    private var pairRow: some View {
        if let payload = gateway.pairingPayload {
            CalmRow("Pair phone", description: payload.url) {
                HStack(spacing: 8) {
                    Button(copiedURL ? "Copied" : "Copy URL", action: copyURL).calmButton(.secondary)
                    Button("Pair phone…") { showsPairing = true }.calmButton(.primary)
                }
            }
        } else if gateway.isLive {
            CalmStatusRow(
                "Pair phone",
                description: "The QR code shows once the pairing address isn’t localhost or 127.0.0.1. Set the address above.",
                tone: .warning
            ) { EmptyView() }
        } else {
            CalmRow(
                "Pair phone",
                description: "Start Gateway first. You can pair while a model is still downloading."
            ) {
                Button("Pair phone…") {}.calmButton(.secondary).disabled(true)
            }
        }
    }

    private func copyURL() {
        gateway.copyPairingURLToPasteboard()
        copiedURL = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copiedURL = false
        }
    }

    private func presentPendingPairing() {
        guard windowManager.consumePendingPairingPresentation(canPresent: gateway.status.allowsPairing) else { return }
        showsPairing = true
    }
}
