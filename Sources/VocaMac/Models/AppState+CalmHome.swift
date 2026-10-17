// AppState+CalmHome.swift
// VocaMac
//
// What the v3 Home and Insights pages read from the app state: whether
// Command Mode can be suggested, the keys to show for it and for
// dictation, and the stats summary.

import Foundation

/// Everything the Insights summary, heatmap and app shares are computed
/// from. Equal inputs give equal results, so pages compute them once per change.
struct CalmInsightsInputs: Equatable {
    let stats: UserStats
    let historyRevision: Int
    let historyEnabled: Bool
    /// The start of today: the heatmap and streak move on at midnight.
    let today: Date
}

extension AppState {
    /// The Command Mode shortcut as key-cap labels, or nil when none is set.
    var commandModeShortcutCaps: [String]? {
        shortcut(for: .commandMode).map(CalmKeyCaps.labels(for:))
    }

    /// Whether Command Mode can run an edit right now: it has a shortcut
    /// and its model is ready. Home only suggests it then.
    var commandModeIsUsable: Bool {
        commandModeShortcutCaps != nil && commandModeProblem(for: commandModeEngine) == nil
    }

    /// The dictation key as key-cap labels (“Right ⌥”).
    var dictationKeyCaps: [String] {
        CalmKeyCaps.labels(for: HotKeyCombo(keyCode: hotKeyCode, modifiers: hotKeyModifiers))
    }

    /// The verb that goes with the dictation key: “Hold” or “Double-tap”.
    var dictationKeyVerb: String {
        activationMode == .doubleTapToggle ? "Double-tap" : "Hold"
    }

    /// The calendar statistics are kept in.
    var statsCalendar: Calendar {
        CalmActivityCalendar.statsCalendar(for: statsManager.stats)
    }

    /// Totals, streak and bests for Home and Insights. History only fills
    /// in bests while it is on.
    func insightsSummary(now: Date = Date()) -> CalmInsightsSummary {
        CalmInsightsSummary(
            stats: statsManager.stats,
            history: historyEnabled ? historyStore.entries : [],
            now: now,
            calendar: statsCalendar
        )
    }

    /// What `insightsSummary()` depends on, for pages that cache it.
    var insightsInputs: CalmInsightsInputs {
        CalmInsightsInputs(
            stats: statsManager.stats,
            historyRevision: historyStore.revision,
            historyEnabled: historyEnabled,
            today: statsCalendar.startOfDay(for: Date())
        )
    }

    /// Whether there is anything to share or reset on Insights.
    var hasStatistics: Bool {
        let stats = statsManager.stats
        return stats.totalTranscriptions > 0
            || stats.totalWords > 0
            || stats.totalAudioDurationSeconds > 0
            || !stats.dailyWordCounts.isEmpty
    }
}
