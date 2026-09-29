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

    /// The most recent waits between stopping a dictation and its text being
    /// pasted, oldest first, at most `maxStopWaits`.
    var stopWaits: [StopWait] = []

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
        // Entry by entry, so one damaged wait doesn't cost the rest.
        let decodedStopWaits = (container.decodeLossily([LossyElement<StopWait>].self, forKey: .stopWaits) ?? [])
            .compactMap(\.value)
        stopWaits = Array(decodedStopWaits.filter(\.isValid).suffix(Self.maxStopWaits))
    }
}

/// Decodes to nil instead of failing the array it is in.
private struct LossyElement<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// How long one dictation took to reach the app after the user stopped.
struct StopWait: Codable, Equatable {
    /// From releasing the key to the text being handed to the app. Delivery
    /// itself (a paste, or an accessibility insert) follows within moments.
    let seconds: Double
    /// Length of the recording.
    let audioSeconds: Double
    /// Whether the recording ran with "Process while speaking", including
    /// one that fell back to decoding the whole recording at stop: what the
    /// setting gave the user.
    let processedWhileSpeaking: Bool

    var isValid: Bool {
        seconds.isFinite && seconds >= 0 && audioSeconds.isFinite && audioSeconds >= 0
    }
}

extension UserStats {
    /// Enough recent waits to show a stable median without growing stats.json.
    static let maxStopWaits = 200

    /// Only dictations this long are compared: shorter ones barely wait
    /// either way, and "Process while speaking" is for long dictations.
    static let comparedStopWaitSeconds = 10.0

    /// Median wait after stop for dictations of at least
    /// `comparedStopWaitSeconds`, with or without "Process while speaking",
    /// and how many dictations it covers. Nil when there are none.
    func medianStopWait(processedWhileSpeaking: Bool) -> (seconds: Double, count: Int)? {
        let waits = stopWaits
            .filter { $0.processedWhileSpeaking == processedWhileSpeaking && $0.audioSeconds >= Self.comparedStopWaitSeconds }
            .map(\.seconds)
            .sorted()
        guard !waits.isEmpty else { return nil }
        let middle = waits.count / 2
        let median = waits.count.isMultiple(of: 2) ? (waits[middle - 1] + waits[middle]) / 2 : waits[middle]
        return (median, waits.count)
    }

    /// Add a wait, keeping only the most recent `maxStopWaits`.
    mutating func recordStopWait(_ wait: StopWait) {
        guard wait.isValid else { return }
        stopWaits.append(wait)
        if stopWaits.count > Self.maxStopWaits {
            stopWaits.removeFirst(stopWaits.count - Self.maxStopWaits)
        }
    }
}

private extension KeyedDecodingContainer {
    /// A malformed field must not make every other valid statistic unreadable.
    func decodeLossily<Value: Decodable>(_ type: Value.Type, forKey key: Key) -> Value? {
        try? decode(Value.self, forKey: key)
    }
}
