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

    init(
        text: String,
        duration: TimeInterval,
        detectedLanguage: String,
        audioLengthSeconds: Double,
        modelUsed: ModelSize,
        timestamp: Date = Date(),
        pieces: [TranscribedPiece] = []
    ) {
        self.id = UUID()
        self.text = text
        self.duration = duration
        self.detectedLanguage = detectedLanguage
        self.timestamp = timestamp
        self.audioLengthSeconds = audioLengthSeconds
        self.modelUsed = modelUsed
        self.pieces = pieces
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
