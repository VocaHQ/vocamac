import XCTest
@testable import VocaMac

final class RecordingTranscriptionTests: XCTestCase {
    private func transcript(_ count: Int) -> VocaTranscription {
        VocaTranscription(text: "complete", duration: 0, detectedLanguage: "en",
                          audioLengthSeconds: Double(count) / 16_000, modelUsed: .appleSpeech)
    }

    func testOrderedChunksAreConsumedBeforeRecordingFinishes() async throws {
        let consumed = expectation(description: "first chunk processed during capture")
        let session = RecordingTranscription(language: "en") { chunks in
            var count = 0
            for try await chunk in chunks {
                if count == 0 { consumed.fulfill() }
                count += chunk.count
            }
            return self.transcript(count)
        }
        session.append([0.1, 0.2], at: 0)
        await fulfillment(of: [consumed], timeout: 1)
        session.append([0.3], at: 2)
        let result = try await session.finish(expectedSampleCount: 3)
        XCTAssertEqual(result.audioLengthSeconds, 3.0 / 16_000)
        XCTAssertEqual(result.text, "complete")
    }

    func testCaptureRestartFailsInsteadOfReturningMixedAudio() async {
        let session = RecordingTranscription(language: nil) { chunks in
            var count = 0
            for try await chunk in chunks { count += chunk.count }
            return self.transcript(count)
        }
        session.append([1, 2], at: 0)
        session.append([3], at: 0)
        do {
            _ = try await session.finish(expectedSampleCount: 1)
            XCTFail("A restarted capture must fall back to the complete batch")
        } catch { }
    }

    func testMissingTailFailsInsteadOfReturningPartialResult() async {
        let session = RecordingTranscription(language: nil) { chunks in
            for try await _ in chunks { }
            return self.transcript(1)
        }
        session.append([1], at: 0)
        do {
            _ = try await session.finish(expectedSampleCount: 2)
            XCTFail("Missing samples must invalidate streaming")
        } catch { }
    }

    func testOverflowIsBoundedAndFailsClosed() async {
        let gate = TestGate()
        let session = RecordingTranscription(language: nil, bufferLimit: 1) { chunks in
            await gate.wait()
            for try await _ in chunks { }
            return self.transcript(2)
        }
        session.append([1], at: 0)
        session.append([2], at: 1)
        await gate.open()
        do {
            _ = try await session.finish(expectedSampleCount: 2)
            XCTFail("Overflow must not return a partial transcript")
        } catch { }
    }

    func testCancelUnblocksConsumerAndQueuedModelOperation() async throws {
        let serializer = LoadSerializer()
        let started = expectation(description: "stream holds engine")
        let session = RecordingTranscription(language: nil) { chunks in
            try await serializer.run {
                started.fulfill()
                for try await _ in chunks { }
                return self.transcript(0)
            }
        }
        await fulfillment(of: [started], timeout: 1)
        session.cancel()
        let result = try await serializer.run { 42 }
        XCTAssertEqual(result, 42)
    }

    func testBatchCursorUsesBoundedChunksIncludingLastSample() async {
        let original = (0..<32_003).map(Float.init)
        let cursor = AudioChunkCursor(original)
        var collected: [Float] = []
        while let chunk = await cursor.next() {
            XCTAssertLessThanOrEqual(chunk.count, 16_000)
            collected += chunk
        }
        XCTAssertEqual(collected, original)
    }
}

private actor TestGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func open() { isOpen = true; waiter?.resume(); waiter = nil }
}

extension RecordingTranscriptionTests {
    func testConsumerReturningEarlyCannotDeliverPartialSuccess() async {
        let session = RecordingTranscription(language: nil) { chunks in
            for try await chunk in chunks {
                return VocaTranscription(text: "partial", duration: 0, detectedLanguage: "en",
                                         audioLengthSeconds: Double(chunk.count) / 16_000, modelUsed: .appleSpeech)
            }
            throw CancellationError()
        }
        session.append([1], at: 0)
        session.append([2], at: 1)
        do {
            _ = try await session.finish(expectedSampleCount: 2)
            XCTFail("An engine must consume the complete recording before returning success")
        } catch { }
    }
}

// MARK: - Commit mode

