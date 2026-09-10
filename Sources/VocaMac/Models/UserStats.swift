// UserStats.swift
// VocaMac
//
// Data model for tracking user usage statistics.

import Foundation

struct UserStats: Codable, Equatable {
    /// Total number of words transcribed across all sessions
    var totalWords: Int = 0

    /// Total number of successful transcriptions performed
    var totalTranscriptions: Int = 0

    /// Total duration of audio recorded in seconds
    var totalAudioDurationSeconds: Double = 0

    /// Date of the most recent transcription
    var lastUsageDate: Date?

    /// Current consecutive days of usage
    var currentStreak: Int = 0

    /// Highest consecutive days of usage recorded
    var bestStreak: Int = 0

    /// Daily word counts to calculate trends and streaks
    /// Key is date string in "yyyy-MM-dd" format
    var dailyWordCounts: [String: Int] = [:]

    /// Daily successful-transcription counts used to distinguish activity from
    /// a corrupt or legitimately zero-word daily bucket.
    /// Key is date string in "yyyy-MM-dd" format.
    var dailyTranscriptionCounts: [String: Int] = [:]

    /// Time-zone identifier used to create and interpret daily buckets.
    /// Keeping this stable prevents travel from reinterpreting historical keys.
    var timeZoneIdentifier: String?

    /// Calculated average Words Per Minute (WPM).
    /// Note: This is "words-per-minute-of-audio", dividing total words by total audio duration.
    var averageWPM: Double {
        guard totalWords > 0,
              totalAudioDurationSeconds.isFinite,
              totalAudioDurationSeconds > 0 else { return 0 }
        let minutes = totalAudioDurationSeconds / 60.0
        let wordsPerMinute = Double(totalWords) / minutes
        return wordsPerMinute.isFinite ? wordsPerMinute : 0
    }
}

extension UserStats {
    /// Decode leniently so evolving the schema never wipes a user's saved stats:
    /// any key missing from an older `stats.json` falls back to its default.
    /// (Synthesized `Codable` requires every non-optional key, so adding a field
    /// later would otherwise fail decoding and silently reset all history.)
    /// Declared in an extension to keep the memberwise `UserStats()` initializer.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        totalWords = max(0, container.decodeLossily(Int.self, forKey: .totalWords) ?? totalWords)
        totalTranscriptions = max(
            0,
            container.decodeLossily(Int.self, forKey: .totalTranscriptions) ?? totalTranscriptions
        )

        let decodedDuration = container.decodeLossily(
            Double.self,
            forKey: .totalAudioDurationSeconds
        ) ?? totalAudioDurationSeconds
        totalAudioDurationSeconds = decodedDuration.isFinite && decodedDuration > 0 ? decodedDuration : 0

        lastUsageDate = container.decodeLossily(Date.self, forKey: .lastUsageDate)
        currentStreak = max(0, container.decodeLossily(Int.self, forKey: .currentStreak) ?? currentStreak)
        bestStreak = max(
            currentStreak,
            max(0, container.decodeLossily(Int.self, forKey: .bestStreak) ?? bestStreak)
        )

        let decodedDailyCounts = container.decodeLossily(
            [String: Int].self,
            forKey: .dailyWordCounts
        ) ?? dailyWordCounts
        // Negative buckets are corrupt, not zero-word activity. Drop them so
        // the legacy migration can safely treat retained zero buckets as real.
        dailyWordCounts = decodedDailyCounts.filter { $0.value >= 0 }

        let decodedDailyTranscriptionCounts = container.decodeLossily(
            [String: Int].self,
            forKey: .dailyTranscriptionCounts
        ) ?? dailyTranscriptionCounts
        dailyTranscriptionCounts = decodedDailyTranscriptionCounts.mapValues { max(0, $0) }

        timeZoneIdentifier = container.decodeLossily(String.self, forKey: .timeZoneIdentifier)
    }
}

private extension KeyedDecodingContainer {
    /// A malformed field must not make every other valid statistic unreadable.
    func decodeLossily<Value: Decodable>(_ type: Value.Type, forKey key: Key) -> Value? {
        try? decode(Value.self, forKey: key)
    }
}
