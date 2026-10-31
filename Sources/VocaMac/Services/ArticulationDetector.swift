// ArticulationDetector.swift
// VocaMac
//
// Finds when the lips were moving: Silent Mode's voice activity detector,
// built on the camera instead of the microphone, so it works for a whisper
// in a noisy room and ignores a colleague talking nearby.
//
// Two forms. `timeline(for:sensitivity:)` reads a whole recording at the
// stop and returns the stretches of articulation and of camera coverage.
// `ArticulationMeter` follows the live stream for the overlay's lip outline
// and level, one frame at a time.
//
// The thresholds are first estimates, measured in mouth widths moved per
// thirtieth of a second. The Sensitivity setting scales them, and the
// session statistics are logged so they can be tuned.

import Foundation

/// How readily lip movement counts as speech, from the Silent Mode page.
enum ArticulationSensitivity {
    static let range: ClosedRange<Double> = 0.5...2.0
    static let standard = 1.0

    static func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Stretches of a recording, in seconds on the frames' clock.
struct ArticulationTimeline: Equatable, Sendable {
    /// When the camera could read the lips.
    var covered: [ClosedRange<TimeInterval>]
    /// When the lips were moving, padded so the first and last sounds of a
    /// word are kept.
    var speaking: [ClosedRange<TimeInterval>]
    /// The same, unpadded: when the movement itself was above threshold.
    var active: [ClosedRange<TimeInterval>]
    /// For the log: the resting level, the threshold, and the highest level.
    var floor: Double
    var threshold: Double
    var peak: Double

    static let empty = ArticulationTimeline(covered: [], speaking: [], active: [], floor: 0, threshold: 0, peak: 0)

    /// Seconds covered by `covered`.
    var coveredSeconds: TimeInterval { covered.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }
}

enum ArticulationDetector {

    // MARK: Tunables

    /// Movement below this, at standard sensitivity, is a face at rest:
    /// tracker jitter, breathing, a swallow.
    static let minimumMotion = 0.018
    /// Speech moves the lips this many times more than the face at rest.
    static let floorMultiple = 2.5
    /// The resting level is a low percentile of the recording, but never
    /// above this: someone who mouths words all the way through has no
    /// resting frames to measure.
    static let restingCeiling = 0.02
    /// Kept before the first and after the last moving frame of a stretch.
    static let leadIn: TimeInterval = 0.3
    static let tail: TimeInterval = 0.35
    /// Pauses shorter than this stay inside one stretch.
    static let bridgedPause: TimeInterval = 0.35
    /// Movement shorter than this is a twitch, not a syllable. Smoothing
    /// spreads a one-frame twitch over four frames (0.13 s), so it is above that.
    static let minimumActive: TimeInterval = 0.16
    /// Frames further apart than this are separate stretches of coverage.
    static let coverageGap: TimeInterval = 0.25

    // MARK: Per-frame motion

    /// Motion for each frame with readable lips, against the previous such
    /// frame, scaled to a thirtieth of a second so the frame rate doesn't
    /// change it. The first frame of each covered stretch has no motion.
    static func motions(for frames: [LipFrame]) -> [(time: TimeInterval, motion: Double?)] {
        var result: [(TimeInterval, Double?)] = []
        result.reserveCapacity(frames.count)
        var previous: (time: TimeInterval, features: LipFeatures)?
        for frame in frames {
            guard let shape = frame.usableShape, let features = LipFeatures(shape) else {
                previous = nil
                continue
            }
            if let previous, frame.time - previous.time <= coverageGap, frame.time > previous.time {
                let perThirtieth = (1.0 / 30) / (frame.time - previous.time)
                result.append((frame.time, features.motion(from: previous.features) * min(perThirtieth, 3)))
            } else {
                result.append((frame.time, nil))
            }
            previous = (frame.time, features)
        }
        return result
    }

    /// The level above which motion is speech, given the recording's resting level.
    static func threshold(floor: Double, sensitivity: Double) -> Double {
        max(minimumMotion, floor * floorMultiple) / ArticulationSensitivity.clamped(sensitivity)
    }

    // MARK: Whole recording

