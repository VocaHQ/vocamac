import XCTest
@testable import VocaMac

final class SherpaAudioPreparationTests: XCTestCase {
    func testValidationRejectsEmptyAndNonFiniteInput() {
        let invalid: [[Float]] = [[], [.nan], [.infinity], [-.infinity], [0.1, .nan]]
        for samples in invalid {
            XCTAssertThrowsError(try SherpaAudioPreparation.validate(samples))
        }
        XCTAssertNoThrow(try SherpaAudioPreparation.validate([0, 0.000001, -1, 1]))
    }

    func testShortSpeechPreservesEverySampleAndAddsTrailingSilence() {
        let speech: [Float] = [0.1, -0.3, 0.2]
        let prepared = SherpaAudioPreparation.prepare(speech)
        XCTAssertEqual(prepared.count, 16_000)
        XCTAssertEqual(Array(prepared.prefix(speech.count)), speech)
        XCTAssertTrue(prepared.dropFirst(speech.count).allSatisfy { $0 == 0 })
    }

    func testEmptyAndDigitalSilenceDoNotReachDecoder() {
        XCTAssertEqual(SherpaAudioPreparation.prepare([]), [])
        XCTAssertEqual(SherpaAudioPreparation.prepare([Float](repeating: 0, count: 32_000)), [])
    }

    func testQuietSpeechIsNotDiscarded() {
        XCTAssertEqual(SherpaAudioPreparation.prepare([0.000001]).first, 0.000001)
    }

    func testNormalLengthAudioIsUnchanged() {
        let samples = [Float](repeating: 0.1, count: 16_001)
        XCTAssertEqual(SherpaAudioPreparation.prepare(samples), samples)
    }

    func testShortFinalSegmentAlsoReceivesPadding() {
        var recording = [Float](repeating: 0.1, count: 128_001)
        recording.replaceSubrange(108_800..<128_000, with: repeatElement(Float.zero, count: 19_200))
        let segments = AudioSegmenter.segment(recording, maxSeconds: 8)
        XCTAssertTrue(segments.contains { $0.count < 16_000 })
        for segment in segments {
            let prepared = SherpaAudioPreparation.prepare(segment)
            XCTAssertGreaterThanOrEqual(prepared.count, 16_000)
            XCTAssertEqual(Array(prepared.prefix(segment.count)), segment)
        }
    }
}
