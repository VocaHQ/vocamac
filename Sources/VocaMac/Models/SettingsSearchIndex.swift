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

    /// Some controls require choosing the app they apply to. Search must not
    /// silently edit or open an arbitrary app rule on the person's behalf.
    var navigationHint: String? {
        switch id {
        case "app-cleanup-prompt", "spoken-symbols":
            return "Click an app under Used in, choose Customize…, then open Advanced."
        case "writing-style-rule-transfer":
            return "Use the ⋯ menu at the top of Styles to import or export your app list."
        case "gateway-docker":
            return "Docker fallback is available when the native gateway isn't installed."
        default: return nil
        }
    }

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
    private static let catalog: [SettingsSearchEntry] = [
        // Dictation
        SettingsSearchEntry(
            id: "activation-mode",
            page: .dictation,
            title: "Holding or double-tapping the dictation key",
            subtitle: "Push to talk or double-tap toggle",
            keywords: ["hotkey", "ptt", "toggle", "hold", "activation mode"]
        ),
        SettingsSearchEntry(
            id: "hotkey",
            page: .dictation,
            title: "Dictation key",
            subtitle: "Activation key",
            keywords: ["shortcut", "option", "key", "hotkey"]
        ),
        SettingsSearchEntry(
            id: "trailing-space",
            page: .formatting,
            title: "Add a space after each dictation",
            subtitle: "Space between utterances",
            keywords: ["space", "output", "glue", "whitespace", "trailing space after dictation"]
        ),
        SettingsSearchEntry(
            id: "paste-last-shortcut",
            page: .dictation,
            title: "Paste last dictation",
            subtitle: "Shortcut to type your last dictation again",
            keywords: ["paste", "last", "again", "repeat", "shortcut", "clipboard", "paste last dictation"]
        ),
        SettingsSearchEntry(
            id: "hands-free-shortcut",
            page: .dictation,
            title: "Hands-free",
            subtitle: "Shortcut to start and stop without holding",
            keywords: ["hands free", "toggle", "long", "shortcut", "lock", "hands-free dictation"]
        ),
        SettingsSearchEntry(
            id: "escape-cancel",
            page: .dictation,
            title: "Escape cancels dictation",
            subtitle: "Throw away a recording with Escape",
            keywords: ["escape", "esc", "cancel", "discard", "abort", "escape cancels dictation"]
        ),
        SettingsSearchEntry(
            id: "mouse-trigger",
            page: .dictation,
            title: "Mouse button",
            subtitle: "Dictate with a middle or side mouse button",
            keywords: ["mouse", "button", "middle", "side", "click", "mouse button"]
        ),
        SettingsSearchEntry(
            id: "auto-capitalize",
            page: .formatting,
            title: "Capitalize sentences",
            subtitle: "Capitalize after punctuation",
            keywords: ["capitalize", "output", "sentence", "punctuation", "auto-capitalize sentences"]
        ),
        SettingsSearchEntry(
            id: "numbers-as-digits",
            page: .formatting,
            title: "Write numbers as digits",
            subtitle: "“twenty three” becomes “23”",
            keywords: ["numbers", "digits", "numerals", "output", "write numbers as digits"]
        ),
        SettingsSearchEntry(
            id: "number-symbols",
            page: .formatting,
            title: "Use symbols and ordinals",
            subtitle: "“fifty percent” becomes “50%”",
            keywords: ["percent", "currency", "dollar", "ordinal", "date", "minus", "symbols", "use symbols and ordinals"]
        ),
        SettingsSearchEntry(
            id: "spoken-emoji",
            page: .formatting,
            title: "Spoken emoji",
            subtitle: "“crying emoji” becomes 😭",
            keywords: ["emoji", "emojis", "smiley", "output", "spoken emoji"]
        ),
        SettingsSearchEntry(
            id: "pause-paragraphs",
            page: .formatting,
            // Not "pause": that query belongs to auto-pause on Performance.
            title: "Paragraph breaks",
            subtitle: "A long silence between sentences starts a new paragraph",
            keywords: ["paragraphs", "line break", "new line", "silence", "greeting", "layout", "paragraph breaks"]
        ),
        SettingsSearchEntry(
            id: "process-while-speaking",
            page: .dictation,
            title: "Process while speaking",
            subtitle: "Transcribe and clean up each sentence before you stop",
            keywords: [
                "speed", "faster", "latency", "wait", "streaming", "sentence", "live", "battery",
                "long dictation", "low power",
                "process while speaking",
            ]
        ),

        // Writing Styles
        SettingsSearchEntry(
            id: "writing-styles",
            page: .writingStyles,
            title: "Styles",
            subtitle: "Make dictation fit the app you're typing in",
            keywords: ["style", "per-app", "app", "formatting", "output", "shape", "writing styles"]
        ),
        SettingsSearchEntry(
            id: "default-writing-style",
            page: .writingStyles,
            title: "Style for everything else",
            subtitle: "Used for apps you haven't set up",
            keywords: ["default", "style", "plain", "fallback", "style everywhere else"]
        ),
        SettingsSearchEntry(
            id: "writing-wording",
            page: .writingStyles,
            title: "Reword to sound Formal or Casual",
            subtitle: "Reword dictation to sound formal or casual",
            keywords: ["tone", "formal", "casual", "professional", "friends", "conversation", "wording", "rewrite", "tone: formal or casual"]
        ),
        SettingsSearchEntry(
            id: "app-style-rules",
            page: .writingStyles,
            title: "Apps with their own style",
            subtitle: "Give an app its own writing style",
            keywords: ["rules", "cursor", "vscode", "slack", "terminal", "messages", "mail app", "notes", "binding", "your apps"]
        ),
        SettingsSearchEntry(
            id: "website-style-rules",
            page: .writingStyles,
            title: "Websites",
            subtitle: "Use a different style on one site",
            keywords: ["rules", "website", "domain", "browser", "safari", "chrome", "url", "per-site"]
        ),
        SettingsSearchEntry(
            id: "app-cleanup-prompt",
            page: .writingStyles,
            title: "Cleanup instructions for one app",
            subtitle: "Custom cleanup instructions for an app or website",
            keywords: ["custom", "prompt", "per-app", "per-site", "instructions", "cleanup", "per-app cleanup instructions"]
        ),
        SettingsSearchEntry(
            id: "spoken-symbols",
            page: .writingStyles,
            title: "Spoken file names and paths",
            subtitle: "Turn \"config dot json\" into config.json",
            keywords: ["filename", "path", "dot", "slash", "camel case", "snake case", "identifier", "symbols", "spoken filenames and paths"]
        ),
        SettingsSearchEntry(
            id: "writing-style-rule-transfer",
            page: .writingStyles,
            title: "Export and import the app list",
            subtitle: "Move your app styles between Macs",
            keywords: ["export", "import", "backup", "share", "json", "transfer", "remove all", "export and import app list"]
        ),
        SettingsSearchEntry(
            id: "writing-style-preview",
            page: .writingStyles,
            title: "Try a style",
            subtitle: "See what each style types",
            keywords: ["preview", "sample", "test", "try", "try a style"]
        ),

        // Snippets
        SettingsSearchEntry(
            id: "snippets",
            page: .snippets,
            title: "Snippets",
            subtitle: "Replace spoken triggers with saved text",
            keywords: ["snippet", "shortcut", "expansion", "trigger", "replace", "macro", "abbreviation", "custom snippets"]
        ),

        // Smart Cleanup
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
            title: "Smart Cleanup model",
            subtitle: "Download a model for on-device cleanup",
            keywords: ["qwen", "ministral", "model", "download", "recommended", "0.5b", "0.6b", "3b", "gguf", "cleanup model"]
        ),
        SettingsSearchEntry(
            id: "cleanup-skip-clean",
            page: .cleanup,
            title: "Skip the model when there’s nothing to clean",
            subtitle: "Type clean dictations without waiting for the cleanup model",
            keywords: ["cleanup", "skip", "fast", "faster", "speed", "latency", "clean", "model", "skip the model when there's nothing to clean"]
        ),
        SettingsSearchEntry(
            id: "cleanup-level",
            page: .cleanup,
            title: "How much to change",
            subtitle: "None, Light, Medium, Grammar, or High",
            keywords: ["level", "none", "light", "medium", "grammar", "high", "corrections", "cleanup level"]
        ),
        SettingsSearchEntry(
            id: "cleanup-provider",
            page: .cleanup,
            title: "Where cleanup runs",
            subtitle: "On this Mac, Ollama, LM Studio, or OpenAI-compatible",
            keywords: ["endpoint", "ollama", "lm studio", "openai", "api key", "server", "remote", "where cleanup runs"]
        ),
        SettingsSearchEntry(
            id: "cleanup-try",
            page: .cleanup,
            title: "Try it with your words",
            subtitle: "Run your own text through the cleanup model",
            keywords: ["try", "test", "preview", "sample", "check", "grammar", "try cleanup"]
        ),
        SettingsSearchEntry(
            id: "cleanup-prompt",
            page: .cleanup,
            title: "Custom instructions",
            subtitle: "Instructions sent to the local model",
            keywords: ["prompt", "instructions", "system", "cleanup prompt"]
        ),

        // Command Mode
        SettingsSearchEntry(
            id: "command-mode-shortcut",
            page: .commandMode,
            title: "Command Mode",
            subtitle: "Edit selected text, or write new text, by voice",
            keywords: ["command", "selected text", "rewrite", "translate", "shortcut", "hold", "edit"]
        ),
        SettingsSearchEntry(
            id: "command-mode-model",
            page: .commandMode,
            title: "Command Mode uses",
            subtitle: "Apple Intelligence, Qwen, or Ministral for editing selected text",
            keywords: ["command", "edit", "rewrite", "translate", "apple intelligence", "qwen", "ministral", "3b", "4b", "7b", "selection", "command mode model"]
        ),
        SettingsSearchEntry(
            id: "command-mode-share",
            page: .commandMode,
            title: "Same model as Smart Cleanup",
            subtitle: "One model for cleanup and Command Mode",
            keywords: ["share", "shared", "same model", "both", "memory", "one model", "use the smart cleanup model"]
        ),
        SettingsSearchEntry(
            id: "command-mode-review",
            page: .commandMode,
            title: "Preview before replacing",
            subtitle: "See what Command Mode changed and approve it",
            keywords: ["command", "review", "diff", "preview", "approve", "confirm", "replace", "review edits before replacing"]
        ),
        SettingsSearchEntry(
            id: "command-mode-clipboard",
            page: .commandMode,
            title: "Copy the selection when an app hides it",
            subtitle: "Copy selections from apps that don't share them",
            keywords: ["command", "clipboard", "copy", "terminal", "editor", "selection", "vs code", "command mode clipboard copy"]
        ),
        SettingsSearchEntry(
            id: "command-mode-saved",
            page: .commandMode,
            title: "Saved commands",
            subtitle: "Command Mode instructions with a name and a shortcut",
            keywords: ["command", "saved", "preset", "shortcut", "hotkey", "quick", "fix grammar", "instruction", "saved commands"]
        ),
        SettingsSearchEntry(
            id: "command-mode-actions",
            page: .commandMode,
            title: "Voice actions",
            subtitle: AppDistribution.hasAppleScriptControl
                ? "Open apps, search the web, add reminders, run Shortcuts"
                : "Open apps, search the web, run Shortcuts",
            keywords: ["command", "action", "open", "launch", "search", "reminder", "shortcuts", "automation", "run", "voice actions"]
        ),
        SettingsSearchEntry(
            id: "command-mode-models",
            page: .commandMode,
            title: "Writing AI models",
            subtitle: "Download a model for editing selected text",
            keywords: ["command", "model", "download", "qwen", "ministral", "3b", "4b", "7b", "command mode models"]
        ),

        // Speech Model
        SettingsSearchEntry(
            id: "models",
            page: .speechModel,
            title: "Speech models",
            subtitle: "Download and select engines",
            keywords: ["whisper", "parakeet", "sherpa", "apple", "model", "download", "endpoint", "remote", "server", "speech models"]
        ),
        SettingsSearchEntry(
            id: "custom-endpoint",
            page: .speechModel,
            title: "Your own server",
            subtitle: "Send recordings to your Whisper-compatible server",
            keywords: ["endpoint", "remote", "server", "openai", "whisper.cpp", "api", "upload", "custom endpoint"]
        ),
        SettingsSearchEntry(
            id: "spoken-languages",
            page: .language,
            title: "Languages you speak",
            subtitle: "Sets recognition and the models suggested for you",
            keywords: ["language", "languages", "multilingual", "bilingual", "filter", "hindi", "spanish", "i speak", "languages you speak"]
        ),
        SettingsSearchEntry(
            id: "language",
            page: .language,
            title: "Listen for",
            subtitle: "Auto-detect or pick a language",
            keywords: ["language", "locale", "english", "hungarian", "transcription language"]
        ),
        SettingsSearchEntry(
            id: "translation",
            page: .language,
            title: "Translate into English",
            subtitle: "Translate speech to English",
            keywords: ["translate", "english", "translation"]
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
            title: "Learn from my corrections",
            subtitle: "Suggest words you fixed after dictating",
            keywords: ["learn", "auto", "suggest", "correction", "edit", "learn from my corrections"]
        ),
        SettingsSearchEntry(
            id: "screen-context",
            page: .dictionary,
            title: "Spell names from the screen",
            subtitle: "Match names and identifiers you can see",
            keywords: ["context", "screen", "identifier", "variable", "code", "names", "accessibility", "spell names from the screen"]
        ),

        // History
        SettingsSearchEntry(
            id: "history",
            page: .history,
            // Lands on Home's feed; the on/off switch is under Privacy and
            // History (“history-retention”).
            title: "Dictation history",
            subtitle: "Find, copy, replay, and retry past dictations on Home",
            keywords: ["history", "past", "previous", "transcripts", "retry", "search", "recordings", "audio", "undo", "dictation history"]
        ),
        SettingsSearchEntry(
            id: "history-retention",
            page: .history,
            title: "Delete dictations older than",
            subtitle: "Delete dictations after a day, a week, or a month",
            keywords: ["retention", "delete", "privacy", "storage", "keep audio", "keep history for", "keep a history", "save history", "turn off history"]
        ),
        SettingsSearchEntry(
            id: "history-excluded-apps",
            page: .history,
            title: "Never save from these apps",
            subtitle: "Keep password managers, banking, or other private apps out of History",
            keywords: ["exclude", "password", "private", "privacy", "apps", "incognito", "never save from these apps"]
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
            title: "Use an external microphone when the lid is closed",
            subtitle: "Automatically use a non-built-in input in clamshell mode",
            keywords: ["external", "microphone", "lid", "closed", "clamshell", "dock", "external microphone with lid closed"]
        ),
        SettingsSearchEntry(
            id: "skip-silence",
            page: .audio,
            title: "Skip silence",
            subtitle: "Cut quiet stretches so the model only hears speech",
            keywords: ["vad", "voice activity", "silence", "trim", "hallucination", "skip silence before transcribing"]
        ),
        SettingsSearchEntry(
            id: "silence",
            page: .audio,
            title: "Stop after silence",
            subtitle: "Auto-stop after silence",
            keywords: ["vad", "silence", "sensitivity", "threshold", "silence detection"]
        ),
        SettingsSearchEntry(
            id: "sound-effects",
            page: .audio,
            title: "Start and stop sound",
            subtitle: "Start and stop tone, or Off",
            keywords: ["sound", "sounds", "beep", "chime", "audio", "cue", "tone", "dictation tone", "preview", "mute sounds", "sound"]
        ),
        SettingsSearchEntry(
            id: "other-audio",
            page: .audio,
            title: "Mute other audio while dictating",
            subtitle: "Mute music while dictating",
            keywords: ["duck", "mute", "music", "volume", "quiet", "lower", "playback", "youtube", "other audio"]
        ),
        SettingsSearchEntry(
            id: "spotify-pause",
            page: .audio,
            title: "Spotify while dictating",
            subtitle: "Holds playback while the mic is open, Connect included",
            keywords: ["spotify", "connect", "music", "resume", "playback", "speaker", "spotify while dictating"]
        ),

        // Performance
        SettingsSearchEntry(
            id: "model-status",
            page: .performance,
            title: "Model memory",
            subtitle: "Loaded or unloaded",
            keywords: ["loaded", "unload", "ram", "memory", "status", "pause", "model status"]
        ),
        SettingsSearchEntry(
            id: "auto-pause",
            page: .performance,
            title: "Pause for apps",
            subtitle: "Unload while listed apps run",
            keywords: ["pause", "game", "app", "offload", "unload", "auto-pause for apps"]
        ),
        SettingsSearchEntry(
            id: "idle-unload",
            page: .performance,
            title: "Unload models when idle",
            subtitle: "Frees memory after a while without dictating",
            keywords: ["idle", "keepalive", "keep-alive", "battery", "ram", "unload", "unload model when idle"]
        ),
        SettingsSearchEntry(
            id: "resources",
            page: .advanced,
            title: "Resource usage",
            subtitle: "App CPU and memory",
            keywords: ["cpu", "memory", "ram", "resources", "system", "resource usage"]
        ),
        SettingsSearchEntry(
            id: "system-info",
            page: .about,
            title: "This Mac",
            subtitle: "CPU, RAM, Metal",
            keywords: ["system", "metal", "device", "hardware", "system information"]
        ),

        // Application
        SettingsSearchEntry(
            id: "launch-at-login",
            page: .application,
            title: "Open at login",
            keywords: ["startup", "login", "launch at login"]
        ),
        SettingsSearchEntry(
            id: "clipboard",
            page: .application,
            title: "Restore clipboard after typing",
            keywords: ["clipboard", "paste", "preserve clipboard"]
        ),
        SettingsSearchEntry(
            id: "cursor-overlay",
            page: .dictation,
            title: "While you talk",
            subtitle: "Style and position near the cursor",
            keywords: ["overlay", "cursor", "indicator", "mic", "position", "style", "hud", "pill", "stop", "cancel", "recording overlay"]
        ),
        SettingsSearchEntry(
            id: "settings-backup",
            page: .application,
            title: "Back up settings, dictionary and snippets",
            subtitle: "Export or import VocaMac preferences",
            keywords: ["settings", "backup", "export", "import", "transfer", "json", "settings backup"]
        ),

        // Gateway
        SettingsSearchEntry(
            id: "gateway",
            page: .gateway,
            title: "Phone gateway",
            subtitle: "Optional self-hosted VocaGateway",
            keywords: ["gateway", "vocagateway", "pair", "phone", "docker", "self-hosted", "qr", "gateway"]
        ),
        SettingsSearchEntry(
            id: "gateway-pair",
            page: .gateway,
            title: "Pair phone",
            subtitle: "QR code for VocaPhone",
            keywords: ["pair", "phone", "qr", "pairing"]
        ),
        SettingsSearchEntry(
            id: "gateway-docker",
            page: .gateway,
            title: "Use Docker instead",
            subtitle: "Install Docker Desktop when native binary is missing",
            keywords: ["docker", "desktop", "container", "compose", "docker fallback"]
        ),

        // Stats / Advanced / About
        SettingsSearchEntry(
            id: "stats",
            page: .stats,
            title: "Insights",
            keywords: ["streak", "words", "history", "share", "social", "linkedin", "usage stats"]
        ),
        SettingsSearchEntry(
            id: "logs",
            page: .advanced,
            title: "Logs",
            keywords: ["log", "debug", "export", "advanced", "diagnostics", "debug logs"]
        ),
        SettingsSearchEntry(
            id: "permissions",
            page: .advanced,
            title: "Permissions",
            keywords: ["mic", "accessibility", "input monitoring", "advanced", "diagnostics", "restart", "reopen", "relaunch"]
        ),
        SettingsSearchEntry(
            id: "about",
            page: .about,
            title: "About",
            subtitle: "This app, the Voca family, and how to reach us",
            keywords: ["about", "vocamac", "version"]
        ),
        SettingsSearchEntry(
            id: "model-credits",
            page: .about,
            title: "Model credits",
            subtitle: "The teams who made the speech and cleanup models",
            keywords: ["credits", "attribution", "openai", "nvidia", "qwen", "mistral", "whisper", "parakeet", "model credits"]
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

    /// Searchable settings rows, without the ones for controls this build
    /// doesn't show (see `AppDistribution`).
    static let entries: [SettingsSearchEntry] = {
        let hidden = AppDistribution.hiddenSettingsTargets
        return catalog.filter { !hidden.contains($0.id) }
    }()

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
