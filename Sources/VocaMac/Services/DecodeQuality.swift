// DecodeQuality.swift
// VocaMac
//
// How sure a decoder was of a transcript, from the per-segment scores
// Whisper reports (and Whisper-compatible servers return in verbose JSON).
//
// Whisper's reference decoder retries a window at a higher temperature when
// its average log-probability is below -1 or its text compresses better than
// 2.4 (it repeats itself), and treats a window as silence when the
// no-speech probability is above 0.6 and the log-probability is low too.
// VocaMac decodes greedily with no fallback for speed; these scores decide
// the one retry it does allow, and give the hallucination guard a second
// opinion when the voice activity detector did not run.

import Foundation

struct DecodeQuality: Equatable, Sendable {
    /// Mean token log-probability, weighted by segment length.
    var averageLogProbability: Double
    /// Largest compression ratio of any segment (higher: more repetitive).
    var compressionRatio: Double
    /// Largest no-speech probability, or nil when the decoder doesn't
    /// compute one. WhisperKit 1.1 always reports 0 (its `TextDecoder`
    /// leaves the no-speech probability unimplemented), so it is ignored there.
    var noSpeechProbability: Double?

    /// Whisper's thresholds.
    static let lowLogProbability = -1.0
    static let highCompressionRatio = 2.4
    static let noSpeechThreshold = 0.6
    /// Far below `lowLogProbability`: the decoder was guessing throughout.
    static let guessingLogProbability = -1.5

    /// One segment's scores and how much text it holds (its weight).
    struct Segment: Equatable, Sendable {
        var averageLogProbability: Double
        var compressionRatio: Double
        var noSpeechProbability: Double?
        var weight: Int
    }

    /// The combined quality of `segments`, or nil when there are none.
    init?(segments: [Segment]) {
        guard !segments.isEmpty else { return nil }
        let totalWeight = segments.reduce(0) { $0 + max(1, $1.weight) }
        averageLogProbability = segments.reduce(0) {
            $0 + $1.averageLogProbability * Double(max(1, $1.weight))
        } / Double(totalWeight)
        compressionRatio = segments.map(\.compressionRatio).max() ?? 0
        let noSpeech = segments.compactMap(\.noSpeechProbability)
        noSpeechProbability = noSpeech.isEmpty ? nil : noSpeech.max()
    }

    init(averageLogProbability: Double, compressionRatio: Double, noSpeechProbability: Double? = nil) {
        self.averageLogProbability = averageLogProbability
        self.compressionRatio = compressionRatio
        self.noSpeechProbability = noSpeechProbability
    }

    /// Whisper's own test for a window it should decode again.
    var needsRetry: Bool {
        averageLogProbability < Self.lowLogProbability || compressionRatio > Self.highCompressionRatio
    }

    /// Whether the decoder's own scores say no one spoke: Whisper's
    /// silence rule when a no-speech probability exists, and otherwise a
    /// decode it was guessing at from start to end.
    var suggestsNoSpeech: Bool {
        if let noSpeechProbability, noSpeechProbability > 0 {
            return noSpeechProbability > Self.noSpeechThreshold
                && averageLogProbability < Self.lowLogProbability
        }
        return averageLogProbability < Self.guessingLogProbability
    }

    /// Whether `self`, a retry, is better than `original`: more confident,
    /// and no more repetitive past Whisper's limit than it was.
    func isBetter(than original: DecodeQuality) -> Bool {
        guard averageLogProbability > original.averageLogProbability else { return false }
        if compressionRatio > Self.highCompressionRatio {
            return compressionRatio < original.compressionRatio
        }
        return true
    }
}
