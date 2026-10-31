// ArticulationDetectorTests.swift
// VocaMacTests
//
// Silent Mode's camera-side voice activity: still lips are rest, moving
// lips are speech, missing frames are gaps in coverage, and Sensitivity
// moves the line.

import XCTest
@testable import VocaMac

final class ArticulationDetectorTests: XCTestCase {

    func testStillLipsAreCoveredButNeverSpeaking() {
        let frames = LipFrameFactory.still(from: 100, seconds: 3)
        let timeline = ArticulationDetector.timeline(for: frames, sensitivity: 1)
        XCTAssertTrue(timeline.speaking.isEmpty)
        XCTAssertTrue(timeline.active.isEmpty)
        XCTAssertEqual(timeline.covered.count, 1)
        XCTAssertEqual(timeline.coveredSeconds, 3, accuracy: 0.1)
    }

    func testMouthingInTheMiddleIsOneStretchWithPadding() throws {
        let frames = LipFrameFactory.still(from: 100, seconds: 1)
            + LipFrameFactory.speaking(from: 101, seconds: 1)
            + LipFrameFactory.still(from: 102, seconds: 1)
        let timeline = ArticulationDetector.timeline(for: frames, sensitivity: 1)
        XCTAssertEqual(timeline.active.count, 1)
        let active = try XCTUnwrap(timeline.active.first)
        XCTAssertEqual(active.lowerBound, 101, accuracy: 0.15)
        XCTAssertEqual(active.upperBound, 102, accuracy: 0.15)
        let speaking = try XCTUnwrap(timeline.speaking.first)
        XCTAssertEqual(speaking.lowerBound, active.lowerBound - ArticulationDetector.leadIn, accuracy: 1e-9)
        XCTAssertEqual(speaking.upperBound, active.upperBound + ArticulationDetector.tail, accuracy: 1e-9)
    }

    func testTwoWordsWithALongPauseAreTwoStretches() {
        let frames = LipFrameFactory.speaking(from: 100, seconds: 0.6)
            + LipFrameFactory.still(from: 100.6, seconds: 1)
            + LipFrameFactory.speaking(from: 101.6, seconds: 0.6)
        let timeline = ArticulationDetector.timeline(for: frames, sensitivity: 1)
        XCTAssertEqual(timeline.active.count, 2)
    }

    func testNoFaceIsNoCoverage() {
        let frames = LipFrameFactory.noFace(from: 100, seconds: 1) + LipFrameFactory.still(from: 101, seconds: 1)
        let timeline = ArticulationDetector.timeline(for: frames, sensitivity: 1)
        XCTAssertEqual(timeline.covered.count, 1)
        XCTAssertEqual(timeline.covered[0].lowerBound, 101, accuracy: 0.05)
    }

    func testSensitivityDecidesWhetherSubtleMouthingCounts() {
        let subtle = LipFrameFactory.still(from: 100, seconds: 1)
            + LipFrameFactory.speaking(from: 101, seconds: 1, amplitude: 0.04)
            + LipFrameFactory.still(from: 102, seconds: 1)
        XCTAssertTrue(ArticulationDetector.timeline(for: subtle, sensitivity: 0.5).active.isEmpty)
        XCTAssertFalse(ArticulationDetector.timeline(for: subtle, sensitivity: 2).active.isEmpty)
    }

    func testAOneFrameTwitchIsNotSpeech() {
        var frames = LipFrameFactory.still(from: 100, seconds: 2)
        frames[30].shape = LipFrameFactory.shape(openness: 0.4)
        let timeline = ArticulationDetector.timeline(for: frames, sensitivity: 1)
        XCTAssertTrue(timeline.active.isEmpty)
    }

    func testMergedJoinsOverlappingRanges() {
        let merged = ArticulationDetector.merged([3...4, 0...1, 0.5...2])
        XCTAssertEqual(merged, [0...2, 3...4])
    }

    // MARK: Live meter

    func testTheMeterFollowsFaceStillnessAndSpeech() {
        var meter = ArticulationMeter()
        XCTAssertEqual(meter.reading, .noFace)
        for frame in LipFrameFactory.still(from: 100, seconds: 1) { meter.ingest(frame) }
        XCTAssertEqual(meter.reading, .still)
        for frame in LipFrameFactory.speaking(from: 101, seconds: 0.5) { meter.ingest(frame) }
        XCTAssertEqual(meter.reading, .speaking)
        XCTAssertGreaterThan(meter.level, 0.3)
        for frame in LipFrameFactory.still(from: 101.5, seconds: 1) { meter.ingest(frame) }
        XCTAssertEqual(meter.reading, .still)
        for frame in LipFrameFactory.noFace(from: 102.5, seconds: 1) { meter.ingest(frame) }
        XCTAssertEqual(meter.reading, .noFace)
        XCTAssertEqual(meter.level, 0)
    }
}
