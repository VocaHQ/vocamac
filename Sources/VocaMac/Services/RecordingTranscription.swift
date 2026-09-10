import Foundation
import os

/// A bounded, nonblocking bridge from the microphone to an engine session.
/// Overflow or a capture restart invalidates streaming; AppState retains the
/// complete recording and retries through the normal batch path.
final class RecordingTranscription: @unchecked Sendable {
    enum StreamError: Error { case discontinuity, overflow, incomplete }

    let language: String?
    private struct State {
        var sampleCount = 0
        var ended = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let continuation: AsyncThrowingStream<[Float], Error>.Continuation
    private let task: Task<VocaTranscription, Error>

    init(
        language: String?,
        bufferLimit: Int = 32,
        transcribe: @escaping @Sendable (AsyncThrowingStream<[Float], Error>) async throws -> VocaTranscription
    ) {
        self.language = language
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream(
            bufferingPolicy: .bufferingOldest(max(1, bufferLimit))
        )
        self.continuation = continuation
        task = Task(priority: .userInitiated) { try await transcribe(stream) }
    }

    func append(_ samples: [Float], at offset: Int) {
        guard !samples.isEmpty else { return }
        state.withLock { state in
            guard !state.ended else { return }
            guard offset == state.sampleCount else {
                state.ended = true
                continuation.finish(throwing: StreamError.discontinuity)
                return
            }
            state.sampleCount += samples.count
            if case .dropped = continuation.yield(samples) {
                state.ended = true
                continuation.finish(throwing: StreamError.overflow)
            }
        }
    }

    func finish(expectedSampleCount: Int) async throws -> VocaTranscription {
        let interval = PerformanceTrace.begin("StreamingFinalize")
        defer { PerformanceTrace.end(interval) }
        let complete = state.withLock { state in
            let complete = state.sampleCount == expectedSampleCount && !state.ended
            state.ended = true
            return complete
        }
        guard complete else {
            cancel()
            _ = try? await task.value
            throw StreamError.incomplete
        }
        let start = ProcessInfo.processInfo.systemUptime
        continuation.finish()
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            guard result.audioLengthSeconds.isFinite,
                  abs(result.audioLengthSeconds * 16_000 - Double(expectedSampleCount)) < 0.5 else {
                throw StreamError.incomplete
            }
            // Match the batch UI's latency metric: time spent waiting after stop,
            // not the user's speaking time overlapped by live inference.
            return VocaTranscription(
                text: result.text, duration: ProcessInfo.processInfo.systemUptime - start,
                detectedLanguage: result.detectedLanguage,
                audioLengthSeconds: result.audioLengthSeconds, modelUsed: result.modelUsed
            )
        } onCancel: { self.cancel() }
    }

    func cancel() {
        state.withLock { $0.ended = true }
        continuation.finish(throwing: CancellationError())
        task.cancel()
    }

    deinit { continuation.finish(); task.cancel() }
}

/// Pull-based batch input avoids enqueuing another full recording in a stream.
actor AudioChunkCursor {
    private let samples: [Float]
    private var offset = 0
    init(_ samples: [Float]) { self.samples = samples }

    func next() -> [Float]? {
        guard offset < samples.count else { return nil }
        let end = min(samples.count, offset + 16_000)
        defer { offset = end }
        return Array(samples[offset..<end])
    }
}

/// Turns a batch engine into a bounded live preview without making partial
/// text authoritative. One task drains microphone chunks immediately while a
/// second periodically decodes a snapshot; EOF always gets one final decode.
enum IncrementalAudioTranscriber {
    private actor Buffer {
        private var samples: [Float] = []
        private var ended = false

        func append(_ chunk: [Float]) { samples.append(contentsOf: chunk) }
        func finish() { ended = true }
        func snapshot() -> (samples: [Float], ended: Bool) { (samples, ended) }
    }

    static func run(
        chunks: AsyncThrowingStream<[Float], Error>,
        updateEverySamples: Int = 32_000,
        transcribe: @escaping @Sendable ([Float]) async throws -> VocaTranscription,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> VocaTranscription {
        let buffer = Buffer()
        return try await withThrowingTaskGroup(of: VocaTranscription?.self) { group in
            group.addTask {
                for try await chunk in chunks {
                    try Task.checkCancellation()
                    await buffer.append(chunk)
                }
                await buffer.finish()
                return nil
            }
            group.addTask {
                var lastDecodedCount = 0
                var lastPartial = ""
                while true {
                    try Task.checkCancellation()
                    let snapshot = await buffer.snapshot()
                    let shouldDecode = !snapshot.samples.isEmpty
                        && (snapshot.ended || (
                            onPartial != nil
                                && snapshot.samples.count - lastDecodedCount >= updateEverySamples
                        ))
                    if shouldDecode {
                        lastDecodedCount = snapshot.samples.count
                        do {
                            let result = try await transcribe(snapshot.samples)
                            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !snapshot.ended, !text.isEmpty, text != lastPartial {
                                lastPartial = text
                                onPartial?(text)
                            }
                            if snapshot.ended { return result }
                        } catch {
                            if snapshot.ended { throw error }
                            VocaLogger.debug(
                                .general,
                                "Live preview decode was not ready; the complete recording remains authoritative"
                            )
                        }
                    } else if snapshot.ended {
                        throw RecordingTranscription.StreamError.incomplete
                    }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
            }

            while let next = try await group.next() {
                if let result = next {
                    group.cancelAll()
                    return result
                }
            }
            throw RecordingTranscription.StreamError.incomplete
        }
    }
}
