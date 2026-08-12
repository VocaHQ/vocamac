// AutoPauseMonitor.swift
// VocaMac
//
// Unloads the speech model while configured apps are running and blocks
// dictation until they exit. Mac adapter for VocaLinux auto-pause (#592).

import Foundation
import AppKit

// MARK: - Models

/// A user-configured app that should trigger auto-pause while running.
struct AutoPauseAppEntry: Codable, Identifiable, Hashable {
    /// Stable identity: prefers bundle ID, falls back to process name.
    var id: String
    /// User-facing name shown in Settings.
    var displayName: String
    /// Bundle identifier when known (GUI apps).
    var bundleIdentifier: String?
    /// Executable / process basename (CLI tools, games, fallback).
    var processName: String?

    init(
        id: String,
        displayName: String,
        bundleIdentifier: String? = nil,
        processName: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.processName = processName
    }

    /// Build an entry from a running application snapshot.
    static func from(snapshot: RunningAppSnapshot) -> AutoPauseAppEntry {
        let bundleID = snapshot.bundleIdentifier
        let process = snapshot.processName
        let id = bundleID ?? process ?? snapshot.displayName
        return AutoPauseAppEntry(
            id: id,
            displayName: snapshot.displayName,
            bundleIdentifier: bundleID,
            processName: process
        )
    }
}

/// Lightweight view of a running process used for matching and the picker UI.
struct RunningAppSnapshot: Hashable {
    var displayName: String
    var bundleIdentifier: String?
    var processName: String?
}

// MARK: - Pure matching

enum AutoPauseMatching {
    /// Normalize a process or configured name for comparison.
    static func normalizeProcessName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let base = (trimmed as NSString).lastPathComponent.lowercased()
        if base.hasSuffix(".exe") {
            return String(base.dropLast(4))
        }
        return base
    }

    /// Return true when any configured entry matches a running snapshot.
    ///
    /// Matching is case-insensitive on bundle ID equality **or** executable
    /// basename equality. An empty configured list never matches.
    static func anyConfiguredAppRunning(
        configured: [AutoPauseAppEntry],
        running: [RunningAppSnapshot]
    ) -> Bool {
        firstMatchingConfiguredApp(configured: configured, running: running) != nil
    }

    /// First configured entry that matches a running snapshot, if any.
    static func firstMatchingConfiguredApp(
        configured: [AutoPauseAppEntry],
        running: [RunningAppSnapshot]
    ) -> AutoPauseAppEntry? {
        guard !configured.isEmpty else { return nil }

        for entry in configured {
            let entryBundle = entry.bundleIdentifier?.lowercased()
            let entryProcess = entry.processName.map { normalizeProcessName($0) }
                ?? normalizeProcessName(entry.id)

            for snap in running {
                if let entryBundle, let snapBundle = snap.bundleIdentifier?.lowercased(),
                   entryBundle == snapBundle {
                    return entry
                }
                if let snapProcess = snap.processName.map({ normalizeProcessName($0) }),
                   !entryProcess.isEmpty, entryProcess == snapProcess {
                    return entry
                }
                if let snapBundle = snap.bundleIdentifier.map({ normalizeProcessName($0) }),
                   !entryProcess.isEmpty, entryProcess == snapBundle {
                    return entry
                }
            }
        }
        return nil
    }

    /// Snapshot regular (and accessory) apps from NSWorkspace.
    static func workspaceRunningApps() -> [RunningAppSnapshot] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            // Skip our own process and background-only agents without a name.
            if app.bundleIdentifier == Bundle.main.bundleIdentifier {
                return nil
            }
            let display = app.localizedName ?? app.bundleIdentifier ?? app.executableURL?.lastPathComponent
            guard let display, !display.isEmpty else { return nil }
            return RunningAppSnapshot(
                displayName: display,
                bundleIdentifier: app.bundleIdentifier,
                processName: app.executableURL?.lastPathComponent ?? app.localizedName
            )
        }
    }
}

// MARK: - Monitor

