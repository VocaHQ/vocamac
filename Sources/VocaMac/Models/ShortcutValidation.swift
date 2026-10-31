// ShortcutValidation.swift
// VocaMac
//
// Rules a keyboard shortcut has to follow before VocaMac accepts it: the
// dictation hotkey, the secondary shortcuts and saved-command shortcuts.

import Foundation

/// Rules shared by the dictation hotkey and the secondary shortcuts. Pure, so
/// they can be tested without an `AppState`.
enum HotKeyComboRules {
    static let typingModifiers: HotKeyModifiers = [.command, .control, .option]

    /// A key that would fire while the user types: anything but a function key
    /// without ⌘, ⌃ or ⌥. Shift or fn alone doesn't help, since ⇧A is typing too.
    static func firesWhileTyping(_ combo: HotKeyCombo) -> Bool {
        guard !KeyCodeReference.isModifierKeyCode(combo.keyCode) else { return false }
        return combo.modifiers.isDisjoint(with: typingModifiers)
            && !isFunctionKey(combo.keyCode)
    }

    /// Why `combo` can't be the dictation hotkey, or nil. A lone modifier
    /// (Right Option, Fn) and a lone function key are valid hotkeys.
    static func dictationHotKeyProblem(
        _ combo: HotKeyCombo,
        existingShortcuts: [HotKeyShortcutAction: HotKeyCombo]
    ) -> String? {
        if firesWhileTyping(combo) {
            let key = KeyCodeReference.displayName(for: HotKeyCombo(keyCode: combo.keyCode, modifiers: []))
            return "\(key) on its own would start dictation while you type. Add ⌘, ⌃, or ⌥, or use a modifier or function key."
        }
        for action in HotKeyShortcutAction.ordered(existingShortcuts.keys) where existingShortcuts[action] == combo {
            return "That's already the \(action.displayName.lowercased()) shortcut."
        }
        return nil
    }

    static func isFunctionKey(_ keyCode: Int) -> Bool {
        [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90].contains(keyCode)
    }

    /// A macOS shortcut the combo takes over while VocaMac runs, or nil.
    /// Allowed, since some people choose it on purpose, but worth saying.
    static func systemConflict(_ combo: HotKeyCombo) -> String? {
        let space = 49
        let tab = 48
        switch (combo.keyCode, combo.modifiers) {
        case (space, [.command]):
            return "⌘ Space opens Spotlight. VocaMac takes it over while running."
        case (space, [.command, .option]):
            return "⌥⌘ Space opens a Finder search. VocaMac takes it over while running."
        case (space, [.control]), (space, [.control, .option]):
            return "\(KeyCodeReference.displayName(for: combo)) switches input sources. VocaMac takes it over while running."
        case (tab, [.command]):
            return "⌘ Tab switches apps. VocaMac takes it over while running."
        default:
            return nil
        }
    }
}

/// Rules a secondary shortcut has to follow.
@MainActor
enum ShortcutValidation {
    /// Function keys are fine alone; anything else needs ⌘, ⌃ or ⌥, or
    /// typing that letter anywhere would trigger the shortcut.
    static func problem(with combo: HotKeyCombo, action: HotKeyShortcutAction, appState: AppState) -> String? {
        if KeyCodeReference.isModifierKeyCode(combo.keyCode) {
            return "Use a key with modifiers, like ⌃⌘V. A modifier on its own is reserved for the dictation hotkey."
        }
        if HotKeyComboRules.firesWhileTyping(combo) {
            return "Add ⌘, ⌃, or ⌥ so the shortcut doesn't fire while you type."
        }
        if combo == HotKeyCombo(keyCode: appState.hotKeyCode, modifiers: appState.hotKeyModifiers) {
            return "That's your dictation hotkey. Pick different keys."
        }
        for other in appState.shortcutActions where other != action && appState.shortcut(for: other) == combo {
            return "That's already the \(appState.shortcutName(for: other)) shortcut."
        }
        return nil
    }

    /// Why `combo` can't be the dictation hotkey, or nil.
    static func dictationHotKeyProblem(with combo: HotKeyCombo, appState: AppState) -> String? {
        var shortcuts: [HotKeyShortcutAction: HotKeyCombo] = [:]
        for action in appState.shortcutActions {
            shortcuts[action] = appState.shortcut(for: action)
        }
        return HotKeyComboRules.dictationHotKeyProblem(combo, existingShortcuts: shortcuts)
    }

    /// Command Mode ships unbound. These use ⌃⌥⌘, which apps and macOS
    /// itself almost never claim, so taking one is unlikely to break anything.
    /// E for "edit" first; the rest in case another VocaMac shortcut has it.
    static let commandModeSuggestions: [HotKeyCombo] = [
        HotKeyCombo(keyCode: 14, modifiers: [.control, .option, .command]),  // E
        HotKeyCombo(keyCode: 40, modifiers: [.control, .option, .command]),  // K
        HotKeyCombo(keyCode: 44, modifiers: [.control, .option, .command]),  // /
    ]

    /// Silent Mode ships unbound too. S for "silent", then M for "mouth".
    /// A secondary shortcut can't be a lone modifier (those are reserved for
    /// the dictation key), so these use ⌃⌥⌘ like Command Mode's.
    static let silentModeSuggestions: [HotKeyCombo] = [
        HotKeyCombo(keyCode: 1, modifiers: [.control, .option, .command]),   // S
        HotKeyCombo(keyCode: 46, modifiers: [.control, .option, .command]),  // M
        HotKeyCombo(keyCode: 47, modifiers: [.control, .option, .command]),  // .
    ]

    /// A shortcut to offer for `action` while it has none, or nil.
    static func suggestion(for action: HotKeyShortcutAction, appState: AppState) -> HotKeyCombo? {
        let candidates: [HotKeyCombo]
        switch action {
        case .commandMode: candidates = commandModeSuggestions
        case .silentMode: candidates = silentModeSuggestions
        default: return nil
        }
        return candidates.first { problem(with: $0, action: action, appState: appState) == nil }
    }
}