/// Records every decode it is asked for and "transcribes" each stretch of
/// sound as `tone<seconds>`, so a merged decode reads like its parts joined.
private actor FakePieceEngine {
    private(set) var decodedLengths: [Int] = []
    var failOnDecode: Int?
    var hold: TestGate?
    /// Text for the next decodes, in order, instead of the tone names.
    var scriptedTexts: [String] = []

    func setScript(_ texts: [String]) { scriptedTexts = texts }

    static func toneNames(_ samples: [Float]) -> String {
        var names: [String] = []
        var run = 0
        func close() {
            if run >= 3_200 { names.append("tone\(Int((Double(run) / 16_000).rounded()))") }
            run = 0
        }
        for start in stride(from: 0, to: samples.count, by: 320) {
            let frame = samples[start..<min(samples.count, start + 320)]
            if SpeechSegmenter.energy(frame) > 1e-4 { run += frame.count } else { close() }
        }
        close()
        return names.joined(separator: " ")
    }

    func setFailure(onDecode index: Int) { failOnDecode = index }
    func setHold(_ gate: TestGate) { hold = gate }

    func transcribe(_ samples: [Float]) async throws -> VocaTranscription {
        decodedLengths.append(samples.count)
        if let hold { await hold.wait() }
        if failOnDecode == decodedLengths.count - 1 {
            throw WhisperError.transcriptionFailed(reason: "fake failure")
        }
        let text = scriptedTexts.isEmpty ? Self.toneNames(samples) : scriptedTexts.removeFirst()
        return VocaTranscription(
            text: text, duration: 0, detectedLanguage: "en",
            audioLengthSeconds: Double(samples.count) / 16_000, modelUsed: .tiny
        )
    }
}

private final class PieceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(Int, TranscribedPiece)] = []
    private var partialStorage: [String] = []
    func append(_ index: Int, _ piece: TranscribedPiece) { lock.withLock { storage.append((index, piece)) } }
    func appendPartial(_ text: String) { lock.withLock { partialStorage.append(text) } }
    var pieces: [(Int, TranscribedPiece)] { lock.withLock { storage } }
    var partials: [String] { lock.withLock { partialStorage } }
}

extension RecordingTranscriptionTests {
    private func tone(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { 0.3 * sin(Float($0) * 2 * .pi * 220 / 16_000) }
    }

    private func committedSession(
        engine: FakePieceEngine, log: PieceLog, partials: Bool = false
    ) -> RecordingTranscription {
        let configuration = SpeechSegmenter.Configuration(pauseSeconds: 0.6, minPieceSeconds: 4, maxPieceSeconds: 25)
        let onPiece: @Sendable (Int, TranscribedPiece) -> Void = { index, piece in log.append(index, piece) }
        let transcribe: @Sendable ([Float]) async throws -> VocaTranscription = { samples in
            try await engine.transcribe(samples)
        }
        var onPartial: (@Sendable (String) -> Void)?
        if partials {
            onPartial = { text in log.appendPartial(text) }
        }
        let partialHandler = onPartial
        return RecordingTranscription(language: "en", bufferLimit: 10_000) { chunks in
            try await IncrementalAudioTranscriber.runCommitted(
                chunks: chunks, segmenter: configuration, onPiece: onPiece,
                updateEverySamples: 16_000, transcribe: transcribe, onPartial: partialHandler
            )
        }
    }

    private func feed(_ audio: [Float], to session: RecordingTranscription, chunk: Int = 1_600) {
        var offset = 0
        while offset < audio.count {
            let end = min(audio.count, offset + chunk)
            session.append(Array(audio[offset..<end]), at: offset)
            offset = end
        }
    }

    func testCommitModeDecodesEachPieceOnceAndJoinsThem() async throws {
        let engine = FakePieceEngine()
        let log = PieceLog()
        let session = committedSession(engine: engine, log: log)
        let audio = tone(5) + [Float](repeating: 0, count: 16_000) + tone(3)
        feed(audio, to: session)
        let result = try await session.finish(expectedSampleCount: audio.count)

        XCTAssertEqual(result.pieces.count, 2)
        XCTAssertTrue(RecordingTranscription.piecesCover(result.pieces, sampleCount: audio.count))
        let lengths = await engine.decodedLengths
        XCTAssertEqual(lengths, [result.pieces[0].range.count, audio.count],
                       "the first piece while recording, then the tail together with it")
        XCTAssertEqual(result.pieces.map(\.text), ["tone5", "tone3"], "the merged decode kept the first piece as it was")
        XCTAssertEqual(result.text, "tone5 tone3")
        XCTAssertEqual(log.pieces.map(\.0), [0, 1])
        XCTAssertEqual(log.pieces.map(\.1), result.pieces)
        XCTAssertEqual(result.audioLengthSeconds, Double(audio.count) / 16_000)
    }

