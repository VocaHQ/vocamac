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
            // Pieces are only usable if together they are the recording.
            guard result.pieces.isEmpty
                    || Self.piecesCover(result.pieces, sampleCount: expectedSampleCount) else {
                throw StreamError.incomplete
            }
            // Match the batch UI's latency metric: time spent waiting after stop,
            // not the user's speaking time overlapped by live inference.
            return VocaTranscription(
                text: result.text, duration: ProcessInfo.processInfo.systemUptime - start,
                detectedLanguage: result.detectedLanguage,
                audioLengthSeconds: result.audioLengthSeconds, modelUsed: result.modelUsed,
                pieces: result.pieces
            )
        } onCancel: { self.cancel() }
    }

    /// True when `pieces` are contiguous and cover exactly `0..<sampleCount`.
    static func piecesCover(_ pieces: [TranscribedPiece], sampleCount: Int) -> Bool {
        var expectedStart = 0
        for piece in pieces {
            guard piece.range.lowerBound == expectedStart, !piece.range.isEmpty else { return false }
            expectedStart = piece.range.upperBound
        }
        return expectedStart == sampleCount
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
/// second periodically decodes the most recent audio; EOF always gets one
/// final decode of the complete recording.
enum IncrementalAudioTranscriber {
    private actor Buffer {
        private var samples: [Float] = []
        private var ended = false

        func append(_ chunk: [Float]) { samples.append(contentsOf: chunk) }
        func finish() { ended = true }
        /// Cheap status poll. Returning the samples themselves every tick
        /// would hand out a reference that turns the next `append` into a copy
        /// of the whole recording — hundreds of MB per second in a long session.
        func status() -> (count: Int, ended: Bool) { (samples.count, ended) }
        func tail(_ count: Int) -> [Float] { Array(samples.suffix(count)) }
        func all() -> [Float] { samples }
    }

    /// Partial decodes see at most this much trailing audio (24 s at 16 kHz),
    /// inside Whisper's 30 s window. Re-decoding the whole recording every two
    /// seconds grows quadratically, and a partial still running when the user
    /// stops delays the final text by however long it has left.
    static let defaultPartialWindowSamples = 16_000 * 24

    static func run(
        chunks: AsyncThrowingStream<[Float], Error>,
        updateEverySamples: Int = 32_000,
        partialWindowSamples: Int = defaultPartialWindowSamples,
        transcribe: @escaping @Sendable ([Float]) async throws -> VocaTranscription,
        transcribeFinal: (@Sendable ([Float]) async throws -> VocaTranscription)? = nil,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> VocaTranscription {
        let buffer = Buffer()
        // Partials favour speed; the final decode may do extra work (such as
        // a vocabulary boost) that a preview nobody keeps does not earn.
        let transcribeFinal = transcribeFinal ?? transcribe
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
                    let status = await buffer.status()
                    if status.ended {
                        guard status.count > 0 else { throw RecordingTranscription.StreamError.incomplete }
                        return try await transcribeFinal(await buffer.all())
                    }
                    if let onPartial, status.count - lastDecodedCount >= updateEverySamples {
                        lastDecodedCount = status.count
                        let window = await buffer.tail(max(1, partialWindowSamples))
                        do {
                            let result = try await decodeUntilEnded(window, buffer: buffer, transcribe: transcribe)
                            try Task.checkCancellation()
                            guard let result else { continue }
                            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !text.isEmpty, text != lastPartial {
                                lastPartial = text
                                // Mark text that starts mid-recording, so a cut
                                // first word doesn't read as a mistake.
                                onPartial(status.count > window.count ? "… " + text : text)
                            }
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            try Task.checkCancellation()
                            VocaLogger.debug(
                                .general,
                                "Live preview decode was not ready; the complete recording remains authoritative"
                            )
                        }
                        continue
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

    /// Run one partial decode, cancelling it as soon as the stream ends so
    /// the final decode doesn't wait behind a preview nobody will see.
    /// Returns nil when the decode was abandoned for that reason. The decode
    /// has stopped by the time this returns, so the engine is never asked
    /// for two decodes at once.
    private static func decodeUntilEnded(
        _ window: [Float],
        buffer: Buffer,
        transcribe: @escaping @Sendable ([Float]) async throws -> VocaTranscription
    ) async throws -> VocaTranscription? {
        try await decodePreview(window, transcribe: transcribe) { await buffer.status().ended }
    }

    /// A preview decode that is abandoned (nil) once `shouldAbandon` says the
    /// engine has more important work.
    fileprivate static func decodePreview(
        _ window: [Float],
        pollNanoseconds: UInt64 = 50_000_000,
        transcribe: @escaping @Sendable ([Float]) async throws -> VocaTranscription,
        shouldAbandon: @escaping @Sendable () async -> Bool
    ) async throws -> VocaTranscription? {
        let decode = Task { try await transcribe(window) }
        let watcher = Task {
            while !Task.isCancelled {
                if await shouldAbandon() {
                    decode.cancel()
                    return
                }
                try? await Task.sleep(nanoseconds: pollNanoseconds)
            }
        }
        defer { watcher.cancel() }
        let outcome = await withTaskCancellationHandler {
            await decode.result
        } onCancel: {
            decode.cancel()
        }
        if decode.isCancelled, await shouldAbandon() {
            return nil
        }
        return try outcome.get()
    }
}

// MARK: - Commit mode

/// How a live session commits pieces while the user speaks.
struct StreamingCommitOptions: Sendable {
    /// Measured on 109 real dictations with Canary 180M Flash: pieces of at
    /// least 8 s differed least from the whole-recording decode (median 1.7%
    /// of words, against 2.5% at 6 s and 4.0% at 4 s) and looped least on a
    /// piece (2 recordings, against 3 and 6), for about 0.07 s more decode at
    /// stop than 6 s.
    var pauseSeconds: Double = 0.6
    var minPieceSeconds: Double = 8
    /// Called once per decoded piece, in order, including the tail decoded at
    /// stop. Runs on the decoder task; hop to the main actor before touching
    /// app state.
    var onPiece: (@Sendable (Int, TranscribedPiece) -> Void)?
    /// Read before each piece is decoded, so recognition vocabulary that
    /// arrives after recording started (screen context) still reaches later
    /// pieces. Nil uses the vocabulary the session was started with. Live
    /// preview decodes never read it: their text is not part of the result,
    /// so they must not count as a piece decoded with older vocabulary.
    var vocabulary: (@Sendable () -> String)?

    init(
        pauseSeconds: Double = 0.6,
        minPieceSeconds: Double = 8,
        onPiece: (@Sendable (Int, TranscribedPiece) -> Void)? = nil,
        vocabulary: (@Sendable () -> String)? = nil
    ) {
        self.pauseSeconds = pauseSeconds
        self.minPieceSeconds = minPieceSeconds
        self.onPiece = onPiece
        self.vocabulary = vocabulary
    }

    /// Segmenter settings for an engine that decodes at most `maxPieceSeconds`
    /// in one pass. The minimum is kept well under the limit so short-window
    /// engines (Moonshine, SenseVoice) still cut at pauses.
    func segmenterConfiguration(maxPieceSeconds: Double) -> SpeechSegmenter.Configuration {
        SpeechSegmenter.Configuration(
            pauseSeconds: pauseSeconds,
            minPieceSeconds: min(minPieceSeconds, maxPieceSeconds / 2),
            maxPieceSeconds: maxPieceSeconds
        )
    }
}

extension IncrementalAudioTranscriber {
    /// Samples, closed pieces waiting for a decode, and end of input. Audio
    /// before the oldest undecoded piece is dropped as pieces are taken.
    private actor CommitBuffer {
        private var samples: [Float] = []
        /// Absolute offset of `samples[0]`.
        private var base = 0
        private var pending: [Range<Int>] = []
        private var ended = false

        func append(_ chunk: [Float], closing closed: [Range<Int>]) {
            samples.append(contentsOf: chunk)
            pending.append(contentsOf: closed)
        }

        func finish(closing closed: [Range<Int>]) {
            pending.append(contentsOf: closed)
            ended = true
        }

        private var total: Int { base + samples.count }

        func status() -> (total: Int, hasPending: Bool, ended: Bool) {
            (total, !pending.isEmpty, ended)
        }

        /// The next closed piece and its audio.
        func takePending() -> (range: Range<Int>, samples: [Float], isLast: Bool)? {
            guard !pending.isEmpty else { return nil }
            let range = pending.removeFirst()
            let lower = range.lowerBound - base
            let upper = range.upperBound - base
            guard lower >= 0, upper <= samples.count else { return nil }
            let audio = Array(samples[lower..<upper])
            samples.removeFirst(upper)
            base = range.upperBound
            return (range, audio, ended && pending.isEmpty)
        }

        /// Audio of the piece still being spoken, at most `limit` samples.
        func openPiece(limit: Int) -> [Float] {
            let start = (pending.last?.upperBound ?? base) - base
            guard start < samples.count else { return [] }
            return Array(samples[max(start, samples.count - limit)...])
        }
    }

    /// A piece shorter than this is padded with silence before decoding;
    /// some decoders return nothing for very short input.
    static let minimumDecodeSamples = 16_000

    /// A piece whose loudest frame is below this (about -60 dBFS) holds no
    /// speech. Decoding silence on its own invites a hallucinated "Thank you."
    static let silentPieceEnergy: Float = 1e-6

    /// Decode each piece once, as soon as a pause closes it, and return the
    /// joined text and the pieces at EOF, when only the tail is left.
    ///
    /// A failed piece decode throws, which invalidates the session: the caller
    /// then decodes the complete recording in batch. Partials show the
    /// committed text plus a preview of the open piece; the preview is never
    /// part of the result.
    static func runCommitted(
        chunks: AsyncThrowingStream<[Float], Error>,
        segmenter configuration: SpeechSegmenter.Configuration,
        onPiece: (@Sendable (Int, TranscribedPiece) -> Void)?,
        updateEverySamples: Int = 32_000,
        transcribe: @escaping @Sendable ([Float]) async throws -> VocaTranscription,
        previewTranscribe: (@Sendable ([Float]) async throws -> VocaTranscription)? = nil,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> VocaTranscription {
        let buffer = CommitBuffer()
        let transcribePreview = previewTranscribe ?? transcribe
        return try await withThrowingTaskGroup(of: VocaTranscription?.self) { group in
            group.addTask {
                var segmenter = SpeechSegmenter(configuration: configuration)
                for try await chunk in chunks {
                    try Task.checkCancellation()
                    let closed = segmenter.append(chunk)
                    for _ in closed { PerformanceTrace.event("PieceClosed") }
                    await buffer.append(chunk, closing: closed)
                }
                await buffer.finish(closing: segmenter.finish())
                return nil
            }
            group.addTask {
                var pieces: [TranscribedPiece] = []
                var modelUsed: ModelSize?
                var lastPreviewCount = 0
                while true {
                    try Task.checkCancellation()
                    if let next = await buffer.takePending() {
                        let interval = PerformanceTrace.begin(next.isLast ? "TailDecode" : "PieceDecode")
                        let piece: TranscribedPiece
                        do {
                            defer { PerformanceTrace.end(interval) }
                            piece = try await decodePiece(next.range, samples: next.samples, transcribe: transcribe) {
                                modelUsed = $0
                            }
                        }
                        pieces.append(piece)
                        onPiece?(pieces.count - 1, piece)
                        if let onPartial, !piece.text.isEmpty {
                            onPartial(TranscribedPiece.join(pieces))
                        }
                        continue
                    }
                    let status = await buffer.status()
                    if status.ended {
                        guard status.total > 0, let modelUsed else {
                            throw RecordingTranscription.StreamError.incomplete
                        }
                        let language = pieces.first { !$0.text.isEmpty }?.language
                            ?? pieces.first?.language ?? "auto"
                        return VocaTranscription(
                            text: TranscribedPiece.join(pieces), duration: 0,
                            detectedLanguage: language,
                            audioLengthSeconds: Double(status.total) / 16_000,
                            modelUsed: modelUsed, pieces: pieces
                        )
                    }
                    if let onPartial, status.total - lastPreviewCount >= updateEverySamples {
                        lastPreviewCount = status.total
                        let window = await buffer.openPiece(
                            limit: Int(configuration.maxPieceSeconds * Double(configuration.sampleRate))
                        )
                        guard window.count >= updateEverySamples / 2 else { continue }
                        do {
                            let preview = try await decodePreview(window, transcribe: transcribePreview) {
                                let status = await buffer.status()
                                return status.ended || status.hasPending
                            }
                            try Task.checkCancellation()
                            if let preview {
                                onPartial(TranscribedPiece.join(pieces.map(\.text) + [preview.text]))
                            }
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            try Task.checkCancellation()
                            VocaLogger.debug(.general, "Live preview decode was not ready; committed pieces are unaffected")
                        }
                        continue
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
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

    private static func decodePiece(
        _ range: Range<Int>,
        samples: [Float],
        transcribe: @Sendable ([Float]) async throws -> VocaTranscription,
        recordModel: (ModelSize) -> Void
    ) async throws -> TranscribedPiece {
        // A recording that is silent throughout never sets the model, so the
        // session fails and the batch path answers it as it does today.
        guard !isSilent(samples) else {
            return TranscribedPiece(range: range, text: "", language: "auto")
        }
        let result = try await transcribe(padded(samples))
        // A decoder stuck in a loop on a short piece ("E E E E…") would be
        // pasted and cleaned as if it were speech. Give the whole recording
        // to the batch path instead, which sees the piece in context.
        guard !RunawayText.isRunaway(result.text) else {
            PerformanceTrace.event("PieceRunawayDecode")
            VocaLogger.warning(.general, "A piece decoded to repeated text; decoding the complete recording instead")
            throw RecordingTranscription.StreamError.incomplete
        }
        recordModel(result.modelUsed)
        return TranscribedPiece(
            range: range,
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            language: result.detectedLanguage
        )
    }

    static func padded(_ samples: [Float]) -> [Float] {
        guard samples.count < minimumDecodeSamples else { return samples }
        return samples + [Float](repeating: 0, count: minimumDecodeSamples - samples.count)
    }

    static func isSilent(_ samples: [Float]) -> Bool {
        let frame = AudioSegmenter.frameLength
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + frame)
            if SpeechSegmenter.energy(samples[start..<end]) >= silentPieceEnergy { return false }
            start = end
        }
        return true
    }
}

/// Recognition vocabulary for a commit-mode Whisper session. Screen context
/// terms arrive after recording starts, so pieces decoded later read the
/// newer vocabulary. At stop the session's pieces are only trusted if every
/// piece was decoded with the vocabulary the batch path would have used.
final class LiveVocabulary: @unchecked Sendable {
    private struct State {
        var current: String
        var served: Set<String> = []
    }
    private let state: OSAllocatedUnfairLock<State>

    init(_ initial: String) {
        state = OSAllocatedUnfairLock(initialState: State(current: initial))
    }

    /// The vocabulary for the next decode; remembered as served.
    func read() -> String {
        state.withLock { state in
            state.served.insert(state.current)
            return state.current
        }
    }

    func update(_ vocabulary: String) {
        state.withLock { $0.current = vocabulary }
    }

    /// True when no decode so far used anything but `vocabulary`.
    func servedOnly(_ vocabulary: String) -> Bool {
        state.withLock { $0.served.isSubset(of: [vocabulary]) }
    }
}

/// Output of a decoder that got stuck repeating itself, which the offline
/// ONNX models occasionally do on short pieces: "E E E E …", "O R O R …",
/// "ooh, ooh, ooh, …", "Firststststst…".
enum RunawayText {
    /// Consecutive repeats that count as a loop rather than emphasis. People
    /// do say "no, no, no, no"; nobody says a word eight times running.
    static let minimumRepeats = 8

    static func isRunaway(_ text: String) -> Bool {
        let words = text.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map(String.init)
        for size in 1...3 where repeatsConsecutively(words, unit: size) {
            return true
        }
        for word in words where word.count >= minimumRepeats * 2 {
            let characters = Array(word)
            for size in 2...4 where repeatsConsecutively(characters, unit: size) {
                return true
            }
        }
        return false
    }

    /// Whether some run of `unit` elements repeats `minimumRepeats` times in
    /// a row: element i equals element i + unit for enough consecutive i.
    private static func repeatsConsecutively<Element: Equatable>(_ elements: [Element], unit: Int) -> Bool {
        let needed = unit * (minimumRepeats - 1)
        guard elements.count >= needed + unit else { return false }
        var run = 0
        for index in 0..<(elements.count - unit) {
            if elements[index] == elements[index + unit] {
                run += 1
                if run >= needed { return true }
            } else {
                run = 0
            }
        }
        return false
    }
}
