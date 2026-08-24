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
            AppStyleBinding(
                id: id,
                displayName: displayName,
                bundleIdentifier: bundleIdentifier,
                processName: processName,
                style: style
            )
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
    static func merging(
        _ existing: [AppStyleBinding],
        with newSuggestions: [Suggestion]
    ) -> [AppStyleBinding] {
        var result = existing
        var existingIDs = Set(existing.map(\.id))
        var existingBundles = Set(existing.compactMap { $0.bundleIdentifier?.lowercased() })
        // A rule the user made by process name ("ghostty") must block the
        // catalog's bundle-ID entry for the same app, or they end up with two
        // rules and no way to tell which one wins.
        var existingProcesses = Set(
            existing.compactMap { binding -> String? in
                let name = binding.processName ?? binding.id
                let normalized = AppIdentityMatching.normalizeProcessName(name)
                return normalized.isEmpty ? nil : normalized
            }
        )

        for suggestion in newSuggestions {
            if existingIDs.contains(suggestion.id) { continue }
            if let bundle = suggestion.bundleIdentifier?.lowercased(), existingBundles.contains(bundle) { continue }
            let process = AppIdentityMatching.normalizeProcessName(suggestion.processName ?? suggestion.id)
            if !process.isEmpty, existingProcesses.contains(process) { continue }

            result.append(suggestion.binding)
            existingIDs.insert(suggestion.id)
            if let bundle = suggestion.bundleIdentifier?.lowercased() { existingBundles.insert(bundle) }
            if !process.isEmpty { existingProcesses.insert(process) }
        }
        return result
    }
}
