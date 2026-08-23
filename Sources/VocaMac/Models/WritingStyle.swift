// WritingStyle.swift
// VocaMac
//
// Per-app dictation output styles. A style is a named bundle of formatting
// rules applied to a finished utterance before it is injected, so the same
// spoken words land as `myfile.md` in an editor and as a plain sentence in
// a chat app.

import Foundation

// MARK: - Rule value types

/// How a style treats sentence capitalization.
enum CapitalizationPolicy: String, Codable, CaseIterable, Identifiable {
    /// Follow the global Dictation preference.
    case inherit
    /// Never change letter case.
    case off
    /// Capitalize the first letter and letters after `.` `!` `?`.
    case sentences

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .inherit:   return "Use global setting"
        case .off:       return "Leave case alone"
        case .sentences: return "Capitalize sentences"
        }
    }
}

/// How a style treats punctuation at the very end of an utterance.
enum TerminalPunctuationPolicy: String, Codable, CaseIterable, Identifiable {
    /// Ship whatever the engine produced.
    case leaveAsIs
    /// Remove a single trailing `.` (editors and shells rarely want one).
    case stripTrailingPeriod
    /// Add `.` when the utterance ends without terminal punctuation.
    case ensurePeriod

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leaveAsIs:           return "Leave as dictated"
        case .stripTrailingPeriod: return "Remove trailing period"
        case .ensurePeriod:        return "End with a period"
        }
    }
}

/// How a style treats the trailing space between consecutive utterances.
enum TrailingSpacePolicy: String, Codable, CaseIterable, Identifiable {
    /// Follow the global Dictation preference.
    case inherit
    case on
    case off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .inherit: return "Use global setting"
        case .on:      return "Always add"
        case .off:     return "Never add"
        }
    }
}

/// Which emphasis markup a style emits for spoken "bold" / "italic" commands.
enum EmphasisDialect: String, Codable, CaseIterable, Identifiable {
    /// Emphasis commands are left as spoken words.
    case none
    /// CommonMark: `**bold**`, `*italic*`, `~~strike~~`.
    case markdown
    /// Slack mrkdwn: `*bold*`, `_italic_`, `~strike~`.
    case slackMrkdwn

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:        return "Off"
        case .markdown:    return "Markdown (**bold**)"
        case .slackMrkdwn: return "Slack (*bold*)"
        }
    }
}

/// How a style treats leading filler words ("um", "uh", "so", …).
enum FillerPolicy: String, Codable, CaseIterable, Identifiable {
    case keep
    /// Drop filler words only at the very start of an utterance.
    case trimLeading

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .keep:        return "Keep"
        case .trimLeading: return "Trim at start"
        }
    }
}

/// Confidence tiers for turning spoken symbol names into literal punctuation.
///
/// Split because the two halves carry very different false-positive risk.
/// Tier A only fires in contexts that cannot plausibly be prose ("config dot
/// json"), while Tier B uses heuristics that could in principle misread a
/// sentence ("user slash admin"). Users can disable B alone.
struct SpokenSymbolTiers: OptionSet, Codable, Hashable {
    let rawValue: Int

    /// Context-locked rules: known file extensions, explicit case commands,
    /// and bracket commands that carry an explicit "open"/"close".
    static let tierA = SpokenSymbolTiers(rawValue: 1 << 0)
    /// Heuristic rules: path slashes and identifier joiners.
    static let tierB = SpokenSymbolTiers(rawValue: 1 << 1)

    static let none: SpokenSymbolTiers = []
    static let all: SpokenSymbolTiers = [.tierA, .tierB]
}

// MARK: - Rules

/// The complete formatting contract for one style.
///
/// Values are plain data so a style preset, a per-app override, and (later) a
/// user-authored style can all be expressed with the same type. Every field is
/// individually editable in Settings.
struct WritingStyleRules: Codable, Hashable {
    var capitalization: CapitalizationPolicy
    var terminalPunctuation: TerminalPunctuationPolicy
    var trailingSpace: TrailingSpacePolicy
    var spokenSymbols: SpokenSymbolTiers
    /// Glue identifier runs around spoken `.` `/` `_` `-` into one token.
    var pathStitching: Bool
    /// Honor "camel case", "snake case", "kebab case", "pascal case".
    var caseCommands: Bool
    var emphasisDialect: EmphasisDialect
    /// Turn a leading "bullet" into a `- ` list marker.
    var listMarkers: Bool
    /// Honor "new line" and "new paragraph".
    var newlineCommands: Bool
    var filler: FillerPolicy

