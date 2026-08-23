// AppIdentity.swift
// VocaMac
//
// Shared identity and matching for other macOS applications. Auto-pause and
// writing styles both need "is this running app the one the user configured",
// and both must answer it the same way, so the rules live here once.

import Foundation
import AppKit

/// Lightweight view of a running process, used for matching and picker UI.
struct RunningAppSnapshot: Hashable {
    var displayName: String
    var bundleIdentifier: String?
    var processName: String?

    init(displayName: String, bundleIdentifier: String? = nil, processName: String? = nil) {
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.processName = processName
    }
}

/// Matching rules shared by every feature that keys off another app.
enum AppIdentityMatching {

    /// Normalize a process or configured name for comparison.
    ///
    /// Strips any directory component, lowercases, and drops a `.exe` suffix
    /// so `/Applications/Foo.app/Contents/MacOS/Foo` and `foo` compare equal.
    static func normalizeProcessName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let base = (trimmed as NSString).lastPathComponent.lowercased()
        if base.hasSuffix(".exe") {
            return String(base.dropLast(4))
        }
        return base
    }

    /// Whether a configured entry identifies the same app as a running snapshot.
    ///
    /// Matches on case-insensitive bundle identifier equality **or** normalized
    /// executable basename equality. `configuredID` is the fallback used when
    /// the entry carries no explicit process name.
    static func matches(
        configuredBundleIdentifier: String?,
        configuredProcessName: String?,
        configuredID: String,
        snapshot: RunningAppSnapshot
    ) -> Bool {
        if let configuredBundle = configuredBundleIdentifier?.lowercased(),
           let snapshotBundle = snapshot.bundleIdentifier?.lowercased(),
           configuredBundle == snapshotBundle {
            return true
        }

        let configuredProcess = configuredProcessName.map { normalizeProcessName($0) }
            ?? normalizeProcessName(configuredID)
        guard !configuredProcess.isEmpty else { return false }

        if let snapshotProcess = snapshot.processName.map({ normalizeProcessName($0) }),
           configuredProcess == snapshotProcess {
            return true
        }

        // A configured entry stored as a bare process name should still match an
        // app whose bundle ID ends in that name (e.g. `ghostty` vs the app's
        // bundle path basename).
        if let snapshotBundle = snapshot.bundleIdentifier.map({ normalizeProcessName($0) }),
           configuredProcess == snapshotBundle {
            return true
        }

        return false
    }

    /// Snapshot the currently running applications, excluding VocaMac itself.
    static func workspaceRunningApps() -> [RunningAppSnapshot] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            snapshot(for: app)
        }
    }

    /// Convert one `NSRunningApplication` into a snapshot, or `nil` when it is
    /// VocaMac itself or has no usable name.
    static func snapshot(for app: NSRunningApplication) -> RunningAppSnapshot? {
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