    func testFirstPieceIsDecodedBeforeRecordingStops() async throws {
        let engine = FakePieceEngine()
        let log = PieceLog()
        let session = committedSession(engine: engine, log: log)
        feed(tone(5) + [Float](repeating: 0, count: 16_000), to: session)
        for _ in 0..<100 where log.pieces.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(log.pieces.count, 1, "a pause closes and decodes a piece while still recording")
        session.cancel()
    }

    func testPreviewTextNeverBecomesTheResult() async throws {
        let engine = FakePieceEngine()
        let log = PieceLog()
        let session = committedSession(engine: engine, log: log, partials: true)
        let audio = tone(6) + [Float](repeating: 0, count: 16_000) + tone(2)
        var offset = 0
        while offset < audio.count {
            let end = min(audio.count, offset + 8_000)
            session.append(Array(audio[offset..<end]), at: offset)
            offset = end
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let result = try await session.finish(expectedSampleCount: audio.count)
        XCTAssertEqual(result.text, "tone6 tone2")
        XCTAssertFalse(log.partials.isEmpty, "the live overlay still gets words")
    }

    func testShortRecordingIsPaddedForTheDecoder() async throws {
        let engine = FakePieceEngine()
        let session = committedSession(engine: engine, log: PieceLog())
        let audio = tone(0.5)
        feed(audio, to: session)
        let result = try await session.finish(expectedSampleCount: audio.count)
        XCTAssertEqual(result.pieces.count, 1)
        let lengths = await engine.decodedLengths
        XCTAssertEqual(lengths, [IncrementalAudioTranscriber.minimumDecodeSamples])
    }

    func testTailWordedDifferentlyKeepsThePreviousPieceText() async throws {
        let engine = FakePieceEngine()
        await engine.setScript(["we ship on friday", "We ship on Friday. Crying emoji. Crying emoji."])
        let log = PieceLog()
        let session = committedSession(engine: engine, log: log)
        let audio = tone(5) + [Float](repeating: 0, count: 16_000) + tone(3)
        feed(audio, to: session)
        let result = try await session.finish(expectedSampleCount: audio.count)
        XCTAssertEqual(result.pieces.map(\.text), ["we ship on friday", "Crying emoji. Crying emoji."],
                       "the previous piece's text, and its finished cleanup, stay")
        XCTAssertTrue(RecordingTranscription.piecesCover(result.pieces, sampleCount: audio.count))
        XCTAssertEqual(log.pieces.last?.1, result.pieces.last)
    }

    func testPieceThatCantBeAlignedIsDecodedAlone() async throws {
        let engine = FakePieceEngine()
        await engine.setScript(["we ship on friday", "Something else entirely was said here.", "then the review"])
        let session = committedSession(engine: engine, log: PieceLog())
        let audio = tone(5) + [Float](repeating: 0, count: 16_000) + tone(3)
        feed(audio, to: session)
        let result = try await session.finish(expectedSampleCount: audio.count)
        XCTAssertEqual(result.pieces.map(\.text), ["we ship on friday", "then the review"])
        let lengths = await engine.decodedLengths
        XCTAssertEqual(lengths.count, 3, "merged decode, then the piece on its own")
    }

    func testEveryPieceIsDecodedWithThePieceBeforeIt() async throws {
        let engine = FakePieceEngine()
        let log = PieceLog()
        let session = committedSession(engine: engine, log: log)
        let silence = [Float](repeating: 0, count: 16_000)
        let audio = tone(5) + silence + tone(6) + silence + tone(2)
        feed(audio, to: session)
        let result = try await session.finish(expectedSampleCount: audio.count)
        XCTAssertEqual(result.pieces.map(\.text), ["tone5", "tone6", "tone2"])
        let lengths = await engine.decodedLengths
        XCTAssertEqual(lengths, [
            result.pieces[0].range.count,
            result.pieces[0].range.count + result.pieces[1].range.count,
            result.pieces[1].range.count + result.pieces[2].range.count,
        ], "a middle piece gets context too, not only the tail")
        XCTAssertEqual(log.pieces.map(\.1), result.pieces, "each piece is reported once, already with context")
    }

    func testSilentTailIsNotMerged() async throws {
        let engine = FakePieceEngine()
        let session = committedSession(engine: engine, log: PieceLog())
        let audio = tone(5) + [Float](repeating: 0, count: 40_000)
        feed(audio, to: session)
        let result = try await session.finish(expectedSampleCount: audio.count)
        let lengths = await engine.decodedLengths
        XCTAssertEqual(lengths.count, 1, "a silent tail adds no decode")
        XCTAssertEqual(result.text, "tone5")
    }

    func testNewWordsStartAfterThePreviousPieceText() {
        let previous = TranscribedPiece(range: 0..<160_000, text: "Hello there.", language: "en")
        XCTAssertEqual(IncrementalAudioTranscriber.textAfter(previous: previous, in: "Hello there. How are you?"), "How are you?")
        XCTAssertEqual(IncrementalAudioTranscriber.textAfter(previous: previous, in: "Hello there, how are you?"), "how are you?",
                       "punctuation the merged decode changed doesn't stop the split")
        XCTAssertNil(IncrementalAudioTranscriber.textAfter(previous: previous, in: "Goodbye now"))
        let silent = TranscribedPiece(range: 0..<160_000, text: "", language: "auto")
        XCTAssertEqual(IncrementalAudioTranscriber.textAfter(previous: silent, in: "Goodbye now"), "Goodbye now")
    }

    func testFailedPieceDecodeInvalidatesTheSession() async {
        let engine = FakePieceEngine()
        await engine.setFailure(onDecode: 0)
        let session = committedSession(engine: engine, log: PieceLog())
        let audio = tone(5) + [Float](repeating: 0, count: 16_000) + tone(3)
        feed(audio, to: session)
        do {
            _ = try await session.finish(expectedSampleCount: audio.count)
            XCTFail("A failed piece must fall back to the batch decode")
        } catch { }
    }

    func testSilentRecordingFallsBackToBatch() async {
        let engine = FakePieceEngine()
        let session = committedSession(engine: engine, log: PieceLog())
        let audio = [Float](repeating: 0, count: 32_000)
        feed(audio, to: session)
        do {
            _ = try await session.finish(expectedSampleCount: audio.count)
            XCTFail("Nothing decoded means no live result")
        } catch { }
        let lengths = await engine.decodedLengths
        XCTAssertEqual(lengths, [], "silence is never sent to the decoder on its own")
    }

    func testCancelDuringAPieceDecodeThrows() async throws {
        let engine = FakePieceEngine()
        let gate = TestGate()
        await engine.setHold(gate)
        let log = PieceLog()
        let session = committedSession(engine: engine, log: log)
        let audio = tone(5) + [Float](repeating: 0, count: 16_000) + tone(3)
        feed(audio, to: session)
        for _ in 0..<100 where await engine.decodedLengths.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        session.cancel()
        await gate.open()
        do {
            _ = try await session.finish(expectedSampleCount: audio.count)
            XCTFail("A cancelled session has no result")
        } catch { }
    }

    func testPiecesMustCoverTheRecording() {
        func piece(_ range: Range<Int>) -> TranscribedPiece { TranscribedPiece(range: range, text: "x", language: "en") }
        XCTAssertTrue(RecordingTranscription.piecesCover([piece(0..<5), piece(5..<9)], sampleCount: 9))
        XCTAssertFalse(RecordingTranscription.piecesCover([piece(0..<5), piece(6..<9)], sampleCount: 9))
        XCTAssertFalse(RecordingTranscription.piecesCover([piece(0..<5)], sampleCount: 9))
        XCTAssertFalse(RecordingTranscription.piecesCover([piece(1..<9)], sampleCount: 9))
    }

    func testLiveVocabularyRemembersWhatEveryPieceUsed() {
        let vocabulary = LiveVocabulary("VocaMac")
        XCTAssertTrue(vocabulary.servedOnly("VocaMac, Parakeet"), "nothing decoded yet")
        XCTAssertEqual(vocabulary.read(), "VocaMac")
        vocabulary.update("VocaMac, Parakeet")
        XCTAssertEqual(vocabulary.read(), "VocaMac, Parakeet")
        XCTAssertFalse(vocabulary.servedOnly("VocaMac, Parakeet"), "the first piece missed the context terms")
    }
}

final class RunawayTextTests: XCTestCase {
    func testDecoderLoopsAreRunaway() {
        XCTAssertTrue(RunawayText.isRunaway(String(repeating: "E ", count: 40)))
        XCTAssertTrue(RunawayText.isRunaway("and see what we can improve? " + String(repeating: "O R ", count: 30)))
        XCTAssertTrue(RunawayText.isRunaway("I write some text say hello, " + String(repeating: "ooh, ", count: 20)))
        XCTAssertTrue(RunawayText.isRunaway("two things. First" + String(repeating: "st", count: 40)))
    }

