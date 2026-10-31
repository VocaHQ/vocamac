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

    /// `insightsSummary()`, computed once per change of its inputs and kept
    /// across page switches (Home's side card and Insights both show it).
    func calmInsightsSummary() -> CalmInsightsSummary {
        calmDerived.value(\.summary, for: insightsInputs) { insightsSummary() }
    }

    /// The streak dots for the last seven days.
    func calmStreakWeek() -> [CalmStreakDay] {
        calmDerived.value(\.week, for: insightsInputs) {
            let calendar = statsCalendar
            return CalmActivityCalendar.streakWeek(
                CalmActivityCalendar.lastSevenDays(stats: statsManager.stats, calendar: calendar), calendar: calendar
            )
        }
    }

    /// The heatmap's year of days.
    func calmHeatmapDays() -> [CalmActivityDay] {
        calmDerived.value(\.heatmap, for: insightsInputs) {
            CalmActivityCalendar.heatmapDays(stats: statsManager.stats, calendar: statsCalendar)
        }
    }

    /// The apps the user dictates into most, from history (empty while it's off).
    func calmAppShares() -> [CalmAppShare] {
        calmDerived.value(\.apps, for: insightsInputs) {
            historyEnabled ? CalmAppShare.top(from: historyStore.entries) : []
        }
    }

    /// How many dictations went out without the user editing them, from
    /// history (nil while it's off or has too few read-backs).
    func calmEditFreeRate() -> CalmEditFreeRate? {
        calmDerived.value(\.editFree, for: insightsInputs) {
            historyEnabled ? CalmEditFreeRate.from(historyStore.entries) : nil
        }
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

/// What the v3 window derives from stats and history, kept on `AppState`
/// so switching pages doesn't redo it. Each page used to recompute the
/// summary and app shares from all of history every time it appeared.
@MainActor
final class CalmDerivedCache {
    struct Entry<Value> {
        let key: CalmInsightsInputs
        let value: Value
    }

    var summary: Entry<CalmInsightsSummary>?
    var week: Entry<[CalmStreakDay]>?
    var heatmap: Entry<[CalmActivityDay]>?
    var apps: Entry<[CalmAppShare]>?
    var editFree: Entry<CalmEditFreeRate?>?
    /// Last decode of the Styles page's group store and of the website
    /// rules, keyed by the JSON they came from: the Styles page and its
    /// Add dialog read them once per rule and row, and decoding JSON each
    /// time made those views slow to open.
    var styleGroups: (json: String?, store: CalmStyleGroupStore)?
    var websites: (json: String?, bindings: [WebsiteStyleBinding])?

    /// The value stored at `slot` when it was computed for `key`, otherwise
    /// a fresh one, which replaces it.
    func value<Value>(
        _ slot: ReferenceWritableKeyPath<CalmDerivedCache, Entry<Value>?>,
        for key: CalmInsightsInputs,
        compute: () -> Value
    ) -> Value {
        if let entry = self[keyPath: slot], entry.key == key { return entry.value }
        let value = compute()
        self[keyPath: slot] = Entry(key: key, value: value)
        return value
    }
}

// MARK: - Getting started

/// One step of Home's Get started checklist.
enum CalmGettingStartedStep: String, CaseIterable, Identifiable, Sendable {
    case dictate, pickModel, addWord, smartCleanup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictate: return "Dictate something"
        case .pickModel: return "Choose a speech model"
        case .addWord: return "Add a word to your dictionary"
        case .smartCleanup: return "Turn on Smart Cleanup"
        }
    }

    var detail: String {
        switch self {
        case .dictate: return "Hold your dictation key in any app and speak"
        case .pickModel: return "Whisper Tiny works; a bigger model gets more right"
        case .addWord: return "Names and jargon come out spelled your way"
        case .smartCleanup: return "Drops “um”s and false starts before it types"
        }
    }

    var actionTitle: String {
        switch self {
        case .dictate: return "Try it"
        case .pickModel: return "Choose"
        case .addWord: return "Add a word"
        case .smartCleanup: return "Set up"
        }
    }
}

extension AppState {
    /// The Get started steps already done. A step counts as done from what
    /// the settings show, so the list never asks for something set up
    /// another way (onboarding, an imported backup).
    var calmGettingStartedDone: Set<CalmGettingStartedStep> {
        var done: Set<CalmGettingStartedStep> = []
        if hasDictated { done.insert(.dictate) }
        if selectedModelSize != ModelSize.tiny.rawValue { done.insert(.pickModel) }
        if !vocabularyTerms.isEmpty || !wordReplacements.isEmpty { done.insert(.addWord) }
        if transcriptCleanupEnabled { done.insert(.smartCleanup) }
        return done
    }

    /// Home's title: no “back” for someone who hasn't dictated yet.
    var calmHomeTitle: String {
        hasDictated ? "Welcome back" : "Welcome"
    }

    /// Whether the person has dictated, as opposed to only transcribing a
    /// file or a meeting (`hasStatistics` counts those too). Speaking time
    /// and the longest dictation are recorded for dictations alone, and
    /// history keeps only dictations and Command Mode edits.
    var hasDictated: Bool {
        let stats = statsManager.stats
        return stats.longestDictationSeconds > 0
            || !stats.dailyAudioSeconds.isEmpty
            || !historyStore.entries.isEmpty
    }
}
