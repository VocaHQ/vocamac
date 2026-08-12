// SettingsSearchIndex.swift
// VocaMac
//
// Lightweight searchable index over settings controls (no third-party deps).

import Foundation

/// One searchable settings control / topic entry.
struct SettingsSearchEntry: Hashable, Identifiable {
    let id: String
    let page: SettingsPage
    let title: String
    let subtitle: String?
    let keywords: [String]

    init(
        id: String,
        page: SettingsPage,
        title: String,
        subtitle: String? = nil,
        keywords: [String] = []
    ) {
        self.id = id
        self.page = page
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
    }
}

/// Indexes settings controls for live sidebar search.
enum SettingsSearchIndex {

    /// Full catalog of searchable settings rows.
    static let entries: [SettingsSearchEntry] = [
        // Dictation
        SettingsSearchEntry(
            id: "activation-mode",
            page: .dictation,
            title: "Activation Mode",
            subtitle: "Push to talk or double-tap toggle",
            keywords: ["hotkey", "ptt", "toggle", "hold"]
        ),
        SettingsSearchEntry(
            id: "hotkey",
            page: .dictation,
            title: "Hotkey",
            subtitle: "Activation key",
            keywords: ["shortcut", "option", "key"]
        ),
        SettingsSearchEntry(
            id: "trailing-space",
            page: .dictation,
            title: "Trailing Space After Dictation",
            subtitle: "Space between utterances",
            keywords: ["space", "output", "glue", "whitespace"]
        ),
        SettingsSearchEntry(
            id: "auto-capitalize",
            page: .dictation,
            title: "Auto-Capitalize Sentences",
            subtitle: "Capitalize after punctuation",
            keywords: ["capitalize", "output", "sentence", "punctuation"]
        ),

        // Speech Model
        SettingsSearchEntry(
            id: "models",
            page: .speechModel,
            title: "Speech Models",
            subtitle: "Download and select engines",
            keywords: ["whisper", "parakeet", "sherpa", "apple", "model", "download"]
        ),
        SettingsSearchEntry(
            id: "language",
            page: .speechModel,
            title: "Transcription Language",
            subtitle: "Auto-detect or pick a language",
            keywords: ["language", "locale", "english", "hungarian"]
        ),
        SettingsSearchEntry(
            id: "translation",
            page: .speechModel,
            title: "Translation",
            subtitle: "Translate speech to English",
            keywords: ["translate", "english"]
        ),
        SettingsSearchEntry(
            id: "vocabulary",
            page: .speechModel,
            title: "Custom Vocabulary",
            subtitle: "Hint proper nouns to Whisper",
            keywords: ["vocab", "dictionary", "terms"]
        ),

        // Audio
        SettingsSearchEntry(
            id: "microphone",
            page: .audio,
            title: "Microphone",
            subtitle: "Input device",
            keywords: ["mic", "device", "input", "audio"]
        ),
        SettingsSearchEntry(
            id: "silence",
            page: .audio,
            title: "Silence Detection",
            subtitle: "Auto-stop after silence",
            keywords: ["vad", "silence", "sensitivity", "threshold"]
        ),
        SettingsSearchEntry(
            id: "sound-effects",
            page: .audio,
            title: "Sound Effects",
            subtitle: "Start and stop cues",
            keywords: ["sound", "beep", "audio"]
        ),

        // Performance
        SettingsSearchEntry(
            id: "model-status",
            page: .performance,
            title: "Model Status",
            subtitle: "Loaded or unloaded",
            keywords: ["loaded", "unload", "ram", "memory", "status", "pause"]
        ),
        SettingsSearchEntry(
            id: "auto-pause",
            page: .performance,
            title: "Auto-Pause for Apps",
            subtitle: "Unload while listed apps run",
            keywords: ["pause", "game", "app", "offload", "unload"]
        ),
        SettingsSearchEntry(
            id: "idle-unload",
            page: .performance,
            title: "Unload Model When Idle",
            subtitle: "Keep-alive timeout",
            keywords: ["idle", "keepalive", "keep-alive", "battery", "ram", "unload"]
        ),
        SettingsSearchEntry(
            id: "resources",
            page: .advanced,
            title: "Resource Usage",
            subtitle: "App CPU and memory",
            keywords: ["cpu", "memory", "ram", "resources", "system"]
        ),
        SettingsSearchEntry(
            id: "system-info",
            page: .advanced,
            title: "System Information",
            subtitle: "CPU, RAM, Metal",
            keywords: ["system", "metal", "device", "hardware"]
        ),

        // Application
        SettingsSearchEntry(
            id: "launch-at-login",
            page: .application,
            title: "Launch at Login",
            keywords: ["startup", "login"]
        ),
        SettingsSearchEntry(
            id: "clipboard",
            page: .application,
            title: "Preserve Clipboard",
            keywords: ["clipboard", "paste"]
        ),
        SettingsSearchEntry(
            id: "cursor-overlay",
            page: .application,
            title: "Recording Overlay",
            subtitle: "Style and position near the cursor",
            keywords: ["overlay", "cursor", "indicator", "mic", "position", "style"]
        ),

        // Stats / Advanced / About
        SettingsSearchEntry(
            id: "stats",
            page: .stats,
            title: "Usage Stats",
            keywords: ["streak", "words", "history"]
        ),
        SettingsSearchEntry(
            id: "logs",
            page: .advanced,
            title: "Debug Logs",
            keywords: ["log", "debug", "export"]
        ),
        SettingsSearchEntry(
            id: "permissions",
            page: .advanced,
            title: "Permissions",
            keywords: ["mic", "accessibility", "input monitoring"]
        ),
        SettingsSearchEntry(
            id: "updates",
            page: .about,
            title: "Updates",
            keywords: ["version", "release", "nightly", "update"]
        ),
    ]

    /// Entries whose title, subtitle, or keywords contain `query` (case-insensitive).
    static func matches(query: String) -> [SettingsSearchEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }

        let needle = trimmed.lowercased()
        return entries.filter { entry in
            if entry.title.lowercased().contains(needle) { return true }
            if let subtitle = entry.subtitle, subtitle.lowercased().contains(needle) { return true }
            return entry.keywords.contains { $0.lowercased().contains(needle) }
        }
    }

    /// Match counts keyed by page (pages with zero matches omitted).
    static func matchCounts(query: String) -> [SettingsPage: Int] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }

        var counts: [SettingsPage: Int] = [:]
        for entry in matches(query: trimmed) {
            counts[entry.page, default: 0] += 1
        }
        return counts
    }

    /// First page that has matches, or nil when the query is empty / no hits.
    static func firstMatchingPage(query: String) -> SettingsPage? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return matches(query: trimmed).first?.page
    }
}
