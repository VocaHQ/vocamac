// WordTimingsTests.swift
// VocaMac Tests
//
// Word- and segment-level transcript timings: how they are collected from a
// Whisper decode, mapped back through silence trimming, cut to a committed
// piece's range, stored in history, and shown.

import XCTest
import WhisperKit
@testable import VocaMac

// MARK: - History Codable compatibility

final class TimedHistoryEntryTests: XCTestCase {

    private var directory: URL!
    private var decoder: JSONDecoder!
    private var encoder: JSONEncoder!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocaMacTimingTests-\(UUID().uuidString)", isDirectory: true)
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// An entry saved by a build before word timings — no `segments` key —
    /// must still decode.
    func testEntryWithoutSegmentsDecodes() throws {
        let json = """
        {
            "id": "B04F9F67-9A20-4E39-9E50-9B573F7845D1",
            "createdAt": "2026-09-29T12:00:00Z",
            "status": "completed",
            "rawText": "hello world",
            "finalText": "Hello world.",
            "modelID": "tiny",
            "audioSeconds": 1.5,
            "retryCount": 0
        }
        """
        let entry = try decoder.decode(DictationHistoryEntry.self, from: Data(json.utf8))
        XCTAssertNil(entry.segments)
        XCTAssertEqual(entry.finalText, "Hello world.")
    }

    func testEntryWithSegmentsRoundTrips() throws {
        var entry = DictationHistoryEntry(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: .completed, rawText: "hi there", finalText: "Hi there.",
            modelID: "tiny", audioSeconds: 2.0
        )
        entry.segments = [
            TimedSegment(
                start: 0.1, end: 1.2, text: " hi there",
                words: [
                    TimedWord(word: " hi", start: 0.1, end: 0.4, probability: 0.9),
                    TimedWord(word: " there", start: 0.5, end: 1.2, probability: 0.8),
                ]
            )
        ]
        let decoded = try decoder.decode(DictationHistoryEntry.self, from: encoder.encode(entry))
        XCTAssertEqual(decoded, entry)
        XCTAssertEqual(decoded.segments?.first?.words.count, 2)
        XCTAssertEqual(decoded.segments?.first?.words.first?.probability ?? -1, 0.9)
    }

    @MainActor
    func testCompleteStoresSegments() async throws {
        let store = DictationHistoryStore(directory: directory)
        let id = await store.begin(audio: nil, target: nil, modelID: "tiny", language: "en", audioSeconds: 1)
        let segments = [
            TimedSegment(
                start: 0, end: 0.8, text: " hello",
                words: [TimedWord(word: " hello", start: 0, end: 0.8, probability: nil)]
            )
        ]
        store.complete(
            id, rawText: "hello", finalText: "Hello.", summary: nil,
            language: "en", transcriptionSeconds: 0.1, segments: segments, keepAudio: false
        )
        XCTAssertEqual(try XCTUnwrap(store.entry(id: id)).segments, segments)
    }

    @MainActor
    func testCompleteWithNoSegmentsLeavesNil() async throws {
        let store = DictationHistoryStore(directory: directory)
        let id = await store.begin(audio: nil, target: nil, modelID: "tiny", language: "en", audioSeconds: 1)
        store.complete(
            id, rawText: "hello", finalText: "Hello.", summary: nil,
            language: "en", transcriptionSeconds: 0.1, segments: [], keepAudio: false
        )
        XCTAssertNil(store.entry(id: id)?.segments, "An empty timing list is stored as none")
    }
}

// MARK: - WhisperKit segment mapping

final class TimedSegmentMappingTests: XCTestCase {

    func testTimedSegmentsFromWhisperKit() {
        let segments = [
            TranscriptionSegment(
                id: 0, seek: 0, start: 0.02, end: 1.48, text: " Hello world.",
                tokens: [], tokenLogProbs: [], temperature: 0,
                avgLogprob: -0.2, compressionRatio: 1, noSpeechProb: 0.01,
                words: [
                    WordTiming(word: " Hello", tokens: [1], start: 0.02, end: 0.62, probability: 0.95),
                    WordTiming(word: " world.", tokens: [2], start: 0.66, end: 1.48, probability: 0.9),
                ]
            ),
            TranscriptionSegment(
                id: 1, seek: 100, start: 1.6, end: 2.4, text: " Next.",
                tokens: [], tokenLogProbs: [], temperature: 0,
                avgLogprob: -0.1, compressionRatio: 1, noSpeechProb: 0.01,
                words: nil
            ),
        ]

        let timed = WhisperService.timedSegments(from: segments)
        XCTAssertEqual(timed.count, 2)
        XCTAssertEqual(timed[0].start, 0.02, accuracy: 0.001)
        XCTAssertEqual(timed[0].end, 1.48, accuracy: 0.001)
        XCTAssertEqual(timed[0].text, " Hello world.")
        XCTAssertEqual(timed[0].words.map(\.word), [" Hello", " world."])
        XCTAssertEqual(timed[0].words[1].end, 1.48, accuracy: 0.001)
        XCTAssertEqual(timed[0].words[0].probability ?? -1, 0.95, accuracy: 0.001)
        XCTAssertTrue(timed[1].words.isEmpty, "A segment without words still has its own range")
    }

