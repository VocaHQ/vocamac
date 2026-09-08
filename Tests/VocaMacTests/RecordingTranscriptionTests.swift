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
