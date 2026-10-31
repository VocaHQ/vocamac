// CalmInsights.swift
// VocaMac
//
// The numbers behind Home's side card and the Insights page: the past
// year of daily activity for the heatmap, the last seven days for the
// streak dots, totals, personal bests, where the user dictates, and the
// Home feed's day groups. Pure functions of `UserStats` and history, so
// they can be tested without a window.

import Foundation

// MARK: - Activity days

/// What the Insights heatmap measures.
enum CalmInsightsMetric: String, CaseIterable, Identifiable, Sendable {
    case words
    case time

    var id: String { rawValue }

    var title: String {
        switch self {
        case .words: return "Words"
        case .time: return "Time"
        }
    }
}

/// One calendar day of dictation activity.
struct CalmActivityDay: Hashable, Identifiable {
    /// Midnight at the start of the day, in the statistics calendar.
    let date: Date
    /// The `yyyy-MM-dd` key the day is stored under.
    let key: String
    let words: Int
    /// Successful dictations that day; nil for days saved before per-day counts existed.
    let dictations: Int?
    /// Seconds of recorded speech; nil for days saved before it was tracked.
    let audioSeconds: Double?
    /// A day after today: kept in the grid's shape but not drawn.
    let isFuture: Bool

    var id: String { key }

    /// Whether the user dictated that day (words, or a word-less dictation).
    var isActive: Bool { words > 0 || (dictations ?? 0) > 0 }
}

/// Day keys, calendars and the heatmap grid.
enum CalmActivityCalendar {
    /// Weeks in the heatmap.
    static let weekCount = 53
    /// Days in the heatmap, oldest first. `UserStats` keeps every daily
    /// bucket, so all of them have data behind them.
    static let dayCount = weekCount * 7

    /// The Gregorian calendar statistics are bucketed in: the time zone the
    /// stats were first recorded in, so travel doesn't move old days.
    static func statsCalendar(for stats: UserStats, base: Calendar = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = stats.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? base.timeZone
        calendar.firstWeekday = base.firstWeekday
        calendar.locale = base.locale
        return calendar
    }

    /// The `yyyy-MM-dd` key `StatsManager` stores a day under.
    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return "unknown" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Midnight at the start of the day stored under `key` (`yyyy-MM-dd`),
    /// or nil when the key isn't a date.
    static func startOfDay(forKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        // A key that doesn't round-trip (month 13) isn't a real day.
        return dayKey(for: date, calendar: calendar) == key ? calendar.startOfDay(for: date) : nil
    }

    /// The day containing `date`, with its stored activity.
    static func day(at date: Date, stats: UserStats, today: Date, calendar: Calendar) -> CalmActivityDay {
        let start = calendar.startOfDay(for: date)
        let key = dayKey(for: start, calendar: calendar)
        return CalmActivityDay(
            date: start,
            key: key,
            words: max(0, stats.dailyWordCounts[key] ?? 0),
            dictations: stats.dailyTranscriptionCounts[key],
            audioSeconds: stats.dailyAudioSeconds[key],
            isFuture: start > calendar.startOfDay(for: today)
        )
    }

