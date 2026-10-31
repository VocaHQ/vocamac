// SilentRangeTranscriptionTests.swift
// VocaMacTests
//
// Decoding only the stretches Silent Mode's camera kept: the audio is cut
// to them, and timings map back to the recording.

import XCTest
@testable import VocaMac

final class SilentRangeTranscriptionTests: XCTestCase {

    func testNoRangesIsNoSpeech() {
        XCTAssertNil(TranscriptionRouter.cameraSpeech([], in: [Float](repeating: 0.1, count: 16_000)))
        XCTAssertNil(TranscriptionRouter.cameraSpeech([20_000..<30_000], in: [Float](repeating: 0.1, count: 16_000)))
    }

    func testTheAudioIsCutToTheRangesAndTimingsMapBack() throws {
        let audio = (0..<48_000).map { Float($0) }
        let speech = try XCTUnwrap(TranscriptionRouter.cameraSpeech([16_000..<24_000], in: audio))
        XCTAssertEqual(speech.samples.count, 8_000)
        XCTAssertEqual(speech.samples.first, 16_000)
        XCTAssertFalse(speech.speechUnconfirmed, "The camera saw speech; nothing is dropped as a hallucination")
        // A word at the start of the cut audio was said one second in.
        XCTAssertEqual(SpeechActivityTrimmer.sourceSeconds(0, pieces: speech.trimPieces), 1, accuracy: 1e-9)
    }

    func testRangesPastTheEndAreClamped() throws {
        let speech = try XCTUnwrap(TranscriptionRouter.cameraSpeech([-5..<4_000, 15_000..<99_000], in: [Float](repeating: 0.1, count: 16_000)))
        XCTAssertEqual(speech.trimPieces.first?.sourceStart, 0)
        XCTAssertLessThanOrEqual(speech.samples.count, 16_000)
    }

    func testEnginesWithoutVoiceActivityDecodeTheKeptRanges() async throws {
        let mock = MockWhisperService()
        _ = try await mock.transcribe(
            audioData: [Float](repeating: 0.1, count: 48_000), language: nil, translate: false, vocabulary: "",
            keeping: [0..<8_000]
        )
        XCTAssertEqual(mock.lastTranscribedAudioData?.count, 8_000)
    }
}
