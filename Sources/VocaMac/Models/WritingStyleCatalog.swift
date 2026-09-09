// WritingStyleCatalog.swift
// VocaMac
//
// Suggested app → style pairings seeded on first run. Static data, no
// network, no downloads: a stale entry simply fails to match and the app
// falls back to the default style.

import Foundation
import AppKit

/// Built-in suggestions for well-known macOS apps.
enum WritingStyleCatalog {

    /// One suggested pairing.
    struct Suggestion: Hashable, Identifiable, Sendable {
        let displayName: String
        let bundleIdentifier: String?
        /// Fallback for tools launched outside `/Applications`, where the
        /// bundle ID may be absent.
        let processName: String?
        let style: WritingStyle

        var id: String { bundleIdentifier ?? processName ?? displayName }

        init(_ displayName: String, bundleIdentifier: String? = nil, processName: String? = nil, style: WritingStyle) {
            self.displayName = displayName
            self.bundleIdentifier = bundleIdentifier
            self.processName = processName
            self.style = style
        }

        /// Convert to a persisted binding.
        var binding: AppStyleBinding {
            var binding = AppStyleBinding(
                id: id,
                displayName: displayName,
                bundleIdentifier: bundleIdentifier,
                processName: processName,
                style: style
            )
            // Plain paste does not create rich text in these destinations.
            if bundleIdentifier == "com.apple.Notes" || bundleIdentifier == "com.culturedcode.ThingsMac" {
                var rules = style.defaultRules
                rules.emphasisDialect = .none
                binding.ruleOverrides = rules
            }
            return binding
        }
    }

    /// The full suggestion list, grouped by style for readability.
    static let suggestions: [Suggestion] = editors + terminals + chat + mail + notes

    // MARK: - Code

    static let editors: [Suggestion] = [
        Suggestion("Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92", processName: "Cursor", style: .code),
        Suggestion("Visual Studio Code", bundleIdentifier: "com.microsoft.VSCode", processName: "Code", style: .code),
        Suggestion("VS Code Insiders", bundleIdentifier: "com.microsoft.VSCodeInsiders", style: .code),
        Suggestion("VSCodium", bundleIdentifier: "com.vscodium", style: .code),
        Suggestion("Xcode", bundleIdentifier: "com.apple.dt.Xcode", style: .code),
        Suggestion("Zed", bundleIdentifier: "dev.zed.Zed", processName: "zed", style: .code),
        Suggestion("Sublime Text", bundleIdentifier: "com.sublimetext.4", style: .code),
        Suggestion("Nova", bundleIdentifier: "com.panic.Nova", style: .code),
        Suggestion("IntelliJ IDEA", bundleIdentifier: "com.jetbrains.intellij", style: .code),
        Suggestion("PyCharm", bundleIdentifier: "com.jetbrains.pycharm", style: .code),
        Suggestion("WebStorm", bundleIdentifier: "com.jetbrains.WebStorm", style: .code),
        Suggestion("GoLand", bundleIdentifier: "com.jetbrains.goland", style: .code),
        Suggestion("Android Studio", bundleIdentifier: "com.google.android.studio", style: .code),
        Suggestion("Windsurf", bundleIdentifier: "com.exafunction.windsurf", style: .code),
        Suggestion("IntelliJ IDEA CE", bundleIdentifier: "com.jetbrains.intellij.ce", style: .code),
        Suggestion("PyCharm CE", bundleIdentifier: "com.jetbrains.pycharm.ce", style: .code),
        Suggestion("PhpStorm", bundleIdentifier: "com.jetbrains.PhpStorm", style: .code),
        Suggestion("RubyMine", bundleIdentifier: "com.jetbrains.rubymine", style: .code),
        Suggestion("CLion", bundleIdentifier: "com.jetbrains.CLion", style: .code),
        Suggestion("Rider", bundleIdentifier: "com.jetbrains.rider", style: .code),
        Suggestion("DataGrip", bundleIdentifier: "com.jetbrains.datagrip", style: .code),
        Suggestion("RustRover", bundleIdentifier: "com.jetbrains.rustrover", style: .code),
        Suggestion("Emacs", bundleIdentifier: "org.gnu.Emacs", processName: "Emacs", style: .code),
        Suggestion("MacVim", bundleIdentifier: "org.vim.MacVim", processName: "MacVim", style: .code),
        Suggestion("Neovide", bundleIdentifier: "com.neovide.neovide", processName: "neovide", style: .code),
        Suggestion("BBEdit", bundleIdentifier: "com.barebones.bbedit", style: .code),
        Suggestion("Trae", bundleIdentifier: "com.trae.app", style: .code)
    ]

    // MARK: - Terminal

