// AppState+CalmAdvanced.swift
// VocaMac
//
// What the v3 Privacy and History, Advanced, Phone gateway and About
// settings pages say: the on-device statement, history and permission
// summaries, memory and update lines. Pure text, so it can be tested
// without drawing a page.

import Foundation

// MARK: - On-device statement

/// What the Privacy page's statement panel says leaves this Mac.
struct CalmPrivacyStatement: Equatable {
    /// Recordings go to a remote speech endpoint (Your own server).
    let audioLeaves: Bool
    /// Transcripts or selected text go to a remote AI endpoint (cleanup or Command Mode).
    let textLeaves: Bool

    /// Whether anything leaves this Mac (the amber variant).
    var isRemote: Bool { audioLeaves || textLeaves }

    var title: String {
        switch (audioLeaves, textLeaves) {
        case (true, true): return "Audio and text leave this Mac"
        case (true, false): return "Audio leaves this Mac"
        case (false, true): return "Text leaves this Mac"
        case (false, false): return "Everything stays on this Mac"
        }
    }

    var message: String {
        switch (audioLeaves, textLeaves) {
        case (true, true):
            return "Your recordings go to your own server, and your words to the AI server you set up."
        case (true, false):
            return "Your recordings go to your own server to be turned into text. Everything else stays here."
        case (false, true):
            return "Your words go to the AI server you set up for Smart Cleanup or Commands. Your audio stays here."
        case (false, false):
            return "Your audio and text never leave it, unless you pick Your own server as your model."
        }
    }

    /// The Models tab that changes what leaves: speech first, as audio is the bigger deal.
    var modelsTab: CalmModelsTab { audioLeaves ? .speech : .writing }
}

extension AppState {
    /// The Privacy page's statement, from the speech engine and the AI endpoint in use.
    var calmPrivacyStatement: CalmPrivacyStatement {
        let usesEndpoint = transcriptCleanupEnabled || commandModeEngine == .endpoint
        return CalmPrivacyStatement(
            audioLeaves: speechProcessingIsRemote,
            textLeaves: usesEndpoint && !cleanupEndpoint.isLocal
        )
    }

    /// Bytes of audio kept with saved dictations.
    var calmHistoryAudioBytes: Int64 {
        historyStore.entries.reduce(Int64(0)) { $0 + ($1.audioBytes ?? 0) }
    }

    /// Saved dictations that still have a recording.
    var calmHistoryAudioCount: Int {
        historyStore.entries.filter(\.hasAudio).count
    }
}

// MARK: - Summaries

/// The text the Privacy, Advanced, Phone gateway and About pages show.
enum CalmAdvancedSummary {
    // MARK: History

    /// “1,284 dictations · 212 MB of audio”, or “Nothing saved yet”.
    static func savedNow(count: Int, audioBytes: Int64) -> String {
        guard count > 0 else { return "Nothing saved yet" }
        var parts = [dictations(count)]
        if audioBytes > 0 {
            parts.append("\(ByteCountFormatter.string(fromByteCount: audioBytes, countStyle: .file)) of audio")
        }
        return parts.joined(separator: " · ")
    }

    /// The retention dropdown's choice under “Delete dictations older than”.
    static func retentionTitle(_ retention: HistoryRetention) -> String {
        retention == .forever ? "Never delete" : retention.displayName
    }

