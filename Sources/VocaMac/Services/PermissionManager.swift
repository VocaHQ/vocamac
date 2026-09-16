// PermissionManager.swift
// VocaMac
//
// Manages system permission checking, requesting, and polling.
// Extracts permission logic from AppState for focused responsibility.

import Foundation
import AppKit
import Combine

/// Manages system permissions: microphone, accessibility, and input monitoring.
///
/// Accessibility and Input Monitoring permissions don't provide callback-based APIs,
/// so this manager polls to detect changes when the user grants access in System Settings.
@MainActor
final class PermissionManager: ObservableObject {

    // MARK: - Published State

    /// Microphone permission status
    @Published var micPermission: PermissionStatus = .notDetermined

    /// Accessibility permission status
    @Published var accessibilityPermission: PermissionStatus = .notDetermined

    /// Input Monitoring permission status
    @Published var inputMonitoringPermission: PermissionStatus = .notDetermined

    // MARK: - Dependencies

    private let audioEngine: AudioRecording
    private let hotKeyManager: HotKeyMonitoring

    // MARK: - Private

    private var permissionPollTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// Called when Accessibility and Input Monitoring are granted but the
    /// hotkey tap is missing or was disabled, so AppState can (re)create it.
    var onAllPermissionsGranted: (() -> Void)?

    // MARK: - Initialization

    init(audioEngine: AudioRecording, hotKeyManager: HotKeyMonitoring) {
        self.audioEngine = audioEngine
        self.hotKeyManager = hotKeyManager
        observePermissionChanges()
    }