    static let terminals: [Suggestion] = [
        Suggestion("Terminal", bundleIdentifier: "com.apple.Terminal", style: .terminal),
        Suggestion("iTerm2", bundleIdentifier: "com.googlecode.iterm2", style: .terminal),
        Suggestion("Ghostty", bundleIdentifier: "com.mitchellh.ghostty", processName: "ghostty", style: .terminal),
        Suggestion("Warp", bundleIdentifier: "dev.warp.Warp-Stable", style: .terminal),
        Suggestion("kitty", bundleIdentifier: "net.kovidgoyal.kitty", processName: "kitty", style: .terminal),
        Suggestion("WezTerm", bundleIdentifier: "com.github.wez.wezterm", processName: "wezterm-gui", style: .terminal),
        Suggestion("Alacritty", bundleIdentifier: "org.alacritty", processName: "alacritty", style: .terminal),
        Suggestion("Hyper", bundleIdentifier: "co.zeit.hyper", style: .terminal),
        Suggestion("Tabby", bundleIdentifier: "org.tabby", processName: "Tabby", style: .terminal),
        Suggestion("Rio", bundleIdentifier: "com.raphaelamorim.rio", processName: "rio", style: .terminal)
    ]

    // MARK: - Chat

    static let chat: [Suggestion] = [
        Suggestion("Slack", bundleIdentifier: "com.tinyspeck.slackmacgap", style: .slack),
        Suggestion("Messages", bundleIdentifier: "com.apple.MobileSMS", style: .chat),
        Suggestion("WhatsApp", bundleIdentifier: "net.whatsapp.WhatsApp", style: .chat),
        Suggestion("Telegram", bundleIdentifier: "ru.keepcoder.Telegram", style: .chat),
        Suggestion("Discord", bundleIdentifier: "com.hnc.Discord", style: .chat),
        Suggestion("Signal", bundleIdentifier: "org.whispersystems.signal-desktop", style: .chat),
        Suggestion("Microsoft Teams", bundleIdentifier: "com.microsoft.teams2", style: .chat),
        Suggestion("Zoom", bundleIdentifier: "us.zoom.xos", style: .chat),
        Suggestion("Element", bundleIdentifier: "im.riot.app", style: .chat),
        Suggestion("Claude", bundleIdentifier: "com.anthropic.claudefordesktop", style: .chat),
        Suggestion("ChatGPT", bundleIdentifier: "com.openai.chat", style: .chat),
        Suggestion("ChatGPT", bundleIdentifier: "com.openai.codex", style: .chat),
        Suggestion("Slack (Beta)", bundleIdentifier: "com.tinyspeck.slackmacgap.beta", style: .slack)
    ]

    // MARK: - Email

    static let mail: [Suggestion] = [
        Suggestion("Mail", bundleIdentifier: "com.apple.mail", style: .email),
        Suggestion("Outlook", bundleIdentifier: "com.microsoft.Outlook", style: .email),
        Suggestion("Spark", bundleIdentifier: "com.readdle.smartemail-Mac", style: .email),
        Suggestion("Superhuman", bundleIdentifier: "com.superhuman.electron", style: .email),
        Suggestion("Mimestream", bundleIdentifier: "com.mimestream.Mimestream", style: .email)
    ]

    // MARK: - Notes

    static let notes: [Suggestion] = [
        Suggestion("Obsidian", bundleIdentifier: "md.obsidian", style: .notes),
        Suggestion("Bear", bundleIdentifier: "net.shinyfrog.bear", style: .notes),
        Suggestion("Notion", bundleIdentifier: "notion.id", style: .notes),
        Suggestion("Notes", bundleIdentifier: "com.apple.Notes", style: .notes),
        Suggestion("Craft", bundleIdentifier: "com.lukilabs.lukiapp", style: .notes),
        Suggestion("iA Writer", bundleIdentifier: "pro.writer.mac", style: .notes),
        Suggestion("Linear", bundleIdentifier: "com.linear", style: .notes),
        Suggestion("Things", bundleIdentifier: "com.culturedcode.ThingsMac", style: .notes),
        Suggestion("Logseq", bundleIdentifier: "com.electron.logseq", style: .notes),
        Suggestion("Ulysses", bundleIdentifier: "com.soulmen.ulysses3", style: .notes),
        Suggestion("Drafts", bundleIdentifier: "com.agiletortoise.Drafts-OSX", style: .notes),
        Suggestion("Todoist", bundleIdentifier: "com.todoist.mac.Todoist", style: .notes),
        Suggestion("Height", bundleIdentifier: "com.height.app", style: .notes)
    ]

    // MARK: - Seeding

    /// Suggestions for apps that are installed right now.
    ///
    /// Seeding only what the user actually has keeps the Settings list short
    /// and honest — a rule for an app they have never opened is noise.
    static func suggestionsForInstalledApps(
        running: [RunningAppSnapshot] = AppIdentityMatching.workspaceRunningApps(),
        isInstalled: (String) -> Bool = defaultInstallCheck
    ) -> [Suggestion] {
        suggestions.filter { suggestion in
            if let bundleID = suggestion.bundleIdentifier, isInstalled(bundleID) {
                return true
            }
            return running.contains { snapshot in
                AppIdentityMatching.matches(
                    configuredBundleIdentifier: suggestion.bundleIdentifier,
                    configuredProcessName: suggestion.processName,
                    configuredID: suggestion.id,
                    snapshot: snapshot
                )
            }
        }
    }

