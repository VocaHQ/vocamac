// LipBeamSearchTests.swift
// VocaMacTests
//
// The lip reader's beam search with a stand-in decoder: CTC prefix scores
// add up to the sequence probability, the decoder and CTC are weighed
// together, and the search stops with the best finished sentence.

import XCTest
@testable import VocaMac

final class LipBeamSearchTests: XCTestCase {
    // Tokens: 0 blank, 1 "▁A", 2 "▁B", 3 end.
    private let vocabulary = 4

    /// CTC scores where each frame strongly prefers one token.
    private func ctc(_ best: [Int], strength: Float = 0.9) -> LipBeamSearch.CTCScores {
        var values: [Float] = []
        for token in best {
            for candidate in 0..<vocabulary {
                let p: Float = candidate == token ? strength : (1 - strength) / Float(vocabulary - 1)
                values.append(log(p))
            }
        }
        return LipBeamSearch.CTCScores(frames: best.count, vocabulary: vocabulary, values: values)
    }

    func testThePrefixScoreOfAWholeSentenceIsItsProbability() {
        let scores = ctc([1, 1, 0, 2])
        var blank: [Float] = []
        var total: Float = 0
        for frame in 0..<scores.frames { total += scores.at(frame, 0); blank.append(total) }
        let empty = LipBeamSearch.PrefixState(nonBlank: [Float](repeating: -.infinity, count: 4), blank: blank, score: 0)
        let afterA = LipBeamSearch.extend(empty, last: nil, token: 1, end: 3, ctc: scores)
        let stateA = LipBeamSearch.PrefixState(nonBlank: afterA.state!.nonBlank, blank: afterA.state!.blank, score: afterA.score)
        let afterB = LipBeamSearch.extend(stateA, last: 1, token: 2, end: 3, ctc: scores)
        let stateB = LipBeamSearch.PrefixState(nonBlank: afterB.state!.nonBlank, blank: afterB.state!.blank, score: afterB.score)
        let sentence = LipBeamSearch.extend(stateB, last: 2, token: 3, end: 3, ctc: scores).score
        // Prefix scores never rise as the prefix grows.
        XCTAssertGreaterThanOrEqual(afterA.score, afterB.score)
        XCTAssertGreaterThanOrEqual(afterB.score, sentence)
        // "A B" is the likely reading of these frames.
        XCTAssertGreaterThan(sentence, log(0.3))
    }

    func testCTCPicksTheSentenceWhenTheDecoderHasNoOpinion() {
        let scores = ctc([1, 1, 0, 2, 2, 0])
        let tokens = LipBeamSearch.decode(ctc: scores, configuration: .init(beamWidth: 4, ctcWeight: 0.5, preBeamWidth: 4)) { prefixes, _ in
            prefixes.map { _ in [Float](repeating: log(0.25), count: 4) }
        }
        XCTAssertEqual(tokens, [1, 2])
    }

    func testTheDecoderBreaksATieTheFramesLeaveOpen() {
        // Frames can't tell "A" from "B" at the end; the decoder prefers B after A.
        var scores = ctc([1, 1, 0, 0])
        var values = scores.values
        for token in [1, 2] { values[3 * vocabulary + token] = log(0.45) }
        values[3 * vocabulary + 0] = log(0.05)
        scores = LipBeamSearch.CTCScores(frames: 4, vocabulary: vocabulary, values: values)
        let tokens = LipBeamSearch.decode(ctc: scores, configuration: .init(beamWidth: 4, ctcWeight: 0.3, preBeamWidth: 4)) { prefixes, _ in
            prefixes.map { prefix in
                prefix.last == 1 ? [log(0.01), log(0.01), log(0.97), log(0.01)] : [log(0.01), log(0.6), log(0.2), log(0.19)]
            }
        }
        XCTAssertEqual(tokens.first, 1)
    }

    func testEveryDecoderCallGetsAFullBatch() {
        var sizes: [Int] = []
        _ = LipBeamSearch.decode(ctc: ctc([1, 0, 2]), configuration: .init(beamWidth: 5, ctcWeight: 0.5, preBeamWidth: 3)) { prefixes, _ in
            sizes.append(prefixes.count)
            return prefixes.map { _ in [Float](repeating: log(0.25), count: 4) }
        }
        XCTAssertFalse(sizes.isEmpty)
        XCTAssertTrue(sizes.allSatisfy { $0 == 5 })
    }

    func testTopTokensAreTheHighestScores() {
        XCTAssertEqual(LipBeamSearch.topTokens([0.1, 0.9, 0.5, 0.7], count: 2), [1, 3])
        XCTAssertEqual(LipBeamSearch.topTokens([0.1, 0.9], count: 5), [0, 1])
    }

    func testLogAddHandlesNegativeInfinity() {
        XCTAssertEqual(LipBeamSearch.logAdd(-.infinity, log(0.5)), log(0.5))
        XCTAssertEqual(LipBeamSearch.logAdd(log(0.25), log(0.25)), log(0.5), accuracy: 1e-6)
    }
}

final class LipLightingTests: XCTestCase {
    private func clip(value: UInt8, contrast: UInt8 = 0) -> [MouthCrop] {
        (0..<4).map { index in
            MouthCrop(time: Double(index), pixels: (0..<100).map { $0 % 2 == 0 ? value &+ contrast : value })
        }
    }

    func testAWellLitClipIsUntouched() {
        let crops = clip(value: 90, contrast: 60)
        XCTAssertEqual(LipLighting.adjusted(crops), crops)
    }

    func testADarkFlatClipIsLifted() {
        let adjusted = LipLighting.adjusted(clip(value: 20, contrast: 10))
        let stats = LipLighting.statistics(adjusted)
        XCTAssertEqual(stats.mean, LipLighting.minimumMean, accuracy: 1)
        XCTAssertEqual(stats.deviation, LipLighting.minimumDeviation, accuracy: 1)
    }

    func testAUniformClipIsLeftAlone() {
        let crops = clip(value: 10)
        XCTAssertEqual(LipLighting.adjusted(crops), crops, "No contrast to stretch")
    }
}
