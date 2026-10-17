// AppState+CalmCommands.swift
// VocaMac
//
// What the v3 Commands page needs beyond plain stored settings: whether
// Command Mode is on (it is on while it has a shortcut), the one problem
// worth showing, the model line, saved-command drafts and their rules, and
// the shortcut recorder's listener pause.

import Foundation

// MARK: - Copy

/// The Commands page's words, kept out of the views so they can be tested.
enum CalmCommandsText {
    /// The hero's example chips (the design's four).
    static let heroExamples = ["Make this shorter", "Fix the grammar", "Turn this into bullet points", "Translate to German"]

    /// The wider range shown in How it works: edits, writing with nothing
    /// selected, and undo.
    static let moreExamples = [
        "Make this shorter", "Fix grammar and spelling", "Make it more formal",
        "Turn this into bullet points", "Translate to Spanish", "Write a polite reply",
        "Uppercase", "Sort these lines", "Shorter still", "Undo that",
    ]

    /// The hero's line under the title, true to the preview setting.
    static func heroMessage(review: CommandReviewMode) -> String {
        switch review {
        case .never: return "Works in any app. Saying “undo” puts your text back."
        case .longSelections: return "Works in any app. Long edits show a preview first, and saying “undo” puts your text back."
        case .always: return "Works in any app. Every edit shows a preview first, and saying “undo” puts your text back."
        }
    }

    /// The preview dropdown's words for each mode.
    static func reviewTitle(_ mode: CommandReviewMode) -> String {
        switch mode {
        case .never: return "Never"
        case .longSelections: return "Long edits"
        case .always: return "Always"
        }
    }

    /// The allow-list row's summary: “None yet”, a few names, or a count.
    static func shortcutsSummary(_ text: String) -> String {
        let names = SavedCommandStore.shortcutNames(from: text)
        switch names.count {
        case 0: return "None yet, so no shortcut can run"
        case 1...2: return names.joined(separator: ", ")
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }

    /// Keys written together for a button title: “⌃⌥⌘E”.
    static func keys(_ combo: HotKeyCombo) -> String {
        CalmKeyCaps.labels(for: combo).joined()
    }

    /// A saved command's title on its card.
    static func commandName(_ command: SavedCommand) -> String {
        let name = command.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Untitled" : name
    }
}

// MARK: - Status

/// The one thing that stops Command Mode working, or ready.
enum CalmCommandsStatus: Equatable {
    /// No shortcut, so nothing starts it. Carries a free one to offer.
    case off(suggestion: HotKeyCombo?)
    /// The local model it runs isn't on this Mac yet.
    case needsDownload(CleanupModelKind)
    /// That model is downloading now.
    case downloading(CleanupModelKind, progress: Double)
    /// Apple Intelligence or the server can't run an edit.
    case problem(String)
    case ready
}

// MARK: - Saved command drafts

/// A saved command being created or edited in its dialog.
struct CalmSavedCommandDraft: Equatable {
    var id: UUID
    var name: String
    var instruction: String
    var shortcut: HotKeyCombo?
    /// Whether the draft edits an existing command (Save, Delete) or makes one (Create).
    let isNew: Bool

    /// An empty draft for a new command.
    init() {
        id = UUID()
        name = ""
        instruction = ""
        shortcut = nil
        isNew = true
    }