    func testOrdinarySpeechIsNot() {
        XCTAssertFalse(RunawayText.isRunaway("No, no, no, no, that's not what I meant."))
        XCTAssertFalse(RunawayText.isRunaway("Hmmmmm, let me think about the the plan."))
        XCTAssertFalse(RunawayText.isRunaway("We ship on Friday. Then we talk about the review, and then we ship again."))
        XCTAssertFalse(RunawayText.isRunaway("1 2 3 4 5 6 7 8 9 10"))
        XCTAssertFalse(RunawayText.isRunaway(""))
    }
}

extension RecordingTranscriptionTests {
    func testPreviewDecodesUseTheirOwnDecoder() async throws {
        let engine = FakePieceEngine()
        let previews = PieceLog()
        let configuration = SpeechSegmenter.Configuration(pauseSeconds: 0.6, minPieceSeconds: 4, maxPieceSeconds: 25)
        let transcribe: @Sendable ([Float]) async throws -> VocaTranscription = { try await engine.transcribe($0) }
        let preview: @Sendable ([Float]) async throws -> VocaTranscription = { samples in
            previews.appendPartial("preview")
            return VocaTranscription(text: "preview", duration: 0, detectedLanguage: "en",
                                     audioLengthSeconds: 0, modelUsed: .tiny)
        }
        let onPartial: @Sendable (String) -> Void = { _ in }
        let session = RecordingTranscription(language: "en", bufferLimit: 10_000) { chunks in
            try await IncrementalAudioTranscriber.runCommitted(
                chunks: chunks, segmenter: configuration, onPiece: nil, updateEverySamples: 16_000,
                transcribe: transcribe, previewTranscribe: preview, onPartial: onPartial
            )
        }
        let audio = tone(3) + [Float](repeating: 0, count: 8_000)
        var offset = 0
        while offset < audio.count {
            let end = min(audio.count, offset + 8_000)
            session.append(Array(audio[offset..<end]), at: offset)
            offset = end
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let result = try await session.finish(expectedSampleCount: audio.count)
        XCTAssertFalse(previews.partials.isEmpty)
        XCTAssertEqual(result.text, "tone3")
        let lengths = await engine.decodedLengths
        XCTAssertEqual(lengths, [audio.count], "the piece decoder never sees preview windows")
    }
}

// MARK: - Review fixes

extension RecordingTranscriptionTests {
    func testSpeechThatDecodesToNothingFallsBackToBatch() async {
        let engine = FakePieceEngine()
        await engine.setScript(["", "", ""])
        let session = committedSession(engine: engine, log: PieceLog())
        let audio = tone(5) + [Float](repeating: 0, count: 16_000) + tone(3)
        feed(audio, to: session)
        do {
            _ = try await session.finish(expectedSampleCount: audio.count)
            XCTFail("Words that decoded to nothing must not silently disappear")
        } catch { }
    }

