// TextDelivery.swift
// VocaMac
//
// How a finished dictation goes into the app: pasted (the default) or
// typed key by key, and whether Return is pressed after it ("Auto Send").
// The rules are pure so they are tested without a window server.

import Foundation

/// How text is put into the focused app.
enum InsertionMethod: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Write into the field or paste with ⌘V, and type it when a paste is
    /// seen to go nowhere.
    case automatic
    /// Always type the text key by key. Slower, but works in apps that
    /// ignore ⌘V or paste something else (remote desktops, some games and
    /// terminals, web apps that block paste).
    case typing

    var id: String { rawValue }

    static let defaultMethod: InsertionMethod = .automatic

    var displayName: String {
        switch self {
        case .automatic: return "Paste"
        case .typing: return "Type"
        }
    }

    var settingsDescription: String {
        switch self {
        case .automatic:
            return "Pastes, and types the text instead when an app doesn’t take the paste"
        case .typing:
            return "Types every dictation key by key. Slower for long text"
        }
    }
}

/// When VocaMac presses Return after a dictation.
enum AutoSendMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    /// Only when the dictation ends with its own sentence “send it”
    /// (or “press enter”), which is removed from the text.
    case spokenCue
    /// After every dictation.
    case always

    var id: String { rawValue }

    static let defaultMode: AutoSendMode = .off

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .spokenCue: return "When I say “send it”"
        case .always: return "After every dictation"
        }
    }

    var settingsDescription: String {
        switch self {
        case .off:
            return "Return is never pressed for you"
        case .spokenCue:
            return "End with “send it” or “press enter” as its own sentence to press Return. Not in terminals or code editors unless you add them"
        case .always:
            return "Presses Return after each dictation. Not in terminals or code editors unless you add them"
        }
    }
}

/// What the text injector does with one dictation.
struct TextDeliveryOptions: Equatable, Sendable {
    /// Type the text instead of writing or pasting it.
    var typesText = false
    /// Type the text when a paste is seen to go unread by the app.
    var typesWhenPasteFails = true
    /// Press Return once the text is in (and only if it is known to be).
    var pressesReturn = false

    static let standard = TextDeliveryOptions()
}

enum TextDeliveryPlan {
    /// Longest text typed key by key. Past this, typing takes long enough
    /// that a focus change midway is likely; the text stays in VocaMac.
    static let maxTypedCharacters = 4_000

    /// Whether the dictation is typed rather than pasted.
    static func typesText(method: InsertionMethod, app: RunningAppSnapshot?, typingApps: [AutoPauseAppEntry]) -> Bool {
        method == .typing || listed(app, in: typingApps)
    }

    /// Whether Return may be pressed in `app`.
    ///
    /// Terminals and code editors are left out unless the user listed the
    /// app: Return there runs a command or breaks a line of code, which an
    /// accidental "send it" must never do.
    static func autoSendAllowed(
        in app: RunningAppSnapshot?, isCodeOrTerminal: Bool, autoSendApps: [AutoPauseAppEntry]
    ) -> Bool {
        guard let app else { return false }
        if listed(app, in: autoSendApps) { return true }
        return !isCodeOrTerminal
    }

    /// Whether Return is pressed after this dictation.
    static func pressesReturn(mode: AutoSendMode, cueSpoken: Bool, allowedHere: Bool) -> Bool {
        guard allowedHere else { return false }
        switch mode {
        case .off: return false
        case .spokenCue: return cueSpoken
        case .always: return true
        }
    }

    private static func listed(_ app: RunningAppSnapshot?, in entries: [AutoPauseAppEntry]) -> Bool {
        HistoryExclusion.isExcluded(app, by: entries)
    }
}

/// The spoken "send it" at the end of a dictation.
///
/// Read from what the engine heard — the user's own words — never from
/// selected text or anything the language model wrote. The cue must be its
/// own sentence (after a full stop, question or exclamation mark, or the
/// whole dictation): "Let me know and I'll send it." ends with the words but
/// is not a request, and a comma is too common inside a sentence to count.
/// When unsure, nothing is sent.
enum AutoSendCue {
    static let phrases = [
        "send it", "send that", "send this", "send message", "send the message",
        "press enter", "press return", "hit enter", "hit return", "hit send",
    ]

    /// Whether `spoken` ends with the cue as its own sentence.
    static func endsWithCue(_ spoken: String) -> Bool {
        cueRange(in: spoken) != nil
    }

    /// `text` without its trailing cue, or nil when it doesn't end with one.
    /// The punctuation before the cue stays: "Thanks. Send it." → "Thanks."
    static func removingCue(from text: String) -> String? {
        guard let range = cueRange(in: text) else { return nil }
        return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The cue's range in `text`, from its first letter to the end.
    private static func cueRange(in text: String) -> Range<String.Index>? {
        let trailing = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?…"))
        var end = text.endIndex
        while end > text.startIndex,
              let scalar = text[text.index(before: end)].unicodeScalars.first,
              trailing.contains(scalar) {
            end = text.index(before: end)
        }
        let body = text[..<end]
        let lowered = body.lowercased().replacingOccurrences(of: "’", with: "'")
        for phrase in phrases where lowered.hasSuffix(phrase) {
            // Lowercasing can change the length of some scripts; the cue
            // itself is ASCII, so count back from the original end.
            guard let start = body.index(end, offsetBy: -phrase.count, limitedBy: body.startIndex),
                  body[start...].lowercased() == phrase else { continue }
            let before = body[..<start].trimmingCharacters(in: .whitespaces)
            guard before.isEmpty || before.last.map({ ".!?…".contains($0) }) == true else { continue }
            // The word must start at the cue, not inside one ("resend it").
            if start > body.startIndex, body[body.index(before: start)].isLetter { continue }
            return start..<text.endIndex
        }
        return nil
    }
}
