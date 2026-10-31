// SilentSpeechGate.swift
// VocaMac
//
// What a Silent Mode recording sends to the speech model, decided at the
// stop from what the camera saw.
//
// One-sided, like the cleanup gate: audio is dropped only where the camera
// had a clear view of still lips. Where it had no view (the camera warming
// up, the face turned away) the audio is kept. And when the camera saw too
// little of the recording to judge, the dictation goes through as usual.

import Foundation

enum SilentSpeechGate {

    /// What to do with the recording.
    enum Decision: Equatable {
        /// Decode only these sample ranges, in order: where the lips moved,
        /// plus anything the camera couldn't see.
        case speech([Range<Int>])
        /// The camera watched still lips the whole time: someone else was
        /// talking, or nothing was said. Nothing is decoded.
        case noArticulation
        /// The camera saw too little to judge; decode as an ordinary dictation.
        case notJudged(reason: String)
    }

    /// The camera must have seen the lips for at least this share of the
    /// recording before it may drop anything.
    static let minimumCoverage = 0.5

    /// Decide what to decode.
    ///
    /// - Parameters:
    ///   - timeline: What the camera saw, on the uptime clock.
    ///   - audioEnd: Uptime at the recording's last sample.
    ///   - sampleCount: Samples recorded.
    ///   - sampleRate: Samples per second.
    static func decide(
        timeline: ArticulationTimeline, audioEnd: TimeInterval, sampleCount: Int, sampleRate: Int = 16_000
    ) -> Decision {
        guard sampleCount > 0, sampleRate > 0 else { return .noArticulation }
        let duration = Double(sampleCount) / Double(sampleRate)
        let audioStart = audioEnd - duration
        let recording = audioStart...audioEnd

        let covered = clipped(timeline.covered, to: recording)
        let coveredSeconds = covered.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        guard coveredSeconds >= duration * minimumCoverage else {
            let percent = Int((coveredSeconds / duration * 100).rounded())
            return .notJudged(reason: "the camera saw the lips for \(percent)% of the recording")
        }

        let speaking = clipped(timeline.speaking, to: recording)
        guard !speaking.isEmpty else { return .noArticulation }

        // Keep the articulated stretches and every stretch the camera missed.
        // A sliver shorter than a missed frame or two is only frame spacing
        // at the recording's edges, not a blind spot.
        let uncovered = gaps(in: covered, within: recording)
            .filter { $0.upperBound - $0.lowerBound > ArticulationDetector.coverageGap }
        let kept = ArticulationDetector.merged(speaking + uncovered)
        let ranges: [Range<Int>] = kept.compactMap { range in
            let lower = max(0, Int(((range.lowerBound - audioStart) * Double(sampleRate)).rounded(.down)))
            let upper = min(sampleCount, Int(((range.upperBound - audioStart) * Double(sampleRate)).rounded(.up)))
            return lower < upper ? lower..<upper : nil
        }
        return ranges.isEmpty ? .noArticulation : .speech(ranges)
    }

    /// The parts of `ranges` inside `bounds`.
    static func clipped(_ ranges: [ClosedRange<TimeInterval>], to bounds: ClosedRange<TimeInterval>) -> [ClosedRange<TimeInterval>] {
        ranges.compactMap { range in
            let lower = max(range.lowerBound, bounds.lowerBound)
            let upper = min(range.upperBound, bounds.upperBound)
            return lower < upper ? lower...upper : nil
        }
    }

    /// The parts of `bounds` that no range in `ranges` covers.
    static func gaps(in ranges: [ClosedRange<TimeInterval>], within bounds: ClosedRange<TimeInterval>) -> [ClosedRange<TimeInterval>] {
        var result: [ClosedRange<TimeInterval>] = []
        var cursor = bounds.lowerBound
        for range in ArticulationDetector.merged(ranges) {
            if range.lowerBound > cursor { result.append(cursor...range.lowerBound) }
            cursor = max(cursor, range.upperBound)
        }
        if cursor < bounds.upperBound { result.append(cursor...bounds.upperBound) }
        return result
    }

    // MARK: Silent commands

    /// A command takes one short burst of movement and nothing else.
    static let longestCommand: TimeInterval = 2.0

    /// The frames of the one short burst of lip movement in `timeline`, when
    /// that is all the recording holds; nil for anything longer, which is
    /// dictation. Only these frames are matched against taught commands.
    static func commandFrames(_ frames: [LipFrame], timeline: ArticulationTimeline) -> [LipFrame]? {
        guard timeline.active.count == 1, let burst = timeline.active.first,
              burst.upperBound - burst.lowerBound <= longestCommand,
              let window = timeline.speaking.first(where: { $0.overlaps(burst) }) else { return nil }
        let slice = frames.filter { window.contains($0.time) && $0.usableShape != nil }
        return slice.count >= 4 ? slice : nil
    }

    /// The frames of a take being taught: from the first movement to the
    /// last, with the same lead-in and tail recognition uses. Nil when the
    /// lips didn't move or were out of view.
    static func takeFrames(_ frames: [LipFrame], sensitivity: Double) -> [LipFrame]? {
        let timeline = ArticulationDetector.timeline(for: frames, sensitivity: sensitivity)
        guard let first = timeline.speaking.first, let last = timeline.speaking.last else { return nil }
        let window = first.lowerBound...last.upperBound
        let slice = frames.filter { window.contains($0.time) && $0.usableShape != nil }
        return slice.count >= 4 ? slice : nil
    }
}