    /// The heatmap's days, oldest first, in whole weeks: column `c` holds
    /// days `c * 7 ..< c * 7 + 7`, starting on the calendar's first weekday.
    /// The last column holds this week, with the days after today marked future.
    static func heatmapDays(stats: UserStats, now: Date = Date(), calendar: Calendar) -> [CalmActivityDay] {
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)
        let intoWeek = (weekday - calendar.firstWeekday + 7) % 7
        guard let start = calendar.date(byAdding: .day, value: -intoWeek - (weekCount - 1) * 7, to: today) else { return [] }
        return (0..<dayCount).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start).map {
                day(at: $0, stats: stats, today: today, calendar: calendar)
            }
        }
    }

    /// The last seven days, today last, for the streak dots.
    static func lastSevenDays(stats: UserStats, now: Date = Date(), calendar: Calendar) -> [CalmActivityDay] {
        let today = calendar.startOfDay(for: now)
        return (0..<7).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: today).map {
                day(at: $0, stats: stats, today: today, calendar: calendar)
            }
        }
    }

    /// The streak dots for `days` (today last): weekday initials, names for
    /// VoiceOver, and which days were dictated.
    static func streakWeek(_ days: [CalmActivityDay], calendar: Calendar) -> [CalmStreakDay] {
        let initials = calendar.veryShortStandaloneWeekdaySymbols
        let names = calendar.standaloneWeekdaySymbols
        return days.enumerated().map { index, day in
            let weekday = calendar.component(.weekday, from: day.date) - 1
            let isToday = index == days.count - 1
            return CalmStreakDay(
                letter: initials.indices.contains(weekday) ? initials[weekday] : "",
                name: isToday ? "Today" : (names.indices.contains(weekday) ? names[weekday] : day.key),
                isDone: day.isActive,
                isToday: isToday
            )
        }
    }

    /// Month labels over the heatmap's columns: a column whose first day is
    /// in the first week of a month is labelled, except the first and last
    /// columns (the label would hang off the grid).
    static func monthLabels(for days: [CalmActivityDay], calendar: Calendar) -> [String] {
        let symbols = calendar.shortMonthSymbols
        return (0..<(days.count / 7)).map { column in
            let first = days[column * 7].date
            guard column > 0, column < days.count / 7 - 1, calendar.component(.day, from: first) <= 7 else { return "" }
            let month = calendar.component(.month, from: first) - 1
            return symbols.indices.contains(month) ? symbols[month] : ""
        }
    }

    /// Row labels down the heatmap's left edge: the second, fourth and
    /// sixth weekday (Mon, Wed, Fri when weeks start on Sunday).
    static func weekdayRowLabels(calendar: Calendar) -> [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        return (0..<7).map { row in
            guard row % 2 == 1 else { return "" }
            let index = (calendar.firstWeekday - 1 + row) % 7
            return symbols.indices.contains(index) ? symbols[index] : ""
        }
    }
}

// MARK: - Heatmap measures

extension CalmActivityDay {
    /// Seconds of speech for the Time view: recorded when known, otherwise
    /// estimated from the day's words at the user's own speaking rate.
    /// Nil when the day has words but there is no rate to estimate from.
    func speakingSeconds(averageWPM: Double) -> (seconds: Double, isEstimate: Bool)? {
        if let audioSeconds, audioSeconds > 0 { return (audioSeconds, false) }
        guard words > 0 else { return (0, false) }
        guard averageWPM.isFinite, averageWPM > 0 else { return nil }
        return (Double(words) / averageWPM * 60, true)
    }

    /// The heatmap level (0…4) for `metric`. Time uses the words scale at
    /// 140 words a minute, so both views read alike.
    func level(for metric: CalmInsightsMetric, averageWPM: Double) -> Int {
        guard !isFuture else { return 0 }
        switch metric {
        case .words:
            if words == 0, isActive { return 1 }
            return CalmHeatLevel.level(forWords: words)
        case .time:
            guard let speaking = speakingSeconds(averageWPM: averageWPM) else { return isActive ? 1 : 0 }
            if speaking.seconds <= 0 { return isActive ? 1 : 0 }
            return max(1, CalmHeatLevel.level(forWords: Int((speaking.seconds / 60 * 140).rounded())))
        }
    }

    /// The line under the heatmap: “Fri, Oct 16 · 473 words in 11 dictations”.
    func detail(for metric: CalmInsightsMetric, averageWPM: Double, calendar: Calendar) -> String {
        let when = CalmDateFormatters.formatter(template: "EEE MMM d", calendar: calendar).string(from: date)
        guard isActive else { return "\(when) · no dictation" }
        switch metric {
        case .words:
            var line = "\(when) · \(CalmFormat.count(words, "word"))"
            if let dictations, dictations > 0 { line += " in \(CalmFormat.count(dictations, "dictation"))" }
            return line
        case .time:
            guard let speaking = speakingSeconds(averageWPM: averageWPM), speaking.seconds > 0 else {
                return "\(when) · \(CalmFormat.count(words, "word")), no time recorded"
            }
            let duration = CalmFormat.speakingTime(speaking.seconds)
            return "\(when) · \(speaking.isEstimate ? "about " : "")\(duration) of speaking"
        }
    }
}

// MARK: - Totals, streak and bests

