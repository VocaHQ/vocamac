// LipBeamSearch.swift
// VocaMac
//
// Joint CTC/attention beam search for the lip reader, as Auto-AVSR decodes:
// the attention decoder proposes the next token, the CTC head checks that
// the whole prefix still fits the frames, and the best few prefixes are
// kept at each step. On 60 LRS3 test clips this reads 26.3% of words wrong
// against 32.5% for picking the best token per frame (greedy CTC).
//
// Pure apart from the decoder step, which is passed in, so it is tested
// with a stand-in decoder.

import Foundation

enum LipBeamSearch {
    struct Configuration: Equatable, Sendable {
        /// Prefixes kept per step. The Core ML decoder takes exactly this many rows.
        var beamWidth = 10
        /// Weight of the CTC prefix score; the decoder gets the rest.
        var ctcWeight: Float = 0.1
        /// Candidate tokens per prefix, by decoder score, before CTC scoring.
        var preBeamWidth = 15
        /// Longest prefix the decoder takes, start token included.
        var maximumLength = 64
    }

    /// One frame-by-token table of CTC log-probabilities, row-major [frames × vocabulary].
    struct CTCScores {
        let frames: Int
        let vocabulary: Int
        let values: [Float]

        @inline(__always) func at(_ frame: Int, _ token: Int) -> Float { values[frame * vocabulary + token] }
    }

    /// A prefix's CTC state: the log-probability of the frames up to `t`
    /// ending in the prefix's last token (`nonBlank`) or in a blank, and
    /// the prefix score (all ways the frames can begin with the prefix).
    struct PrefixState {
        var nonBlank: [Float]
        var blank: [Float]
        var score: Float
    }

    private struct Hypothesis {
        var tokens: [Int]
        var score: Float
        var ctc: PrefixState
    }

    /// The best token sequence (start token excluded, end token dropped).
    ///
    /// - Parameters:
    ///   - ctc: The CTC head's log-probabilities; token 0 is the blank and the
    ///     last token is both the start and the end of a sentence.
    ///   - step: The decoder: for `beamWidth` prefixes (padded), their log-
    ///     probabilities for the next token after `position`.
    static func decode(
        ctc: CTCScores, configuration: Configuration = Configuration(),
        step: ([[Int]], Int) throws -> [[Float]]
    ) rethrows -> [Int] {
        let end = ctc.vocabulary - 1
        guard ctc.frames > 0 else { return [] }
        var initialBlank = [Float](repeating: 0, count: ctc.frames)
        var running: Float = 0
        for frame in 0..<ctc.frames {
            running += ctc.at(frame, 0)
            initialBlank[frame] = running
        }
        var hypotheses = [Hypothesis(
            tokens: [end], score: 0,
            ctc: PrefixState(nonBlank: [Float](repeating: -.infinity, count: ctc.frames), blank: initialBlank, score: 0)
        )]
        var ended: [(tokens: [Int], score: Float)] = []
        let decoderWeight = 1 - configuration.ctcWeight

        for position in 0..<min(ctc.frames, configuration.maximumLength - 1) {
            var batch = hypotheses.map(\.tokens)
            while batch.count < configuration.beamWidth { batch.append(batch.last ?? [end]) }
            let decoded = try step(Array(batch.prefix(configuration.beamWidth)), position)

            var candidates: [(score: Float, hypothesis: Int, token: Int, ctc: PrefixState?)] = []
            for (index, hypothesis) in hypotheses.enumerated() {
                let scores = decoded[index]
                let last = hypothesis.tokens.count > 1 ? hypothesis.tokens.last : nil
                for token in topTokens(scores, count: configuration.preBeamWidth) {
                    let (state, prefixScore) = extend(hypothesis.ctc, last: last, token: token, end: end, ctc: ctc)
                    let total = hypothesis.score + decoderWeight * scores[token]
                        + configuration.ctcWeight * (prefixScore - hypothesis.ctc.score)
                    candidates.append((total, index, token, state.map { PrefixState(nonBlank: $0.nonBlank, blank: $0.blank, score: prefixScore) }))
                }
            }
            candidates.sort { $0.score > $1.score }

            var next: [Hypothesis] = []
            for candidate in candidates.prefix(configuration.beamWidth) {
                let tokens = hypotheses[candidate.hypothesis].tokens + [candidate.token]
                if candidate.token == end {
                    ended.append((tokens, candidate.score))
                } else if let state = candidate.ctc {
                    next.append(Hypothesis(tokens: tokens, score: candidate.score, ctc: state))
                }
            }
            hypotheses = next
            // Scores only fall as prefixes grow, so once a finished sentence
            // beats every open one, nothing can overtake it.
            guard let bestOpen = hypotheses.map(\.score).max() else { break }
            if let bestEnded = ended.map(\.score).max(), bestEnded > bestOpen { break }
        }
        let best = ended.max { $0.score < $1.score }?.tokens ?? hypotheses.first?.tokens ?? []
        return best.dropFirst().filter { $0 != end }
    }

    /// The `count` highest-scoring token ids.
    static func topTokens(_ scores: [Float], count: Int) -> [Int] {
        guard count < scores.count else { return Array(scores.indices) }
        var best: [(Int, Float)] = []
        best.reserveCapacity(count + 1)
        for (token, score) in scores.enumerated() {
            guard best.count < count || score > best[best.count - 1].1 else { continue }
            let insertAt = best.firstIndex { score > $0.1 } ?? best.count
            best.insert((token, score), at: insertAt)
            if best.count > count { best.removeLast() }
        }
        return best.map(\.0)
    }

    @inline(__always) static func logAdd(_ a: Float, _ b: Float) -> Float {
        if a == -.infinity { return b }
        if b == -.infinity { return a }
        let larger = max(a, b)
        return larger + log1p(exp(-abs(a - b)))
    }

    /// The CTC state and prefix score after appending `token` to a prefix
    /// whose last token is `last` (nil for the empty prefix). For the end
    /// token, the score is the probability of the whole prefix as the
    /// sentence, and there is no further state.
    static func extend(
        _ state: PrefixState, last: Int?, token: Int, end: Int, ctc: CTCScores
    ) -> (state: (nonBlank: [Float], blank: [Float])?, score: Float) {
        let frames = ctc.frames
        if token == end {
            return (nil, logAdd(state.nonBlank[frames - 1], state.blank[frames - 1]))
        }
        var nonBlank = [Float](repeating: -.infinity, count: frames)
        var blank = [Float](repeating: -.infinity, count: frames)
        nonBlank[0] = last == nil ? ctc.at(0, token) : -.infinity
        var score = nonBlank[0]
        for frame in 1..<max(frames, 1) {
            // A repeated token needs a blank between its two copies.
            let previous = token == last ? state.blank[frame - 1] : logAdd(state.nonBlank[frame - 1], state.blank[frame - 1])
            let emit = ctc.at(frame, token)
            nonBlank[frame] = logAdd(nonBlank[frame - 1], previous) + emit
            blank[frame] = logAdd(nonBlank[frame - 1], blank[frame - 1]) + ctc.at(frame, 0)
            score = logAdd(score, previous + emit)
        }
        return ((nonBlank, blank), score)
    }
}
