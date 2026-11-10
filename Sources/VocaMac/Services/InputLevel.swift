// InputLevel.swift
// VocaMac
//
// How loud a recording is, and a bounded gain for one that is too quiet.
//
// Samples reach the engines as the microphone delivered them. A low-gain
// mic or a whisper can peak far below full scale, and the voice activity
// detector then finds no speech and the dictation ends as "Didn't catch
// that." Lifting a quiet recording's peak before the detector and the
// decode gives both a level they were trained on. The gain is capped, and
// near-digital silence is never lifted, so room noise is not turned into
// something that sounds like speech; the detector still has to find speech
// in the lifted copy, and the hallucination guard still applies when it
// only finds speech-like frames.

import Foundation

enum InputLevel {

    /// A recording's loudness.
    struct Measurement: Equatable, Sendable {
        /// Largest absolute sample, 0...1 for in-range audio.
        var peak: Float
        /// Root mean square over the whole recording.
        var rms: Float
        /// Share of samples at or above `clippingLevel`.
        var clippedFraction: Double

        var peakDecibels: Float { InputLevel.decibels(peak) }
        var rmsDecibels: Float { InputLevel.decibels(rms) }
    }

    /// Something worth telling the user about the microphone level.
    enum Warning: Equatable, Sendable {
        /// Speech this quiet is often missed; the mic gain may be too low.
        case tooQuiet
        /// Sustained clipping distorts words; the mic gain may be too high.
        case clipping
    }

    /// A sample at or above this is clipped.
    static let clippingLevel: Float = 0.99

    /// Share of clipped samples that counts as sustained clipping rather
    /// than one plosive hitting the limit (0.1%, 16 samples a second).
    static let clippingFraction = 0.001

    /// Peaks below this (about -26 dBFS) are lifted. Normal dictation on a
    /// built-in mic peaks well above it.
    static let quietPeak: Float = 0.05

    /// What a lifted recording's peak is raised to (about -6 dBFS).
    static let targetPeak: Float = 0.5

    /// Most gain ever applied: 20 dB.
    static let maximumGain: Float = 10

    /// Below this RMS (about -70 dBFS) the recording is digital silence or
    /// the mic is muted; lifting it would only amplify noise.
    static let silenceRMS: Float = 0.000_3

    /// Peaks below this (about -40 dBFS) with real signal in them get a
    /// "mic is too quiet" note when nothing was heard.
    static let tooQuietPeak: Float = 0.01

    static func decibels(_ value: Float) -> Float {
        value > 0 ? 20 * log10(value) : -.infinity
    }

    static func measure(_ samples: [Float]) -> Measurement {
        guard !samples.isEmpty else { return Measurement(peak: 0, rms: 0, clippedFraction: 0) }
        var peak: Float = 0
        var sumSquares: Double = 0
        var clipped = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
            sumSquares += Double(sample) * Double(sample)
            if magnitude >= clippingLevel { clipped += 1 }
        }
        return Measurement(
            peak: peak,
            rms: Float((sumSquares / Double(samples.count)).squareRoot()),
            clippedFraction: Double(clipped) / Double(samples.count)
        )
    }

    /// The gain that lifts a quiet recording's peak to `targetPeak`, capped
    /// at `maximumGain`; 1 for a recording loud enough already, or one that
    /// is silence.
    static func gain(for level: Measurement) -> Float {
        guard level.peak > 0, level.peak < quietPeak, level.rms >= silenceRMS else { return 1 }
        return min(maximumGain, targetPeak / level.peak)
    }

    /// `samples` multiplied by `gain`, clamped to full scale.
    static func applying(_ gain: Float, to samples: [Float]) -> [Float] {
        guard gain != 1 else { return samples }
        return samples.map { max(-1, min(1, $0 * gain)) }
    }

    /// What, if anything, to say about this level.
    static func warning(for level: Measurement) -> Warning? {
        if level.clippedFraction >= clippingFraction { return .clipping }
        if level.rms >= silenceRMS, level.peak < tooQuietPeak { return .tooQuiet }
        return nil
    }
}
