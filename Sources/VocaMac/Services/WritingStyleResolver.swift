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

    var profile: WritingProfile {
        WritingProfile(
            format: style, rules: rules, intent: intent, cleanup: cleanup,
            cleanupLevel: cleanupLevel, cleanupPrompt: cleanupPrompt
        )
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

enum WritingStyleResolver {

    /// Resolve the style for the app that is about to receive text.
    ///
    /// - Parameters:
    ///   - target: The frontmost app at injection time, or the snapshot taken
    ///     when recording started. `nil` falls back to the default style.
    ///   - bindings: The user's configured per-app rules.
    ///   - defaultStyle: Used when no binding matches.
    ///   - isEnabled: The master toggle. When off, nothing is shaped at all.
    static func resolve(
        target: RunningAppSnapshot?,
        bindings: [AppStyleBinding],
        defaultStyle: WritingStyle,
        isEnabled: Bool,
        defaultIntent: WritingIntent = .preserve
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
        }

        return ResolvedWritingStyle(
            style: defaultStyle,
            rules: defaultStyle.defaultRules,
            matchedAppName: nil,
            intent: defaultIntent
        )
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