    func testSpecialTokensStrippedFromSegmentText() {
        // With wordTimestamps on, segment text carries the decoder's control
        // tokens; result.text does not, so neither should ours.
        let segments = [
            TranscriptionSegment(
                id: 0, seek: 0, start: 0, end: 4.0,
                text: "<|startoftranscript|><|en|><|transcribe|><|0.00|> Hello world.<|4.00|>",
                tokens: [], tokenLogProbs: [], temperature: 0,
                avgLogprob: -0.2, compressionRatio: 1, noSpeechProb: 0.01,
                words: nil
            )
        ]
        let timed = WhisperService.timedSegments(from: segments)
        XCTAssertEqual(timed.first?.text, " Hello world.")
    }

    func testMappingTimesShiftsSegmentAndWords() {
        let segment = TimedSegment(
            start: 1, end: 2, text: " hi",
            words: [TimedWord(word: " hi", start: 1, end: 2, probability: 0.5)]
        )
        let shifted = segment.mappingTimes { $0 + 10 }
        XCTAssertEqual(shifted.start, 11)
        XCTAssertEqual(shifted.words.first?.start, 11)
        XCTAssertEqual(shifted.words.first?.end, 12)
        XCTAssertEqual(shifted.text, " hi", "Mapping moves times, not text")
    }
}

// MARK: - Silence-trim inverse map

final class TrimRemapTests: XCTestCase {

    /// One kept stretch starting a second in: the decode heard the recording
    /// without its first second.
    func testLeadingSilenceShift() {
        let pieces = SpeechActivityTrimmer.copiedPieces(
            from: [16_000..<48_000], sampleCount: 48_000
        )
        XCTAssertEqual(pieces, [SpeechActivityTrimmer.CopiedPiece(outputStart: 0, sourceStart: 16_000, count: 32_000)])
        XCTAssertEqual(SpeechActivityTrimmer.sourceSeconds(0, pieces: pieces), 1.0, accuracy: 0.0001)
        XCTAssertEqual(SpeechActivityTrimmer.sourceSeconds(1.5, pieces: pieces), 2.5, accuracy: 0.0001)
    }

    /// Two stretches with a long pause between them: the pause is kept only
    /// at its edges, so times after it land further into the recording.
    func testLongPauseRemap() {
        let rate = SpeechActivityTrimmer.sampleRate
        let pause = Int(SpeechActivityTrimmer.maximumPause * Double(rate))
        let ranges = [8_000..<24_000, 48_000..<56_000]
        let sampleCount = 64_000
        let pieces = SpeechActivityTrimmer.copiedPieces(from: ranges, sampleCount: sampleCount)

        // Output: 1 s of speech, half-pause tail, half-pause lead-in, then
        // the second stretch.
        let firstEnd = 16_000
        XCTAssertEqual(pieces.first?.count, 16_000)
        XCTAssertEqual(pieces[1].sourceStart, 24_000)
        XCTAssertEqual(pieces[2].sourceStart, 48_000 - (pause - pause / 2))
        XCTAssertEqual(pieces.last?.sourceStart, 48_000)

        // The total output matches what apply assembles.
        XCTAssertEqual(pieces.map(\.count).reduce(0, +), SpeechActivityTrimmer.assembledLength(ranges))

        // Times inside each kept stretch map back to their source position.
        XCTAssertEqual(
            SpeechActivityTrimmer.sourceSeconds(0.5, pieces: pieces),
            8_000.0 / Double(rate) + 0.5, accuracy: 0.0001
        )
        // The start of the second stretch (after first speech + kept pause).
        let secondStretchAt = Double(firstEnd + pause) / Double(rate)
        XCTAssertEqual(
            SpeechActivityTrimmer.sourceSeconds(secondStretchAt, pieces: pieces),
            48_000.0 / Double(rate), accuracy: 0.0001
        )
    }

