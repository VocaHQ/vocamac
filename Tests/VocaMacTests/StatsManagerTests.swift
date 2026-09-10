// StatsManagerTests.swift
// VocaMac Tests
//
// Tests for StatsManager logic including word counting, streaks, and WPM.

import XCTest
import Combine
@testable import VocaMac

final class StatsManagerTests: XCTestCase {
    var statsManager: StatsManager!
    var cancellables: Set<AnyCancellable>!
    var tempFileURL: URL!

    @MainActor
    override func setUp() {
        super.setUp()
        tempFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("stats_test_\(UUID().uuidString).json")
        statsManager = StatsManager(statsFileURL: tempFileURL)
        cancellables = []
    }

    @MainActor
    override func tearDown() {
        statsManager?.flushPendingSaves()
        try? FileManager.default.removeItem(at: tempFileURL)
        super.tearDown()
    }

    @MainActor
    func testInitialStatsAreEmpty() {
        XCTAssertEqual(statsManager.stats.totalWords, 0)
        XCTAssertEqual(statsManager.stats.totalTranscriptions, 0)
        XCTAssertEqual(statsManager.stats.currentStreak, 0)
    }

    @MainActor
    func testRecordingTranscriptionUpdatesCounts() {
        let transcription = VocaTranscription(
            text: "Hello world this is a test.", // 6 words
            duration: 1.0,
            detectedLanguage: "en",
            audioLengthSeconds: 10.0,
            modelUsed: .tiny
        )

        statsManager.recordTranscription(transcription)

        XCTAssertEqual(statsManager.stats.totalWords, 6)
        XCTAssertEqual(statsManager.stats.totalTranscriptions, 1)
        XCTAssertEqual(statsManager.stats.totalAudioDurationSeconds, 10.0)
    }

    @MainActor
    func testWPMCalculation() {
        let transcription = VocaTranscription(
            text: "One two three four five.", // 5 words
            duration: 1.0,
            detectedLanguage: "en",
            audioLengthSeconds: 30.0, // 0.5 minutes
            modelUsed: .tiny
        )

        statsManager.recordTranscription(transcription)

        // WPM = 5 words / 0.5 minutes = 10 WPM
        XCTAssertEqual(statsManager.stats.averageWPM, 10.0)
    }

    @MainActor
    func testStreakIncrementsOnNewDay() {
        let calendar = Calendar.current
        let today = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        // 1. Record for yesterday
        let t1 = VocaTranscription(
            text: "Yesterday transcription",
            duration: 1.0,
            detectedLanguage: "en",
            audioLengthSeconds: 1.0,
            modelUsed: .tiny,
            timestamp: yesterday
        )
        statsManager.recordTranscription(t1)
        XCTAssertEqual(statsManager.stats.currentStreak, 1)

        // 2. Record for today
        let t2 = VocaTranscription(
            text: "Today transcription",
            duration: 1.0,
            detectedLanguage: "en",
            audioLengthSeconds: 1.0,
            modelUsed: .tiny,
            timestamp: today
        )
        statsManager.recordTranscription(t2)
        XCTAssertEqual(statsManager.stats.currentStreak, 2, "Streak should increment on consecutive days")
        XCTAssertEqual(statsManager.stats.bestStreak, 2)
    }

    @MainActor
    func testStreakBrokenAfterGap() {
        let calendar = Calendar.current
        let today = Date()
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: today)!
        var currentDate = threeDaysAgo
        statsManager = StatsManager(
            statsFileURL: tempFileURL,
            calendar: calendar,
            now: { currentDate }
        )

        // 1. Record for 3 days ago
        let t1 = VocaTranscription(
            text: "Old transcription",
            duration: 1.0,
            detectedLanguage: "en",
            audioLengthSeconds: 1.0,
            modelUsed: .tiny,
            timestamp: threeDaysAgo
        )
        statsManager.recordTranscription(t1)
        XCTAssertEqual(statsManager.stats.currentStreak, 1)

