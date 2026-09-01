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

        // Auto-pause lets a user type an app's bundle ID into the same field
        // that normally holds a process name. Compare the configured name
        // against the snapshot's bundle ID too, so `com.apple.Terminal` typed
        // by hand still matches. Whole-string equality, not a suffix test:
        // matching `code` against `com.microsoft.VSCode` would bind an app the
        // user never named.
        if let snapshotBundle = snapshot.bundleIdentifier.map({ normalizeProcessName($0) }),
           configuredProcess == snapshotBundle {
            return true
        }

        return false
    }

    /// Snapshot the currently running applications, excluding VocaMac itself.
    ///
    /// Deduplicated: helper processes of one app can share a name and bundle
    /// ID, and a list with two identical rows is both confusing in the picker
    /// and ambiguous as a SwiftUI identity.
    static func workspaceRunningApps() -> [RunningAppSnapshot] {
        var seen = Set<RunningAppSnapshot>()
        var result: [RunningAppSnapshot] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let snapshot = snapshot(for: app), seen.insert(snapshot).inserted else { continue }
            result.append(snapshot)
        }
        return result
    }

    /// Convert one `NSRunningApplication` into a snapshot, or `nil` when it is
    /// VocaMac itself, has no usable name, or is missing.
    static func snapshot(for app: NSRunningApplication?) -> RunningAppSnapshot? {
        guard let app else { return nil }
        // Compare only when we have an identifier of our own: in an unbundled
        // dev build both sides are nil, which would hide every unbundled app.
        if let ownBundleID = Bundle.main.bundleIdentifier, app.bundleIdentifier == ownBundleID {
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
