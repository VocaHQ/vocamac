import XCTest
@testable import VocaMac

final class SpeechSegmenterTests: XCTestCase {
    private let rate = 16_000

    private func tone(_ seconds: Double, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { amplitude * sin(Float($0) * 2 * .pi * 220 / Float(rate)) }
    }

    private func silence(_ seconds: Double, noise: Float = 0) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        return (0..<Int(seconds * Double(rate))).map { _ in
            noise == 0 ? 0 : Float.random(in: -noise...noise, using: &generator)
        }
    }

    private func segment(
        _ audio: [Float], chunk: Int = 1_600,
        pause: Double = 0.6, min: Double = 4, max: Double = 25
    ) -> [Range<Int>] {
        var segmenter = SpeechSegmenter(configuration: .init(
            pauseSeconds: pause, minPieceSeconds: min, maxPieceSeconds: max
        ))
        var ranges: [Range<Int>] = []
        var offset = 0
        while offset < audio.count {
            let end = Swift.min(audio.count, offset + chunk)
            ranges += segmenter.append(Array(audio[offset..<end]))
            offset = end
        }
        return ranges + segmenter.finish()
    }

    private func assertContiguous(_ ranges: [Range<Int>], total: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            RecordingTranscription.piecesCover(
                ranges.map { TranscribedPiece(range: $0, text: "", language: "en") }, sampleCount: total
            ),
            "\(ranges)", file: file, line: line
        )
    }

    func testPauseAfterEnoughSpeechClosesAPieceInsideThePause() {
        let audio = tone(5) + silence(1) + tone(3)
        let ranges = segment(audio)
        XCTAssertEqual(ranges.count, 2)
        assertContiguous(ranges, total: audio.count)
        let cut = ranges[0].upperBound
        XCTAssertGreaterThan(cut, 5 * rate, "the cut lands in the pause, not in speech")
        XCTAssertLessThan(cut, 6 * rate)
    }

    func testPauseShorterThanTheThresholdDoesNotClose() {
        let audio = tone(5) + silence(0.3) + tone(3)
        XCTAssertEqual(segment(audio), [0..<audio.count])
    }

    func testPauseBeforeTheMinimumLengthDoesNotClose() {
        let audio = tone(2) + silence(1) + tone(3)
        XCTAssertEqual(segment(audio), [0..<audio.count])
    }

    func testContinuousSpeechIsCutBeforeTheEngineLimit() {
        let audio = tone(30)
        let ranges = segment(audio, max: 8)
        XCTAssertGreaterThanOrEqual(ranges.count, 4)
        assertContiguous(ranges, total: audio.count)
        for range in ranges {
            XCTAssertLessThanOrEqual(range.count, 8 * rate)
        }
    }

    func testPieceExactlyAtTheLimitStaysWithinIt() {
        let audio = tone(8)
        let ranges = segment(audio, max: 8)
        assertContiguous(ranges, total: audio.count)
        XCTAssertTrue(ranges.allSatisfy { $0.count <= 8 * rate })
    }

    func testLeadingSilenceIsNotAPieceOfItsOwn() {
        let audio = silence(5) + tone(5) + silence(1) + tone(2)
        let ranges = segment(audio)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertGreaterThan(ranges[0].upperBound, 10 * rate, "the first piece holds the leading silence and the speech")
        assertContiguous(ranges, total: audio.count)
    }

    func testTrailingSilenceEndsInTheLastPiece() {
        let audio = tone(5) + silence(3)
        let ranges = segment(audio)
        assertContiguous(ranges, total: audio.count)
        XCTAssertEqual(ranges.last?.upperBound, audio.count)
    }

    func testChunkSizeDoesNotChangeTheCuts() {
        let audio = tone(4.5) + silence(0.9) + tone(6) + silence(0.7) + tone(1.3)
        let reference = segment(audio, chunk: audio.count)
        XCTAssertEqual(segment(audio, chunk: 317), reference)
        XCTAssertEqual(segment(audio, chunk: 1_024), reference)
        XCTAssertEqual(reference.count, 3)
    }

    func testPauseInANoisyRoomIsStillFound() {
        let audio = tone(5, amplitude: 0.5) + silence(1, noise: 0.03) + tone(3, amplitude: 0.5)
        XCTAssertEqual(segment(audio).count, 2)
    }

    func testEmptyInputHasNoPieces() {
        var segmenter = SpeechSegmenter(configuration: .init())
        XCTAssertEqual(segmenter.append([]), [])
        XCTAssertEqual(segmenter.finish(), [])
    }

    func testShortWindowEnginesKeepTheMinimumBelowTheLimit() {
        let configuration = StreamingCommitOptions(minPieceSeconds: 8).segmenterConfiguration(maxPieceSeconds: 7.5)
        XCTAssertEqual(configuration.minPieceSeconds, 3.75)
        XCTAssertEqual(configuration.maxPieceSeconds, 7.5)
    }
}

