// AudioSegmenter.swift
// VocaMac
//
// Splits a recording into segments short enough for engines that decode an
// utterance in a single pass. Cuts are placed at the quietest point near the
// target boundary so words are not sliced in half.

import Foundation

enum AudioSegmenter {

    /// Frame used when measuring loudness — 20ms at 16kHz.
    private static let frameLength = 320

    /// How far back from the target boundary to look for a quiet point.
    ///
    /// Wide enough to reach the previous sentence break in continuous speech.
    /// A narrow window often finds only a within-phrase dip, and cutting
    /// there splits a word — the following segment then starts mid-word and
    /// the model invents something to fit. Segments come out shorter, which
    /// costs a little speed but keeps the joins clean.
    private static let searchWindowSeconds = 4.0

    /// Split `samples` into consecutive ranges no longer than `maxSeconds`.
    ///
    /// Audio already short enough is returned as a single range. Otherwise
    /// each cut is placed at the lowest-energy frame within the search window
    /// ending at the maximum length, which lands in a pause between words
    /// when there is one.
    static func segmentRanges(
        sampleCount: Int,
        maxSeconds: Double,
        sampleRate: Int = 16_000,
        energyAt: (Range<Int>) -> Float
    ) -> [Range<Int>] {
        let maxSamples = Int(maxSeconds * Double(sampleRate))
        guard maxSamples > 0, sampleCount > maxSamples else {
            return sampleCount > 0 ? [0..<sampleCount] : []
        }

        let searchSamples = min(Int(searchWindowSeconds * Double(sampleRate)), maxSamples / 2)
        var ranges: [Range<Int>] = []
        var start = 0

        while start < sampleCount {
            let remaining = sampleCount - start
            if remaining <= maxSamples {
                ranges.append(start..<sampleCount)
                break
            }

            let hardEnd = start + maxSamples
            let searchStart = max(start + frameLength, hardEnd - searchSamples)

            // Measure loudness across the window the cut may land in.
            var energies: [Float] = []
            var frameOffsets: [Int] = []
            var frameStart = searchStart
            while frameStart + frameLength <= hardEnd {
                energies.append(energyAt(frameStart..<(frameStart + frameLength)))
                frameOffsets.append(frameStart)
                frameStart += frameLength
            }

            let cutIndex = bestCutOffset(
                energies: energies,
                frameOffsets: frameOffsets,
                fallback: hardEnd
            )

            // Never emit an empty or backwards range.
            let cut = max(start + frameLength, min(cutIndex, hardEnd))
            ranges.append(start..<cut)
            start = cut
        }

        return ranges
    }

    /// Shortest run of quiet frames treated as a real pause rather than a dip
    /// inside a word. Stop consonants give a frame or two of near-silence, so
    /// cutting on those splits words; a gap between words runs longer.
    private static let minimumPauseFrames = 4

    /// Pick the sample offset to cut at, preferring the middle of the longest
    /// pause in the window.
    ///
    /// Quiet is judged relative to this window rather than by a fixed level,
    /// so it holds for both a whisper and a loud room. When speech never
    /// pauses there is no good cut, and the quietest single frame is used.
    private static func bestCutOffset(
        energies: [Float],
        frameOffsets: [Int],
        fallback: Int
    ) -> Int {
        guard !energies.isEmpty else { return fallback }

        let sorted = energies.sorted()
        // A percentile alone marks flat/continuous sound as quiet and can
        // bury short pauses when they occupy less than a quarter of the window.
        // Require a 10 dB energy drop relative to the louder frames as well.
        let quietThreshold = min(sorted[sorted.count / 4], sorted[sorted.count * 3 / 4] * 0.1)

        var bestStart = 0, bestLength = 0
        var runStart = 0, runLength = 0
        for (index, energy) in energies.enumerated() {
            if energy <= quietThreshold {
                if runLength == 0 { runStart = index }
                runLength += 1
                if runLength > bestLength {
                    bestLength = runLength
                    bestStart = runStart
                }
            } else {
                runLength = 0
            }
        }

        if bestLength >= minimumPauseFrames {
            let middle = bestStart + bestLength / 2
            return frameOffsets[min(middle, frameOffsets.count - 1)] + frameLength / 2
        }

        // With no meaningful energy dip, use the full window instead of
        // inventing an early boundary in continuous sound.
        guard let minimum = sorted.first, minimum <= quietThreshold else { return fallback }

        // No sustained pause — fall back to the single quietest frame.
        var quietestIndex = 0
        for (index, energy) in energies.enumerated() where energy < energies[quietestIndex] {
            quietestIndex = index
        }
        return frameOffsets[quietestIndex] + frameLength / 2
    }

    /// Convenience wrapper that measures energy directly from the samples.
    static func segment(_ samples: [Float], maxSeconds: Double, sampleRate: Int = 16_000) -> [[Float]] {
        let ranges = segmentRanges(
            sampleCount: samples.count,
            maxSeconds: maxSeconds,
            sampleRate: sampleRate
        ) { range in
            var sum: Float = 0
            for i in range { sum += samples[i] * samples[i] }
            return sum / Float(range.count)
        }

        if ranges.count <= 1 {
            return samples.isEmpty ? [] : [samples]
        }
        return ranges.map { Array(samples[$0]) }
    }
}
