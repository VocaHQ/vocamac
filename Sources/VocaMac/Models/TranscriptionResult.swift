// TranscriptionResult.swift
// VocaMac
//
// Represents the output of a VocaMac transcription.
// Named VocaTranscription to avoid collision with WhisperKit's TranscriptionResult.

import Foundation

struct VocaTranscription: Identifiable {
    /// Unique identifier for this transcription
    let id: UUID

    /// The transcribed text
    let text: String

    /// Time taken to perform the transcription (seconds)
    let duration: TimeInterval

    /// Detected or specified language (ISO 639-1 code)
    let detectedLanguage: String

    /// When the transcription was performed
    let timestamp: Date

    /// Length of the source audio in seconds
    let audioLengthSeconds: Double

    /// Which model was used for this transcription
    let modelUsed: ModelSize

    /// The pieces a live session decoded while recording, in order, when it
    /// ran in commit mode. Empty for a batch result.
    let pieces: [TranscribedPiece]

    /// The transcript's stretches with where they sit in the source audio,
    /// and each word's timing when the engine reports one (WhisperKit does;
    /// the other engines leave `segments` empty). Seconds on the recording's
    /// own timeline — silence trimmed away before the decode is mapped back.
    var segments: [TimedSegment]

    init(
        text: String,
        duration: TimeInterval,
        detectedLanguage: String,
        audioLengthSeconds: Double,
        modelUsed: ModelSize,
        timestamp: Date = Date(),
        pieces: [TranscribedPiece] = [],
        segments: [TimedSegment] = []
    ) {
        self.id = UUID()
        self.text = text
        self.duration = duration
        self.detectedLanguage = detectedLanguage
        self.timestamp = timestamp
        self.audioLengthSeconds = audioLengthSeconds
        self.modelUsed = modelUsed
        self.pieces = pieces
        self.segments = segments
    }
}

/// One word (or word piece) an engine heard, with where it sits in the
/// source audio.
struct TimedWord: Codable, Equatable, Sendable {
    var word: String
    /// Seconds into the source audio.
    var start: Double
    /// Seconds into the source audio.
    var end: Double
    /// Decoder confidence between 0 and 1, when the engine reports one.
    var probability: Double?

    /// This word on another timeline: its times passed through `transform`
    /// (e.g. mapped back to an untrimmed recording, or shifted into place
    /// within a longer one).
    func mappingTimes(_ transform: (Double) -> Double) -> TimedWord {
        TimedWord(
            word: word, start: transform(start), end: transform(end),
            probability: probability
        )
    }
}

/// A stretch of transcript with where it sits in the source audio. `words`
/// carries each word's timing for engines that report them; a segment can
/// still have its own range when they don't (a committed piece, for one).
struct TimedSegment: Codable, Equatable, Sendable {
    /// Seconds into the source audio.
    var start: Double
    /// Seconds into the source audio.
    var end: Double
    var text: String
    var words: [TimedWord]

    init(start: Double, end: Double, text: String, words: [TimedWord] = []) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }

    /// A committed piece as a segment: its sample range in the recording is
    /// its timing. Piece-level only — see `decodeCommitted` for word timings.
    init(piece: TranscribedPiece) {
        self.init(
            start: Double(piece.range.lowerBound) / 16_000,
            end: Double(piece.range.upperBound) / 16_000,
            text: piece.text, words: []
        )
    }

    /// This segment on another timeline: its times, and its words', passed
    /// through `transform`.
    func mappingTimes(_ transform: (Double) -> Double) -> TimedSegment {
        TimedSegment(
            start: transform(start), end: transform(end), text: text,
            words: words.map { $0.mappingTimes(transform) }
        )
    }
}

/// Formats a position inside a recording for display.
enum TranscriptTimestamp {
    /// `m:ss.d` (e.g. "1:23.4"), clamped at 0.
    static func display(_ seconds: Double) -> String {
        let total = max(0, seconds)
        var minutes = Int(total) / 60
        var remainder = total - Double(minutes * 60)
        if remainder >= 59.95 {
            minutes += 1
            remainder = 0
        }
        return String(format: "%d:%04.1f", minutes, remainder)
    }
}

/// One stretch of a recording, decoded on its own while the user was still
/// speaking. Final once decoded: unlike a live preview it is never revised.
struct TranscribedPiece: Equatable, Sendable {
    /// Sample range in the complete 16 kHz recording.
    let range: Range<Int>
    let text: String
    /// What the engine reported for this piece.
    let language: String

    /// Join piece texts the way the transcript reads: a space between pieces,
    /// except between two pieces of a script written without spaces (Chinese,
    /// Japanese), where a space would be an error.
    static func join(_ texts: [String]) -> String {
        var joined = ""
        for text in texts {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let last = joined.unicodeScalars.last, let first = trimmed.unicodeScalars.first {
                if !(isUnspacedScript(last) && isUnspacedScript(first)) {
                    joined += " "
                }
            }
            joined += trimmed
        }
        return joined
    }

    static func join(_ pieces: [TranscribedPiece]) -> String {
        join(pieces.map(\.text))
    }

    /// Han, kana, CJK punctuation, and full-width forms. Korean uses spaces
    /// between words, so Hangul is not included.
    static func isUnspacedScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,   // CJK symbols and punctuation
             0x3040...0x30FF,   // Hiragana, Katakana
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0xFF00...0xFFEF,   // Half- and full-width forms
             0x20000...0x2FA1F: // CJK Extensions B+
            return true
        default:
            return false
        }
    }
}
