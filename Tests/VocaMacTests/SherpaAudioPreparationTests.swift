import XCTest
@testable import VocaMac

final class SherpaAudioPreparationTests: XCTestCase {
    private let edge = SherpaAudioPreparation.edgeSilenceSampleCount

    func testValidationRejectsEmptyAndNonFiniteInput() {
        let invalid: [[Float]] = [[], [.nan], [.infinity], [-.infinity], [0.1, .nan]]
        for samples in invalid {
            XCTAssertThrowsError(try SherpaAudioPreparation.validate(samples))
        }
        XCTAssertNoThrow(try SherpaAudioPreparation.validate([0, 0.000001, -1, 1]))
    }

    func testShortSpeechIsPaddedToTheMinimumSampleCount() {
        let speech: [Float] = [0.1, -0.3, 0.2]
        let prepared = SherpaAudioPreparation.prepare(speech)
        XCTAssertEqual(prepared.count, 16_000)
        XCTAssertEqual(Array(prepared[edge..<(edge + speech.count)]), speech)
        XCTAssertTrue(prepared.dropFirst(edge + speech.count).allSatisfy { $0 == 0 })
    }

    /// Speech that starts in sample zero makes the NeMo decoders emit
    /// end-of-transcript immediately and return nothing at all, so every
    /// segment gets a silent lead-in.
    func testSpeechNeverStartsInTheFirstSample() {
        let cases: [[Float]] = [
            [0.4],
            [Float](repeating: 0.1, count: 16_001),
            [Float](repeating: -0.2, count: 320_000),
        ]
        for samples in cases {
            let prepared = SherpaAudioPreparation.prepare(samples)
            XCTAssertEqual(Array(prepared.prefix(edge)), [Float](repeating: 0, count: edge))
            XCTAssertEqual(Array(prepared.suffix(edge)), [Float](repeating: 0, count: edge))
            XCTAssertEqual(Array(prepared[edge..<(edge + samples.count)]), samples)
        }
    }

    /// The segment budget in SherpaService subtracts this, so it has to stay
    /// equal to what `prepare` actually adds.
    func testAddedSilenceSecondsMatchesWhatPrepareAdds() {
        let samples = [Float](repeating: 0.1, count: 320_000)
        let prepared = SherpaAudioPreparation.prepare(samples)
        let added = Double(prepared.count - samples.count) / 16_000
        XCTAssertEqual(added, SherpaAudioPreparation.addedSilenceSeconds, accuracy: 0.0001)
    }

    /// A segment cut to the model's budget must still fit that model's
    /// one-pass limit once it is padded — Moonshine returns nothing at all
    /// past its limit, and SenseVoice drops characters.
    func testMaximumSegmentStillFitsEveryModelsLimitAfterPadding() {
        for spec in SherpaModelCatalog.specs {
            let budget = spec.maxSegmentSeconds - SherpaAudioPreparation.addedSilenceSeconds
            XCTAssertGreaterThan(budget, 0, "\(spec.size.rawValue) has no room for the padding")
            let segment = [Float](repeating: 0.1, count: Int(budget * 16_000))
            let prepared = SherpaAudioPreparation.prepare(segment)
            XCTAssertLessThanOrEqual(
                Double(prepared.count) / 16_000,
                spec.maxSegmentSeconds,
                "\(spec.size.rawValue) overruns its limit once padded"
            )
        }
    }

    func testEmptyAndDigitalSilenceDoNotReachDecoder() {
        XCTAssertEqual(SherpaAudioPreparation.prepare([]), [])
        XCTAssertEqual(SherpaAudioPreparation.prepare([Float](repeating: 0, count: 32_000)), [])
    }

    func testQuietSpeechIsNotDiscarded() {
        XCTAssertEqual(SherpaAudioPreparation.prepare([0.000001])[edge], 0.000001)
    }

    func testLongAudioKeepsEverySampleAndOnlyGainsEdgeSilence() {
        let samples = (0..<16_001).map { Float($0 % 7) * 0.1 + 0.01 }
        let prepared = SherpaAudioPreparation.prepare(samples)
        XCTAssertEqual(prepared.count, samples.count + 2 * edge)
        XCTAssertEqual(Array(prepared[edge..<(edge + samples.count)]), samples)
    }

    func testShortFinalSegmentAlsoReceivesPadding() {
        var recording = [Float](repeating: 0.1, count: 128_001)
        recording.replaceSubrange(108_800..<128_000, with: repeatElement(Float.zero, count: 19_200))
        let segments = AudioSegmenter.segment(recording, maxSeconds: 8)
        XCTAssertTrue(segments.contains { $0.count < 16_000 })
        for segment in segments {
            let prepared = SherpaAudioPreparation.prepare(segment)
            XCTAssertGreaterThanOrEqual(prepared.count, 16_000)
            XCTAssertEqual(Array(prepared[edge..<(edge + segment.count)]), segment)
        }
    }
}
