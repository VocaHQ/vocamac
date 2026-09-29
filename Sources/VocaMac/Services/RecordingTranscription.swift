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
    /// app state. With `revisesPrevious`, it can be called a second time for
    /// a piece whose words the next piece's decode corrected.
    var onPiece: (@Sendable (Int, TranscribedPiece) -> Void)?
    /// Called with the piece still being spoken, decoded early in a short
    /// quiet stretch, so its cleanup can start before stop too. If speech
    /// resumes, the piece is decoded again and this text is never used.
    var onTentativePiece: (@Sendable (Int, TranscribedPiece) -> Void)?
    /// Read before each piece is decoded, so recognition vocabulary that
    /// arrives after recording started (screen context) still reaches later
    /// pieces. Nil uses the vocabulary the session was started with. Live
    /// preview decodes never read it: their text is not part of the result,
    /// so they must not count as a piece decoded with older vocabulary.
    var vocabulary: (@Sendable () -> String)?
    /// Quiet this long after speech decodes the piece being spoken, so a
    /// stop that follows finds the last piece already decoded. For sessions
    /// that stop on silence; nil never decodes early.
    var earlyDecodeQuietSeconds: Double?
    /// Whether an early decode may run yet. A decode kept with vocabulary
    /// that has since changed would send the whole recording to the batch
    /// path, so Whisper waits for its screen-context terms. Nil always may.
    var isReadyForEarlyDecode: (@Sendable () -> Bool)?
    /// Let each piece's decode, which hears the end of the piece before it
    /// together with what followed, correct that piece's words. Measured on
    /// 80 real dictations against the other engine's whole-recording decode:
    /// Canary 180M Flash errors 7.1% -> 6.6%, Parakeet v3 7.4% -> 7.2%.
    ///
    /// Free without cleanup. With it, a corrected piece is cleaned a second
    /// time: on a 45 s dictation (Canary + Ministral 3 3B) the median wait
    /// after stop went from 0.87 s to 1.66 s and energy from 51 J to 84 J,
    /// so the app turns this off when it cleans pieces ahead.
    var revisesPrevious = true

    init(
        pauseSeconds: Double = 0.6,
        minPieceSeconds: Double = 8,
        onPiece: (@Sendable (Int, TranscribedPiece) -> Void)? = nil,
        onTentativePiece: (@Sendable (Int, TranscribedPiece) -> Void)? = nil,
        vocabulary: (@Sendable () -> String)? = nil,
        earlyDecodeQuietSeconds: Double? = nil,
        isReadyForEarlyDecode: (@Sendable () -> Bool)? = nil,
        revisesPrevious: Bool = true
    ) {
        self.pauseSeconds = pauseSeconds
        self.minPieceSeconds = minPieceSeconds
        self.onPiece = onPiece
        self.onTentativePiece = onTentativePiece
        self.vocabulary = vocabulary
        self.earlyDecodeQuietSeconds = earlyDecodeQuietSeconds
        self.isReadyForEarlyDecode = isReadyForEarlyDecode
        self.revisesPrevious = revisesPrevious
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
    /// is kept from the start of the last decoded piece, so the next piece
    /// can be decoded together with it; anything older is dropped.
    private actor CommitBuffer {
        private var samples: [Float] = []
        /// Absolute offset of `samples[0]`.
        private var base = 0
        /// Where the last piece taken for decoding started and ended. Its
        /// audio is kept until the next piece is taken.
        private var takenStart = 0
        private var takenEnd = 0
        private var pending: [SpeechSegmenter.ClosedPiece] = []
        private var ended = false
        private var lastSpeechEnd = 0

        struct Status {
            let total: Int
            let hasPending: Bool
            let ended: Bool
            /// Where the piece still being spoken starts.
            let openStart: Int
            /// End of the last sound the segmenter heard.
            let lastSpeechEnd: Int
        }

        func append(_ chunk: [Float], closing closed: [SpeechSegmenter.ClosedPiece], lastSpeechEnd: Int) {
            samples.append(contentsOf: chunk)
            pending.append(contentsOf: closed)
            self.lastSpeechEnd = lastSpeechEnd
        }

        func finish(closing closed: [SpeechSegmenter.ClosedPiece], lastSpeechEnd: Int) {
            pending.append(contentsOf: closed)
            self.lastSpeechEnd = lastSpeechEnd
            ended = true
        }

        private var total: Int { base + samples.count }
        private var openStart: Int { pending.last?.range.upperBound ?? takenEnd }

        /// Audio held but not yet decoded, plus the previous piece kept for
        /// context.
        var heldSamples: Int { samples.count }

        func status() -> Status {
            Status(
                total: total, hasPending: !pending.isEmpty, ended: ended,
                openStart: openStart, lastSpeechEnd: lastSpeechEnd
            )
        }

        /// The next closed piece and its audio.
        func takePending() -> (piece: SpeechSegmenter.ClosedPiece, samples: [Float], isLast: Bool)? {
            guard !pending.isEmpty else { return nil }
            let piece = pending.removeFirst()
            let lower = piece.range.lowerBound - base
            let upper = piece.range.upperBound - base
            guard lower >= 0, upper <= samples.count else { return nil }
            let audio = Array(samples[lower..<upper])
            // Keep the previous piece too: the next one is decoded with it.
            samples.removeFirst(takenStart - base)
            base = takenStart
            takenStart = piece.range.lowerBound
            takenEnd = piece.range.upperBound
            return (piece, audio, ended && pending.isEmpty)
        }

        /// Audio still held for `range`, or nil once it has been dropped.
        func audio(_ range: Range<Int>) -> [Float]? {
            let lower = range.lowerBound - base
            let upper = range.upperBound - base
            guard lower >= 0, upper <= samples.count, lower < upper else { return nil }
            return Array(samples[lower..<upper])
        }

        /// Audio of the piece still being spoken, at most its last `limit`
        /// samples, and the absolute offset they start at.
        func openPiece(limit: Int) -> (start: Int, samples: [Float]) {
            let start = max(openStart, total - max(0, limit))
            guard start < total else { return (start, []) }
            return (start, Array(samples[(start - base)...]))
        }
    }

    /// A piece shorter than this is padded with silence before decoding;
    /// some decoders return nothing for very short input.
    static let minimumDecodeSamples = 16_000

    /// A piece whose loudest frame is below this (about -60 dBFS) holds no
    /// speech. Decoding silence on its own invites a hallucinated "Thank you."
    static let silentPieceEnergy: Float = 1e-6

    /// Live previews in commit mode decode at most this much of the piece
    /// being spoken (8 s). Some engines can't stop a decode halfway, so a
    /// preview still running at stop delays the last piece by whatever it
    /// has left; a short window keeps that small.
    static let defaultCommitPreviewWindowSamples = 16_000 * 8

    /// Decode each piece once, as soon as a pause closes it, and return the
    /// joined text and the pieces at EOF, when only the tail is left.
    ///
    /// A failed piece decode throws, which invalidates the session: the caller
    /// then decodes the complete recording in batch. Partials show the
    /// committed text plus a preview of the open piece; the preview is never
    /// part of the result.
    ///
    /// With `earlyDecodeQuietSeconds`, the piece being spoken is also decoded
    /// whenever the speaker goes quiet that long. If nothing near speech
    /// level follows before the piece closes, that decode is the piece, so a
    /// stop after a short silence has nothing left to decode.
    static func runCommitted(
        chunks: AsyncThrowingStream<[Float], Error>,
        segmenter configuration: SpeechSegmenter.Configuration,
        onPiece: (@Sendable (Int, TranscribedPiece) -> Void)?,
        onTentativePiece: (@Sendable (Int, TranscribedPiece) -> Void)? = nil,
        earlyDecodeQuietSeconds: Double? = nil,
        isReadyForEarlyDecode: (@Sendable () -> Bool)? = nil,
        revisesPrevious: Bool = false,
        updateEverySamples: Int = 32_000,
        previewWindowSamples: Int = defaultCommitPreviewWindowSamples,
        transcribe: @escaping @Sendable ([Float]) async throws -> VocaTranscription,
        previewTranscribe: (@Sendable ([Float]) async throws -> VocaTranscription)? = nil,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> VocaTranscription {
        let buffer = CommitBuffer()
        let transcribePreview = previewTranscribe ?? transcribe
        let maxPieceSamples = Int(configuration.maxPieceSeconds * Double(configuration.sampleRate))
        let earlyQuietSamples = earlyDecodeQuietSeconds.map { Int($0 * Double(configuration.sampleRate)) }
        return try await withThrowingTaskGroup(of: VocaTranscription?.self) { group in
            group.addTask {
                var segmenter = SpeechSegmenter(configuration: configuration)
                let maxHeldSamples = Int((2 * configuration.maxPieceSeconds + maxBacklogSeconds) * 16_000)
                for try await chunk in chunks {
                    try Task.checkCancellation()
                    let closed = segmenter.appendPieces(chunk)
                    for _ in closed { PerformanceTrace.event("PieceClosed") }
                    await buffer.append(chunk, closing: closed, lastSpeechEnd: segmenter.lastSpeechEnd)
                    // Decoding has fallen behind the microphone. Holding the
                    // backlog would grow without bound; give up on pieces and
                    // let the batch path decode the recording at stop.
                    guard await buffer.heldSamples <= maxHeldSamples else {
                        VocaLogger.warning(.general, "Piece decoding fell behind; the complete recording will be decoded at stop")
                        throw RecordingTranscription.StreamError.overflow
                    }
                }
                let tail = segmenter.finishPieces()
                await buffer.finish(closing: tail, lastSpeechEnd: segmenter.lastSpeechEnd)
                return nil
            }
            group.addTask {
                var pieces: [TranscribedPiece] = []
                var modelUsed: ModelSize?
                var lastPreviewCount = 0
                /// The piece being spoken, decoded early, and where the audio
                /// that decode heard ended.
                var early: (decode: CommittedDecode, start: Int, heardEnd: Int)?
                /// Speech end the last early decode was started for, so each
                /// quiet stretch is decoded at most once.
                var earlySpeechEnd = 0
                let audio: @Sendable (Range<Int>) async -> [Float]? = { await buffer.audio($0) }

                func keep(_ decode: CommittedDecode) {
                    if let revised = decode.revisedPrevious, let last = pieces.indices.last {
                        pieces[last] = revised
                        onPiece?(last, revised)
                    }
                    modelUsed = decode.modelUsed ?? modelUsed
                    pieces.append(decode.piece)
                    onPiece?(pieces.count - 1, decode.piece)
                    if let onPartial, !decode.piece.text.isEmpty {
                        onPartial(TranscribedPiece.join(pieces))
                    }
                }

                while true {
                    try Task.checkCancellation()
                    if let next = await buffer.takePending() {
                        let interval = PerformanceTrace.begin(next.isLast ? "TailDecode" : "PieceDecode")
                        defer { PerformanceTrace.end(interval) }
                        let earlyFits: Bool
                        if let early, early.start == next.piece.range.lowerBound {
                            let after = early.heardEnd < next.piece.range.upperBound
                                ? await buffer.audio(early.heardEnd..<next.piece.range.upperBound) : []
                            earlyFits = isEarlyDecode(heardEnd: early.heardEnd, usableFor: next.piece, audioAfter: after)
                        } else {
                            earlyFits = false
                        }
                        if let early, earlyFits {
                            PerformanceTrace.event("EarlyDecodeUsed")
                            keep(CommittedDecode(
                                piece: TranscribedPiece(
                                    range: next.piece.range, text: early.decode.piece.text,
                                    language: early.decode.piece.language
                                ),
                                revisedPrevious: early.decode.revisedPrevious,
                                modelUsed: early.decode.modelUsed
                            ))
                        } else {
                            keep(try await decodeCommitted(
                                next.piece.range, samples: next.samples, previous: pieces.last,
                                maxPieceSamples: maxPieceSamples, revisesPrevious: revisesPrevious,
                                audio: audio, transcribe: transcribe
                            ))
                        }
                        early = nil
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
                    if let earlyQuietSamples,
                       status.lastSpeechEnd > status.openStart,
                       status.lastSpeechEnd > earlySpeechEnd,
                       status.total - status.lastSpeechEnd >= earlyQuietSamples,
                       isReadyForEarlyDecode?() ?? true {
                        earlySpeechEnd = status.lastSpeechEnd
                        let open = await buffer.openPiece(limit: maxPieceSamples)
                        guard open.start == status.openStart, !open.samples.isEmpty else { continue }
                        let range = open.start..<(open.start + open.samples.count)
                        let interval = PerformanceTrace.begin("EarlyDecode")
                        defer { PerformanceTrace.end(interval) }
                        do {
                            let decode = try await decodeCommitted(
                                range, samples: open.samples, previous: pieces.last,
                                maxPieceSamples: maxPieceSamples, revisesPrevious: revisesPrevious,
                                audio: audio, transcribe: transcribe
                            )
                            try Task.checkCancellation()
                            early = (decode, range.lowerBound, range.upperBound)
                            onTentativePiece?(pieces.count, decode.piece)
                            if let onPartial, !decode.piece.text.isEmpty {
                                onPartial(TranscribedPiece.join(pieces.map(\.text) + [decode.piece.text]))
                                lastPreviewCount = status.total
                            }
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // The piece is decoded again when it closes, and a
                            // real failure then invalidates the session.
                            try Task.checkCancellation()
                            early = nil
                        }
                        continue
                    }
                    if let onPartial, status.total - lastPreviewCount >= updateEverySamples {
                        lastPreviewCount = status.total
                        let window = await buffer.openPiece(limit: previewWindowSamples)
                        guard window.samples.count >= updateEverySamples / 2 else { continue }
                        do {
                            let preview = try await decodePreview(window.samples, transcribe: transcribePreview) {
                                let status = await buffer.status()
                                return status.ended || status.hasPending
                            }
                            try Task.checkCancellation()
                            if let preview {
                                let text = preview.text.trimmingCharacters(in: .whitespacesAndNewlines)
                                // Mark a preview that starts partway into the
                                // piece, so a cut first word doesn't read as a
                                // mistake.
                                let shown = window.start > status.openStart && !text.isEmpty ? "… " + text : text
                                onPartial(TranscribedPiece.join(pieces.map(\.text) + [shown]))
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

    /// Whether an early decode of the piece being spoken can stand for the
    /// piece that closed: it heard every sound the segmenter found in it, and
    /// nothing after what it heard comes near speech level (a soft last word
    /// the relative measure might call quiet).
    static func isEarlyDecode(
        heardEnd: Int, usableFor piece: SpeechSegmenter.ClosedPiece, audioAfter: [Float]?
    ) -> Bool {
        guard piece.speechEnd <= heardEnd else { return false }
        guard let audioAfter else { return false }
        return !containsSpeechLevel(audioAfter)
    }

    // MARK: - One piece

    /// A piece decoded the way a session keeps it.
    struct CommittedDecode: Sendable {
        let piece: TranscribedPiece
        /// The previous piece as this decode heard it, when its words differ
        /// and the caller asked for revisions.
        let revisedPrevious: TranscribedPiece?
        /// Nil when nothing was decoded (a silent piece).
        let modelUsed: ModelSize?
    }

    /// Decode `range`. Every piece after the first is decoded together with
    /// as much of the piece before it as fits in one pass of the engine, so
    /// it doesn't start cold after a pause: on its own a piece loses the
    /// words that decide "flour" from "flower", and drops repeated phrases.
    /// Only the words after the previous piece's text are kept; that piece,
    /// and any cleanup already done for it, stays as it was unless
    /// `revisesPrevious` lets the merged decode correct its last words. A
    /// merged decode that can't be lined up with the previous piece is
    /// dropped and the piece is decoded alone.
    ///
    /// Throws when the piece loops or its speech decodes to nothing, so the
    /// session falls back to decoding the whole recording.
    static func decodeCommitted(
        _ range: Range<Int>,
        samples: [Float],
        previous: TranscribedPiece?,
        maxPieceSamples: Int,
        revisesPrevious: Bool = false,
        audio: (Range<Int>) async -> [Float]?,
        transcribe: @Sendable ([Float]) async throws -> VocaTranscription
    ) async throws -> CommittedDecode {
        var modelUsed: ModelSize?
        var contextual: TranscribedPiece?
        var revised: TranscribedPiece?
        if let previous, !isSilent(samples),
           let previousAudio = await audio(previous.range),
           let start = contextStart(
               previous: previous.range, next: range, maxSamples: maxPieceSamples, previousAudio: previousAudio
           ),
           let mergedAudio = await audio(start..<range.upperBound) {
            let merged = try await decodePiece(
                start..<range.upperBound, samples: mergedAudio, transcribe: transcribe
            ) { modelUsed = $0 }
            if let split = split(merged.text, previous: previous, contextStart: start) {
                contextual = TranscribedPiece(range: range, text: split.newText, language: merged.language)
                if revisesPrevious, let text = split.revisedPrevious {
                    revised = TranscribedPiece(range: previous.range, text: text, language: previous.language)
                }
            }
        }
        let piece: TranscribedPiece
        if let contextual, !(contextual.text.isEmpty && hasSpeech(samples)) {
            piece = contextual
        } else {
            // First piece, or the merged text couldn't be lined up with the
            // previous piece: decode this one alone.
            revised = nil
            piece = try await decodePiece(range, samples: samples, transcribe: transcribe) { modelUsed = $0 }
        }
        // Speech that decoded to nothing (a decoder that stopped on its first
        // token) must not vanish from the result.
        guard !(piece.text.isEmpty && hasSpeech(samples)) else {
            VocaLogger.warning(.general, "A piece with speech decoded to nothing; decoding the complete recording instead")
            throw RecordingTranscription.StreamError.incomplete
        }
        return CommittedDecode(piece: piece, revisedPrevious: revised, modelUsed: modelUsed)
    }

    /// Less context than this (2 s) barely helps a piece and still costs a
    /// decode, so the piece is decoded alone instead.
    static let minimumContextSamples = 32_000

    /// Where to look for a pause to start the context in (2 s).
    static let contextSearchSamples = 32_000

    /// Where the context for `next` starts: the start of the previous piece
    /// when both fit in one pass of the engine. Otherwise as much of the end
    /// of the previous piece as fits, starting in a pause so the first word
    /// isn't cut in half, or nil when less than `minimumContextSamples` fits.
    ///
    /// Engines split longer audio themselves (SherpaService at its segment
    /// limit), usually at the very pause between the two pieces, which gives
    /// back a cold start for twice the decode.
    static func contextStart(
        previous: Range<Int>, next: Range<Int>, maxSamples: Int, previousAudio: [Float]
    ) -> Int? {
        let budget = maxSamples - next.count
        if budget >= previous.count { return previous.lowerBound }
        guard budget >= minimumContextSamples, previousAudio.count == previous.count else { return nil }
        let earliest = previous.upperBound - budget
        let searchEnd = min(earliest + contextSearchSamples, previous.upperBound - minimumContextSamples)
        let frame = AudioSegmenter.frameLength
        var energies: [Float] = []
        var offsets: [Int] = []
        var offset = earliest
        while offset + frame <= searchEnd {
            let local = offset - previous.lowerBound
            energies.append(SpeechSegmenter.energy(previousAudio[local..<(local + frame)]))
            offsets.append(offset)
            offset += frame
        }
        guard !energies.isEmpty else { return earliest }
        let cut = AudioSegmenter.bestCutOffset(energies: energies, frameOffsets: offsets, fallback: earliest)
        return min(max(cut, earliest), searchEnd)
    }

    /// The words of `merged`, a decode of `previous` and the piece after it,
    /// that belong to the new piece. Nil when `previous`'s text can't be found
    /// at the start of it.
    static func textAfter(previous: TranscribedPiece, in merged: String) -> String? {
        split(merged, previous: previous, contextStart: previous.range.lowerBound)?.newText
    }

    /// Split a decode of context audio (from `contextStart` to the end of
    /// `previous`) followed by a new piece into the new piece's words and,
    /// when they differ from its text, the previous piece as this decode
    /// heard it.
    ///
    /// An exact prefix is the common case. The merged decode often words the
    /// previous piece slightly differently ("hour." for "hour,"), so failing
    /// that, the best word alignment with it decides where the new words
    /// start.
    static func split(
        _ merged: String, previous: TranscribedPiece, contextStart: Int
    ) -> (newText: String, revisedPrevious: String?)? {
        let prefix = previous.text
        guard !prefix.isEmpty else { return (merged.trimmingCharacters(in: .whitespacesAndNewlines), nil) }
        let wholeContext = contextStart <= previous.range.lowerBound
        if wholeContext, merged.hasPrefix(prefix) {
            let rest = merged.dropFirst(prefix.count)
            if rest.isEmpty || rest.first?.isWhitespace == true {
                return (rest.trimmingCharacters(in: .whitespacesAndNewlines), nil)
            }
        }
        let contextSamples = previous.range.upperBound - max(contextStart, previous.range.lowerBound)
        guard let alignment = OverlapDeduplication.align(
            decoded: merged, previous: prefix,
            contextSeconds: Double(contextSamples) / 16_000,
            contextShare: Double(contextSamples) / Double(max(1, previous.range.count))
        ) else { return nil }
        let decodedWords = OverlapDeduplication.words(merged)
        let previousWords = OverlapDeduplication.words(prefix)
        let newText = decodedWords.dropFirst(alignment.decodedEnd).joined(separator: " ")
        let heard = Array(decodedWords[alignment.decodedStart..<alignment.decodedEnd])
        let kept = Array(previousWords[alignment.previousStart...])
        guard revision(of: kept, heard: heard) != nil else { return (newText, nil) }
        // Keep the piece's own words up to the first real change: the merged
        // decode starts at the context, and capitalizes whatever word it
        // started on as if a sentence began there ("route, We are").
        var shared = 0
        while shared < min(kept.count, heard.count),
              OverlapDeduplication.normalized(kept[shared]) == OverlapDeduplication.normalized(heard[shared]) {
            shared += 1
        }
        let revised = previousWords[..<(alignment.previousStart + shared)] + heard[shared...]
        return (newText, revised.joined(separator: " "))
    }

    /// The previous piece's last words as a later decode heard them, when
    /// that decode changed a few words (not just punctuation or case). A
    /// larger change more likely means a bad alignment than a better hearing.
    static func revision(of kept: [String], heard: [String]) -> [String]? {
        let keptWords = kept.map(OverlapDeduplication.normalized).filter { !$0.isEmpty }
        let heardWords = heard.map(OverlapDeduplication.normalized).filter { !$0.isEmpty }
        guard !heardWords.isEmpty, keptWords != heardWords else { return nil }
        let allowed = max(1, keptWords.count / 5)
        guard OverlapDeduplication.editDistance(keptWords, heardWords) <= allowed else { return nil }
        return heard
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

    /// How far piece decoding may fall behind the microphone, beyond the
    /// open and previous pieces, before the session gives up.
    static let maxBacklogSeconds = 60.0

    /// Frames at or above this energy (about -40 dBFS) are speech-level;
    /// room noise sits well below it.
    static let speechEnergy: Float = 1e-4

    /// Whether a piece holds at least a quarter second of speech-level sound,
    /// so an empty transcript for it means lost words rather than noise.
    static func hasSpeech(_ samples: [Float]) -> Bool {
        let frame = AudioSegmenter.frameLength
        var loudFrames = 0
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + frame)
            if SpeechSegmenter.energy(samples[start..<end]) >= speechEnergy {
                loudFrames += 1
                if loudFrames * frame >= 4_000 { return true }
            }
            start = end
        }
        return false
    }

    /// Whether any frame of `samples` reaches speech level.
    static func containsSpeechLevel(_ samples: [Float]) -> Bool {
        let frame = AudioSegmenter.frameLength
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + frame)
            if SpeechSegmenter.energy(samples[start..<end]) >= speechEnergy { return true }
            start = end
        }
        return false
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
        var isSettled: Bool
    }
    private let state: OSAllocatedUnfairLock<State>

    /// - Parameter settled: False while screen-context terms may still
    ///   change the vocabulary.
    init(_ initial: String, settled: Bool = true) {
        state = OSAllocatedUnfairLock(initialState: State(current: initial, isSettled: settled))
    }

    /// The vocabulary for the next decode; remembered as served.
    func read() -> String {
        state.withLock { state in
            state.served.insert(state.current)
            return state.current
        }
    }

    /// The final vocabulary for the recording.
    func update(_ vocabulary: String) {
        state.withLock {
            $0.current = vocabulary
            $0.isSettled = true
        }
    }

    /// Whether the vocabulary can no longer change before stop.
    var isSettled: Bool { state.withLock { $0.isSettled } }

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