        // 2. Record for today (2 day gap)
        currentDate = today
        let t2 = VocaTranscription(
            text: "Today transcription",
            duration: 1.0,
            detectedLanguage: "en",
            audioLengthSeconds: 1.0,
            modelUsed: .tiny,
            timestamp: today
        )
        statsManager.recordTranscription(t2)
        XCTAssertEqual(statsManager.stats.currentStreak, 1, "Streak should reset after a gap")
    }

    @MainActor
    func testDailyBucketsUseInjectedCalendarTimeZone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 2 * 60 * 60)!
        statsManager = StatsManager(statsFileURL: tempFileURL, calendar: calendar)

        let nearMidnightUTC = Date(timeIntervalSince1970: 1_704_060_000) // 2023-12-31 22:00:00 UTC, 2024-01-01 in GMT+2
        let transcription = VocaTranscription(
            text: "local day",
            duration: 1.0,
            detectedLanguage: "en",
            audioLengthSeconds: 1.0,
            modelUsed: .tiny,
            timestamp: nearMidnightUTC
        )

        statsManager.recordTranscription(transcription)

        XCTAssertEqual(statsManager.stats.dailyWordCounts["2024-01-01"], 2)
        XCTAssertNil(statsManager.stats.dailyWordCounts["2023-12-31"])
    }

    @MainActor
    func testStreakUsesTranscriptionDateRatherThanCurrentDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let firstDay = Date(timeIntervalSince1970: 946_684_800) // 2000-01-01 00:00:00 UTC
        let secondDay = Date(timeIntervalSince1970: 946_771_200) // 2000-01-02 00:00:00 UTC
        statsManager = StatsManager(
            statsFileURL: tempFileURL,
            calendar: calendar,
            now: { secondDay }
        )

        statsManager.recordTranscription(VocaTranscription(
            text: "first day",
            duration: 1.0,
            detectedLanguage: "en",
            audioLengthSeconds: 1.0,
            modelUsed: .tiny,
            timestamp: firstDay
        ))
        statsManager.recordTranscription(VocaTranscription(
            text: "second day",
            duration: 1.0,
            detectedLanguage: "en",
            audioLengthSeconds: 1.0,
            modelUsed: .tiny,
            timestamp: secondDay
        ))

        XCTAssertEqual(statsManager.stats.currentStreak, 2)
        XCTAssertEqual(statsManager.stats.bestStreak, 2)
    }

    @MainActor
    func testSameDayTranscriptionsDoNotIncrementStreak() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let first = Date(timeIntervalSince1970: 946_684_800) // 2000-01-01 00:00:00 UTC
        let second = Date(timeIntervalSince1970: 946_728_000) // 2000-01-01 12:00:00 UTC
        statsManager = StatsManager(statsFileURL: tempFileURL, calendar: calendar, now: { second })

        statsManager.recordTranscription(VocaTranscription(
            text: "morning words",
            duration: 1.0,
            detectedLanguage: "en",
            audioLengthSeconds: 1.0,
            modelUsed: .tiny,
            timestamp: first
        ))
        statsManager.recordTranscription(VocaTranscription(
            text: "afternoon words",
            duration: 1.0,
            detectedLanguage: "en",
            audioLengthSeconds: 1.0,
            modelUsed: .tiny,
            timestamp: second
        ))

        XCTAssertEqual(statsManager.stats.currentStreak, 1)
        XCTAssertEqual(statsManager.stats.bestStreak, 1)
    }

    @MainActor
    func testResetStats() {
        let transcription = VocaTranscription(text: "Test", duration: 1.0, detectedLanguage: "en", audioLengthSeconds: 1.0, modelUsed: .tiny)
        statsManager.recordTranscription(transcription)
        XCTAssertEqual(statsManager.stats.totalTranscriptions, 1)

        statsManager.resetStats()
        XCTAssertEqual(statsManager.stats.totalTranscriptions, 0)
        XCTAssertEqual(statsManager.stats.totalWords, 0)
    }

    @MainActor
    func testWordCountHandlesSpacelessScripts() {
        // Japanese has no word separators; a naive whitespace split counts it as 1.
        let transcription = VocaTranscription(
            text: "これはテストです",
            duration: 1.0,
            detectedLanguage: "ja",
            audioLengthSeconds: 1.0,
            modelUsed: .tiny
        )

        statsManager.recordTranscription(transcription)

        XCTAssertGreaterThan(statsManager.stats.totalWords, 1, "Space-less scripts should be tokenized into multiple words")
    }

    func testStatsDecodeToleratesMissingAndUnknownKeys() throws {
        // Simulates an older/newer stats.json: only one known key present, plus a
        // now-removed legacy key. Decoding must not throw or wipe — missing keys
        // fall back to defaults and unknown keys are ignored.
        let json = Data("""
        {"totalWords": 42, "dailyDurationSeconds": {"2024-01-01": 5.0}}
        """.utf8)

        let decoded = try JSONDecoder().decode(UserStats.self, from: json)

        XCTAssertEqual(decoded.totalWords, 42)
        XCTAssertEqual(decoded.totalTranscriptions, 0)
        XCTAssertEqual(decoded.currentStreak, 0)
        XCTAssertNil(decoded.lastUsageDate)
        XCTAssertTrue(decoded.dailyWordCounts.isEmpty)
    }

    func testStatsDecodeSalvagesValidFieldsAndRepairsInvalidValues() throws {
        let json = Data("""
        {
          "totalWords": 42,
          "totalTranscriptions": "broken",
          "totalAudioDurationSeconds": -10,
          "currentStreak": -3,
          "bestStreak": 4,
          "dailyWordCounts": {"2026-09-10": -8}
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(UserStats.self, from: json)

        XCTAssertEqual(decoded.totalWords, 42)
        XCTAssertEqual(decoded.totalTranscriptions, 0)
        XCTAssertEqual(decoded.totalAudioDurationSeconds, 0)
        XCTAssertEqual(decoded.currentStreak, 0)
        XCTAssertEqual(decoded.bestStreak, 4)
        XCTAssertEqual(decoded.dailyWordCounts["2026-09-10"], 0)
    }

    @MainActor
    func testZeroWordBucketWithoutTranscriptionActivityDoesNotInflateStreak() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let thirdDay = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 3)
        ))
        var savedStats = UserStats()
        savedStats.dailyWordCounts = [
            "2026-09-01": 2,
            "2026-09-02": -8,
            "2026-09-03": 2
        ]
        try JSONEncoder().encode(savedStats).write(to: tempFileURL)

        statsManager = StatsManager(
            statsFileURL: tempFileURL,
            calendar: calendar,
            now: { thirdDay }
        )

        XCTAssertEqual(statsManager.stats.dailyWordCounts["2026-09-02"], 0)
        XCTAssertEqual(statsManager.stats.currentStreak, 1)
        XCTAssertEqual(statsManager.stats.bestStreak, 1)
    }

    @MainActor
    func testZeroWordTranscriptionStillCountsAsActivity() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 10)
        ))
        statsManager = StatsManager(statsFileURL: tempFileURL, calendar: calendar, now: { date })

        statsManager.recordTranscription(VocaTranscription(
            text: "🙂",
            duration: 1,
            detectedLanguage: "und",
            audioLengthSeconds: 1,
            modelUsed: .tiny,
            timestamp: date
        ))

        XCTAssertEqual(statsManager.stats.dailyWordCounts["2026-09-10"], 0)
        XCTAssertEqual(statsManager.stats.dailyTranscriptionCounts["2026-09-10"], 1)
        XCTAssertEqual(statsManager.stats.currentStreak, 1)
        XCTAssertEqual(statsManager.stats.bestStreak, 1)
    }

    @MainActor
    func testNonGregorianSystemCalendarStillWritesGregorianDayKeys() {
        var calendar = Calendar(identifier: .buddhist)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01 00:00:00 UTC
        statsManager = StatsManager(statsFileURL: tempFileURL, calendar: calendar, now: { date })

        statsManager.recordTranscription(VocaTranscription(
            text: "calendar test",
            duration: 1,
            detectedLanguage: "en",
            audioLengthSeconds: 1,
            modelUsed: .tiny,
            timestamp: date
        ))

        XCTAssertEqual(statsManager.stats.dailyWordCounts["2024-01-01"], 2)
        XCTAssertNil(statsManager.stats.dailyWordCounts["2567-01-01"])
    }

    @MainActor
    func testOutOfOrderTranscriptionsRebuildStreakWithoutRegressingLastUsage() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 8)))
        let secondDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: firstDay))
        let thirdDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: firstDay))
        statsManager = StatsManager(statsFileURL: tempFileURL, calendar: calendar, now: { thirdDay })

        for date in [firstDay, thirdDay, secondDay] {
            statsManager.recordTranscription(VocaTranscription(
                text: "out of order",
                duration: 1,
                detectedLanguage: "en",
                audioLengthSeconds: 1,
                modelUsed: .tiny,
                timestamp: date
            ))
        }

        XCTAssertEqual(statsManager.stats.currentStreak, 3)
        XCTAssertEqual(statsManager.stats.bestStreak, 3)
        XCTAssertEqual(statsManager.stats.lastUsageDate, thirdDay)
    }

    @MainActor
    func testRefreshingStreakExpiresItButPreservesBest() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        let secondDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: firstDay))
        let fifthDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 4, to: firstDay))
        var currentDate = secondDay
        statsManager = StatsManager(statsFileURL: tempFileURL, calendar: calendar, now: { currentDate })

        for date in [firstDay, secondDay] {
            statsManager.recordTranscription(VocaTranscription(
                text: "streak words",
                duration: 1,
                detectedLanguage: "en",
                audioLengthSeconds: 1,
                modelUsed: .tiny,
                timestamp: date
            ))
        }
        XCTAssertEqual(statsManager.stats.currentStreak, 2)

        currentDate = fifthDay
        statsManager.refreshCurrentStreak()

        XCTAssertEqual(statsManager.stats.currentStreak, 0)
        XCTAssertEqual(statsManager.stats.bestStreak, 2)
    }

    @MainActor
    func testFutureBucketsDoNotSuppressOrInflateStreaks() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let currentDate = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 2)
        ))
        var savedStats = UserStats()
        savedStats.dailyWordCounts = [
            "2026-09-01": 2,
            "2026-09-02": 2,
            "2026-09-10": 2,
            "2026-09-11": 2,
            "2026-09-12": 2
        ]
        try JSONEncoder().encode(savedStats).write(to: tempFileURL)

        statsManager = StatsManager(
            statsFileURL: tempFileURL,
            calendar: calendar,
            now: { currentDate }
        )

        XCTAssertEqual(statsManager.stats.currentStreak, 2)
        XCTAssertEqual(statsManager.stats.bestStreak, 2)
    }

    @MainActor
    func testReloadKeepsPersistedStatisticsTimeZone() throws {
        var originCalendar = Calendar(identifier: .gregorian)
        originCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))
        let usageDate = Date(timeIntervalSince1970: 1_788_949_800) // 2026-09-09 10:30:00 UTC
        let referenceDate = Date(timeIntervalSince1970: 1_788_951_600) // 2026-09-09 11:00:00 UTC
        statsManager = StatsManager(
            statsFileURL: tempFileURL,
            calendar: originCalendar,
            now: { referenceDate }
        )
        statsManager.recordTranscription(VocaTranscription(
            text: "near midnight",
            duration: 1,
            detectedLanguage: "en",
            audioLengthSeconds: 1,
            modelUsed: .tiny,
            timestamp: usageDate
        ))
        statsManager.flushPendingSaves()

        var destinationCalendar = Calendar(identifier: .gregorian)
        destinationCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Etc/GMT+12"))
        statsManager = StatsManager(
            statsFileURL: tempFileURL,
            calendar: destinationCalendar,
            now: { referenceDate }
        )

        XCTAssertEqual(statsManager.stats.timeZoneIdentifier, originCalendar.timeZone.identifier)
        XCTAssertEqual(statsManager.stats.dailyWordCounts["2026-09-10"], 2)
        XCTAssertEqual(statsManager.stats.currentStreak, 1)
    }

    @MainActor
    func testInvalidAudioDurationsDoNotPoisonTotalsOrPersistence() {
        let transcription = VocaTranscription(
            text: "valid words",
            duration: 1,
            detectedLanguage: "en",
            audioLengthSeconds: .nan,
            modelUsed: .tiny
        )

        statsManager.recordTranscription(transcription)
        statsManager.flushPendingSaves()

        XCTAssertEqual(statsManager.stats.totalAudioDurationSeconds, 0)
        XCTAssertEqual(statsManager.stats.averageWPM, 0)
        XCTAssertNoThrow(try Data(contentsOf: tempFileURL))

        let reloaded = StatsManager(statsFileURL: tempFileURL)
        XCTAssertEqual(reloaded.stats.totalTranscriptions, 1)
        XCTAssertEqual(reloaded.stats.totalWords, 2)
        XCTAssertEqual(reloaded.stats.totalAudioDurationSeconds, 0)
    }

    @MainActor
    func testSaveCreatesMissingParentDirectory() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("stats_test_dir_\(UUID().uuidString)", isDirectory: true)
        let nestedURL = parent.appendingPathComponent("nested/stats.json")
        defer { try? FileManager.default.removeItem(at: parent) }
        statsManager = StatsManager(statsFileURL: nestedURL)

        statsManager.recordTranscription(VocaTranscription(
            text: "persist me",
            duration: 1,
            detectedLanguage: "en",
            audioLengthSeconds: 1,
            modelUsed: .tiny
        ))
        statsManager.flushPendingSaves()

        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedURL.path))
        let decoded = try JSONDecoder().decode(UserStats.self, from: Data(contentsOf: nestedURL))
        XCTAssertEqual(decoded.totalTranscriptions, 1)
    }

    @MainActor
    func testCountsSaturateInsteadOfOverflowing() throws {
        let date = Date(timeIntervalSince1970: 1_789_000_000)
        var savedStats = UserStats()
        savedStats.totalWords = Int.max
        savedStats.totalTranscriptions = Int.max
        savedStats.dailyWordCounts = ["2026-09-10": Int.max]
        try JSONEncoder().encode(savedStats).write(to: tempFileURL)
        statsManager = StatsManager(statsFileURL: tempFileURL, now: { date })

        statsManager.recordTranscription(VocaTranscription(
            text: "one more",
            duration: 1,
            detectedLanguage: "en",
            audioLengthSeconds: 1,
            modelUsed: .tiny,
            timestamp: date
        ))

        XCTAssertEqual(statsManager.stats.totalWords, Int.max)
        XCTAssertEqual(statsManager.stats.totalTranscriptions, Int.max)
    }
}
