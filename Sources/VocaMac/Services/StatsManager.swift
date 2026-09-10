// StatsManager.swift
// VocaMac
//
// Manages the persistence and updating of user statistics.

import Foundation
import Combine

@MainActor
class StatsManager: StatsManaging, ObservableObject {
    @Published private(set) var stats: UserStats = UserStats()

    var objectWillChangePublisher: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }

    private let fileManager = FileManager.default
    private let statsFileURL: URL
    private var statisticsTimeZone: TimeZone
    private let now: () -> Date

    private var calendar: Calendar {
        var localGregorianCalendar = Calendar(identifier: .gregorian)
        localGregorianCalendar.timeZone = statisticsTimeZone
        return localGregorianCalendar
    }

    /// Serial queue for off-main disk writes so recording never blocks the UI.
    private let saveQueue = DispatchQueue(label: "com.vocamac.stats.save", qos: .utility)

    init(
        statsFileURL: URL? = nil,
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping () -> Date = Date.init
    ) {
        if let statsFileURL {
            self.statsFileURL = statsFileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let vMacDir = appSupport.appendingPathComponent("VocaMac", isDirectory: true)

            self.statsFileURL = vMacDir.appendingPathComponent("stats.json")
        }

        // Day keys are a documented Gregorian `yyyy-MM-dd` format. Capture the
        // caller's time zone without letting a non-Gregorian system calendar
        // produce keys the Stats view cannot parse or sort. Once persisted,
        // this zone stays stable so travel cannot reinterpret historical keys.
        self.statisticsTimeZone = calendar.timeZone
        self.now = now
        loadStats()
    }

    private func loadStats() {
        do {
            if fileManager.fileExists(atPath: statsFileURL.path) {
                let data = try Data(contentsOf: statsFileURL)
                let decodedStats = try JSONDecoder().decode(UserStats.self, from: data)
                var loadedStats = decodedStats
                if let identifier = loadedStats.timeZoneIdentifier,
                   let persistedTimeZone = TimeZone(identifier: identifier) {
                    statisticsTimeZone = persistedTimeZone
                } else {
                    loadedStats.timeZoneIdentifier = statisticsTimeZone.identifier
                }
                stats = recalculatingStreaks(in: loadedStats, asOf: now())
                if stats != decodedStats {
                    saveStats()
                }
                VocaLogger.debug(.general, "User stats loaded from disk")
            } else {
                VocaLogger.info(.general, "No stats file found, starting fresh")
            }
        } catch {
            VocaLogger.error(.general, "Failed to load stats: \(error.localizedDescription)")
        }
    }

    private func saveStats() {
        // Encode on the main actor (cheap, tiny payload), then write off-main so a
        // busy disk can't hitch the UI. The serial queue preserves write ordering.
        let data: Data
        do {
            data = try JSONEncoder().encode(stats)
        } catch {
            VocaLogger.error(.general, "Failed to encode stats: \(error.localizedDescription)")
            return
        }
        let url = statsFileURL
        saveQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
                VocaLogger.debug(.general, "User stats saved to disk")
            } catch {
                VocaLogger.error(.general, "Failed to save stats: \(error.localizedDescription)")
            }
        }
    }

    func recordTranscription(_ transcription: VocaTranscription) {
        let text = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Count words using the system tokenizer so space-less scripts
        // (Chinese, Japanese, Thai, …) aren't undercounted as a single word.
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { _, _, _, _ in
            words += 1
        }

        let dateKey = dayKey(for: transcription.timestamp)

        var updatedStats = stats

        // Update basic counts without allowing corrupt imported values or an
        // invalid engine duration to overflow/poison future JSON saves.
        updatedStats.totalWords = addingWithoutOverflow(updatedStats.totalWords, words)
        updatedStats.totalTranscriptions = addingWithoutOverflow(updatedStats.totalTranscriptions, 1)
        updatedStats.totalAudioDurationSeconds = addingDuration(
            transcription.audioLengthSeconds,
            to: updatedStats.totalAudioDurationSeconds
        )

        // Update daily stats
        updatedStats.dailyWordCounts[dateKey] = addingWithoutOverflow(
            updatedStats.dailyWordCounts[dateKey, default: 0],
            words
        )
        updatedStats.dailyTranscriptionCounts[dateKey] = addingWithoutOverflow(
            updatedStats.dailyTranscriptionCounts[dateKey, default: 0],
            1
        )
        updatedStats.timeZoneIdentifier = statisticsTimeZone.identifier

        if updatedStats.lastUsageDate.map({ transcription.timestamp > $0 }) ?? true {
            updatedStats.lastUsageDate = transcription.timestamp
        }

        // Deriving streaks from daily activity makes late/out-of-order results
        // deterministic instead of resetting the user's current streak.
        stats = recalculatingStreaks(in: updatedStats, asOf: now())

        saveStats()
    }

    /// Refresh the cached streak when the calendar day changes without a new
    /// transcription. A streak stays active through the day after last use.
    func refreshCurrentStreak() {
        let refreshedStats = recalculatingStreaks(in: stats, asOf: now())
        guard refreshedStats != stats else { return }
        stats = refreshedStats
        saveStats()
    }

    /// Finish queued writes before application termination. Normal recording
    /// stays non-blocking; quitting cannot drop the most recent tiny snapshot.
    func flushPendingSaves() {
        saveQueue.sync {}
    }

    func resetStats() {
        stats = UserStats(timeZoneIdentifier: statisticsTimeZone.identifier)
        saveStats()
    }

    /// Formats an instant as the persisted statistics calendar's Gregorian day key.
    private func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return "unknown"
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Parses a strict Gregorian day key in the persisted statistics time zone.
    private func date(fromDayKey key: String) -> Date? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              dayKey(for: date) == key else {
            return nil
        }
        return date
    }

    /// Rebuilds cached streaks from genuine, non-future activity days.
    ///
    /// Positive daily word counts support files from the previous schema, while
    /// daily transcription counts preserve valid activity that produced no words.
    /// Future buckets remain stored but do not affect streaks until their day arrives.
    private func recalculatingStreaks(in original: UserStats, asOf referenceDate: Date) -> UserStats {
        var updated = original
        let referenceDay = calendar.startOfDay(for: referenceDate)
        let wordActivityKeys = original.dailyWordCounts.compactMap { key, count in
            count > 0 ? key : nil
        }
        let transcriptionActivityKeys = original.dailyTranscriptionCounts.compactMap { key, count in
            count > 0 ? key : nil
        }
        let activityDays = Set(wordActivityKeys + transcriptionActivityKeys)
            .compactMap(date(fromDayKey:))
            .filter { $0 <= referenceDay }
            .sorted()

        guard let latestDay = activityDays.last else {
            updated.currentStreak = 0
            // Files from the oldest schema may have a last-use instant but no
            // daily buckets. Preserve their cached streak only while that
            // instant is today or yesterday. A present-but-invalid, zero, or
            // future bucket is not evidence of activity.
            guard original.dailyWordCounts.isEmpty,
                  original.dailyTranscriptionCounts.isEmpty,
                  let lastUsageDate = original.lastUsageDate else { return updated }
            let gap = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: lastUsageDate),
                to: referenceDay
            ).day
            if gap == 0 || gap == 1 {
                updated.currentStreak = original.currentStreak
            }
            return updated
        }

        var run = 1
        var latestRun = 1
        var computedBest = 1
        for (previous, next) in zip(activityDays, activityDays.dropFirst()) {
            let gap = calendar.dateComponents([.day], from: previous, to: next).day
            run = gap == 1 ? run + 1 : 1
            latestRun = run
            computedBest = max(computedBest, run)
        }

        let daysSinceLatestUsage = calendar.dateComponents(
            [.day],
            from: latestDay,
            to: referenceDay
        ).day
        updated.currentStreak = daysSinceLatestUsage == 0 || daysSinceLatestUsage == 1 ? latestRun : 0
        // Preserve a historical best from an older schema that may not have
        // complete daily buckets, while still repairing understated values.
        updated.bestStreak = max(original.bestStreak, computedBest)
        return updated
    }

    /// Adds non-negative counters and saturates at `Int.max` on overflow.
    private func addingWithoutOverflow(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflowed) = max(0, lhs).addingReportingOverflow(max(0, rhs))
        return overflowed ? Int.max : sum
    }

    /// Adds a valid positive duration while repairing invalid totals and overflow.
    private func addingDuration(_ duration: TimeInterval, to total: TimeInterval) -> TimeInterval {
        let safeTotal = total.isFinite && total > 0 ? total : 0
        guard duration.isFinite, duration > 0 else { return safeTotal }
        let sum = safeTotal + duration
        return sum.isFinite ? sum : Double.greatestFiniteMagnitude
    }
}
