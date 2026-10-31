// AudioStopTailTests.swift
// VocaMac

import XCTest
@testable import VocaMac

final class AudioStopTailTests: XCTestCase {

    private func tone(_ count: Int, amplitude: Float) -> [Float] {
        (0..<count).map { amplitude * sin(Float($0) * 2 * .pi * 220 / 16_000) }
    }

    func testVoicedEndHoldsTheStop() {
        let audio = [Float](repeating: 0, count: 8_000) + tone(3_200, amplitude: 0.2)
        XCTAssertTrue(AudioEngine.endsInSpeech(audio[...], threshold: 0.01))
    }

    func testSilentEndStopsAtOnce() {
        let audio = tone(8_000, amplitude: 0.2) + [Float](repeating: 0, count: 1_600)
        XCTAssertFalse(AudioEngine.endsInSpeech(audio[...], threshold: 0.01))
    }

    func testRoomNoiseAtTheThresholdDoesNotHoldTheStop() {
        // RMS of a sine is amplitude / √2: 0.014 here, above the threshold
        // but under twice it.
        let audio = tone(3_200, amplitude: 0.02)
        XCTAssertFalse(AudioEngine.endsInSpeech(audio[...], threshold: 0.01))
    }

    func testTooLittleAudioIsNotJudged() {
        XCTAssertFalse(AudioEngine.endsInSpeech(tone(400, amplitude: 0.3)[...], threshold: 0.01))
    }

    func testTheExtensionIsBounded() {
        XCTAssertLessThanOrEqual(AudioEngine.stopTailExtension, 0.3)
        XCTAssertGreaterThan(AudioEngine.stopTailExtension, AudioEngine.stopTailWait)
    }
}
