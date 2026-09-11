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
            id: "paste-last-shortcut",
            page: .dictation,
            title: "Paste Last Dictation",
            subtitle: "Shortcut to type your last dictation again",
            keywords: ["paste", "last", "again", "repeat", "shortcut", "clipboard"]
        ),
        SettingsSearchEntry(
            id: "hands-free-shortcut",
            page: .dictation,
            title: "Hands-free Dictation",
            subtitle: "Shortcut to start and stop without holding",
            keywords: ["hands free", "toggle", "long", "shortcut", "lock"]
        ),
        SettingsSearchEntry(
            id: "command-mode-shortcut",
            page: .dictation,
            title: "Command Mode",
            subtitle: "Voice-edit selected text while holding a shortcut",
            keywords: ["command", "selected text", "rewrite", "translate", "shortcut", "hold"]
        ),
        SettingsSearchEntry(
            id: "escape-cancel",
            page: .dictation,
            title: "Escape Cancels Dictation",
            subtitle: "Throw away a recording with Escape",
            keywords: ["escape", "esc", "cancel", "discard", "abort"]
        ),
        SettingsSearchEntry(
            id: "mouse-trigger",
            page: .dictation,
            title: "Mouse Button",
            subtitle: "Dictate with a middle or side mouse button",
            keywords: ["mouse", "button", "middle", "side", "click"]
        ),
        SettingsSearchEntry(
            id: "auto-capitalize",
            page: .dictation,
            title: "Auto-Capitalize Sentences",
            subtitle: "Capitalize after punctuation",
            keywords: ["capitalize", "output", "sentence", "punctuation"]
        ),

        // Writing Styles
        SettingsSearchEntry(
            id: "writing-styles",
            page: .writingStyles,
            title: "Writing Styles",
            subtitle: "Shape dictation for the target app",
            keywords: ["style", "per-app", "app", "formatting", "output", "shape"]
        ),
        SettingsSearchEntry(
            id: "default-writing-style",
            page: .writingStyles,
            title: "Default Style",
            subtitle: "Used when an app has no rule",
            keywords: ["default", "style", "plain", "fallback"]
        ),
        SettingsSearchEntry(
            id: "writing-wording",
            page: .writingStyles,
            title: "Formal and Casual Wording",
            subtitle: "Choose how dictation sounds in each app",
            keywords: ["formal", "casual", "professional", "friends", "conversation", "wording", "rewrite"]
        ),
        SettingsSearchEntry(
            id: "app-style-rules",
            page: .writingStyles,
            title: "App Rules",
            subtitle: "Per-app style bindings",
            keywords: ["cursor", "vscode", "slack", "terminal", "messages", "mail app", "notes", "binding"]
        ),
        SettingsSearchEntry(
            id: "website-style-rules",
            page: .writingStyles,
            title: "Website Rules",
            subtitle: "Choose formatting and cleanup by browser domain",
            keywords: ["website", "domain", "browser", "safari", "chrome", "url", "per-site"]
        ),
        SettingsSearchEntry(
            id: "app-cleanup-prompt",
            page: .writingStyles,
            title: "Per-App Cleanup Prompt",
            subtitle: "Custom cleanup instructions for an app or website",
            keywords: ["custom", "prompt", "per-app", "per-site", "instructions", "cleanup"]
        ),
        SettingsSearchEntry(
            id: "spoken-symbols",
            page: .writingStyles,
            title: "Spoken Filenames and Paths",
            subtitle: "Turn \"config dot json\" into config.json",
            keywords: ["filename", "path", "dot", "slash", "camel case", "snake case", "identifier", "symbols"]
        ),
        SettingsSearchEntry(
            id: "writing-style-rule-transfer",
            page: .writingStyles,
            title: "Export and Import Rules",
            subtitle: "Move app rules between Macs",
            keywords: ["export", "import", "backup", "share", "json", "transfer", "remove all"]
        ),
        SettingsSearchEntry(
            id: "writing-style-preview",
            page: .writingStyles,
            title: "Style Preview",
            subtitle: "See what each style does",
            keywords: ["preview", "sample", "test", "try"]
        ),

        // Snippets
        SettingsSearchEntry(
            id: "snippets",
            page: .snippets,
            title: "Custom Snippets",
            subtitle: "Replace spoken triggers with saved text",
            keywords: ["snippet", "shortcut", "expansion", "trigger", "replace", "macro", "abbreviation"]
        ),

        SettingsSearchEntry(
            id: "cleanup",
            page: .cleanup,
            title: "Smart Cleanup",
            subtitle: "Local LLM polish after transcription",
            keywords: ["cleanup", "clean", "filler", "llm", "qwen", "gguf", "rewrite", "punctuation", "scratch"]
        ),
        SettingsSearchEntry(
            id: "cleanup-model",
            page: .cleanup,
            title: "Cleanup Model",
            subtitle: "Download Qwen for on-device cleanup",
            keywords: ["qwen", "model", "download", "0.5b", "0.6b", "gguf"]
        ),
        SettingsSearchEntry(
            id: "command-mode-clipboard",
            page: .cleanup,
            title: "Command Mode Clipboard Copy",
            subtitle: "Copy selections from apps that don't share them",
            keywords: ["command", "clipboard", "copy", "terminal", "editor", "selection", "vs code"]
        ),
        SettingsSearchEntry(
            id: "command-mode-model",
            page: .cleanup,
            title: "Command Mode Model",
            subtitle: "Apple Intelligence, Qwen 1.5B, 4B, or 7B for editing selected text",
            keywords: ["command", "edit", "rewrite", "translate", "apple intelligence", "qwen", "4b", "7b", "selection"]
        ),
        SettingsSearchEntry(
            id: "cleanup-level",
            page: .cleanup,
            title: "Cleanup Level",
            subtitle: "None, Light, Medium, or High",
            keywords: ["level", "none", "light", "medium", "high", "corrections"]
        ),
        SettingsSearchEntry(
            id: "cleanup-provider",
            page: .cleanup,
            title: "Cleanup Provider",
            subtitle: "On-device, Ollama, LM Studio, or OpenAI-compatible",
            keywords: ["endpoint", "ollama", "lm studio", "openai", "api key", "server", "remote"]
        ),
        SettingsSearchEntry(
            id: "cleanup-try",
            page: .cleanup,
            title: "Try Cleanup",
            subtitle: "Run your own text through the cleanup model",
            keywords: ["try", "test", "preview", "sample", "check", "grammar"]
        ),
        SettingsSearchEntry(
            id: "cleanup-prompt",
            page: .cleanup,
            title: "Cleanup Prompt",
            subtitle: "Instructions sent to the local model",
            keywords: ["prompt", "instructions", "system"]
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
            page: .dictionary,
            title: "Vocabulary",
            subtitle: "Spell names and jargon your way with every model",
            keywords: ["vocab", "dictionary", "terms", "custom vocabulary", "names", "jargon", "spelling"]
        ),
        SettingsSearchEntry(
            id: "word-replacements",
            page: .dictionary,
            title: "Replacements",
            subtitle: "Type something else for a word a model gets wrong",
            keywords: ["replace", "replacement", "correction", "misheard", "substitute", "fix"]
        ),
        SettingsSearchEntry(
            id: "learn-corrections",
            page: .dictionary,
            title: "Learn from My Corrections",
            subtitle: "Suggest words you fixed after dictating",
            keywords: ["learn", "auto", "suggest", "correction", "edit"]
        ),
        SettingsSearchEntry(
            id: "screen-context",
            page: .dictionary,
            title: "Spell Names from the Screen",
            subtitle: "Match names and identifiers you can see",
            keywords: ["context", "screen", "identifier", "variable", "code", "names", "accessibility"]
        ),

        // History
        SettingsSearchEntry(
            id: "history",
            page: .history,
            title: "Dictation History",
            subtitle: "Find, copy, replay, and retry past dictations",
            keywords: ["history", "past", "previous", "transcripts", "retry", "search", "recordings", "audio", "undo"]
        ),
        SettingsSearchEntry(
            id: "history-retention",
            page: .history,
            title: "Keep History For",
            subtitle: "Delete dictations after a day, a week, or a month",
            keywords: ["retention", "delete", "privacy", "storage", "keep audio"]
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
            id: "closed-lid-microphone",
            page: .audio,
            title: "External Microphone with Lid Closed",
            subtitle: "Automatically use a non-built-in input in clamshell mode",
            keywords: ["external", "microphone", "lid", "closed", "clamshell", "dock"]
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
            keywords: ["sound", "beep", "audio", "tone", "preview"]
        ),
        SettingsSearchEntry(
            id: "other-audio",
            page: .audio,
            title: "Other Audio",
            subtitle: "Mute music while dictating",
            keywords: ["duck", "mute", "music", "volume", "quiet", "lower", "playback", "youtube"]
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
        SettingsSearchEntry(
            id: "settings-backup",
            page: .application,
            title: "Settings Backup",
            subtitle: "Export or import VocaMac preferences",
            keywords: ["settings", "backup", "export", "import", "transfer", "json"]
        ),

        // Stats / Advanced / About
        SettingsSearchEntry(
            id: "stats",
            page: .stats,
            title: "Usage Stats",
            keywords: ["streak", "words", "history", "share", "social", "linkedin"]
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
            id: "about",
            page: .about,
            title: "About",
            subtitle: "This app, the Voca family, and how to reach us",
            keywords: ["about", "vocamac", "beta"]
        ),
        SettingsSearchEntry(
            id: "updates",
            page: .about,
            title: "Updates",
            keywords: ["version", "release", "nightly", "update"]
        ),
        SettingsSearchEntry(
            id: "family",
            page: .about,
            title: "Part of VocaHQ",
            subtitle: "VocaLinux, VocaMac, VocaWin, VocaPhone, VocaGateway",
            keywords: ["family", "vocahq", "vocalinux", "vocamac", "vocawin", "windows", "vocaphone", "vocagateway"]
        ),
        SettingsSearchEntry(
            id: "github-issues",
            page: .about,
            title: "Report a bug or idea",
            subtitle: "GitHub issues",
            keywords: ["github", "issues", "bug", "feedback", "idea"]
        ),
        SettingsSearchEntry(
            id: "discord",
            page: .about,
            title: "Discord",
            subtitle: "Talk to us",
            keywords: ["discord", "chat", "community"]
        ),
        SettingsSearchEntry(
            id: "x",
            page: .about,
            title: "X",
            subtitle: "Talk to us",
            keywords: ["x", "twitter", "x.com"]
        ),
        SettingsSearchEntry(
            id: "email",
            page: .about,
            title: "Email",
            subtitle: "hello@vocahq.com",
            keywords: ["email", "mail", "hello"]
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
