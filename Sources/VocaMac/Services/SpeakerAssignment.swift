// SpeakerAssignment.swift
// VocaMac
//
// Puts names to a transcript: given what the speech engine heard (timed
// segments, with word timings when the engine reports them) and when each
// speaker talked (the diarizer's turns), say who said each stretch. Pure, so
// it is tested without audio.

import Foundation

/// When one speaker talked, in seconds into the audio.
struct SpeakerTurn: Equatable, Sendable {
    var start: Double
    var end: Double
    /// The diarizer's own label; renumbered by `SpeakerAssignment`.
    var speaker: String
}

enum SpeakerAssignment {
    /// A word with no overlapping turn goes to the nearest turn within this
    /// many seconds, else to the speaker before it.
    static let nearestTurnSeconds = 1.0

    /// The transcript as speaker-labelled segments, consecutive words of one
    /// speaker joined. Speakers are numbered "1", "2", … in the order they
    /// first talk. Without turns, segments keep their own boundaries and no
    /// speaker.
    static func assign(segments: [TimedSegment], turns: [SpeakerTurn]) -> [VoiceNoteSegment] {
        let ordered = segments.sorted { $0.start < $1.start }
        guard !turns.isEmpty else {
            return ordered.compactMap { segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : VoiceNoteSegment(start: segment.start, end: segment.end, text: text, speaker: nil)
            }
        }
        let numbered = renumber(turns)

        var pieces: [(start: Double, end: Double, text: String, speaker: String?)] = []
        var previous: String?
        for segment in ordered {
            if segment.words.isEmpty {
                let speaker = speaker(from: segment.start, to: segment.end, turns: numbered) ?? previous
                pieces.append((segment.start, segment.end, segment.text, speaker))
                previous = speaker ?? previous
            } else {
                for word in segment.words {
                    let speaker = speaker(from: word.start, to: word.end, turns: numbered) ?? previous
                    pieces.append((word.start, word.end, word.word, speaker))
                    previous = speaker ?? previous
                }
            }
        }

        var result: [VoiceNoteSegment] = []
        var current: (start: Double, end: Double, parts: [String], speaker: String?)?
        for piece in pieces {
            if let open = current, open.speaker == piece.speaker {
                current = (open.start, max(open.end, piece.end), open.parts + [piece.text], open.speaker)
            } else {
                if let open = current { result.append(segment(from: open)) }
                current = (piece.start, piece.end, [piece.text], piece.speaker)
            }
        }
        if let open = current { result.append(segment(from: open)) }
        return result.filter { !$0.text.isEmpty }
    }

    private static func segment(from open: (start: Double, end: Double, parts: [String], speaker: String?)) -> VoiceNoteSegment {
        VoiceNoteSegment(start: open.start, end: open.end, text: joinWords(open.parts), speaker: open.speaker)
    }

    /// Turns with speakers renamed "1", "2", … by first appearance.
    static func renumber(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
        var names: [String: String] = [:]
        return turns.sorted { $0.start < $1.start }.map { turn in
            var renamed = turn
            if let name = names[turn.speaker] {
                renamed.speaker = name
            } else {
                let name = String(names.count + 1)
                names[turn.speaker] = name
                renamed.speaker = name
            }
            return renamed
        }
    }

    /// The speaker who talked most during `start...end`, else the nearest
    /// one within `nearestTurnSeconds`, else nil.
    static func speaker(from start: Double, to end: Double, turns: [SpeakerTurn]) -> String? {
        var overlap: [String: Double] = [:]
        for turn in turns {
            let shared = min(end, turn.end) - max(start, turn.start)
            if shared > 0 { overlap[turn.speaker, default: 0] += shared }
        }
        if let best = overlap.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) {
            return best.key
        }
        let middle = (start + end) / 2
        let nearest = turns.min { distance(middle, $0) < distance(middle, $1) }
        guard let nearest, distance(middle, nearest) <= nearestTurnSeconds else { return nil }
        return nearest.speaker
    }

    private static func distance(_ time: Double, _ turn: SpeakerTurn) -> Double {
        if time < turn.start { return turn.start - time }
        if time > turn.end { return time - turn.end }
        return 0
    }

    /// Words back into text. Engines that mark word starts with a leading
    /// space (WhisperKit's " Hello") are concatenated; bare words are joined
    /// with spaces, except punctuation, which sticks to the word before it.
    static func joinWords(_ words: [String]) -> String {
        if words.contains(where: { $0.first?.isWhitespace == true }) {
            return words.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var text = ""
        for word in words {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if text.isEmpty || trimmed.allSatisfy({ $0.isPunctuation && !"(\"“‘".contains($0) }) {
                text += trimmed
            } else {
                text += " " + trimmed
            }
        }
        return text
    }
}
