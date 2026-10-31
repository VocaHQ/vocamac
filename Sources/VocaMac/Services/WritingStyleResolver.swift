// WritingStyleResolver.swift
// VocaMac
//
// Decides which writing style a given dictation should use. Pure, so the
// whole decision is testable from a fixture list without a window server.

import Foundation

/// The style chosen for one dictation, plus why.
struct ResolvedWritingStyle: Equatable {
    let style: WritingStyle
    let rules: WritingStyleRules
    /// The app whose rule matched, for display in Settings and the menu bar.
    let matchedAppName: String?
    var intent: WritingIntent = .preserve
    var cleanup: WritingCleanupPolicy = .inherit
    var cleanupLevel: CleanupLevel?
    var cleanupPrompt: String?
    /// A Terminal rule whose tab in front runs a coding agent: the text is
    /// prose to the agent, so it is formatted and cleaned up as Plain text
    /// (see `WritingStyleResolver.applyingCodingAgent`). `style` stays
    /// Terminal, which is what the menu shows and binds.
    var codingAgent = false
    /// No rule of the user's matched: the app is one VocaMac knows, and it
    /// gets its kind's style (`WritingStyleResolver.automaticStyle`).
    var isAutomatic = false
    /// Learned from the user's edits: the first word starts in lowercase,
    /// whatever the style's capitalization (`AppState.applyingLearnedCasing`).
    var startsInLowercase = false

    var profile: WritingProfile {
        guard codingAgent else {
            return WritingProfile(
                format: style, rules: rules, intent: intent, cleanup: cleanup,
                cleanupLevel: cleanupLevel, cleanupPrompt: cleanupPrompt, startsInLowercase: startsInLowercase
            )
        }
        // Prose for the agent, in the speaker's own words: no Formal or
        // Casual rewrite of an instruction.
        return WritingProfile(
            format: .plain, rules: WritingStyle.plain.defaultRules, intent: .preserve, cleanup: cleanup,
            cleanupLevel: cleanupLevel, cleanupPrompt: cleanupPrompt
        )
    }

    /// The style's name as the menu shows it.
    var displayName: String {
        if codingAgent { return "\(style.displayName) · coding agent" }
        return isAutomatic ? "\(style.displayName) · automatic" : style.displayName
    }

    /// The unshaped result: global preferences only.
    static let plain = ResolvedWritingStyle(
        style: .plain,
        rules: WritingStyle.plain.defaultRules,
        matchedAppName: nil
    )

    /// Passthrough used when the feature is switched off. It intentionally
    /// matches Plain's formatting contract while retaining disabled state for
    /// resolution and UI reporting.
    static let disabled = ResolvedWritingStyle(
        style: .plain,
        rules: .passthrough,
        matchedAppName: nil
    )
}

/// The style an app VocaMac knows gets when the user has no rule for it.
struct AutomaticWritingStyle: Equatable {
    let style: WritingStyle
    let rules: WritingStyleRules
    let appName: String
}

enum WritingStyleResolver {

    /// Resolve the style for the app that is about to receive text.
    ///
    /// - Parameters:
    ///   - target: The frontmost app at injection time, or the snapshot taken
    ///     when recording started. `nil` falls back to the default style.
    ///   - bindings: The user's configured per-app rules.
    ///   - defaultStyle: Used when no binding matches.
    ///   - isEnabled: The master toggle. When off, nothing is shaped at all.
    ///   - automatic: The style for an app with no rule, when VocaMac knows
    ///     what kind of app it is (`automaticStyle`). Nil leaves every app
    ///     without a rule on the default style.
    static func resolve(
        target: RunningAppSnapshot?,
        bindings: [AppStyleBinding],
        defaultStyle: WritingStyle,
        isEnabled: Bool,
        defaultIntent: WritingIntent = .preserve,
        automatic: ((RunningAppSnapshot) -> AutomaticWritingStyle?)? = nil
    ) -> ResolvedWritingStyle {
        guard isEnabled else { return .disabled }

        if let target {
            // Later bindings win, so re-binding an app from the menu bar
            // overrides an earlier seeded entry without needing a removal.
            if let match = bindings.last(where: { $0.isEnabled && $0.matches(target) }) {
                return ResolvedWritingStyle(
                    style: match.style,
                    rules: match.effectiveRules,
                    matchedAppName: match.displayName,
                    intent: match.intent,
                    cleanup: match.cleanup,
                    cleanupLevel: match.cleanupLevel,
                    cleanupPrompt: match.cleanupPrompt
                )
            }
            // Only the format is automatic. Tone stays the user's own:
            // Formal and Casual change words, so they never switch on by
            // themselves.
            if let known = automatic?(target) {
                var resolved = ResolvedWritingStyle(
                    style: known.style, rules: known.rules, matchedAppName: known.appName, intent: defaultIntent
                )
                resolved.isAutomatic = true
                return resolved
            }
        }

        return ResolvedWritingStyle(
            style: defaultStyle,
            rules: defaultStyle.defaultRules,
            matchedAppName: nil,
            intent: defaultIntent
        )
    }