    /// A range list covering everything is an identity map.
    func testUntrimmedIsIdentity() {
        let pieces = SpeechActivityTrimmer.copiedPieces(from: [0..<32_000], sampleCount: 32_000)
        XCTAssertEqual(SpeechActivityTrimmer.sourceSeconds(1.234, pieces: pieces), 1.234, accuracy: 0.0001)
    }

    func testSourceSecondsEdgeCases() {
        XCTAssertEqual(SpeechActivityTrimmer.sourceSeconds(3.0, pieces: []), 3.0)
        let pieces = [SpeechActivityTrimmer.CopiedPiece(outputStart: 0, sourceStart: 100, count: 160)]
        // Past the output's end lands on the last kept sample.
        XCTAssertEqual(SpeechActivityTrimmer.sourceSeconds(5.0, pieces: pieces), 260.0 / 16_000, accuracy: 0.0001)
    }

    /// The copy plan and `apply` must agree — the inverse map is only as
    /// good as the list of pieces it mirrors.
    func testCopiedPiecesMatchesApply() {
        var samples = [Float](repeating: 0, count: 64_000)
        for index in samples.indices { samples[index] = Float(index % 7) }
        let ranges = [8_000..<24_000, 30_000..<33_000, 48_000..<56_000]
        let applied = SpeechActivityTrimmer.apply(ranges, to: samples)
        let pieces = SpeechActivityTrimmer.copiedPieces(from: ranges, sampleCount: samples.count)
        var rebuilt: [Float] = []
        for piece in pieces {
            rebuilt.append(contentsOf: samples[piece.sourceStart..<(piece.sourceStart + piece.count)])
        }
        XCTAssertEqual(applied, rebuilt)
    }
}

// MARK: - Committed piece timing cut

final class PieceTimingCutTests: XCTestCase {

    private let rate = 16_000.0

    private func segment(start: Double, end: Double, words: [TimedWord]) -> TimedSegment {
        TimedSegment(start: start, end: end, text: " text", words: words)
    }

    private func word(_ text: String, _ start: Double, _ end: Double) -> TimedWord {
        TimedWord(word: text, start: start, end: end, probability: nil)
    }

    func testWordsOutsideThePieceAreDropped() {
        // A merged decode heard 4 s of context plus the 2 s piece; the piece
        // occupies 4–6 s on the recording's timeline.
        let range = Int(4 * rate)..<Int(6 * rate)
        let timed = [
            segment(start: 0.5, end: 4.5, words: [word(" old", 0.5, 1.0), word(" new", 4.2, 4.5)]),
            segment(start: 4.8, end: 5.5, words: [word(" words", 4.8, 5.0), word(" here", 5.1, 5.5)]),
        ]
        let cut = IncrementalAudioTranscriber.segments(inside: range, of: timed)
        XCTAssertEqual(cut.count, 2)
        XCTAssertEqual(cut[0].words.map(\.word), [" new"], "Context words before the piece are gone")
        XCTAssertEqual(cut[0].start, 4.0, accuracy: 0.0001, "A segment spanning the boundary is clamped to it")
        XCTAssertEqual(cut[1].words.map(\.word), [" words", " here"])
    }

    func testSegmentFullyOutsideIsDropped() {
        let range = Int(4 * rate)..<Int(6 * rate)
        let timed = [segment(start: 0, end: 3.9, words: [word(" gone", 0, 1)])]
        XCTAssertTrue(IncrementalAudioTranscriber.segments(inside: range, of: timed).isEmpty)
    }

    func testWordSpanningTheStartIsClamped() {
        let range = Int(4 * rate)..<Int(6 * rate)
        let timed = [segment(start: 3.8, end: 4.6, words: [word(" split", 3.8, 4.6)])]
        let cut = IncrementalAudioTranscriber.segments(inside: range, of: timed)
        XCTAssertEqual(cut.first?.words.first?.start ?? -1, 4.0, accuracy: 0.0001)
        XCTAssertEqual(cut.first?.words.first?.end ?? -1, 4.6, accuracy: 0.0001)
    }
}

// MARK: - Display formatting

final class TranscriptTimestampTests: XCTestCase {

    func testDisplay() {
        XCTAssertEqual(TranscriptTimestamp.display(0), "0:00.0")
        XCTAssertEqual(TranscriptTimestamp.display(2.36), "0:02.4")
        XCTAssertEqual(TranscriptTimestamp.display(65.25), "1:05.2")
        XCTAssertEqual(TranscriptTimestamp.display(-1), "0:00.0", "Negative times clamp to 0")
    }

    func testMinuteRollover() {
        XCTAssertEqual(TranscriptTimestamp.display(59.96), "1:00.0", "A second that rounds to 60 rolls into the minute")
    }
}
