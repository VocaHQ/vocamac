// PermissionManager.swift
// VocaMac
//
// Manages system permission checking, requesting, and polling.
// Extracts permission logic from AppState for focused responsibility.

import Foundation
import AppKit
import Combine
import IOKit.hid

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

    /// Permissions VocaMac asked for since launch.
    @Published private(set) var requestedThisLaunch: Set<RelaunchablePermission> = []

    /// Permissions asked for since launch that the user has since come back
    /// to VocaMac from. Until they return, they may still be granting it, so
    /// a relaunch would be premature advice.
    @Published private(set) var returnedAfterRequest: Set<RelaunchablePermission> = []

    /// Set while onboarding is open. Only then does an Accessibility grant
    /// bring VocaMac forward: elsewhere the user is working in another app,
    /// which dictation should type into.
    var returnsToOnboardingAfterGrant = false

    /// Every permission is granted, but the hotkey tap still couldn't be
    /// created after polling for it.
    @Published private(set) var hotKeyStuckAfterGrant = false

    // MARK: - Dependencies

    private let audioEngine: AudioRecording
    private let hotKeyManager: HotKeyMonitoring
    private let defaults: UserDefaults

    // MARK: - Private

    private var permissionPollTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// Called when Accessibility and Input Monitoring are granted but the
    /// hotkey tap is missing or was disabled, so AppState can (re)create it.
    var onAllPermissionsGranted: (() -> Void)?

    // MARK: - Initialization

    /// Whether VocaMac is the active app, and how to make it so. Injected
    /// for tests.
    private let isAppActive: () -> Bool
    private let activateApp: () -> Void

    init(
        audioEngine: AudioRecording,
        hotKeyManager: HotKeyMonitoring,
        defaults: UserDefaults = .standard,
        isAppActive: @escaping () -> Bool = { NSApp.isActive },
        activateApp: @escaping () -> Void = { NSApp.activate(ignoringOtherApps: true) }
    ) {
        self.audioEngine = audioEngine
        self.hotKeyManager = hotKeyManager
        self.defaults = defaults
        self.isAppActive = isAppActive
        self.activateApp = activateApp
        observePermissionChanges()
    }

    /// Nothing polls once every permission is granted. A revoke-and-grant is
    /// caught by these events instead: the system's Accessibility trust
    /// notification, the hotkey tap reporting that macOS disabled it, and the
    /// user coming back to VocaMac.
    private func observePermissionChanges() {
        let recheck: @Sendable (Notification) -> Void = { [weak self] _ in
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
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.userReturned()
                self?.recheckHotKeyHealth()
            }
        })
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
        } else {
            hotKeyStuckAfterGrant = false
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

    /// Whether quitting and reopening VocaMac may get a permission through:
    /// one the user went to System Settings for is still off, or the hotkey
    /// tap never came up after every permission was granted.
    var mayNeedRelaunch: Bool {
        Self.mayNeedRelaunch(
            accessibility: accessibilityPermission,
            inputMonitoring: inputMonitoringPermission,
            returnedAfterRequest: returnedAfterRequest,
            hotKeyStuckAfterGrant: hotKeyStuckAfterGrant
        )
    }

    static func mayNeedRelaunch(
        accessibility: PermissionStatus,
        inputMonitoring: PermissionStatus,
        returnedAfterRequest: Set<RelaunchablePermission>,
        hotKeyStuckAfterGrant: Bool
    ) -> Bool {
        hotKeyStuckAfterGrant || isAwaitingGrant(
            accessibility: accessibility,
            inputMonitoring: inputMonitoring,
            returnedAfterRequest: returnedAfterRequest
        )
    }

    /// Whether a permission the user went off to grant and came back from
    /// still reads as off.
    var isAwaitingGrant: Bool {
        Self.isAwaitingGrant(
            accessibility: accessibilityPermission,
            inputMonitoring: inputMonitoringPermission,
            returnedAfterRequest: returnedAfterRequest
        )
    }

    static func isAwaitingGrant(
        accessibility: PermissionStatus,
        inputMonitoring: PermissionStatus,
        returnedAfterRequest: Set<RelaunchablePermission>
    ) -> Bool {
        returnedAfterRequest.contains { permission in
            switch permission {
            case .accessibility: return accessibility != .granted
            case .inputMonitoring: return inputMonitoring != .granted
            }
        }
    }

    /// Re-check all permission statuses from the system.
    func checkPermissions() {
        micPermission = audioEngine.checkPermissionStatus()

        let accessibilityGranted = hotKeyManager.checkAccessibilityPermission(prompt: false)
        let previousAccessibility = accessibilityPermission
        accessibilityPermission = status(granted: accessibilityGranted, for: .accessibility)
        if Self.shouldReturnAfterGrant(
            old: previousAccessibility,
            new: accessibilityPermission,
            requestedThisLaunch: requestedThisLaunch.contains(.accessibility),
            onboardingIsOpen: returnsToOnboardingAfterGrant,
            isActive: isAppActive()
        ) {
            activateApp()
        }

        let inputMonitoringGranted = checkInputMonitoringPermission()
        inputMonitoringPermission = status(granted: inputMonitoringGranted, for: .inputMonitoring)
    }

    /// macOS can't say whether it ever asked about Accessibility or Input
    /// Monitoring, so VocaMac remembers whether it did. Until then a missing
    /// permission is "not determined", not "denied": nobody refused anything.
    static func status(granted: Bool, asked: Bool) -> PermissionStatus {
        if granted { return .granted }
        return asked ? .denied : .notDetermined
    }

    private func status(granted: Bool, for permission: RelaunchablePermission) -> PermissionStatus {
        // Seen granted counts as asked, so a later revoke reads as denied.
        if granted { defaults.set(true, forKey: permission.askedKey) }
        let macOSRefused = permission == .inputMonitoring
            && IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeDenied
        return Self.status(
            granted: granted,
            asked: Self.hasAsked(for: permission, defaults: defaults, macOSRefused: macOSRefused)
        )
    }

    /// Whether VocaMac asked for a permission: its own flag, or macOS
    /// reporting a refusal. Only Input Monitoring has that report
    /// (`IOHIDCheckAccess`), which also covers installs from before the
    /// flags. Accessibility has none, so an unflagged one reads as not asked;
    /// its Allow… still leads to System Settings.
    static func hasAsked(
        for permission: RelaunchablePermission,
        defaults: UserDefaults,
        macOSRefused: Bool = false
    ) -> Bool {
        defaults.bool(forKey: permission.askedKey) || macOSRefused
    }

    /// Bring onboarding forward once Accessibility comes on in System
    /// Settings, so the user needn't find its window again. Not for Input
    /// Monitoring:
    /// macOS answers that grant with its own Quit & Reopen dialog, which
    /// coming forward would cover.
    static func shouldReturnAfterGrant(
        old: PermissionStatus,
        new: PermissionStatus,
        requestedThisLaunch: Bool,
        onboardingIsOpen: Bool,
        isActive: Bool
    ) -> Bool {
        old != .granted && new == .granted && requestedThisLaunch && onboardingIsOpen && !isActive
    }

    private func noteRequested(_ permission: RelaunchablePermission) {
        defaults.set(true, forKey: permission.askedKey)
        requestedThisLaunch.insert(permission)
    }

    /// VocaMac became active again: anything asked for before this has had
    /// its chance to be granted.
    func userReturned() {
        returnedAfterRequest.formUnion(requestedThisLaunch)
    }

    /// Mark every permission as not yet asked for, after `tccutil` reset
    /// their grants.
    static func forgetPermissionRequests(defaults: UserDefaults = .standard) {
        for permission in [RelaunchablePermission.accessibility, .inputMonitoring] {
            defaults.set(false, forKey: permission.askedKey)
        }
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
        noteRequested(.accessibility)
        _ = HotKeyManager.checkAccessibilityPermission(prompt: true)
        startPermissionPolling()
    }

    /// What asking for Input Monitoring does.
    enum InputMonitoringRequest: Equatable {
        /// macOS hasn't asked yet: show its own prompt, which adds VocaMac
        /// to the list and offers to open System Settings.
        case askMacOS
        /// macOS asked before and won't again: open System Settings.
        case openSettings
    }

    static func inputMonitoringRequest(for access: IOHIDAccessType) -> InputMonitoringRequest {
        access == kIOHIDAccessTypeUnknown ? .askMacOS : .openSettings
    }

    /// Ask for Input Monitoring: macOS's prompt the first time, System
    /// Settings after that. Doing both at once left two windows asking.
    func requestInputMonitoringPermission() {
        noteRequested(.inputMonitoring)
        defer { startPermissionPolling() }

        if Self.inputMonitoringRequest(for: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)) == .askMacOS {
            // Off the main thread in case macOS waits on the prompt.
            Task.detached(priority: .userInitiated) {
                _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            }
            return
        }

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
                    self.hotKeyStuckAfterGrant = false
                    self.stopPermissionPolling()
                case .giveUpOnHotKey:
                    self.hotKeyStuckAfterGrant = true
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

// MARK: - RelaunchablePermission

/// The permissions macOS may apply only after VocaMac reopens.
enum RelaunchablePermission: Hashable {
    case accessibility
    case inputMonitoring

    /// Whether VocaMac has ever asked for it.
    var askedKey: String {
        switch self {
        case .accessibility: return PreferenceKey.askedForAccessibility
        case .inputMonitoring: return PreferenceKey.askedForInputMonitoring
        }
    }
}

// MARK: - PermissionManaging Conformance

extension PermissionManager: PermissionManaging {
    var objectWillChangePublisher: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }
}
