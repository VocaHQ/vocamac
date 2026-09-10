// DictationHistory.swift
// VocaMac
//
// A local record of past dictations: what the engine heard, what was typed,
// and the audio behind it, so a dictation can be copied, pasted again, or
// retried after a failure.

import Foundation

/// Where a dictation got to before it was recorded in history.
enum DictationHistoryStatus: String, Codable, Equatable {
    /// Audio saved, transcription still running. A pending entry found at
    /// launch means VocaMac quit or crashed mid-dictation.
    case pending
    /// Transcribed and delivered.
    case completed
    /// Transcribed, but the engine heard nothing usable.
    case empty
    /// The engine threw.
    case failed
    /// VocaMac quit or crashed before the dictation finished.
    case interrupted
    /// The user cancelled while the dictation was being transcribed.
    case cancelled

    var displayName: String {
        switch self {
        case .pending: return "Transcribing"
        case .completed: return "Done"
        case .empty: return "Nothing heard"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        case .cancelled: return "Cancelled"
        }
    }

    /// Statuses the user would want to retry: the audio exists but no text
    /// reached them.
    var needsRecovery: Bool {
        switch self {
        case .failed, .interrupted, .cancelled: return true
        case .pending, .completed, .empty: return false
        }
    }
}

/// How long history entries are kept before they are deleted.
enum HistoryRetention: String, CaseIterable, Identifiable, Codable {
    case day
    case week
    case month
    case forever

    var id: String { rawValue }

    static let defaultRetention: HistoryRetention = .month

    var displayName: String {
        switch self {
        case .day: return "1 day"
        case .week: return "7 days"
        case .month: return "30 days"
        case .forever: return "Forever"
        }
    }

    /// Age after which an entry is deleted. `nil` keeps entries forever.
    var maximumAge: TimeInterval? {
        switch self {
        case .day: return 24 * 60 * 60
        case .week: return 7 * 24 * 60 * 60
        case .month: return 30 * 24 * 60 * 60
        case .forever: return nil
        }
    }

    static func resolved(stored: String) -> HistoryRetention {
        HistoryRetention(rawValue: stored) ?? defaultRetention
    }
}

/// One dictation in history.
struct DictationHistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    var status: DictationHistoryStatus
    /// What the speech engine returned, before any dictionary, style, or cleanup.
    var rawText: String
    /// What VocaMac typed (or would have typed).
    var finalText: String
    /// One-line description of what the output pipeline did.
    var summary: String?
    var appName: String?
    var bundleIdentifier: String?
    var processName: String?
    /// `ModelSize.rawValue` of the model that transcribed it.
    var modelID: String
    var language: String?
    var audioSeconds: Double
    var transcriptionSeconds: Double?
    /// File name inside the history audio folder, when audio is kept.
    var audioFileName: String?
    var audioBytes: Int64?
    var errorMessage: String?
    var retryCount: Int

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        status: DictationHistoryStatus = .pending,
        rawText: String = "",
        finalText: String = "",
        summary: String? = nil,
        appName: String? = nil,
        bundleIdentifier: String? = nil,
        processName: String? = nil,
        modelID: String,
        language: String? = nil,
        audioSeconds: Double,
        transcriptionSeconds: Double? = nil,
        audioFileName: String? = nil,
        audioBytes: Int64? = nil,
        errorMessage: String? = nil,
        retryCount: Int = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.status = status
        self.rawText = rawText
        self.finalText = finalText
        self.summary = summary
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.processName = processName
        self.modelID = modelID
        self.language = language
        self.audioSeconds = audioSeconds
        self.transcriptionSeconds = transcriptionSeconds
        self.audioFileName = audioFileName
        self.audioBytes = audioBytes
        self.errorMessage = errorMessage
        self.retryCount = retryCount
    }

    /// The text a user means when they say "that dictation".
    var displayText: String {
        let final = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        return final.isEmpty ? rawText.trimmingCharacters(in: .whitespacesAndNewlines) : final
    }

    /// Whether the dictionary, a writing style, or cleanup changed the words,
    /// beyond spacing and case — the case where "show original" is useful.
    var hasEditedOutput: Bool {
        let raw = Self.comparable(rawText)
        let final = Self.comparable(finalText)
        return !raw.isEmpty && !final.isEmpty && raw != final
    }

    var hasAudio: Bool { audioFileName != nil }

    /// The target app as a snapshot, for re-running its writing style on retry.
    var targetApp: RunningAppSnapshot? {
        guard let appName else { return nil }
        return RunningAppSnapshot(displayName: appName, bundleIdentifier: bundleIdentifier, processName: processName)
    }

    /// Words only: sentence case, added punctuation, and spacing are what
    /// every formatted dictation changes, so they don't count as an edit.
    private static func comparable(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