    /// Where the camera saw the lips, and where they moved.
    static func timeline(for frames: [LipFrame], sensitivity: Double) -> ArticulationTimeline {
        let samples = motions(for: frames)
        let covered = coverage(of: samples.map(\.time))
        let levels = smoothed(samples)
        let measured = levels.compactMap(\.level).sorted()
        guard !measured.isEmpty else {
            return ArticulationTimeline(covered: covered, speaking: [], active: [], floor: 0, threshold: 0, peak: 0)
        }
        let floor = min(percentile(measured, 0.2), restingCeiling)
        let limit = threshold(floor: floor, sensitivity: sensitivity)
        let peak = measured.last ?? 0

        // Stretches of above-threshold motion, joined across short pauses.
        var active: [ClosedRange<TimeInterval>] = []
        for sample in levels {
            guard let level = sample.level, level > limit else { continue }
            if let last = active.last, sample.time - last.upperBound <= bridgedPause {
                active[active.count - 1] = last.lowerBound...sample.time
            } else {
                active.append(sample.time...sample.time)
            }
        }
        // Each frame's motion was measured over the interval before it.
        active = active
            .map { ($0.lowerBound - 1.0 / 30)...$0.upperBound }
            .filter { $0.upperBound - $0.lowerBound >= minimumActive }

        let speaking = merged(active.map { ($0.lowerBound - leadIn)...($0.upperBound + tail) })
        return ArticulationTimeline(
            covered: covered, speaking: speaking, active: active,
            floor: floor, threshold: limit, peak: peak
        )
    }

    /// Covered stretches from the times of readable frames.
    static func coverage(of times: [TimeInterval]) -> [ClosedRange<TimeInterval>] {
        var ranges: [ClosedRange<TimeInterval>] = []
        for time in times {
            if let last = ranges.last, time - last.upperBound <= coverageGap {
                ranges[ranges.count - 1] = last.lowerBound...time
            } else {
                ranges.append(time...time)
            }
        }
        // A lone frame stands for the moment around it.
        let half = 1.0 / 60
        return ranges.map { ($0.lowerBound - half)...($0.upperBound + half) }
    }

    /// Motion averaged over three neighbouring frames, so one noisy frame
    /// neither starts nor breaks a stretch.
    static func smoothed(_ samples: [(time: TimeInterval, motion: Double?)]) -> [(time: TimeInterval, level: Double?)] {
        samples.indices.map { index in
            guard samples[index].motion != nil else { return (samples[index].time, nil) }
            let neighbours = [index - 1, index, index + 1]
                .filter { samples.indices.contains($0) }
                .compactMap { samples[$0].motion }
            let level = neighbours.reduce(0, +) / Double(neighbours.count)
            return (samples[index].time, level)
        }
    }

    static func merged(_ ranges: [ClosedRange<TimeInterval>]) -> [ClosedRange<TimeInterval>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var result: [ClosedRange<TimeInterval>] = []
        for range in sorted {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}

// MARK: - Live meter

/// Follows the live frames for the overlay: whether a face is in view, how
/// much the lips are moving (0…1), and whether that counts as speaking.
struct ArticulationMeter {
    enum Reading: Equatable {
        /// No readable face for a while.
        case noFace
        /// A face, lips still.
        case still
        /// Lips moving above the threshold.
        case speaking
    }

    var sensitivity: Double = ArticulationSensitivity.standard
    private(set) var reading: Reading = .noFace
    /// Motion relative to the threshold, eased, 0…1.
    private(set) var level: Double = 0

    private var previous: (time: TimeInterval, features: LipFeatures)?
    private var lastFace: TimeInterval?
    private var smoothedMotion = 0.0
    /// The lowest recent motion, rising slowly so it follows the face at rest.
    private var floor = ArticulationDetector.restingCeiling
    private var speakingUntil: TimeInterval = 0

    /// Seconds without a face before the meter says so.
    static let faceLostAfter: TimeInterval = 0.5

    init(sensitivity: Double = ArticulationSensitivity.standard) {
        self.sensitivity = sensitivity
    }

    mutating func ingest(_ frame: LipFrame) {
        guard let shape = frame.usableShape, let features = LipFeatures(shape) else {
            previous = nil
            if let lastFace, frame.time - lastFace > Self.faceLostAfter {
                reading = .noFace
                level = 0
            } else if lastFace == nil {
                reading = .noFace
            }
            return
        }
        lastFace = frame.time
        defer { previous = (frame.time, features) }
        guard let previous, frame.time > previous.time,
              frame.time - previous.time <= ArticulationDetector.coverageGap else {
            if reading == .noFace { reading = .still }
            return
        }
        let perThirtieth = min((1.0 / 30) / (frame.time - previous.time), 3)
        let motion = features.motion(from: previous.features) * perThirtieth
        smoothedMotion = smoothedMotion * 0.5 + motion * 0.5
        // Down at once, up slowly: the floor tracks rest, not speech.
        floor = smoothedMotion < floor ? smoothedMotion : min(floor + 0.0004, ArticulationDetector.restingCeiling)
        let threshold = ArticulationDetector.threshold(floor: floor, sensitivity: sensitivity)
        if smoothedMotion > threshold {
            speakingUntil = frame.time + ArticulationDetector.tail
        }
        reading = frame.time <= speakingUntil ? .speaking : .still
        let target = min(smoothedMotion / (threshold * 2), 1)
        level += (target - level) * (target > level ? 0.6 : 0.2)
    }
}
