// SilentSpeechGateTests.swift
// VocaMacTests
//
// What a Silent Mode recording sends to the speech model: the stretches the
// lips moved in, anything the camera missed, nothing when it watched still
// lips, and everything when it saw too little to judge.

import XCTest
@testable import VocaMac

final class SilentSpeechGateTests: XCTestCase {
    private let rate = 16_000

    /// A 3-second recording ending at uptime 103.
    private let audioEnd: TimeInterval = 103
    private var sampleCount: Int { 3 * rate }

    private func decide(_ frames: [LipFrame]) -> SilentSpeechGate.Decision {
        let timeline = ArticulationDetector.timeline(for: frames, sensitivity: 1)
        return SilentSpeechGate.decide(timeline: timeline, audioEnd: audioEnd, sampleCount: sampleCount, sampleRate: rate)
    }

    func testOnlyTheArticulatedStretchIsKept() throws {
        let frames = LipFrameFactory.still(from: 100, seconds: 1)
            + LipFrameFactory.speaking(from: 101, seconds: 1)
            + LipFrameFactory.still(from: 102, seconds: 1)
        guard case .speech(let ranges) = decide(frames) else { return XCTFail("Expected speech") }
        XCTAssertEqual(ranges.count, 1)
        let range = try XCTUnwrap(ranges.first)
        // About 1 s of movement, padded by the lead-in and tail.
        let seconds = Double(range.count) / Double(rate)
        XCTAssertEqual(seconds, 1 + ArticulationDetector.leadIn + ArticulationDetector.tail, accuracy: 0.25)
        XCTAssertEqual(Double(range.lowerBound) / Double(rate), 1 - ArticulationDetector.leadIn, accuracy: 0.15)
    }

    func testStillLipsTheWholeTimeDecodeNothing() {
        XCTAssertEqual(decide(LipFrameFactory.still(from: 100, seconds: 3)), .noArticulation)
    }

    func testTooLittleCoverageIsNotJudged() {
        let frames = LipFrameFactory.noFace(from: 100, seconds: 2) + LipFrameFactory.still(from: 102, seconds: 1)
        guard case .notJudged = decide(frames) else { return XCTFail("Expected not judged") }
    }

    func testNoFramesAtAllIsNotJudged() {
        guard case .notJudged = decide([]) else { return XCTFail("Expected not judged") }
    }

    /// The camera came up a second late: what was said before it could see
    /// is kept, since it can't say the lips were still.
    func testAudioBeforeTheCameraStartedIsKept() throws {
        let frames = LipFrameFactory.speaking(from: 101, seconds: 0.8)
            + LipFrameFactory.still(from: 101.8, seconds: 1.2)
        guard case .speech(let ranges) = decide(frames) else { return XCTFail("Expected speech") }
        XCTAssertEqual(ranges.first?.lowerBound, 0, "The uncovered start is kept")
    }

    func testRangesStayInsideTheRecording() {
        let frames = LipFrameFactory.speaking(from: 99, seconds: 5)
        guard case .speech(let ranges) = decide(frames) else { return XCTFail("Expected speech") }
        XCTAssertEqual(ranges, [0..<sampleCount])
    }

    func testGapsAndClipping() {
        let gaps = SilentSpeechGate.gaps(in: [1...2, 3...4], within: 0...5)
        XCTAssertEqual(gaps, [0...1, 2...3, 4...5])
        XCTAssertEqual(SilentSpeechGate.clipped([-1...1, 4...9], to: 0...5), [0...1, 4...5])
    }

    // MARK: Commands

    func testOneShortBurstIsACommandCandidate() throws {
        let frames = LipFrameFactory.still(from: 100, seconds: 1)
            + LipFrameFactory.speaking(from: 101, seconds: 0.6)
            + LipFrameFactory.still(from: 101.6, seconds: 1)
        let timeline = ArticulationDetector.timeline(for: frames, sensitivity: 1)
        let burst = try XCTUnwrap(SilentSpeechGate.commandFrames(frames, timeline: timeline))
        XCTAssertGreaterThan(burst.count, 18)
        XCTAssertLessThan(burst.count, 45)
    }

    func testTwoBurstsOrALongOneAreDictation() {
        let two = LipFrameFactory.speaking(from: 100, seconds: 0.6)
            + LipFrameFactory.still(from: 100.6, seconds: 1)
            + LipFrameFactory.speaking(from: 101.6, seconds: 0.6)
        XCTAssertNil(SilentSpeechGate.commandFrames(two, timeline: ArticulationDetector.timeline(for: two, sensitivity: 1)))
        let long = LipFrameFactory.speaking(from: 100, seconds: 3)
        XCTAssertNil(SilentSpeechGate.commandFrames(long, timeline: ArticulationDetector.timeline(for: long, sensitivity: 1)))
    }

    func testATakeWithoutMovementIsRejected() {
        XCTAssertNil(SilentSpeechGate.takeFrames(LipFrameFactory.still(from: 100, seconds: 2), sensitivity: 1))
        XCTAssertNotNil(SilentSpeechGate.takeFrames(
            LipFrameFactory.still(from: 100, seconds: 0.5) + LipFrameFactory.speaking(from: 100.5, seconds: 0.6),
            sensitivity: 1
        ))
    }
}