    /// A draft of `command`.
    init(editing command: SavedCommand) {
        id = command.id
        name = command.name
        instruction = command.instruction
        shortcut = HotKeyCombo(storageString: command.shortcut)
        isNew = false
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedInstruction: String { instruction.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why the name can't be used: another command answers to the same
    /// words (compared the way Command Mode hears them).
    func nameProblem(in commands: [SavedCommand]) -> String? {
        let wanted = CommandInstruction.normalized(trimmedName)
        guard !wanted.isEmpty else { return nil }
        let clash = commands.first { $0.id != id && CommandInstruction.normalized($0.name) == wanted }
        guard let clash else { return nil }
        return "“\(CalmCommandsText.commandName(clash))” already answers to that name."
    }

    /// Both a name to say and an instruction to run, and no name clash.
    func isValid(in commands: [SavedCommand]) -> Bool {
        !trimmedName.isEmpty && !trimmedInstruction.isEmpty && nameProblem(in: commands) == nil
    }

    /// `commands` with this draft saved: replaced in place, or added last.
    func applied(to commands: [SavedCommand]) -> [SavedCommand] {
        let saved = SavedCommand(
            id: id, name: trimmedName, instruction: trimmedInstruction,
            shortcut: shortcut?.storageString ?? ""
        )
        var result = commands
        if let index = result.firstIndex(where: { $0.id == id }) {
            result[index] = saved
        } else {
            result.append(saved)
        }
        return result
    }
}

// MARK: - AppState

extension AppState {
    /// Where the switch remembers the shortcut it turned off, so turning it
    /// back on restores the same keys.
    static let calmCommandsLastShortcutKey = "calm.commands.lastShortcut"

    // MARK: On and off

    /// Command Mode has no switch of its own: it runs while it has a
    /// shortcut. The page's switch shows that.
    var isCommandModeOn: Bool { shortcut(for: .commandMode) != nil }

    /// Turn Command Mode off (clearing and remembering its shortcut) or on
    /// (restoring the remembered keys, else the suggested ones).
    ///
    /// - Returns: False when it couldn't turn on because no keys are free;
    ///   the page then opens the recorder.
    @discardableResult
    func setCommandModeOn(_ isOn: Bool, defaults: UserDefaults = .standard) -> Bool {
        if !isOn {
            if let current = shortcut(for: .commandMode) {
                defaults.set(current.storageString, forKey: Self.calmCommandsLastShortcutKey)
            }
            setShortcut(nil, for: .commandMode)
            return true
        }
        guard !isCommandModeOn else { return true }
        let remembered = defaults.string(forKey: Self.calmCommandsLastShortcutKey).flatMap(HotKeyCombo.init(storageString:))
        let candidate = remembered.flatMap { combo in
            ShortcutValidation.problem(with: combo, action: .commandMode, appState: self) == nil ? combo : nil
        } ?? ShortcutValidation.suggestion(for: .commandMode, appState: self)
        guard let candidate else { return false }
        setShortcut(candidate, for: .commandMode)
        return true
    }

    // MARK: Status

    /// The one problem the page shows, most basic first.
    var calmCommandsStatus: CalmCommandsStatus {
        guard isCommandModeOn else {
            return .off(suggestion: ShortcutValidation.suggestion(for: .commandMode, appState: self))
        }
        let engine = commandModeEngine
        if case .local(let kind) = engine {
            if case .downloading(let active, let progress) = transcriptCleanup.modelState, active == kind {
                return .downloading(kind, progress: progress)
            }
            if !transcriptCleanup.isDownloaded(kind) { return .needsDownload(kind) }
        }
        guard let problem = commandModeProblem(for: engine) else { return .ready }
        // The old wording points at a page that moved.
        return .problem(problem.replacingOccurrences(of: "Settings → Command Mode", with: "Settings › Models"))
    }

    /// The Model row's line: what runs the edits and where.
    var calmCommandsModelLine: String {
        switch commandModeEngine {
        case .local(let kind):
            var parts = [CalmModelText.name(kind)]
            if !transcriptCleanup.isDownloaded(kind) {
                parts.append("not downloaded")
            } else if !sharesAIModel {
                parts.append("on this Mac")
            }
            if sharesAIModel { parts.append("shared with Smart Cleanup") }
            return parts.joined(separator: " · ")
        case .appleIntelligence:
            return "Apple Intelligence · built into macOS"
        case .endpoint:
            let endpoint = cleanupEndpoint
            return "\(endpoint.provider.displayName) · \(endpoint.resolvedModel) · same server as Smart Cleanup"
        }
    }

    // MARK: Saved commands

    /// Save a draft from the New or Edit dialog.
    func saveCommandDraft(_ draft: CalmSavedCommandDraft) {
        savedCommands = draft.applied(to: savedCommands)
    }

    func deleteSavedCommand(_ id: UUID) {
        savedCommands = savedCommands.filter { $0.id != id }
    }

    /// Add the starter set, keeping any command already there.
    func addStarterCommands() {
        let existing = Set(savedCommands.map { CommandInstruction.normalized($0.name) })
        let starters = SavedCommand.starters
            .filter { !existing.contains(CommandInstruction.normalized($0.name)) }
            .map { SavedCommand(name: $0.name, instruction: $0.instruction) }
        savedCommands += starters
    }
}