/// Polls for configured processes and fires pause/resume callbacks on transitions.
@MainActor
final class AutoPauseMonitor: ObservableObject {

    nonisolated static let defaultPollIntervalSeconds: TimeInterval = 5
    nonisolated static let minPollIntervalSeconds: TimeInterval = 1
    nonisolated static let maxPollIntervalSeconds: TimeInterval = 60

    /// Called once when the match set becomes non-empty.
    var onPause: (() -> Void)?
    /// Called once when the match set becomes empty after a pause.
    var onResume: (() -> Void)?

    /// Re-read every poll so Settings changes apply without restart.
    var getConfig: () -> (enabled: Bool, apps: [AutoPauseAppEntry], pollInterval: TimeInterval)

    /// Injectable process snapshot for tests.
    var processSnapshot: () -> [RunningAppSnapshot]

    @Published private(set) var isPaused: Bool = false
    /// The configured app that currently triggers auto-pause, if any.
    @Published private(set) var activeTrigger: AutoPauseAppEntry?
    private(set) var isRunning: Bool = false

    private var timer: Timer?
    private var lastPollInterval: TimeInterval = defaultPollIntervalSeconds

    init(
        getConfig: @escaping () -> (enabled: Bool, apps: [AutoPauseAppEntry], pollInterval: TimeInterval) = {
            (false, [], defaultPollIntervalSeconds)
        },
        processSnapshot: @escaping () -> [RunningAppSnapshot] = AutoPauseMatching.workspaceRunningApps,
        onPause: (() -> Void)? = nil,
        onResume: (() -> Void)? = nil
    ) {
        self.getConfig = getConfig
        self.processSnapshot = processSnapshot
        self.onPause = onPause
        self.onResume = onResume
    }

    deinit {
        timer?.invalidate()
    }

    /// Start periodic polling. Safe to call if already started.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        scheduleTimer(immediate: true)
        VocaLogger.info(.general, "Auto-pause monitor started")
    }

    /// Stop polling.
    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        VocaLogger.info(.general, "Auto-pause monitor stopped")
    }

    /// Run a single poll cycle. Returns whether a configured process matched.
    @discardableResult
    func checkOnce() -> Bool {
        let (enabled, apps, _) = readConfig()
        guard enabled else {
            activeTrigger = nil
            clearPauseIfNeeded()
            return false
        }

        let matchedEntry = AutoPauseMatching.firstMatchingConfiguredApp(
            configured: apps,
            running: processSnapshot()
        )
        if let matchedEntry {
            activeTrigger = matchedEntry
            enterPauseIfNeeded()
            return true
        } else {
            activeTrigger = nil
            clearPauseIfNeeded()
            return false
        }
    }

    private func readConfig() -> (Bool, [AutoPauseAppEntry], TimeInterval) {
        let config = getConfig()
        let interval = Self.clampPollInterval(config.pollInterval)
        return (config.enabled, config.apps, interval)
    }

    static func clampPollInterval(_ seconds: TimeInterval) -> TimeInterval {
        min(maxPollIntervalSeconds, max(minPollIntervalSeconds, seconds))
    }

    private func scheduleTimer(immediate: Bool) {
        timer?.invalidate()
        let (_, _, interval) = readConfig()
        lastPollInterval = interval

        if immediate {
            checkOnce()
        }

        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollFromTimer()
            }
        }
        // Allow firing while UI tracking runs (settings window scroll, etc.).
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func pollFromTimer() {
        guard isRunning else { return }
        let (_, _, interval) = readConfig()
        if abs(interval - lastPollInterval) > 0.01 {
            scheduleTimer(immediate: false)
        }
        checkOnce()
    }

    private func enterPauseIfNeeded() {
        guard !isPaused else { return }
        isPaused = true
        VocaLogger.info(.general, "Auto-pause: configured app detected")
        onPause?()
    }

    private func clearPauseIfNeeded() {
        guard isPaused else { return }
        isPaused = false
        activeTrigger = nil
        VocaLogger.info(.general, "Auto-pause cleared")
        onResume?()
    }
}