    /// Nothing polls once every permission is granted. A revoke-and-grant is
    /// caught by these events instead: the system's Accessibility trust
    /// notification, the hotkey tap reporting that macOS disabled it, and the
    /// user coming back to VocaMac.
    private func observePermissionChanges() {
        let recheck: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.recheckHotKeyHealth() }
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil, queue: .main
        ) { notification in
            // The trust database updates just after the notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { recheck(notification) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .hotKeyEventTapDisabled, object: nil, queue: .main, using: recheck
        ))
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: recheck
        ))
    }

    deinit {
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Whether the hotkey tap exists and macOS still delivers events to it.
    var isHotKeyTapHealthy: Bool {
        guard hotKeyManager.isListening else { return false }
        guard let tap = hotKeyManager.eventTap else { return true }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// Re-read permissions and restore the hotkey tap if it needs it; poll
    /// while anything is still missing.
    func recheckHotKeyHealth() {
        checkPermissions()
        restoreHotKeyIfPossible()
        if !allPermissionsGranted || !isHotKeyTapHealthy {
            startPermissionPolling()
        }
    }

    private func restoreHotKeyIfPossible() {
        guard accessibilityPermission == .granted,
              inputMonitoringPermission == .granted,
              !isHotKeyTapHealthy else { return }
        onAllPermissionsGranted?()
    }

    // MARK: - Permission Checking

    /// Whether all required permissions are granted.
    var allPermissionsGranted: Bool {
        micPermission == .granted &&
        accessibilityPermission == .granted &&
        inputMonitoringPermission == .granted
    }

    /// Re-check all permission statuses from the system.
    func checkPermissions() {
        micPermission = audioEngine.checkPermissionStatus()

        let accessibilityGranted = hotKeyManager.checkAccessibilityPermission(prompt: false)
        accessibilityPermission = accessibilityGranted ? .granted : .denied

        let inputMonitoringGranted = checkInputMonitoringPermission()
        inputMonitoringPermission = inputMonitoringGranted ? .granted : .denied
    }

    /// Check Input Monitoring permission using multiple strategies since no
    /// single approach is 100% reliable:
    /// 1. If HotKeyManager created a tap, check if macOS has disabled it (revocation)
    /// 2. Try creating a fresh `.cghidEventTap` to trigger/check Input Monitoring
    private func checkInputMonitoringPermission() -> Bool {
        // Strategy 1: If HotKeyManager has an active, enabled tap, it's granted.
        // A disabled tap stays disabled after the permission comes back, so
        // it can't prove a denial; probe with a fresh tap instead.
        if hotKeyManager.isListening, let tap = hotKeyManager.eventTap,
           CGEvent.tapIsEnabled(tap: tap) {
            return true
        }

        // Strategy 2: Try creating a fresh .cghidEventTap. This probes Input
        // Monitoring more accurately than .cgSessionEventTap, which may inherit
        // Terminal's permissions when launched from CLI.
        let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, _, event, _ in Unmanaged.passRetained(event) },
            userInfo: nil
        )
        if let tap = tap {
            CFMachPortInvalidate(tap)
            return true
        }
        return false
    }

    // MARK: - Permission Requests

    /// Request microphone permission. Opens System Settings if already denied.
    func requestMicrophonePermission() {
        if micPermission == .denied {
            openMicrophoneSettings()
            return
        }

        audioEngine.requestPermission { [weak self] granted in
            Task { @MainActor in
                self?.micPermission = granted ? .granted : .denied
            }
        }
    }

    /// Open the Microphone privacy pane in System Settings.
    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.checkPermissions()
        }
    }

    /// Prompt the user to grant Accessibility permission.
    func requestAccessibilityPermission() {
        let _ = HotKeyManager.checkAccessibilityPermission(prompt: true)
        startPermissionPolling()
    }

    /// Trigger Input Monitoring permission dialog and open System Settings.
    func requestInputMonitoringPermission() {
        // Attempting to create an event tap triggers macOS to auto-add
        // the app to the Input Monitoring list in System Settings.
        let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, _, event, _ in Unmanaged.passRetained(event) },
            userInfo: nil
        )
        if let tap = tap {
            CFMachPortInvalidate(tap)
        }

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }

        startPermissionPolling()
    }

    // MARK: - Permission Polling

    enum PollingDecision: Equatable {
        case keepPolling
        case stop
        case giveUpOnHotKey
    }

    /// Creating the tap can fail for a moment right after a permission is
    /// granted, while macOS still reports it as granted. About 30 s of 3 s
    /// polls covers that; past it, app activation, wake and the Accessibility
    /// notification still re-check.
    static let maxHotKeyRestartPolls = 10

    private var hotKeyRestartPolls = 0

    static func pollingDecision(
        allPermissionsGranted: Bool,
        isHotKeyTapHealthy: Bool,
        hotKeyRestartPolls: Int
    ) -> PollingDecision {
        guard allPermissionsGranted else { return .keepPolling }
        if isHotKeyTapHealthy { return .stop }
        return hotKeyRestartPolls >= maxHotKeyRestartPolls ? .giveUpOnHotKey : .keepPolling
    }

    /// Start polling permissions every 3 seconds until all are granted and
    /// the hotkey tap is working.
    func startPermissionPolling() {
        guard permissionPollTimer == nil else { return }
        guard !allPermissionsGranted || !isHotKeyTapHealthy else { return }

        VocaLogger.debug(.appState, "Starting permission polling")
        hotKeyRestartPolls = 0
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.checkPermissions()

                // Notify when the permissions are there but the hotkey tap
                // is missing or was disabled by a revoke.
                self.restoreHotKeyIfPossible()

                if self.allPermissionsGranted && !self.isHotKeyTapHealthy {
                    self.hotKeyRestartPolls += 1
                }
                switch Self.pollingDecision(
                    allPermissionsGranted: self.allPermissionsGranted,
                    isHotKeyTapHealthy: self.isHotKeyTapHealthy,
                    hotKeyRestartPolls: self.hotKeyRestartPolls
                ) {
                case .keepPolling:
                    break
                case .stop:
                    self.stopPermissionPolling()
                case .giveUpOnHotKey:
                    VocaLogger.warning(.appState, "Hotkey tap still couldn't be created with every permission granted; waiting for the next activation or permission change")
                    self.stopPermissionPolling()
                }
            }
        }
    }

    /// Stop the permission polling timer.
    func stopPermissionPolling() {
        VocaLogger.debug(.appState, "Stopping permission polling — all permissions granted")
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }
}

// MARK: - PermissionManaging Conformance

extension PermissionManager: PermissionManaging {
    var objectWillChangePublisher: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }
}