    /// The apps kept out of History, for the row's value line.
    static func excludedApps(_ names: [String]) -> String {
        switch names.count {
        case 0: return "None yet. Add password managers or banking apps."
        case 1, 2: return names.joined(separator: " and ")
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }

    /// The Clear history confirmation's description.
    static func clearHistoryMessage(count: Int) -> String {
        "This deletes \(dictations(count)) and their recordings from this Mac. Your totals in Insights are kept."
    }

    /// The Delete audio confirmation's description.
    static func deleteAudioMessage(count: Int) -> String {
        "This deletes the recordings of \(dictations(count)). Their text stays in History, but they can’t be played or retried."
    }

    /// “1 dictation”, “1,284 dictations”.
    static func dictations(_ count: Int) -> String {
        "\(count.formatted()) dictation\(count == 1 ? "" : "s")"
    }

    // MARK: Permissions

    /// A permission row's description: why it's needed, and how to fix it when it's off.
    static func permissionDescription(purpose: String, status: PermissionStatus) -> String {
        switch status {
        case .granted, .notDetermined: return purpose
        case .denied: return "\(purpose). Turn it on in System Settings › Privacy & Security."
        }
    }

    /// The fix button on a permission row (nil when it's allowed).
    static func permissionAction(_ status: PermissionStatus) -> String? {
        switch status {
        case .granted: return nil
        case .notDetermined: return "Grant access"
        case .denied: return "Open Settings"
        }
    }

    /// The Re-check row's description.
    static func recheckDescription(mayNeedRelaunch: Bool) -> String {
        mayNeedRelaunch
            ? "Turned one on but it still shows as off? macOS can wait until VocaMac reopens. Restart VocaMac."
            : "Check again after changing System Settings. Restarting can also fix a stuck microphone."
    }

    // MARK: Logs and resources

    /// “1,204 entries · helpful when reporting a problem”.
    static func logs(entryCount: Int) -> String {
        let entries = entryCount == 1 ? "1 entry" : "\(entryCount.formatted()) entries"
        return "\(entries) · helpful when reporting a problem"
    }

    /// Memory in MB, or GB from 1,024 MB.
    static func memory(_ megabytes: Double) -> String {
        megabytes >= 1024
            ? String(format: "%.1f GB", megabytes / 1024)
            : String(format: "%.0f MB", megabytes)
    }

    /// CPU use as a percentage of one core.
    static func cpu(_ percent: Double) -> String {
        String(format: "%.1f%%", percent)
    }

    /// The model-memory row's line on why the model is or isn't loaded.
    static func modelStatus(isLoaded: Bool, unloadMessage: String?, freedMB: Double?) -> String {
        if isLoaded { return "Loaded and ready, so dictation starts right away" }
        if let unloadMessage {
            if let freedMB { return unloadMessage + String(format: " About %.0f MB was freed.", freedMB) }
            return unloadMessage
        }
        return "It loads when you next dictate"
    }

    // MARK: About

    /// Stable or Nightly, from the version string.
    static func channel(version: String) -> String {
        version.lowercased().contains("nightly") ? "Nightly" : "Stable"
    }

    /// “Version 1.0.0 · Stable”.
    static func versionLine(version: String) -> String {
        "Version \(version) · \(channel(version: version))"
    }

    /// “M1 Pro · 16 GB · macOS 26.1”.
    static func thisMac(processor: String?, memoryGB: Int?, osVersion: OperatingSystemVersion) -> String {
        var parts: [String] = []
        if let processor, !processor.isEmpty { parts.append(processor) }
        if let memoryGB, memoryGB > 0 { parts.append("\(memoryGB) GB") }
        var os = "macOS \(osVersion.majorVersion).\(osVersion.minorVersion)"
        if osVersion.patchVersion > 0 { os += ".\(osVersion.patchVersion)" }
        parts.append(os)
        return parts.joined(separator: " · ")
    }

    /// “Apple Silicon · Neural Engine”.
    static func thisMacDetail(isAppleSilicon: Bool, hasNeuralEngine: Bool) -> String {
        [isAppleSilicon ? "Apple Silicon" : "Intel", hasNeuralEngine ? "Neural Engine" : "No Neural Engine"]
            .joined(separator: " · ")
    }

    /// How an update status reads next to the version.
    enum UpdateTone: Equatable {
        /// Accent, semibold (“Up to date”, “Update available”).
        case good
        /// Muted (checking, downloading).
        case quiet
        /// Amber (errors).
        case problem
    }

    /// The short status next to the version (nil when there's nothing to say).
    static func updateStatus(_ state: UpdateState) -> (text: String, tone: UpdateTone)? {
        switch state {
        case .idle: return nil
        case .checking: return ("Checking…", .quiet)
        case .upToDate: return ("Up to date", .good)
        case .updateAvailable(let info), .updateAvailableViaHomebrew(let info, _):
            return ("\(displayVersion(info)) is available", .good)
        case .downloading(let progress, _, _, _): return ("Downloading \(Int(progress * 100))%", .quiet)
        case .verifying: return ("Checking the download…", .quiet)
        case .readyToInstall: return ("Ready to install", .good)
        case .installing: return ("Installing…", .quiet)
        case .installFailed, .error: return ("Couldn’t update", .problem)
        }
    }

    /// The longer message shown under the version when an update failed.
    static func updateProblem(_ state: UpdateState) -> String? {
        switch state {
        case .error(let message), .installFailed(_, let message): return message
        default: return nil
        }
    }

    /// “VocaMac 1.1”: the release's version without a leading “v”.
    static func displayVersion(_ info: UpdateInfo) -> String {
        let raw = info.version.isEmpty ? info.tagName : info.version
        let version = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        return "VocaMac \(version)"
    }

    /// The update dialog's release-notes lines (headings, bullets, paragraphs, code).
    static func releaseNoteLines(_ notes: String) -> [String] {
        ReleaseNotes.blocks(from: notes).map { block in
            switch block {
            case .heading(let text), .paragraph(let text), .code(let text): return text
            case .bullet(let text): return "• \(text)"
            }
        }
    }

    // MARK: Phone gateway

    /// The Advanced page's Phone gateway row line.
    static func gatewayRow(status: GatewayEmbedController.Status, isReady: Bool) -> String {
        switch status {
        case .stopped: return "Dictate on your phone and type on this Mac"
        case .starting: return "Starting…"
        case .pairable: return isReady ? "Running · ready to pair" : "Running · model may still be downloading"
        case .ready: return "Running · ready to pair"
        case .error: return "Couldn’t start. Open it to see why."
        }
    }

    /// The gateway status row's description.
    static func gatewayStatusDetail(status: GatewayEmbedController.Status, isLive: Bool, isReady: Bool) -> String {
        switch status {
        case .stopped: return isLive ? "Reachable, but not started by VocaMac" : "Not running"
        case .starting: return "Starting up…"
        case .pairable, .ready: return isReady ? "Running · model ready" : "Running · model may still be downloading"
        case .error(let message): return message
        }
    }

    /// The gateway status tag.
    static func gatewayTag(_ status: GatewayEmbedController.Status) -> (text: String, tone: CalmTone) {
        switch status {
        case .stopped: return ("Stopped", .neutral)
        case .starting: return ("Starting", .neutral)
        case .pairable: return ("Pairable", .success)
        case .ready: return ("Ready", .success)
        case .error: return ("Error", .warning)
        }
    }
}