    /// Whether an app with this bundle ID is installed, via LaunchServices.
    static func defaultInstallCheck(_ bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    /// Merge suggestions into an existing binding list without disturbing
    /// anything the user already configured.
    ///
    /// - Parameter excluding: Rules the user deliberately removed while an
    ///   async discovery was in flight. They occupy merge slots (id / bundle /
    ///   process) so catalog entries for those apps are not resurrected, but
    ///   they are not written back into the result.
    static func merging(
        _ existing: [AppStyleBinding],
        with newSuggestions: [Suggestion],
        excluding: [AppStyleBinding] = []
    ) -> [AppStyleBinding] {
        var result = existing
        var existingIDs = Set(existing.map(\.id))
        var existingBundles = Set(existing.compactMap { $0.bundleIdentifier?.lowercased() })
        // A rule the user made by process name ("Terminal" / "ghostty") must
        // block the catalog's bundle-ID entry for the same app, or they end
        // up with two rules and no way to tell which one wins. Occupancy keys
        // are process name + full bundle ID (plus narrow Terminal aliases) —
        // never raw display name or last path segment alone, which conflates
        // distinct apps that share a label (OpenAI Chat vs Codex).
        var existingProcesses = Set<String>()
        for binding in existing {
            existingProcesses.formUnion(mergeProcessKeys(for: binding))
        }

        for binding in excluding {
            existingIDs.insert(binding.id)
            if let bundle = binding.bundleIdentifier?.lowercased() {
                existingBundles.insert(bundle)
            }
            existingProcesses.formUnion(mergeProcessKeys(for: binding))
        }

        for suggestion in newSuggestions {
            if existingIDs.contains(suggestion.id) { continue }
            if let bundle = suggestion.bundleIdentifier?.lowercased(), existingBundles.contains(bundle) { continue }
            let suggestionKeys = mergeProcessKeys(for: suggestion)
            if !suggestionKeys.isDisjoint(with: existingProcesses) { continue }

            result.append(suggestion.binding)
            existingIDs.insert(suggestion.id)
            if let bundle = suggestion.bundleIdentifier?.lowercased() { existingBundles.insert(bundle) }
            existingProcesses.formUnion(suggestionKeys)
        }
        return result
    }

    /// Process-identity keys for merge occupancy: normalized process name and
    /// full bundle ID only. Display names and last bundle-ID segments are too
    /// weak — `com.openai.chat` and `com.openai.codex` both display as
    /// "ChatGPT" and must not share an occupancy slot.
    ///
    /// Terminal is the careful exception: its catalog entry has a bundle ID
    /// and no process name, so a process-only "Terminal" rule would otherwise
    /// fail to block `com.apple.Terminal` after mid-flight removal. Narrow
    /// aliases bridge that gap without reopening display-name conflation.
    private static let mergeProcessBundleAliases: [(process: String, bundle: String)] = [
        ("terminal", "com.apple.terminal")
    ]

    private static func mergeProcessKeys(for binding: AppStyleBinding) -> Set<String> {
        var keys = Set<String>()
        if let process = binding.processName {
            insertMergeProcessKey(process, into: &keys)
        } else {
            insertMergeProcessKey(binding.id, into: &keys)
        }
        if let bundle = binding.bundleIdentifier {
            insertMergeProcessKey(bundle, into: &keys)
        }
        expandMergeProcessAliases(into: &keys)
        return keys
    }

    private static func mergeProcessKeys(for suggestion: Suggestion) -> Set<String> {
        var keys = Set<String>()
        if let process = suggestion.processName {
            insertMergeProcessKey(process, into: &keys)
        } else if suggestion.bundleIdentifier == nil {
            // Process-only / id-only suggestions still occupy their process key.
            insertMergeProcessKey(suggestion.id, into: &keys)
        }
        if let bundle = suggestion.bundleIdentifier {
            insertMergeProcessKey(bundle, into: &keys)
        }
        expandMergeProcessAliases(into: &keys)
        return keys
    }

    private static func expandMergeProcessAliases(into keys: inout Set<String>) {
        for alias in mergeProcessBundleAliases {
            if keys.contains(alias.process) || keys.contains(alias.bundle) {
                keys.insert(alias.process)
                keys.insert(alias.bundle)
            }
        }
    }

    private static func insertMergeProcessKey(_ raw: String, into keys: inout Set<String>) {
        let normalized = AppIdentityMatching.normalizeProcessName(raw)
        if !normalized.isEmpty {
            keys.insert(normalized)
        }
    }
}