    /// The style for an app the catalog knows, when the user has no rule
    /// for it: the catalog's style (Slack for Slack, Terminal for a
    /// terminal), unless the user picked another style for that kind of
    /// app on the Styles page, which then wins.
    ///
    /// - Parameter pickedStyle: The style the user chose for a group, or nil
    ///   when they never chose one. A pick equal to the group's own default
    ///   is no choice at all: it keeps Slack on Slack and terminals on
    ///   Terminal inside groups whose card shows Chat or Code.
    static func automaticStyle(
        for target: RunningAppSnapshot,
        pickedStyle: (CalmStyleGroup) -> WritingStyle?
    ) -> AutomaticWritingStyle? {
        guard let suggestion = WritingStyleCatalog.suggestion(matching: target) else { return nil }
        let group = CalmStyleGroup.catalogGroup(
            bundleIdentifier: suggestion.bundleIdentifier, processName: suggestion.processName, id: suggestion.id
        ) ?? CalmStyleGroup.family(of: suggestion.style)
        let name = target.displayName.isEmpty ? suggestion.displayName : target.displayName
        if let picked = pickedStyle(group), picked != group.defaultStyle, picked != suggestion.style {
            return AutomaticWritingStyle(style: picked, rules: picked.defaultRules, appName: name)
        }
        return AutomaticWritingStyle(style: suggestion.style, rules: suggestion.binding.effectiveRules, appName: name)
    }

    /// Dictation into a terminal whose tab in front runs a coding agent
    /// (`CodingAgentDetector`) is prose to the agent, not a command: clean
    /// it up like Plain text. RewriteProtectedText still keeps paths, flags,
    /// and identifiers exact.
    ///
    /// Only the default Terminal behaviour changes. A rule whose rules,
    /// cleanup policy, level, or prompt the user set keeps them: they chose
    /// how that terminal's text should come out.
    static func applyingCodingAgent(_ resolved: ResolvedWritingStyle, detected: Bool) -> ResolvedWritingStyle {
        guard detected, resolved.style == .terminal, resolved.rules == WritingStyle.terminal.defaultRules,
              resolved.cleanup == .inherit, resolved.cleanupLevel == nil,
              resolved.cleanupPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        else { return resolved }
        var prose = resolved
        prose.codingAgent = true
        return prose
    }

    /// Website rules override the receiving browser's app rule. Matching uses
    /// only the URL host and never stores page content or browsing history.
    static func applyingWebsiteRule(
        _ resolved: ResolvedWritingStyle,
        url: URL?,
        bindings: [WebsiteStyleBinding]
    ) -> ResolvedWritingStyle {
        // The most specific domain wins, so a mail.example.com rule beats an
        // example.com rule whichever was added first. Among equals, the later.
        let specificity = { (binding: WebsiteStyleBinding) -> Int in
            binding.hostPattern.trimmingCharacters(in: CharacterSet(charactersIn: "*.")).count
        }
        guard let url,
              let match = bindings.filter({ $0.matches(url) })
                .enumerated()
                .max(by: { (specificity($0.element), $0.offset) < (specificity($1.element), $1.offset) })?
                .element else { return resolved }
        return ResolvedWritingStyle(
            style: match.style,
            rules: match.style.defaultRules,
            matchedAppName: match.displayName,
            intent: match.intent,
            cleanup: match.cleanup,
            cleanupLevel: match.cleanupLevel,
            cleanupPrompt: match.cleanupPrompt
        )
    }
}
