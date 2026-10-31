// AppDistribution.swift
// VocaMac
//
// Which channel this binary ships through. The Mac App Store build is
// compiled with the APP_STORE condition (scripts/build-appstore.sh) and runs
// in the App Sandbox; see docs/APP_STORE.md for what it leaves out and why.

import Foundation

/// The distribution this binary was built for, and the features that exist
/// only in the direct download (Developer ID DMG and Homebrew).
///
/// App Review requires the App Sandbox, forbids an app that updates itself
/// (Guideline 2.4.5(vii)) or starts programs from outside its bundle, and
/// rarely grants the exceptions AppleScript control of other apps needs.
/// Code that would do any of that is compiled out under `APP_STORE`; these
/// flags hide the settings and menu rows that lead to it.
enum AppDistribution {
#if APP_STORE
    /// Built for the Mac App Store: sandboxed, updated by the App Store.
    static let isAppStore = true
#else
    /// Built for the direct download.
    static let isAppStore = false
#endif

    /// Checking GitHub for a new release and installing it in place.
    static var hasSelfUpdate: Bool { !isAppStore }

    /// Starting the user's own `vocagateway` program and pairing a phone with it.
    static var hasPhoneGateway: Bool { !isAppStore }

    /// Pausing Spotify and adding reminders, which drive those apps with AppleScript.
    static var hasAppleScriptControl: Bool { !isAppStore }

    /// Clearing VocaMac's privacy grants with `tccutil`.
    static var canResetPermissions: Bool { !isAppStore }

    /// Offering to report the last crash, read from ~/Library/Logs/DiagnosticReports.
    /// The sandbox can't read that folder; the App Store collects crashes instead.
    static var canReadCrashReports: Bool { !isAppStore }

    /// Looking at another app's processes, to tell a coding agent in a
    /// terminal from a shell. The sandbox doesn't allow it.
    static var canReadOtherProcesses: Bool { !isAppStore }

    /// Serving local coding agents with `VocaMac --mcp`. An agent starts the
    /// app's binary from a terminal, which a sandboxed App Store copy can't
    /// usefully serve: it can't read the history or preferences of the
    /// container from outside it.
    static var hasMCPServer: Bool { !isAppStore }

    /// Settings search entries for controls this build doesn't show.
    static var hiddenSettingsTargets: Set<String> {
        var hidden: Set<String> = []
        if !hasSelfUpdate { hidden.insert("updates") }
        if !hasPhoneGateway { hidden.formUnion(["gateway", "gateway-pair", "gateway-docker"]) }
        if !hasAppleScriptControl { hidden.insert("spotify-pause") }
        if !canReadOtherProcesses { hidden.insert("coding-agents") }
        if !hasMCPServer { hidden.insert("mcp-server") }
        return hidden
    }
}