/// What Insights and Home's side card show, computed from the stats.
struct CalmInsightsSummary {
    /// The typing speed VocaMac compares dictation with.
    static let typingWPM = 40.0

    let wordsPerMinute: Int
    /// How many times faster than typing, nil without a speaking rate.
    let timesFasterThanTyping: Double?
    let yearWords: Int
    let yearActiveDays: Int
    let lifetimeWords: Int
    let lifetimeDictations: Int
    let lifetimeSpeakingSeconds: Double
    /// Typing the same words at `typingWPM`, minus the time spent speaking.
    let savedSeconds: Double
    let currentStreak: Int
    let bestStreak: Int
    let hasDictatedToday: Bool
    let biggestDayWords: Int?
    let longestDictationSeconds: Double?
    let fastestStopWaitSeconds: Double?
    let medianStopWait: (seconds: Double, count: Int)?
    let medianStopWaitWithoutProcessing: (seconds: Double, count: Int)?

    init(stats: UserStats, history: [DictationHistoryEntry] = [], now: Date = Date(), calendar: Calendar) {
        let wpm = stats.averageWPM
        wordsPerMinute = Int(wpm.rounded())
        timesFasterThanTyping = wpm > 0 ? wpm / Self.typingWPM : nil

        let year = CalmActivityCalendar.heatmapDays(stats: stats, now: now, calendar: calendar).filter { !$0.isFuture }
        yearWords = year.reduce(0) { $0 + $1.words }
        yearActiveDays = year.filter(\.isActive).count

        lifetimeWords = stats.totalWords
        lifetimeDictations = stats.totalTranscriptions
        lifetimeSpeakingSeconds = stats.totalAudioDurationSeconds
        savedSeconds = max(0, Double(stats.totalWords) / Self.typingWPM * 60 - stats.totalAudioDurationSeconds)

        currentStreak = stats.currentStreak
        bestStreak = max(stats.bestStreak, stats.currentStreak)
        hasDictatedToday = CalmActivityCalendar.day(at: now, stats: stats, today: now, calendar: calendar).isActive

        let biggest = stats.dailyWordCounts.values.max() ?? 0
        biggestDayWords = biggest > 0 ? biggest : nil

        // History fills in dictations from before the stats tracked the
        // longest one, but only those since the stats' first day, and only
        // those after the last Reset All Statistics: the first day alone
        // would let a reset's earlier dictations that day count again.
        let firstStatsDay = (Array(stats.dailyWordCounts.keys) + Array(stats.dailyTranscriptionCounts.keys)).min()
        let longestInHistory = firstStatsDay.map { firstDay in
            // Day keys sort in time order, so “on or after the first day”
            // is a date comparison; no key needs formatting per entry.
            let firstDayStart = CalmActivityCalendar.startOfDay(forKey: firstDay, calendar: calendar)
            let earliest = max(firstDayStart ?? .distantPast, stats.resetDate ?? .distantPast)
            return history
                .filter { entry in
                    entry.status == .completed && !entry.isCommandEdit && entry.audioSeconds.isFinite
                        && entry.createdAt >= earliest
                        && (firstDayStart != nil
                            || CalmActivityCalendar.dayKey(for: entry.createdAt, calendar: calendar) >= firstDay)
                }
                .map(\.audioSeconds)
                .max() ?? 0
        } ?? 0
        let longest = max(stats.longestDictationSeconds, longestInHistory)
        longestDictationSeconds = longest > 0 ? longest : nil

        fastestStopWaitSeconds = stats.stopWaits.map(\.seconds).min()
        let withProcessing = stats.medianStopWait(processedWhileSpeaking: true)
        let withoutProcessing = stats.medianStopWait(processedWhileSpeaking: false)
        medianStopWait = withProcessing ?? withoutProcessing
        medianStopWaitWithoutProcessing = withProcessing == nil ? nil : withoutProcessing
    }

    /// “About 3× faster than typing”, or nil before the first dictation
    /// and when speaking is slower than typing (nothing true to boast).
    var speedNote: String? {
        guard let ratio = timesFasterThanTyping, ratio >= 0.9 else { return nil }
        if ratio < 1.1 { return "About as fast as typing" }
        let shown = ratio >= 2 ? String(Int(ratio.rounded())) : String(format: "%.1f", ratio)
        return "About \(shown)× faster than typing"
    }