final class TranscribedPieceTests: XCTestCase {
    func testPiecesJoinWithASpace() {
        XCTAssertEqual(TranscribedPiece.join(["Hello there.", " How are you?"]), "Hello there. How are you?")
    }

    func testEmptyPiecesAddNothing() {
        XCTAssertEqual(TranscribedPiece.join(["", "One.", "  ", "Two."]), "One. Two.")
        XCTAssertEqual(TranscribedPiece.join([String]()), "")
    }

    func testUnspacedScriptsJoinWithoutASpace() {
        XCTAssertEqual(TranscribedPiece.join(["你好。", "今天天气很好。"]), "你好。今天天气很好。")
        XCTAssertEqual(TranscribedPiece.join(["こんにちは。", "元気ですか"]), "こんにちは。元気ですか")
        XCTAssertEqual(TranscribedPiece.join(["안녕하세요.", "반갑습니다."]), "안녕하세요. 반갑습니다.",
                       "Korean separates words with spaces")
        XCTAssertEqual(TranscribedPiece.join(["我用 VocaMac", "写东西"]), "我用 VocaMac 写东西")
    }
}

final class FinalizedPieceTrackerTests: XCTestCase {
    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TranscribedPiece] = []
        func append(_ piece: TranscribedPiece) { lock.withLock { storage.append(piece) } }
        var pieces: [TranscribedPiece] { lock.withLock { storage } }
    }

    func testFinalizedResultsBecomePiecesCoveringTheRecording() {
        let received = Received()
        let tracker = FinalizedPieceTracker(language: "en") { _, piece in received.append(piece) }
        tracker.finalized("Hello there.", endSeconds: 1.5)
        tracker.finalized(" How are you?", endSeconds: 3.0)

        XCTAssertEqual(received.pieces.map(\.text), ["Hello there.", "How are you?"], "each arrives while recording")
        let pieces = tracker.pieces(sampleCount: 52_000)
        XCTAssertEqual(pieces.map(\.range), [0..<24_000, 24_000..<52_000], "the last piece runs to the end")
        XCTAssertTrue(RecordingTranscription.piecesCover(pieces, sampleCount: 52_000))
    }

    func testPiecesThatWouldReadDifferentlyAreNotUsed() {
        let tracker = FinalizedPieceTracker(language: "en") { _, _ in }
        tracker.finalized("Hello", endSeconds: 1)
        tracker.finalized("world", endSeconds: 2)
        XCTAssertEqual(tracker.pieces(sampleCount: 32_000), [], "Apple joins these as \"Helloworld\"")
    }

    func testResultsPastTheRecordingAreNotUsed() {
        let tracker = FinalizedPieceTracker(language: "en") { _, _ in }
        tracker.finalized("Hello there.", endSeconds: 5)
        tracker.finalized(" Bye.", endSeconds: 6)
        XCTAssertEqual(tracker.pieces(sampleCount: 16_000), [])
    }
}
