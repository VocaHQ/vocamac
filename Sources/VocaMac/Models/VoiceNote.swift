// VoiceNote.swift
// VocaMac
//
// A voice note: a meeting, a call, or a memo recorded on this Mac, with its
// transcript split by speaker and an optional summary written by the local
// model. Notes never leave the Mac unless the user exports them.

import Foundation

/// Where a note's audio came from.
enum VoiceNoteSource: String, Codable, CaseIterable, Sendable {
    /// What the Mac played (a call, a video), through a process tap.
    case systemAudio
    /// The microphone.
    case microphone
    /// The microphone and what the Mac played, mixed.
    case meeting
    /// Text saved from the Scratchpad; no audio.
    case scratchpad
    /// A long dictation saved from History.
    case history

    var displayName: String {
        switch self {
        case .systemAudio: return "System audio"
        case .microphone: return "Memo"
        case .meeting: return "Meeting"
        case .scratchpad: return "Scratchpad"
        case .history: return "Dictation"
        }
    }
}

/// Where a note got to.
enum VoiceNoteStatus: String, Codable, Sendable {
    /// Audio saved, transcription running. Found at launch, it means VocaMac
    /// quit mid-way; it becomes `interrupted`.
    case pending
    case completed
    case failed
    case interrupted

    var displayName: String {
        switch self {
        case .pending: return "Transcribing"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        }
    }

    /// The audio is there and no transcript came of it.
    var needsRetry: Bool { self == .failed || self == .interrupted }
}

/// A stretch of transcript with its time and, when known, its speaker.
struct VoiceNoteSegment: Codable, Equatable, Sendable {
    /// Seconds into the note's audio.
    var start: Double
    var end: Double
    var text: String
    /// "1", "2", … in order of first appearance; nil when speakers weren't told apart.
    var speaker: String?
}

/// Where a note's summary was written.
enum VoiceNoteSummaryPlace: String, Codable, Sendable {
    /// A local model on this Mac.
    case thisMac
    /// Apple Intelligence.
    case appleIntelligence
    /// The server Command Mode is set to use.
    case server

    init(engine: CommandModeEngine) {
        switch engine {
        case .local: self = .thisMac
        case .appleIntelligence: self = .appleIntelligence
        case .endpoint: self = .server
        }
    }
}

/// What the local model made of a note.
struct VoiceNoteSummary: Codable, Equatable, Sendable {
    /// Two or three sentences.
    var overview: String
    var decisions: [String]
    var actionItems: [String]
    /// The model that wrote it, for the record.
    var model: String?
    var createdAt: Date
    /// Where it was written; nil for summaries saved before this was kept.
    var place: VoiceNoteSummaryPlace?

    var isEmpty: Bool { overview.isEmpty && decisions.isEmpty && actionItems.isEmpty }

    /// Who wrote it and where, for the line under it.
    var provenance: String {
        let writer = model ?? "the Command Mode model"
        switch place {
        case .thisMac?: return "Written on this Mac by \(writer)."
        case .appleIntelligence?: return "Written by Apple Intelligence."
        case .server?: return "Written by \(writer) on the server Command Mode uses."
        case nil: return "Written by \(writer)."
        }
    }
}

/// One note.
struct VoiceNote: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    var title: String
    var source: VoiceNoteSource
    var status: VoiceNoteStatus
    var durationSeconds: Double
    /// The transcript, speaker-labelled segments in order. Empty until
    /// transcribed, and for a Scratchpad note (`text` holds its words).
    var segments: [VoiceNoteSegment]
    /// The whole transcript as plain text.
    var text: String
    /// Names the user gave speakers, by speaker id ("1" → "Priya").
    var speakerNames: [String: String]
    var summary: VoiceNoteSummary?
    /// File name in the note's folder; nil when there is no audio (or it was dropped).
    var audioFileName: String?
    var audioBytes: Int64?
    /// `ModelSize.rawValue` of the model that transcribed it.
    var modelID: String?
    var language: String?
    var errorMessage: String?

    init(
        id: UUID = UUID(), createdAt: Date = Date(), title: String, source: VoiceNoteSource,
        status: VoiceNoteStatus = .pending, durationSeconds: Double = 0, segments: [VoiceNoteSegment] = [],
        text: String = "", speakerNames: [String: String] = [:], summary: VoiceNoteSummary? = nil,
        audioFileName: String? = nil, audioBytes: Int64? = nil, modelID: String? = nil,
        language: String? = nil, errorMessage: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.source = source
        self.status = status
        self.durationSeconds = durationSeconds
        self.segments = segments
        self.text = text
        self.speakerNames = speakerNames
        self.summary = summary
        self.audioFileName = audioFileName
        self.audioBytes = audioBytes
        self.modelID = modelID
        self.language = language
        self.errorMessage = errorMessage
    }

    var hasAudio: Bool { audioFileName != nil }

    /// Speaker ids in order of first appearance.
    var speakers: [String] {
        var seen = Set<String>()
        return segments.compactMap(\.speaker).filter { seen.insert($0).inserted }
    }

    /// "Priya", or "Speaker 2" until the user names them.
    func speakerName(_ id: String) -> String {
        let named = speakerNames[id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return named.isEmpty ? "Speaker \(id)" : named
    }

    /// The default title: what and when ("Meeting, 28 Oct at 14:05").
    static func defaultTitle(source: VoiceNoteSource, date: Date) -> String {
        "\(source.displayName), \(date.formatted(.dateTime.day().month(.abbreviated))) at \(date.formatted(date: .omitted, time: .shortened))"
    }
}