    /// The streak card's nudge.
    var streakNudge: String {
        if currentStreak == 0 { return "Dictate today to start a streak." }
        if !hasDictatedToday { return "Dictate today to keep it going." }
        return "Dictate tomorrow to make it \(currentStreak + 1)."
    }
}

// MARK: - Where you dictate

/// One app's share of the words in history.
struct CalmAppShare: Hashable, Identifiable {
    let name: String
    let words: Int
    /// 0…1 of all words in the counted entries.
    let share: Double

    var id: String { name }

    /// The rounded percent shown at the end of the bar.
    var percent: Int { Int((share * 100).rounded()) }

    /// The apps the user dictated the most words into, most first: finished
    /// dictations (not Command Mode edits) whose app is known.
    static func top(_ count: Int = 4, from entries: [DictationHistoryEntry]) -> [CalmAppShare] {
        var wordsByApp: [String: Int] = [:]
        for entry in entries where entry.status == .completed && !entry.isCommandEdit {
            guard let app = entry.appName?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty else { continue }
            let words = CalmFormat.wordCount(entry.displayText)
            guard words > 0 else { continue }
            wordsByApp[app, default: 0] += words
        }
        let total = wordsByApp.values.reduce(0, +)
        guard total > 0 else { return [] }
        return wordsByApp
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.localizedCompare($1.key) == .orderedAscending }
            .prefix(count)
            .map { CalmAppShare(name: $0.key, words: $0.value, share: Double($0.value) / Double(total)) }
    }
}

// MARK: - Sent without edits

/// The share of dictations the user left as typed: the measure of accuracy
/// they actually feel. Counts only dictations VocaMac read back afterwards
/// (`DictationHistoryEntry.editedText`), so it needs History and learning
/// from corrections on.
struct CalmEditFreeRate: Equatable {
    let unedited: Int
    let observed: Int

    /// Fewer read-backs than this make a percentage that means nothing.
    static let minimumObserved = 5

    var percent: Int { Int((Double(unedited) / Double(max(observed, 1)) * 100).rounded()) }

    static func from(_ entries: [DictationHistoryEntry]) -> CalmEditFreeRate? {
        var observed = 0
        var unedited = 0
        for entry in entries where entry.status == .completed && !entry.isCommandEdit {
            guard let edited = entry.wasEditedAfterTyping else { continue }
            observed += 1
            if !edited { unedited += 1 }
        }
        guard observed >= minimumObserved else { return nil }
        return CalmEditFreeRate(unedited: unedited, observed: observed)
    }
}

// MARK: - Home feed

/// The Home feed's dictations for one day.
struct CalmFeedDay: Identifiable {
    let day: Date
    private(set) var entries: [DictationHistoryEntry]

    var id: Date { day }

    /// History entries (newest first) grouped by the day they were made.
    /// What Home shows before the user scrolls further: the newest `limit`
    /// entries of `entries` (newest first), grouped by day. Only these are
    /// turned into rows, so the feed's cost stays the same however long the
    /// history is.
    static func page(_ entries: [DictationHistoryEntry], limit: Int, calendar: Calendar = .current) -> [CalmFeedDay] {
        groups(Array(entries.prefix(max(0, limit))), calendar: calendar)
    }

    static func groups(_ entries: [DictationHistoryEntry], calendar: Calendar = .current) -> [CalmFeedDay] {
        var groups: [CalmFeedDay] = []
        for entry in entries {
            let day = calendar.startOfDay(for: entry.createdAt)
            if let last = groups.last, last.day == day {
                // Append in place: rebuilding the group copied its entries every time.
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append(CalmFeedDay(day: day, entries: [entry]))
            }
        }
        return groups
    }

