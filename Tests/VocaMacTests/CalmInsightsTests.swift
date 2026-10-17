// CalmInsightsTests.swift
// VocaMac Tests
//
// The numbers behind the v3 Home side card and Insights page: the year
// heatmap, streak dots, totals, personal bests, per-app shares, feed day
// groups and formats, plus the stats fields they need.

import SwiftUI
import XCTest
@testable import VocaMac

final class CalmInsightsTests: XCTestCase {
    /// Gregorian, UTC, weeks starting Sunday, English names.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.firstWeekday = 1
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// Friday 16 October 2026, 15:00 UTC.
    private var now: Date {
        get throws {
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 15)))
        }
    }

    private func key(_ daysBack: Int, from date: Date) throws -> String {
        let day = try XCTUnwrap(calendar.date(byAdding: .day, value: -daysBack, to: date))
        return CalmActivityCalendar.dayKey(for: day, calendar: calendar)
    }

    // MARK: - UserStats storage

    func testOldStatsWithoutNewFieldsDecodeToDefaults() throws {
        let json = #"{"totalWords": 12, "totalTranscriptions": 2, "totalAudioDurationSeconds": 6, "dailyWordCounts": {"2026-10-16": 12}}"#
        let stats = try JSONDecoder().decode(UserStats.self, from: Data(json.utf8))
        XCTAssertEqual(stats.totalWords, 12)
        XCTAssertEqual(stats.dailyWordCounts["2026-10-16"], 12)
        XCTAssertTrue(stats.dailyAudioSeconds.isEmpty)
        XCTAssertEqual(stats.longestDictationSeconds, 0)
    }

    func testNewFieldsRoundTripAndDropInvalidValues() throws {
        var stats = UserStats()
        stats.dailyAudioSeconds = ["2026-10-16": 42.5]
        stats.longestDictationSeconds = 252
        let decoded = try JSONDecoder().decode(UserStats.self, from: JSONEncoder().encode(stats))
        XCTAssertEqual(decoded.dailyAudioSeconds, ["2026-10-16": 42.5])
        XCTAssertEqual(decoded.longestDictationSeconds, 252)

        let damaged = #"{"dailyAudioSeconds": {"2026-10-15": -3, "2026-10-16": 9}, "longestDictationSeconds": -1}"#
        let repaired = try JSONDecoder().decode(UserStats.self, from: Data(damaged.utf8))
        XCTAssertEqual(repaired.dailyAudioSeconds, ["2026-10-16": 9])
        XCTAssertEqual(repaired.longestDictationSeconds, 0)

        let wrongType = #"{"totalWords": 3, "dailyAudioSeconds": "nope", "longestDictationSeconds": "long"}"#
        let lenient = try JSONDecoder().decode(UserStats.self, from: Data(wrongType.utf8))
        XCTAssertEqual(lenient.totalWords, 3, "A bad new field must not cost the rest")
        XCTAssertTrue(lenient.dailyAudioSeconds.isEmpty)
    }

    @MainActor
    func testStatsManagerRecordsDailySpeechAndLongestDictation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("calm_stats_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = StatsManager(statsFileURL: url, calendar: calendar, now: { (try? self.now) ?? Date() })
        let when = try now
        manager.recordTranscription(VocaTranscription(
            text: "one two three", duration: 1, detectedLanguage: "en", audioLengthSeconds: 30, modelUsed: .tiny, timestamp: when
        ))
        manager.recordTranscription(VocaTranscription(
            text: "four five", duration: 1, detectedLanguage: "en", audioLengthSeconds: 12, modelUsed: .tiny, timestamp: when
        ))
        manager.recordTranscription(VocaTranscription(
            text: "six", duration: 1, detectedLanguage: "en", audioLengthSeconds: .nan, modelUsed: .tiny, timestamp: when
        ))
        let today = try key(0, from: when)
        XCTAssertEqual(manager.stats.dailyAudioSeconds[today], 42)
        XCTAssertEqual(manager.stats.longestDictationSeconds, 30)
        manager.flushPendingSaves()
    }

    /// File and meeting transcriptions count toward words and totals, but
    /// not toward the day's speaking time or the longest dictation.
    @MainActor
    func testFileAndMeetingTranscriptionsAreNotDictations() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("calm_stats_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = StatsManager(statsFileURL: url, calendar: calendar, now: { (try? self.now) ?? Date() })
        let when = try now
        manager.recordTranscription(VocaTranscription(
            text: "one two three", duration: 1, detectedLanguage: "en", audioLengthSeconds: 20, modelUsed: .tiny, timestamp: when
        ))
        manager.recordTranscription(VocaTranscription(
            text: "a long meeting", duration: 1, detectedLanguage: "en", audioLengthSeconds: 3_600, modelUsed: .tiny, timestamp: when
        ), isDictation: false)
        let today = try key(0, from: when)
        XCTAssertEqual(manager.stats.dailyAudioSeconds[today], 20)
        XCTAssertEqual(manager.stats.longestDictationSeconds, 20)
        XCTAssertEqual(manager.stats.totalWords, 6)
        XCTAssertEqual(manager.stats.totalTranscriptions, 2)
        manager.flushPendingSaves()
    }

    /// The heatmap reads 371 days back; nothing may prune them.
    @MainActor
    func testDailyBucketsOlderThanAYearSurviveRecordAndReload() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("calm_stats_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let when = try now
        let old = try key(CalmActivityCalendar.dayCount + 30, from: when)
        var seeded = UserStats()
        seeded.dailyWordCounts = [old: 99]
        seeded.dailyTranscriptionCounts = [old: 3]
        seeded.timeZoneIdentifier = "UTC"
        try JSONEncoder().encode(seeded).write(to: url)

        let manager = StatsManager(statsFileURL: url, calendar: calendar, now: { when })
        manager.recordTranscription(VocaTranscription(
            text: "hello", duration: 1, detectedLanguage: "en", audioLengthSeconds: 2, modelUsed: .tiny, timestamp: when
        ))
        manager.flushPendingSaves()

        let reloaded = StatsManager(statsFileURL: url, calendar: calendar, now: { when })
        XCTAssertEqual(reloaded.stats.dailyWordCounts[old], 99)
        XCTAssertEqual(reloaded.stats.dailyTranscriptionCounts[old], 3)
        reloaded.flushPendingSaves()
    }

    // MARK: - Heatmap grid

    func testHeatmapIsFiftyThreeWholeWeeksEndingThisWeek() throws {
        let when = try now
        var stats = UserStats()
        stats.dailyWordCounts = [try key(0, from: when): 473, try key(364, from: when): 10]
        stats.dailyTranscriptionCounts = [try key(0, from: when): 11]
        let days = CalmActivityCalendar.heatmapDays(stats: stats, now: when, calendar: calendar)

        XCTAssertEqual(days.count, 371)
        XCTAssertEqual(calendar.component(.weekday, from: days[0].date), 1, "Columns start on the first weekday")
        let todayIndex = try XCTUnwrap(days.lastIndex { !$0.isFuture })
        XCTAssertEqual(days[todayIndex].key, try key(0, from: when))
        XCTAssertEqual(days[todayIndex].words, 473)
        XCTAssertEqual(days[todayIndex].dictations, 11)
        // Friday: Saturday is still to come in the last column.
        XCTAssertEqual(todayIndex, 369)
        XCTAssertTrue(days[370].isFuture)
        XCTAssertTrue(days.contains { $0.key == (try? key(364, from: when)) && $0.words == 10 })
    }

    func testHeatmapHonoursAMondayStart() throws {
        var monday = calendar
        monday.firstWeekday = 2
        let days = CalmActivityCalendar.heatmapDays(stats: UserStats(), now: try now, calendar: monday)
        XCTAssertEqual(days.count, 371)
        XCTAssertEqual(monday.component(.weekday, from: days[0].date), 2)
        XCTAssertEqual(CalmActivityCalendar.weekdayRowLabels(calendar: monday), ["", "Tue", "", "Thu", "", "Sat", ""])
        XCTAssertEqual(CalmActivityCalendar.weekdayRowLabels(calendar: calendar), ["", "Mon", "", "Wed", "", "Fri", ""])
    }

    func testMonthLabelsSitOnTheFirstWeekOfEachMonth() throws {
        let days = CalmActivityCalendar.heatmapDays(stats: UserStats(), now: try now, calendar: calendar)
        let labels = CalmActivityCalendar.monthLabels(for: days, calendar: calendar)
        XCTAssertEqual(labels.count, 53)
        XCTAssertEqual(labels.first, "")
        XCTAssertEqual(labels.last, "")
        let shown = labels.filter { !$0.isEmpty }
        XCTAssertEqual(shown.count, 12, "Every month gets one label in its first week")
        XCTAssertEqual(shown.last, "Oct")
        XCTAssertEqual(shown.first, "Nov")
    }

    func testLastSevenDaysEndTodayWithLettersAndNames() throws {
        let when = try now
        var stats = UserStats()
        stats.dailyWordCounts = [try key(0, from: when): 5, try key(1, from: when): 8]
        stats.dailyTranscriptionCounts = [try key(6, from: when): 1]
        let days = CalmActivityCalendar.lastSevenDays(stats: stats, now: when, calendar: calendar)
        let week = CalmActivityCalendar.streakWeek(days, calendar: calendar)
        XCTAssertEqual(week.map(\.letter), ["S", "S", "M", "T", "W", "T", "F"])
        XCTAssertEqual(week.map(\.isDone), [true, false, false, false, false, true, true])
        XCTAssertEqual(week.last?.name, "Today")
        XCTAssertEqual(week.last?.isToday, true)
        XCTAssertEqual(week.first?.name, "Saturday")
    }

    // MARK: - Levels and detail line

    func testWordsLevelsAndDetailLine() throws {
        let date = try now
        let day = CalmActivityDay(date: date, key: "k", words: 473, dictations: 11, audioSeconds: nil, isFuture: false)
        XCTAssertEqual(day.level(for: .words, averageWPM: 140), 2)
        XCTAssertEqual(day.detail(for: .words, averageWPM: 140, calendar: calendar), "Fri, Oct 16 · 473 words in 11 dictations")

        let legacy = CalmActivityDay(date: date, key: "k", words: 1, dictations: nil, audioSeconds: nil, isFuture: false)
        XCTAssertEqual(legacy.detail(for: .words, averageWPM: 0, calendar: calendar), "Fri, Oct 16 · 1 word")

        let empty = CalmActivityDay(date: date, key: "k", words: 0, dictations: nil, audioSeconds: nil, isFuture: false)
        XCTAssertEqual(empty.level(for: .words, averageWPM: 140), 0)
        XCTAssertEqual(empty.detail(for: .time, averageWPM: 140, calendar: calendar), "Fri, Oct 16 · no dictation")

        let wordless = CalmActivityDay(date: date, key: "k", words: 0, dictations: 2, audioSeconds: nil, isFuture: false)
        XCTAssertEqual(wordless.level(for: .words, averageWPM: 140), 1, "A day with only emoji still counts")
    }

    func testTimeUsesRecordedSecondsElseAnEstimate() throws {
        let date = try now
        let recorded = CalmActivityDay(date: date, key: "k", words: 100, dictations: 3, audioSeconds: 180, isFuture: false)
        XCTAssertEqual(recorded.detail(for: .time, averageWPM: 100, calendar: calendar), "Fri, Oct 16 · 3 min of speaking")
        // 3 minutes at 140 words a minute is 420 words: level 2.
        XCTAssertEqual(recorded.level(for: .time, averageWPM: 100), 2)

        let older = CalmActivityDay(date: date, key: "k", words: 300, dictations: nil, audioSeconds: nil, isFuture: false)
        XCTAssertEqual(older.detail(for: .time, averageWPM: 150, calendar: calendar), "Fri, Oct 16 · about 2 min of speaking")
        XCTAssertEqual(older.detail(for: .time, averageWPM: 0, calendar: calendar), "Fri, Oct 16 · 300 words, no time recorded")
        XCTAssertEqual(older.level(for: .time, averageWPM: 0), 1)

        let future = CalmActivityDay(date: date, key: "k", words: 900, dictations: 1, audioSeconds: 600, isFuture: true)
        XCTAssertEqual(future.level(for: .words, averageWPM: 140), 0)
    }

    // MARK: - Summary

    func testSummaryTotalsAndNotes() throws {
        let when = try now
        var stats = UserStats()
        stats.totalWords = 7_019
        stats.totalTranscriptions = 210
        stats.totalAudioDurationSeconds = 7_019.0 / 148 * 60
        stats.currentStreak = 6
        stats.bestStreak = 4
        stats.dailyWordCounts = [try key(0, from: when): 473, try key(1, from: when): 1_439, try key(400, from: when): 50]
        stats.longestDictationSeconds = 120
        let summary = CalmInsightsSummary(stats: stats, now: when, calendar: calendar)

        XCTAssertEqual(summary.wordsPerMinute, 148)
        XCTAssertEqual(summary.speedNote, "About 4× faster than typing")
        XCTAssertEqual(summary.yearWords, 1_912, "Only the heatmap's year counts")
        XCTAssertEqual(summary.yearActiveDays, 2)
        XCTAssertEqual(summary.bestStreak, 6, "Best is never below current")
        XCTAssertTrue(summary.hasDictatedToday)
        XCTAssertEqual(summary.streakNudge, "Dictate tomorrow to make it 7.")
        XCTAssertEqual(summary.biggestDayWords, 1_439)
        XCTAssertEqual(summary.longestDictationSeconds, 120)
        // 7,019 words typed at 40 wpm ≈ 175.5 min; spoken in ≈ 47.4 min.
        XCTAssertEqual(summary.savedSeconds, 7_019.0 / 40 * 60 - 7_019.0 / 148 * 60, accuracy: 0.01)
        XCTAssertEqual(CalmFormat.saved(summary.savedSeconds), "2 h")
    }

    func testSummaryWithoutDataHidesBestsAndNudgesToStart() throws {
        let summary = CalmInsightsSummary(stats: UserStats(), now: try now, calendar: calendar)
        XCTAssertNil(summary.speedNote)
        XCTAssertNil(summary.biggestDayWords)
        XCTAssertNil(summary.longestDictationSeconds)
        XCTAssertNil(summary.fastestStopWaitSeconds)
        XCTAssertNil(summary.medianStopWait)
        XCTAssertEqual(summary.streakNudge, "Dictate today to start a streak.")
        XCTAssertEqual(summary.savedSeconds, 0)
    }

    func testStreakKeptFromYesterdayAsksForToday() throws {
        let when = try now
        var stats = UserStats()
        stats.currentStreak = 3
        stats.dailyWordCounts = [try key(1, from: when): 10]
        let summary = CalmInsightsSummary(stats: stats, now: when, calendar: calendar)
        XCTAssertFalse(summary.hasDictatedToday)
        XCTAssertEqual(summary.streakNudge, "Dictate today to keep it going.")
    }

    func testSpeedNoteBands() throws {
        func note(wpm: Double) throws -> String? {
            var stats = UserStats()
            stats.totalWords = Int(wpm)
            stats.totalAudioDurationSeconds = 60
            return CalmInsightsSummary(stats: stats, now: try now, calendar: calendar).speedNote
        }
        XCTAssertNil(try note(wpm: 20), "Slower than typing is not “as fast”")
        XCTAssertNil(try note(wpm: 35))
        XCTAssertEqual(try note(wpm: 37), "About as fast as typing")
        XCTAssertEqual(try note(wpm: 42), "About as fast as typing")
        XCTAssertEqual(try note(wpm: 60), "About 1.5× faster than typing")
        XCTAssertEqual(try note(wpm: 120), "About 3× faster than typing")
    }

    func testLongestDictationFallsBackToHistoryAndWaitsSplitByProcessing() throws {
        let when = try now
        var stats = UserStats()
        stats.dailyWordCounts = [try key(3, from: when): 12]
        stats.recordStopWait(StopWait(seconds: 0.3, audioSeconds: 4, processedWhileSpeaking: true))
        stats.recordStopWait(StopWait(seconds: 0.5, audioSeconds: 20, processedWhileSpeaking: true))
        stats.recordStopWait(StopWait(seconds: 0.7, audioSeconds: 30, processedWhileSpeaking: true))
        stats.recordStopWait(StopWait(seconds: 2.0, audioSeconds: 40, processedWhileSpeaking: false))
        let history = [
            DictationHistoryEntry(createdAt: when, status: .completed, finalText: "hi", modelID: "tiny", audioSeconds: 252),
            DictationHistoryEntry(createdAt: when, status: .failed, modelID: "tiny", audioSeconds: 900),
        ]
        let summary = CalmInsightsSummary(stats: stats, history: history, now: when, calendar: calendar)
        XCTAssertEqual(summary.longestDictationSeconds, 252, "Only finished dictations count")
        XCTAssertEqual(summary.fastestStopWaitSeconds, 0.3)
        XCTAssertEqual(try XCTUnwrap(summary.medianStopWait).seconds, 0.6, accuracy: 0.0001)
        XCTAssertEqual(summary.medianStopWait?.count, 2)
        XCTAssertEqual(summary.medianStopWaitWithoutProcessing?.seconds, 2.0)

        var onlyWithout = UserStats()
        onlyWithout.recordStopWait(StopWait(seconds: 1.5, audioSeconds: 12, processedWhileSpeaking: false))
        let single = CalmInsightsSummary(stats: onlyWithout, now: try now, calendar: calendar)
        XCTAssertEqual(single.medianStopWait?.seconds, 1.5)
        XCTAssertNil(single.medianStopWaitWithoutProcessing, "One median shows as the plain row")
    }

    /// After Reset All Statistics the stats start again, so history from
    /// before the reset no longer fills in the longest dictation.
    func testLongestDictationIgnoresHistoryFromBeforeTheStats() throws {
        let when = try now
        let older = try XCTUnwrap(calendar.date(byAdding: .day, value: -10, to: when))
        let history = [DictationHistoryEntry(createdAt: older, status: .completed, finalText: "hi", modelID: "tiny", audioSeconds: 252)]

        let reset = CalmInsightsSummary(stats: UserStats(), history: history, now: when, calendar: calendar)
        XCTAssertNil(reset.longestDictationSeconds)

        var restarted = UserStats()
        restarted.dailyWordCounts = [try key(0, from: when): 5]
        restarted.longestDictationSeconds = 8
        let summary = CalmInsightsSummary(stats: restarted, history: history, now: when, calendar: calendar)
        XCTAssertEqual(summary.longestDictationSeconds, 8)
    }

    /// A reset and a new dictation the same day: history from earlier that
    /// day, before the reset, must not bring the old best back.
    @MainActor
    func testResetKeepsSameDayHistoryFromBeforeIt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("calm_stats_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let when = try now
        let morning = try XCTUnwrap(calendar.date(byAdding: .hour, value: -6, to: when))
        let afternoon = try XCTUnwrap(calendar.date(byAdding: .minute, value: 30, to: when))
        var clock = morning
        let manager = StatsManager(statsFileURL: url, calendar: calendar, now: { clock })
        manager.recordTranscription(VocaTranscription(
            text: "a long one", duration: 1, detectedLanguage: "en", audioLengthSeconds: 252, modelUsed: .tiny, timestamp: morning
        ))
        clock = when
        manager.resetStats()
        XCTAssertEqual(manager.stats.resetDate, when)
        clock = afternoon
        manager.recordTranscription(VocaTranscription(
            text: "short", duration: 1, detectedLanguage: "en", audioLengthSeconds: 8, modelUsed: .tiny, timestamp: afternoon
        ))
        manager.flushPendingSaves()

        let history = [
            DictationHistoryEntry(createdAt: morning, status: .completed, finalText: "a long one", modelID: "tiny", audioSeconds: 252),
            DictationHistoryEntry(createdAt: afternoon, status: .completed, finalText: "short", modelID: "tiny", audioSeconds: 8),
        ]
        let summary = CalmInsightsSummary(stats: manager.stats, history: history, now: afternoon, calendar: calendar)
        XCTAssertEqual(summary.longestDictationSeconds, 8, "The pre-reset best must not come back")

        // The reset moment survives a save and reload; older stats have none.
        let reloaded = StatsManager(statsFileURL: url, calendar: calendar, now: { afternoon })
        XCTAssertEqual(reloaded.stats.resetDate, when)
        reloaded.flushPendingSaves()
        let old = try JSONDecoder().decode(UserStats.self, from: Data(#"{"totalWords": 1}"#.utf8))
        XCTAssertNil(old.resetDate)
    }

    /// With history off, its entries don't fill in bests.
    @MainActor
    func testSummaryIgnoresHistoryWhileItIsOff() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.statsManager.stats.dailyWordCounts = ["2000-01-01": 3]
        let id = await appState.historyStore.begin(audio: nil, target: nil, modelID: "tiny", language: "en", audioSeconds: 30)
        appState.historyStore.complete(id, rawText: "hi", finalText: "hi", summary: nil, language: "en", transcriptionSeconds: 0.1, keepAudio: false)
        appState.historyEnabled = true
        XCTAssertNotNil(appState.insightsSummary().longestDictationSeconds)
        appState.historyEnabled = false
        XCTAssertNil(appState.insightsSummary().longestDictationSeconds)
    }

    /// Pages cache the summary and feed: computed once per change of their
    /// inputs, and history's revision moves with every change to it.
    @MainActor
    func testCachedResultsRecomputeOnlyWhenInputsChange() async {
        let memo = CalmMemo<Int, Int>()
        var computed = 0
        XCTAssertEqual(memo.value(for: 1) { computed += 1; return 10 }, 10)
        XCTAssertEqual(memo.value(for: 1) { computed += 1; return 11 }, 10)
        XCTAssertEqual(computed, 1)
        XCTAssertEqual(memo.value(for: 2) { computed += 1; return 20 }, 20)
        XCTAssertEqual(computed, 2)

        let (appState, mocks) = AppState.makeTestState()
        let before = appState.insightsInputs
        XCTAssertEqual(appState.insightsInputs, before)
        _ = await appState.historyStore.begin(audio: nil, target: nil, modelID: "tiny", language: "en", audioSeconds: 3)
        XCTAssertNotEqual(appState.insightsInputs.historyRevision, before.historyRevision)
        let afterHistory = appState.insightsInputs
        mocks.statsManager.stats.totalWords = 4
        XCTAssertNotEqual(appState.insightsInputs, afterHistory)
    }

    // MARK: - Where you dictate

    func testAppSharesCountWordsOfFinishedDictations() {
        let entries = [
            DictationHistoryEntry(status: .completed, finalText: "one two three four five six", appName: "Slack", modelID: "m", audioSeconds: 1),
            DictationHistoryEntry(status: .completed, finalText: "one two", appName: "Mail", modelID: "m", audioSeconds: 1),
            DictationHistoryEntry(status: .completed, finalText: "one two", appName: "Notes", modelID: "m", audioSeconds: 1),
            DictationHistoryEntry(status: .failed, finalText: "lots of words that never arrived", appName: "Xcode", modelID: "m", audioSeconds: 1),
            DictationHistoryEntry(status: .completed, finalText: "edited words", appName: "Pages", modelID: "m",
                                  audioSeconds: 1, commandOriginal: "before"),
            DictationHistoryEntry(status: .completed, finalText: "no app", modelID: "m", audioSeconds: 1),
        ]
        let shares = CalmAppShare.top(from: entries)
        XCTAssertEqual(shares.map(\.name), ["Slack", "Mail", "Notes"], "Ties sort by name")
        XCTAssertEqual(shares.map(\.percent), [60, 20, 20])
        XCTAssertTrue(CalmAppShare.top(from: []).isEmpty)
        XCTAssertEqual(CalmAppShare.top(1, from: entries).map(\.name), ["Slack"])
    }

    // MARK: - Feed

    func testFeedGroupsNewestFirstByDay() throws {
        let when = try now
        let earlier = try XCTUnwrap(calendar.date(byAdding: .hour, value: -3, to: when))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: when))
        let entries = [
            DictationHistoryEntry(createdAt: when, modelID: "m", audioSeconds: 1),
            DictationHistoryEntry(createdAt: earlier, modelID: "m", audioSeconds: 1),
            DictationHistoryEntry(createdAt: yesterday, modelID: "m", audioSeconds: 1),
        ]
        let groups = CalmFeedDay.groups(entries, calendar: calendar)
        XCTAssertEqual(groups.map(\.entries.count), [2, 1])
        XCTAssertEqual(groups.first?.day, calendar.startOfDay(for: when))
        XCTAssertEqual(CalmDaySection<EmptyView>.caption(for: groups[0].day, now: when, calendar: calendar), "Today")
        XCTAssertEqual(CalmDaySection<EmptyView>.caption(for: groups[1].day, now: when, calendar: calendar), "Yesterday")
        XCTAssertTrue(CalmFeedDay.groups([], calendar: calendar).isEmpty)
    }

    // MARK: - Formats

    func testFormats() throws {
        XCTAssertEqual(CalmFormat.duration(42), "42 s")
        XCTAssertEqual(CalmFormat.duration(252), "4 min 12 s")
        XCTAssertEqual(CalmFormat.duration(240), "4 min")
        XCTAssertEqual(CalmFormat.duration(3_900), "1 h 5 min")
        XCTAssertEqual(CalmFormat.duration(0), "0 s")
        XCTAssertEqual(CalmFormat.speakingTime(40), "40 s")
        XCTAssertEqual(CalmFormat.speakingTime(3_900), "1 h 5 min")
        XCTAssertEqual(CalmFormat.saved(30), "0 min")
        XCTAssertEqual(CalmFormat.saved(35 * 60), "35 min")
        XCTAssertEqual(CalmFormat.saved(21 * 3_600), "21 h")
        XCTAssertEqual(CalmFormat.wait(0.34), "0.3 s")
        XCTAssertEqual(CalmFormat.count(1, "day"), "1 day")
        XCTAssertEqual(CalmFormat.wordCount("Hello, world — two words"), 4)

        var us = calendar
        us.locale = Locale(identifier: "en_US")
        let afternoon = try XCTUnwrap(us.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 13, minute: 4)))
        XCTAssertEqual(CalmFormat.feedTime(afternoon, calendar: us), "1:04 pm")
    }

    // MARK: - AppState helpers

    @MainActor
    func testCommandModeTipNeedsAShortcutAndAReadyModel() {
        let (appState, mocks) = AppState.makeTestState()
        XCTAssertNil(appState.commandModeShortcutCaps)
        XCTAssertFalse(appState.commandModeIsUsable, "No shortcut, nothing to press")

        appState.setShortcut(HotKeyCombo(keyCode: 14, modifiers: [.control, .option]), for: .commandMode)
        XCTAssertEqual(appState.commandModeShortcutCaps, ["⌃", "⌥", "E"])
        XCTAssertTrue(appState.commandModeIsUsable)

        mocks.transcriptCleanup.downloadedKinds = []
        XCTAssertFalse(appState.commandModeIsUsable, "The model has to be on this Mac")
    }

    @MainActor
    func testDictationKeyVerbFollowsActivationMode() {
        let (appState, _) = AppState.makeTestState()
        appState.activationMode = .pushToTalk
        XCTAssertEqual(appState.dictationKeyVerb, "Hold")
        appState.activationMode = .doubleTapToggle
        XCTAssertEqual(appState.dictationKeyVerb, "Double-tap")
        appState.activationMode = .pushToTalk
        XCTAssertFalse(appState.dictationKeyCaps.isEmpty)
    }

    @MainActor
    func testHasStatisticsAndSummaryReadTheStatsManager() {
        let (appState, mocks) = AppState.makeTestState()
        XCTAssertFalse(appState.hasStatistics)
        mocks.statsManager.stats.totalWords = 10
        mocks.statsManager.stats.totalAudioDurationSeconds = 6
        XCTAssertTrue(appState.hasStatistics)
        XCTAssertEqual(appState.insightsSummary().wordsPerMinute, 100)
    }

    // MARK: Heatmap fit

    func testHeatmapUsesFullCellsWhenThereIsRoom() {
        let fit = CalmHeatmapFit.fit(width: 900, weekCount: 53)
        XCTAssertEqual(fit, CalmHeatmapFit(cell: 12, gap: 3, weeks: 53))
    }

    func testHeatmapShrinksCellsToFitTheMinimumWindow() {
        // The Insights panel at the 1080-wide minimum window leaves about 700.
        let fit = CalmHeatmapFit.fit(width: 698, weekCount: 53)
        XCTAssertEqual(fit.weeks, 53)
        XCTAssertLessThan(fit.cell, 12)
        XCTAssertGreaterThanOrEqual(fit.cell, CalmHeatmapFit.minCell)
        XCTAssertLessThanOrEqual(fit.width, 698)
    }

    func testHeatmapSwitchesToTightGapsBeforeDroppingWeeks() {
        let fit = CalmHeatmapFit.fit(width: 53 * 9 + 52 * 2, weekCount: 53)
        XCTAssertEqual(fit.gap, 2)
        XCTAssertEqual(fit.weeks, 53)
        XCTAssertGreaterThanOrEqual(fit.cell, CalmHeatmapFit.minCell)
    }

    func testHeatmapDropsOldestWeeksRatherThanOverflowing() {
        for width in stride(from: CGFloat(60), through: 1400, by: 7) {
            let fit = CalmHeatmapFit.fit(width: width, weekCount: 53)
            XCTAssertLessThanOrEqual(fit.width, max(width, CalmHeatmapFit.minCell), "width \(width)")
            XCTAssertGreaterThanOrEqual(fit.cell, CalmHeatmapFit.minCell, "width \(width)")
            XCTAssertLessThanOrEqual(fit.cell, CalmHeatmapFit.maxCell, "width \(width)")
            XCTAssertLessThanOrEqual(fit.weeks, 53)
        }
        let narrow = CalmHeatmapFit.fit(width: 400, weekCount: 53)
        XCTAssertEqual(narrow.cell, CalmHeatmapFit.minCell)
        XCTAssertEqual(narrow.weeks, 40)
    }
}