    init(
        capitalization: CapitalizationPolicy = .inherit,
        terminalPunctuation: TerminalPunctuationPolicy = .leaveAsIs,
        trailingSpace: TrailingSpacePolicy = .inherit,
        spokenSymbols: SpokenSymbolTiers = .none,
        pathStitching: Bool = false,
        caseCommands: Bool = false,
        emphasisDialect: EmphasisDialect = .none,
        listMarkers: Bool = false,
        newlineCommands: Bool = false,
        filler: FillerPolicy = .keep
    ) {
        self.capitalization = capitalization
        self.terminalPunctuation = terminalPunctuation
        self.trailingSpace = trailingSpace
        self.spokenSymbols = spokenSymbols
        self.pathStitching = pathStitching
        self.caseCommands = caseCommands
        self.emphasisDialect = emphasisDialect
        self.listMarkers = listMarkers
        self.newlineCommands = newlineCommands
        self.filler = filler
    }

    /// Rules that reproduce VocaMac's pre-writing-styles behavior exactly:
    /// defer both toggles to the global Dictation preferences and change
    /// nothing else.
    static let passthrough = WritingStyleRules()
}

// MARK: - Style

/// Built-in output styles. Users bind these to apps; `plain` is the fallback
/// and is byte-for-byte identical to the pre-feature pipeline.
enum WritingStyle: String, CaseIterable, Identifiable, Codable {
    case plain
    case code
    case terminal
    case chat
    case slack
    case email
    case notes

    var id: String { rawValue }

    /// New installs and any unrecognized stored id.
    static let defaultStyle: WritingStyle = .plain

    var displayName: String {
        switch self {
        case .plain:    return "Plain"
        case .code:     return "Code"
        case .terminal: return "Terminal"
        case .chat:     return "Chat"
        case .slack:    return "Slack"
        case .email:    return "Email"
        case .notes:    return "Notes"
        }
    }

    var shortDescription: String {
        switch self {
        case .plain:
            return "No shaping. Uses only the global Dictation settings."
        case .code:
            return "Filenames, paths, and identifiers. No sentence case, no trailing period."
        case .terminal:
            return "Like Code, but never adds a trailing space that would break shell history."
        case .chat:
            return "Sentence case, no forced punctuation, no code shaping."
        case .slack:
            return "Chat plus Slack's *bold* markup and bullet lists."
        case .email:
            return "Full sentences ending in a period, with Markdown emphasis."
        case .notes:
            return "Markdown documents: **bold**, bullets, and filename shaping."
        }
    }

    var systemImage: String {
        switch self {
        case .plain:    return "text.alignleft"
        case .code:     return "chevron.left.forwardslash.chevron.right"
        case .terminal: return "terminal"
        case .chat:     return "bubble.left.and.bubble.right"
        case .slack:    return "number.square"
        case .email:    return "envelope"
        case .notes:    return "note.text"
        }
    }

    /// The preset's rules. A binding may override individual fields.
    var defaultRules: WritingStyleRules {
        switch self {
        case .plain:
            return WritingStyleRules(
                spokenSymbols: .tierA
            )
        case .code:
            return WritingStyleRules(
                capitalization: .off,
                terminalPunctuation: .stripTrailingPeriod,
                spokenSymbols: .all,
                pathStitching: true,
                caseCommands: true,
                newlineCommands: true,
                filler: .trimLeading
            )
        case .terminal:
            return WritingStyleRules(
                capitalization: .off,
                terminalPunctuation: .stripTrailingPeriod,
                trailingSpace: .off,
                spokenSymbols: .all,
                pathStitching: true,
                caseCommands: true,
                filler: .trimLeading
            )
        case .chat:
            return WritingStyleRules(
                capitalization: .sentences,
                newlineCommands: true
            )
        case .slack:
            return WritingStyleRules(
                capitalization: .sentences,
                emphasisDialect: .slackMrkdwn,
                listMarkers: true,
                newlineCommands: true
            )
        case .email:
            return WritingStyleRules(
                capitalization: .sentences,
                terminalPunctuation: .ensurePeriod,
                emphasisDialect: .markdown,
                newlineCommands: true,
                filler: .trimLeading
            )
        case .notes:
            return WritingStyleRules(
                capitalization: .sentences,
                spokenSymbols: .tierA,
                pathStitching: true,
                emphasisDialect: .markdown,
                listMarkers: true,
                newlineCommands: true
            )
        }
    }

    /// Resolve a stored preference. Empty, missing, and unknown ids become
    /// `plain` so a corrupt value can never change how text is formatted.
    static func resolved(stored: String?) -> WritingStyle {
        guard let stored, !stored.isEmpty else { return defaultStyle }
        return WritingStyle(rawValue: stored) ?? defaultStyle
    }
}

// MARK: - SpokenSymbolTiers Codable

extension SpokenSymbolTiers {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(Int.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
