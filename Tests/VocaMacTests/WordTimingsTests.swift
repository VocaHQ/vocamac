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

    func testFilteredTimedSegmentsStripsHallucinations() {
        let segments = [
            TranscriptionSegment(
                id: 0, seek: 0, start: 0, end: 1.0,
                text: " Hello [BLANK_AUDIO] world (music)",
                tokens: [], tokenLogProbs: [], temperature: 0,
                avgLogprob: -0.2, compressionRatio: 1, noSpeechProb: 0.01,
                words: [
                    WordTiming(word: " Hello", tokens: [1], start: 0, end: 0.3, probability: 0.9),
                    WordTiming(word: " [BLANK_AUDIO]", tokens: [2], start: 0.3, end: 0.5, probability: 0.1),
                    WordTiming(word: " world", tokens: [3], start: 0.5, end: 0.8, probability: 0.9),
                    WordTiming(word: " (music)", tokens: [4], start: 0.8, end: 1.0, probability: 0.1),
                ]
            ),
            TranscriptionSegment(
                id: 1, seek: 0, start: 1.0, end: 1.5,
                text: "[BLANK_AUDIO]",
                tokens: [], tokenLogProbs: [], temperature: 0,
                avgLogprob: -0.2, compressionRatio: 1, noSpeechProb: 0.9,
                words: nil
            ),
        ]
        let timed = WhisperService.filteredTimedSegments(from: segments, model: .tiny, audioSeconds: 1.5)
        XCTAssertEqual(timed.count, 1, "A segment that is only a hallucination is dropped")
        XCTAssertFalse(timed[0].text.contains("BLANK_AUDIO"))
        XCTAssertFalse(timed[0].text.lowercased().contains("music"))
        XCTAssertEqual(timed[0].words.map(\.word), [" Hello", " world"])
    }

    func testFilteredTimedSegmentsCollapsesLoops() {
        let looped = String(repeating: "Chalo. ", count: 20)
        let segments = [
            TranscriptionSegment(
                id: 0, seek: 0, start: 0, end: 0.5,
                text: looped,
                tokens: [], tokenLogProbs: [], temperature: 0,
                avgLogprob: -0.2, compressionRatio: 8, noSpeechProb: 0.01,
                words: nil
            )
        ]
        let timed = WhisperService.filteredTimedSegments(from: segments, model: .tiny, audioSeconds: 0.5)
        XCTAssertEqual(timed.count, 1)
        XCTAssertEqual(
            timed[0].text,
            WhisperService.filteredTimingText(looped, model: .tiny, audioSeconds: 0.5)
        )
        XCTAssertLessThan(
            timed[0].text.count,
            looped.trimmingCharacters(in: .whitespacesAndNewlines).count,
            "Looped segment text is collapsed like the main transcript"
        )
    }

    func testFilteredTimedSegmentsStripsUnexpectedScripts() {
        let segments = [
            TranscriptionSegment(
                id: 0, seek: 0, start: 0, end: 1.0,
                text: "Haan 谢谢 thik hai",
                tokens: [], tokenLogProbs: [], temperature: 0,
                avgLogprob: -0.2, compressionRatio: 1, noSpeechProb: 0.01,
                words: [
                    WordTiming(word: " Haan", tokens: [1], start: 0, end: 0.3, probability: 0.9),
                    WordTiming(word: " 谢谢", tokens: [2], start: 0.3, end: 0.6, probability: 0.2),
                    WordTiming(word: " thik", tokens: [3], start: 0.6, end: 0.8, probability: 0.9),
                    WordTiming(word: " hai", tokens: [4], start: 0.8, end: 1.0, probability: 0.9),
                ]
            )
        ]
        let timed = WhisperService.filteredTimedSegments(
            from: segments, model: .vocaHinglish, audioSeconds: 1.0
        )
        XCTAssertEqual(timed.count, 1)
        XCTAssertFalse(timed[0].text.contains("谢谢"))
        XCTAssertEqual(timed[0].words.map(\.word), [" Haan", " thik", " hai"])
    }

    /// Loop collapse that keeps a trailing word must keep that word's timing
    /// too ("go go… go home" -> "go home", not timing for only the first "go").
    func testFilteredTimedSegmentsKeepsTrailingWordsAfterLoopCollapse() {
        var words: [WordTiming] = []
        for index in 0..<8 {
            let start = Double(index) * 0.2
            words.append(WordTiming(
                word: " go", tokens: [1], start: Float(start), end: Float(start + 0.15),
                probability: 0.9
            ))
        }
        words.append(WordTiming(
            word: " home", tokens: [2], start: 1.6, end: 2.0, probability: 0.95
        ))
        let segments = [
            TranscriptionSegment(
                id: 0, seek: 0, start: 0, end: 2.0,
                text: words.map(\.word).joined(),
                tokens: [], tokenLogProbs: [], temperature: 0,
                avgLogprob: -0.2, compressionRatio: 8, noSpeechProb: 0.01,
                words: words
            )
        ]
        let timed = WhisperService.filteredTimedSegments(from: segments, model: .tiny, audioSeconds: 0.5)
        XCTAssertEqual(timed.count, 1)
        let kept = timed[0].words.map { $0.word.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(kept.contains("home"), "Trailing word after a collapsed loop keeps its timing")
        XCTAssertTrue(kept.contains("go"), "First copy of the looped word is kept")
        XCTAssertLessThan(kept.filter { $0 == "go" }.count, 8, "Looped copies are not all kept")
        let text = timed[0].text.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(text.contains("home"))
        XCTAssertFalse(text.contains("go go go"), "Collapsed text should not still loop")
    }

    /// A phrase repeated across segment boundaries must collapse the same way
    /// the main transcript does after joining.
    func testFilteredTimedSegmentsCollapsesCrossSegmentLoops() {
        let unit = "Chalo. "
        let seg1Words = (0..<6).map { index in
            WordTiming(
                word: " Chalo.", tokens: [1],
                start: Float(index) * 0.3, end: Float(index) * 0.3 + 0.25,
                probability: 0.9
            )
        }
        let seg2Words = (0..<6).map { index in
            WordTiming(
                word: " Chalo.", tokens: [1],
                start: 2.0 + Float(index) * 0.3, end: 2.0 + Float(index) * 0.3 + 0.25,
                probability: 0.9
            )
        }
        let segments = [
            TranscriptionSegment(
                id: 0, seek: 0, start: 0, end: 1.8,
                text: String(repeating: unit, count: 6),
                tokens: [], tokenLogProbs: [], temperature: 0,
                avgLogprob: -0.2, compressionRatio: 4, noSpeechProb: 0.01,
                words: seg1Words
            ),
            TranscriptionSegment(
                id: 1, seek: 0, start: 2.0, end: 3.8,
                text: String(repeating: unit, count: 6),
                tokens: [], tokenLogProbs: [], temperature: 0,
                avgLogprob: -0.2, compressionRatio: 4, noSpeechProb: 0.01,
                words: seg2Words
            ),
        ]
        let joined = segments.map(\.text).joined()
        let collapsed = TranscriptRepetition.collapsingLoops(in: joined, audioSeconds: 0.5)
        XCTAssertLessThan(
            collapsed.trimmingCharacters(in: .whitespacesAndNewlines).count,
            joined.trimmingCharacters(in: .whitespacesAndNewlines).count,
            "Joined text must actually collapse for this fixture"
        )
        let timed = WhisperService.filteredTimedSegments(from: segments, model: .tiny, audioSeconds: 0.5)
        let timedText = timed.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            timedText,
            collapsed.trimmingCharacters(in: .whitespacesAndNewlines),
            "Timestamps text matches the main transcript after cross-segment collapse"
        )
        let goCount = timed.flatMap(\.words).filter {
            $0.word.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Chalo")
        }.count
        XCTAssertLessThan(goCount, 12, "Cross-segment loop copies are not all kept in timings")
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
            TimedSegment(
                start: 0.5, end: 4.5, text: " old new",
                words: [word(" old", 0.5, 1.0), word(" new", 4.2, 4.5)]
            ),
            TimedSegment(
                start: 4.8, end: 5.5, text: " words here",
                words: [word(" words", 4.8, 5.0), word(" here", 5.1, 5.5)]
            ),
        ]
        let cut = IncrementalAudioTranscriber.segments(inside: range, of: timed)
        XCTAssertEqual(cut.count, 2)
        XCTAssertEqual(cut[0].words.map(\.word), [" new"], "Context words before the piece are gone")
        XCTAssertEqual(cut[0].text, " new", "Segment text is rebuilt from kept words, not the merged context")
        XCTAssertFalse(cut[0].text.contains("old"))
        XCTAssertEqual(cut[0].start, 4.0, accuracy: 0.0001, "A segment spanning the boundary is clamped to it")
        XCTAssertEqual(cut[1].words.map(\.word), [" words", " here"])
        XCTAssertEqual(cut[1].text, " words here")
    }

    func testSegmentWithOnlyContextWordsIsDropped() {
        let range = Int(4 * rate)..<Int(6 * rate)
        let timed = [
            TimedSegment(
                start: 0.5, end: 4.2, text: " old context",
                words: [word(" old", 0.5, 1.0), word(" context", 1.0, 1.5)]
            )
        ]
        // Overlaps the piece start but every word is outside — drop it.
        let cut = IncrementalAudioTranscriber.segments(inside: range, of: timed)
        XCTAssertTrue(cut.isEmpty)
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

    /// A wordless segment clamped to the piece boundary is dropped so the
    /// caller can fall back to the piece's own text instead of an empty range.
    func testWordlessClampedSegmentIsDropped() {
        let range = Int(4 * rate)..<Int(6 * rate)
        let timed = [
            TimedSegment(start: 3.5, end: 5.0, text: " committed speech", words: [])
        ]
        let cut = IncrementalAudioTranscriber.segments(inside: range, of: timed)
        XCTAssertTrue(cut.isEmpty, "Clamped wordless segments are dropped for piece-text fallback")
    }

    /// Early-decode reuse re-cuts timings to the closed piece. A wordless
    /// early segment spanning past the closed end becomes empty after the
    /// clamp; fall back to TimedSegment(piece:) so History Timestamps still
    /// cover the kept piece text (same contract as decodeCommitted).
    func testEarlyDecodeReuseFallsBackToPieceWhenWordlessClampEmpties() {
        // Early decode heard through 5.5 s; the piece later closed at 5.0 s
        // (pause mid-point after earlyQuiet fired).
        let earlyRange = 0..<Int(5.5 * rate)
        let closedRange = 0..<Int(5.0 * rate)
        let earlyPiece = TranscribedPiece(
            range: earlyRange, text: "committed speech", language: "en"
        )
        let earlySegments = [TimedSegment(piece: earlyPiece)]
        // Mirror runCommitted's earlyFits keep path.
        let nextPiece = TranscribedPiece(
            range: closedRange, text: earlyPiece.text, language: earlyPiece.language
        )
        let cut = IncrementalAudioTranscriber.segments(inside: closedRange, of: earlySegments)
        XCTAssertTrue(cut.isEmpty, "wordless early segment past closed end is dropped")
        let kept = cut.isEmpty ? [TimedSegment(piece: nextPiece)] : cut
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].text, "committed speech")
        XCTAssertEqual(kept[0].start, 0, accuracy: 0.0001)
        XCTAssertEqual(kept[0].end, 5.0, accuracy: 0.0001)
        XCTAssertTrue(kept[0].words.isEmpty)
    }

    /// Revising a previous piece replaces its timings, not only its text.
    func testRevisionReplacesPreviousTimings() {
        let previous = TranscribedPiece(range: 0..<32_000, text: "old words", language: "en")
        let revised = TranscribedPiece(range: 0..<32_000, text: "new words", language: "en")
        var pieces = [previous]
        var timed = [
            TimedSegment(
                start: 0, end: 2.0, text: " old words",
                words: [
                    TimedWord(word: " old", start: 0, end: 0.8, probability: 0.9),
                    TimedWord(word: " words", start: 0.9, end: 2.0, probability: 0.9),
                ]
            )
        ]
        let revisedSegments = [
            TimedSegment(
                start: 0, end: 2.0, text: " new words",
                words: [
                    TimedWord(word: " new", start: 0, end: 0.8, probability: 0.9),
                    TimedWord(word: " words", start: 0.9, end: 2.0, probability: 0.9),
                ]
            )
        ]
        let decode = IncrementalAudioTranscriber.CommittedDecode(
            piece: TranscribedPiece(range: 32_000..<64_000, text: "next", language: "en"),
            segments: [
                TimedSegment(start: 2.0, end: 4.0, text: " next", words: [
                    TimedWord(word: " next", start: 2.0, end: 4.0, probability: 0.9)
                ])
            ],
            revisedPrevious: revised,
            revisedPreviousSegments: revisedSegments,
            modelUsed: .tiny
        )
        // Mirror keep()'s revision handling.
        if let revisedPiece = decode.revisedPrevious, let last = pieces.indices.last {
            pieces[last] = revisedPiece
            let lower = Double(revisedPiece.range.lowerBound) / 16_000
            let upper = Double(revisedPiece.range.upperBound) / 16_000
            timed.removeAll { $0.end > lower && $0.start < upper }
            let revisedTimed = decode.revisedPreviousSegments.isEmpty
                ? [TimedSegment(piece: revisedPiece)]
                : decode.revisedPreviousSegments
            timed.append(contentsOf: revisedTimed)
        }
        pieces.append(decode.piece)
        timed.append(contentsOf: decode.segments)
        XCTAssertEqual(pieces[0].text, "new words")
        XCTAssertEqual(timed.count, 2)
        XCTAssertEqual(timed[0].text, " new words")
        XCTAssertEqual(timed[0].words.map(\.word), [" new", " words"])
        XCTAssertFalse(timed.contains { $0.text.contains("old") })
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
