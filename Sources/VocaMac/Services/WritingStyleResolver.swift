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

    /// The unshaped result: global preferences only.
    static let plain = ResolvedWritingStyle(
        style: .plain,
        rules: WritingStyle.plain.defaultRules,
        matchedAppName: nil
    )

    /// Passthrough used when the feature is switched off. Distinct from
    /// `plain` because it must not apply even Tier A symbol rules.
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
        isEnabled: Bool
    ) -> ResolvedWritingStyle {
        guard isEnabled else { return .disabled }

        if let target {
            // Later bindings win, so re-binding an app from the menu bar
            // overrides an earlier seeded entry without needing a removal.
            if let match = bindings.last(where: { $0.isEnabled && $0.matches(target) }) {
                return ResolvedWritingStyle(
                    style: match.style,
                    rules: match.effectiveRules,
                    matchedAppName: match.displayName
                )
            }
        }

        return ResolvedWritingStyle(
            style: defaultStyle,
            rules: defaultStyle.defaultRules,
            matchedAppName: nil
        )
    }
}
