// AudioSegmenterTests.swift
// VocaMac Tests
//
// Tests for splitting long recordings into segments short enough for
// engines that decode an utterance in a single pass.

import XCTest

@testable import VocaMac

final class AudioSegmenterTests: XCTestCase {

    private let sampleRate = 16_000

    /// Tone of a given length, used as "speech" that should not be cut.
    private func tone(seconds: Double, amplitude: Float = 0.3) -> [Float] {
        let count = Int(seconds * Double(sampleRate))
        return (0..<count).map { sin(2.0 * .pi * 440.0 * Float($0) / Float(sampleRate)) * amplitude }
    }

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(sampleRate)))
    }

    func testShortAudioIsNotSplit() {
        let audio = tone(seconds: 3)
        let segments = AudioSegmenter.segment(audio, maxSeconds: 8)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.count, audio.count)
    }

    func testEmptyAudioProducesNoSegments() {
        XCTAssertTrue(AudioSegmenter.segment([], maxSeconds: 8).isEmpty)
    }

    func testAudioExactlyAtLimitIsNotSplit() {
        let audio = tone(seconds: 8)
        XCTAssertEqual(AudioSegmenter.segment(audio, maxSeconds: 8).count, 1)
    }

    func testLongAudioIsSplitIntoSegmentsWithinTheLimit() {
        let audio = tone(seconds: 30)
        let segments = AudioSegmenter.segment(audio, maxSeconds: 8)

        XCTAssertGreaterThan(segments.count, 1)
        for segment in segments {
            let seconds = Double(segment.count) / Double(sampleRate)
            XCTAssertLessThanOrEqual(seconds, 8.0 + 0.001, "segment exceeds the model's limit")
            XCTAssertGreaterThan(segment.count, 0)
        }
    }

    func testSegmentsCoverTheWholeRecordingWithoutOverlap() {
        let audio = tone(seconds: 25)
        let segments = AudioSegmenter.segment(audio, maxSeconds: 8)

        // Every sample must be transcribed exactly once, or words go missing.
        XCTAssertEqual(segments.reduce(0) { $0 + $1.count }, audio.count)
    }

    func testCutsLandInSilenceRatherThanMidWord() {
        // Speech, a clear pause, then more speech. The pause sits before the
        // 8s limit, so that is where the cut belongs.
        let audio = tone(seconds: 6.5) + silence(seconds: 1.0) + tone(seconds: 10)
        let segments = AudioSegmenter.segment(audio, maxSeconds: 8)

        let firstLength = Double(segments[0].count) / Double(sampleRate)
        XCTAssertGreaterThan(firstLength, 6.4, "cut before the pause would clip speech")
        XCTAssertLessThan(firstLength, 7.6, "cut after the pause would clip the next phrase")
    }

    func testPrefersALongPauseOverABrieferDip() {
        // A stop consonant gives a frame or two of near-silence; a gap
        // between phrases runs much longer. Cutting on the short dip would
        // split a word, so the longer pause wins even though the dip sits
        // closer to the limit. Both are inside the search window, which
        // reaches back 4s from the 8s limit.
        let audio = tone(seconds: 5.0)
            + silence(seconds: 0.5)     // real pause at 5.0s
            + tone(seconds: 1.4)
            + silence(seconds: 0.04)    // brief dip at 6.9s
            + tone(seconds: 10)
        let segments = AudioSegmenter.segment(audio, maxSeconds: 8)

        let firstLength = Double(segments[0].count) / Double(sampleRate)
        XCTAssertGreaterThan(firstLength, 4.9, "cut before the pause clips speech")
        XCTAssertLessThan(firstLength, 5.6, "cut should land in the long pause, not the brief dip")
    }

    func testBriefPauseIsNotHiddenByTheLoudnessPercentile() {
        var audio = [Float](repeating: 0.2, count: 160_000)
        audio.replaceSubrange(112_000..<116_800, with: repeatElement(Float.zero, count: 4_800))
        let segments = AudioSegmenter.segment(audio, maxSeconds: 8)
        XCTAssertTrue((112_000..<116_800).contains(segments[0].count),
                      "A 300 ms pause must win over continuous sound")
    }

    func testConstantEnergyDoesNotInventAPauseHalfwayThroughTheWindow() {
        let segments = AudioSegmenter.segment([Float](repeating: 0.2, count: 160_000), maxSeconds: 8)
        XCTAssertEqual(segments[0].count, 128_000)
        XCTAssertEqual(segments.flatMap { $0 }, [Float](repeating: 0.2, count: 160_000))
    }

    func testContinuousSpeechStillTerminates() {
        // No pause anywhere: the segmenter must still make progress rather
        // than loop or emit empty ranges.
        let audio = tone(seconds: 40)
        let segments = AudioSegmenter.segment(audio, maxSeconds: 8)

        XCTAssertGreaterThanOrEqual(segments.count, 5)
        XCTAssertTrue(segments.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(segments.reduce(0) { $0 + $1.count }, audio.count)
    }
}