    func testQuietNoiseThatDecodesToNothingIsFine() async throws {
        let engine = FakePieceEngine()
        await engine.setScript(["hello there", "", ""])
        let session = committedSession(engine: engine, log: PieceLog())
        let noise = (0..<48_000).map { _ in Float.random(in: -0.003...0.003) }
        let audio = tone(5) + [Float](repeating: 0, count: 16_000) + noise
        feed(audio, to: session)
        let result = try await session.finish(expectedSampleCount: audio.count)
        XCTAssertEqual(result.text, "hello there")
    }

    func testDecodingThatFallsFarBehindGivesUpInsteadOfBuffering() async throws {
        let engine = FakePieceEngine()
        let gate = TestGate()
        await engine.setHold(gate)
        let session = committedSession(engine: engine, log: PieceLog())
        // Longer than the cap: two 25 s pieces plus a minute of backlog.
        let audio = (0..<18).flatMap { _ in tone(5) + [Float](repeating: 0, count: 16_000) + tone(1) }
        feed(audio, to: session)
        // Let the microphone side take in the whole backlog while the first
        // decode is still stuck.
        try await Task.sleep(nanoseconds: 500_000_000)
        await gate.open()
        do {
            _ = try await session.finish(expectedSampleCount: audio.count)
            XCTFail("An unbounded backlog must fall back to the batch path")
        } catch { }
    }
}