    /// The days as one flat run of captions and dictations, for a single
    /// lazy stack. Day lists nested in a lazy stack each guess their own
    /// height, and those guesses made the feed's scroll height jump and
    /// left it blank when the user dragged to the end.
    static func items(_ days: [CalmFeedDay]) -> [CalmFeedItem] {
        var items: [CalmFeedItem] = []
        items.reserveCapacity(days.reduce(days.count) { $0 + $1.entries.count })
        for (dayIndex, day) in days.enumerated() {
            items.append(.caption(day: day.day, isFirst: dayIndex == 0))
            for (index, entry) in day.entries.enumerated() {
                items.append(.entry(entry, isFirstInDay: index == 0, isLastInDay: index == day.entries.count - 1))
            }
        }
        return items
    }
}

/// One item of the Home feed: a day's caption, or a dictation and where it
/// sits in that day's list.
enum CalmFeedItem: Identifiable {
    case caption(day: Date, isFirst: Bool)
    case entry(DictationHistoryEntry, isFirstInDay: Bool, isLastInDay: Bool)

    enum Identity: Hashable {
        case day(Date)
        case entry(UUID)
    }

    var id: Identity {
        switch self {
        case .caption(let day, _): return .day(day)
        case .entry(let entry, _, _): return .entry(entry.id)
        }
    }
}

// MARK: - Formatting

/// Number, duration and time formats used on Home and Insights.
enum CalmFormat {
    /// “1,439”.
    static func number(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// “1 word”, “1,439 words”.
    static func count(_ value: Int, _ noun: String) -> String {
        "\(number(value)) \(noun)\(value == 1 ? "" : "s")"
    }

    /// Words the way `StatsManager` counts them.
    static func wordCount(_ text: String) -> Int {
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { _, _, _, _ in words += 1 }
        return words
    }

    /// A recording's length: “42 s”, “4 min 12 s”, “1 h 5 min”.
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 s" }
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(max(1, whole)) s" }
        if whole < 3_600 {
            let rest = whole % 60
            return rest == 0 ? "\(whole / 60) min" : "\(whole / 60) min \(rest) s"
        }
        let minutes = (whole % 3_600) / 60
        return minutes == 0 ? "\(whole / 3_600) h" : "\(whole / 3_600) h \(minutes) min"
    }

    /// Time of speaking on a day: “40 s”, “3 min”, “1 h 5 min”.
    static func speakingTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 min" }
        if seconds < 60 { return "\(max(1, Int(seconds.rounded()))) s" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }

    /// Time saved, coarse: “21 h”, “35 min”, “0 min”.
    static func saved(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 60 else { return "0 min" }
        if seconds < 3_600 { return "\(Int((seconds / 60).rounded())) min" }
        return "\(Int((seconds / 3_600).rounded())) h"
    }

    /// A wait after stopping: “0.3 s”.
    static func wait(_ seconds: Double) -> String {
        String(format: "%.1f s", max(0, seconds))
    }

    /// A feed row's time: “1:04 pm” (or “13:04” where the locale uses a 24-hour clock).
    static func feedTime(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = CalmDateFormatters.formatter(template: "jmm", calendar: calendar, lowercaseAmPm: true)
        // Newer ICU puts a narrow no-break space before am/pm; the design uses a plain one.
        return formatter.string(from: date).replacingOccurrences(of: "\u{202F}", with: " ")
    }
}

/// Date formatters for the window, made once per template and calendar.
/// Making a `DateFormatter` costs far more than using one, and the feed
/// formats a time for every row it draws.
enum CalmDateFormatters {
    private struct Key: Hashable {
        let template: String
        let calendar: Calendar
        let lowercaseAmPm: Bool
    }

    /// Guarded by `lock`. A configured `DateFormatter` is safe to use from
    /// any thread; only the dictionary needs the lock.
    nonisolated(unsafe) private static var cache: [Key: DateFormatter] = [:]
    private static let lock = NSLock()

    /// A formatter for `template` (`setLocalizedDateFormatFromTemplate`) in
    /// `calendar`'s time zone and locale. `lowercaseAmPm` writes “am” / “pm”.
    static func formatter(template: String, calendar: Calendar, lowercaseAmPm: Bool = false) -> DateFormatter {
        let key = Key(template: template, calendar: calendar, lowercaseAmPm: lowercaseAmPm)
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate(template)
        if lowercaseAmPm {
            formatter.amSymbol = "am"
            formatter.pmSymbol = "pm"
        }
        cache[key] = formatter
        return formatter
    }
}
