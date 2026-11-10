// AppleSpeechService.swift
// VocaMac
//
// Transcription via Apple's SpeechAnalyzer/SpeechTranscriber (macOS 26+).
// Model assets are downloaded and managed by the system, so this engine
// needs no download UI and adds nothing to VocaMac's model storage.
//
// The implementation is compiled only with an SDK that ships the
// SpeechAnalyzer API (Xcode 26+); older toolchains build a stub that reports
// the engine as unavailable so CI on earlier macOS keeps working.

import Foundation
import AVFoundation
import os
#if canImport(Speech)
import Speech
#endif

// MARK: - AppleSpeechService

/// Unchecked: the prepared state lives in `state`, behind a lock. The router
/// reads it from the main actor and unloads it (`abandonEngines`) while a
/// transcription it gave up on may still be running.
final class AppleSpeechService: @unchecked Sendable {

    // MARK: - Properties

    /// Whether the running system and the SDK this binary was built with
    /// both support SpeechAnalyzer.
    static var isRuntimeSupported: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    private struct State {
        /// Whether the engine has been prepared (assets checked/installed)
        var isPrepared = false
        /// An analyzer ready for the next utterance, and its locale.
        var preparedSession: (any PreparedSpeechSession)?
        var preparedLocale: String?
        /// Bumped by every load and unload, so a session prepared for an
        /// earlier one is discarded instead of installed.
        var generation = 0
        /// A replacement session is being prepared in the background.
        var isPreparingNext = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isModelLoaded: Bool { state.withLock { $0.isPrepared } }

    var loadedModelName: String? { isModelLoaded ? ModelSize.appleSpeech.rawValue : nil }

    /// Language codes SpeechTranscriber supports on this Mac, or nil when
    /// the system has no SpeechAnalyzer or reports none.
    static func supportedLanguageCodes() async -> Set<String>? {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let locales = await SpeechTranscriber.supportedLocales
            let codes = Set(locales.compactMap { $0.language.languageCode?.identifier })
            // An empty answer is a failed query, not an engine with no
            // languages; nil keeps the picker on its fallback list.
            return codes.isEmpty ? nil : codes
        }
        #endif
        return nil
    }

    // MARK: - Model Management

    /// Prepare the system speech engine: resolves the locale to dictate in
    /// and asks the OS to install transcription assets if they are missing.
    ///
    /// - Parameter language: ISO 639-1 code the user selected, or nil to
    ///   follow the system locale. This must match what `transcribe` will ask
    ///   for, otherwise load installs assets for one language and the first
    ///   dictation downloads another — or load fails because the system
    ///   locale is unsupported while the selected language is fine.
    func loadModel(
        language: String? = nil,
        onPhaseChange: ((String) -> Void)? = nil
    ) async throws {
        #if compiler(>=6.2)
        guard #available(macOS 26.0, *) else { throw TranscriptionError.unsupportedSystem }

        VocaLogger.info(.appleSpeechService, "Preparing Apple Speech (system engine)...")
        let startTime = CFAbsoluteTimeGetCurrent()

        onPhaseChange?("Checking speech assets…")
        let locale = language.map { Locale(identifier: $0) } ?? Locale.current
        await unloadModel()
        let generation = state.withLock { $0.generation }
        let session = try await AppleSpeechEngine.prepareSession(for: locale, onPhaseChange: onPhaseChange)
        // A load given up on, or unloaded under, must not install itself.
        let installed = state.withLock { state -> Bool in
            guard state.generation == generation, !Task.isCancelled else { return false }
            state.preparedSession = session
            state.preparedLocale = locale.identifier
            state.isPrepared = true
            return true
        }
        guard installed else {
            await session.cancel()
            throw CancellationError()
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        VocaLogger.info(.appleSpeechService, "Apple Speech ready in \(String(format: "%.2f", elapsed))s")
        #else
        throw TranscriptionError.unsupportedSystem
        #endif
    }

    func unloadModel() async {
        let session = state.withLock { state -> (any PreparedSpeechSession)? in
            state.generation &+= 1
            state.isPrepared = false
            defer {
                state.preparedSession = nil
                state.preparedLocale = nil
            }
            return state.preparedSession
        }
        await session?.cancel()
    }

    // MARK: - Transcription

    /// Transcribe audio data to text using the system speech engine.
    /// - Parameters:
    ///   - audioData: Array of Float32 PCM samples at 16kHz mono
    ///   - language: ISO 639-1 language code, or nil to use the system locale.
    ///     Translation is not supported by this engine.
    ///   - vocabulary: Dictionary terms (comma/newline separated) handed to
    ///     the analyzer as contextual strings.
    func transcribe(
        audioData: [Float],
        language: String? = nil,
        vocabulary: String = ""
    ) async throws -> VocaTranscription {
        guard !audioData.isEmpty else { throw TranscriptionError.emptyAudio(.appleSpeech) }
        let cursor = AudioChunkCursor(audioData)
        return try await transcribe(
            chunks: AsyncThrowingStream(unfolding: { await cursor.next() }),
            language: language, vocabulary: vocabulary
        )
    }

    /// Own one prepared analyzer for one utterance. Finished sessions are never reused.
    /// - Parameter onPiece: Called with each finalized result while audio is
    ///   still arriving, as a piece ending where the result's audio ends.
    ///   When given, the transcription also carries those pieces.
    func transcribe(
        chunks: AsyncThrowingStream<[Float], Error>,
        language: String?,
        vocabulary: String = "",
        vocabularyUpdates: LiveVocabulary? = nil,
        onPiece: (@Sendable (Int, TranscribedPiece) -> Void)? = nil
    ) async throws -> VocaTranscription {
        #if compiler(>=6.2)
        guard #available(macOS 26.0, *) else { throw TranscriptionError.unsupportedSystem }
        let locale = language.map { Locale(identifier: $0) } ?? Locale.current
        let start = CFAbsoluteTimeGetCurrent()
        // Take the prepared analyzer, if it is for this locale. Finished
        // sessions are never reused, so the next one is prepared once this
        // utterance is done (`prepareNextSession`).
        let taken = state.withLock { state -> (isPrepared: Bool, session: (any PreparedSpeechSession)?, matches: Bool, generation: Int) in
            let session = state.preparedSession
            let matches = state.preparedLocale == locale.identifier
            state.preparedSession = nil
            state.preparedLocale = nil
            return (state.isPrepared, session, matches, state.generation)
        }
        guard taken.isPrepared else {
            await taken.session?.cancel()
            throw TranscriptionError.modelNotLoaded(.appleSpeech)
        }
        defer { prepareNextSession(for: locale, generation: taken.generation) }
        let session: any PreparedSpeechSession
        if let prepared = taken.session, taken.matches {
            session = prepared
        } else {
            await taken.session?.cancel()
            session = try await AppleSpeechEngine.prepareSession(for: locale)
        }
        do {
            try Task.checkCancellation()
            let hints = RecognitionHints.contextualStrings(from: vocabulary)
            let detectedLanguage = language ?? locale.language.languageCode?.identifier ?? "auto"
            // Always track finalized results so batch (no onPiece) still gets
            // segment timings for history. Live callers keep their callback.
            let tracker = FinalizedPieceTracker(
                language: detectedLanguage, onPiece: onPiece ?? { _, _ in }
            )
            let (text, count) = try await session.transcribe(
                chunks, contextualStrings: hints, contextUpdates: vocabularyUpdates
            ) { text, endSeconds, words in
                tracker.finalized(text, endSeconds: endSeconds, words: words)
            }
            let pieces = tracker.pieces(sampleCount: count)
            // pieces() needs >= 2 aligned results for live commit mode. Batch
            // and single-result decodes still need a segment for history.
            // Word timings and confidences go on whichever segment they fall
            // in, for pause paragraphs and the Dictionary's sound-alike fixes.
            let segments = tracker.attachingWords(to: pieces.isEmpty
                ? tracker.timedSegments(sampleCount: count, fallbackText: text)
                : pieces.map(TimedSegment.init(piece:)))
            return VocaTranscription(
                text: text, duration: CFAbsoluteTimeGetCurrent() - start,
                detectedLanguage: detectedLanguage,
                audioLengthSeconds: Double(count) / 16_000, modelUsed: .appleSpeech,
                pieces: pieces, segments: segments
            )
        } catch {
            await session.cancel()
            throw error
        }
        #else
        throw TranscriptionError.unsupportedSystem
        #endif
    }

    #if compiler(>=6.2)
    /// Prepare the analyzer for the next utterance in the background, so it
    /// is ready (assets resolved, preheated) by the time the user dictates
    /// again, as the first one is after a load.
    @available(macOS 26.0, *)
    private func prepareNextSession(for locale: Locale, generation: Int) {
        let starts = state.withLock { state -> Bool in
            guard state.isPrepared, state.generation == generation,
                  state.preparedSession == nil, !state.isPreparingNext else { return false }
            state.isPreparingNext = true
            return true
        }
        guard starts else { return }
        Task.detached(priority: .utility) { [weak self] in
            let session = try? await AppleSpeechEngine.prepareSession(for: locale)
            let installed = self?.state.withLock { state -> Bool in
                state.isPreparingNext = false
                // Unloaded, reloaded, or already replaced meanwhile.
                guard let session, state.isPrepared, state.generation == generation,
                      state.preparedSession == nil else { return false }
                state.preparedSession = session
                state.preparedLocale = locale.identifier
                return true
            } ?? false
            if !installed { await session?.cancel() }
        }
    }
    #endif
}

// MARK: - AppleSpeechEngine (SpeechAnalyzer wrapper)

#if compiler(>=6.2)
@available(macOS 26.0, *)
enum AppleSpeechEngine {

    /// Sample rate of the audio VocaMac's AudioEngine produces.
    private static let inputSampleRate: Double = 16_000

    /// Resolve a requested locale to one SpeechTranscriber supports.
    /// Falls back from an exact BCP-47 match to a same-language match.
    static func resolveSupportedLocale(matching locale: Locale) async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        if let exact = supported.first(where: {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }) {
            return exact
        }
        return supported.first {
            $0.language.languageCode == locale.language.languageCode
        }
    }

    /// The words of a result with their audio time ranges and confidences,
    /// from the attributes `prepareSession` asks the transcriber for. Empty
    /// when the result carries none.
    static func timedWords(in text: AttributedString) -> [TimedWord] {
        var words: [TimedWord] = []
        for run in text.runs {
            // Keyed by type: the dynamic-member form forms a non-Sendable key path.
            guard let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else { continue }
            let word = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            let start = range.start.seconds
            let end = range.end.seconds
            guard !word.isEmpty, start.isFinite, end.isFinite else { continue }
            words.append(TimedWord(word: word, start: start, end: max(start, end), probability: run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self]))
        }
        return words
    }

    /// The format dictation is converted to before it reaches the analyzer:
    /// the analyzer's sample rate and channels, always as Int16 samples.
    ///
    /// On macOS 27, `AnalyzerInput(buffer:)` traps on every Float32 buffer,
    /// whatever its rate or layout, while Int16 buffers work. The analyzer
    /// asks for Int16 today, so this changes nothing unless it asks for
    /// another sample type, which would otherwise crash the app.
    static func analyzerInputFormat(for format: AVAudioFormat) -> AVAudioFormat? {
        guard format.commonFormat != .pcmFormatInt16 else { return format }
        return AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: format.sampleRate,
            channels: format.channelCount, interleaved: format.isInterleaved
        )
    }

    /// Resolve assets and preheat before the first recording rather than after stop.
    fileprivate static func prepareSession(
        for locale: Locale, onPhaseChange: ((String) -> Void)? = nil
    ) async throws -> any PreparedSpeechSession {
        let interval = PerformanceTrace.begin("AppleSpeechPreparation")
        defer { PerformanceTrace.end(interval) }
        guard let resolved = await resolveSupportedLocale(matching: locale) else {
            throw TranscriptionError.localeNotSupported(locale.identifier)
        }
        // Word time ranges and confidences come back as attributes on each
        // result's text (`timedWords(in:)`).
        let transcriber = SpeechTranscriber(
            locale: resolved, transcriptionOptions: [], reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onPhaseChange?("Downloading speech assets…")
            try await request.downloadAndInstall()
        }
        guard let bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let format = analyzerInputFormat(for: bestFormat) else {
            throw TranscriptionError.audioFormatUnavailable
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        onPhaseChange?("Preparing speech recognition…")
        do {
            try await analyzer.prepareToAnalyze(in: format)
            try Task.checkCancellation()
            return ApplePreparedSpeechSession(analyzer: analyzer, transcriber: transcriber, format: format)
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }
}

@available(macOS 26.0, *)
private actor ApplePreparedSpeechSession: PreparedSpeechSession {
    let analyzer: SpeechAnalyzer
    let transcriber: SpeechTranscriber
    let format: AVAudioFormat
    private var started = false

    init(analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber, format: AVAudioFormat) {
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.format = format
    }

    func transcribe(
        _ chunks: AsyncThrowingStream<[Float], Error>,
        contextualStrings: [String],
        contextUpdates: LiveVocabulary?,
        onFinal: @escaping @Sendable (String, Double, [TimedWord]) -> Void
    ) async throws -> (String, Int) {
        guard !started else { throw TranscriptionError.modelNotLoaded(.appleSpeech) }
        started = true
        await applyContext(contextualStrings)
        // Screen terms arrive a moment after recording starts. The audio
        // analyzed before then keeps the first context; the rest gets both.
        contextUpdates?.onUpdate { [weak self] vocabulary in
            Task { await self?.applyContext(RecognitionHints.contextualStrings(from: vocabulary)) }
        }
        // Terms that arrived before the observer was in place.
        if let latest = contextUpdates.map({ RecognitionHints.contextualStrings(from: $0.read()) }),
           latest != contextualStrings {
            await applyContext(latest)
        }
        let collector = Task { [transcriber] in
            var pieces: [String] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters)
                pieces.append(text)
                onFinal(text, result.range.end.seconds, AppleSpeechEngine.timedWords(in: result.text))
            }
            return pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let source = SpeechInputCursor(chunks: chunks, format: format)
        do {
            return try await withTaskCancellationHandler {
                let input = AsyncThrowingStream<AnalyzerInput, Error>(unfolding: { try await source.next() })
                let end = try await analyzer.analyzeSequence(input)
                if let end { try await analyzer.finalizeAndFinish(through: end) }
                else { await analyzer.cancelAndFinishNow() }
                let text = try await collector.value
                return (text, await source.sampleCount)
            } onCancel: {
                collector.cancel()
                Task { await self.cancel() }
            }
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            _ = try? await collector.value
            throw error
        }
    }

    func cancel() async { await analyzer.cancelAndFinishNow() }

    /// Bias recognition toward the Dictionary before any audio arrives.
    ///
    /// Set per utterance rather than at prepare time: sessions are prepared
    /// ahead of recording, before the vocabulary for this dictation is known.
    /// A hint is never worth a failed dictation, so errors only log.
    private func applyContext(_ contextualStrings: [String]) async {
        guard !contextualStrings.isEmpty else { return }
        let context = AnalysisContext()
        context.contextualStrings[.general] = contextualStrings
        do {
            try await analyzer.setContext(context)
            VocaLogger.debug(.appleSpeechService, "Apple Speech context set with \(contextualStrings.count) term(s)")
        } catch {
            VocaLogger.warning(.appleSpeechService, "Apple Speech ignored vocabulary context: \(error.localizedDescription)")
        }
    }
}

/// Lazily convert only the next chunk requested by SpeechAnalyzer. The converter
/// spans chunks and drains at EOF until it reports the end of the stream, so
/// resampling drops neither boundary frames nor the tail it still holds.
@available(macOS 26.0, *)
actor SpeechInputCursor {
    private var iterator: AsyncThrowingStream<[Float], Error>.Iterator
    private let format: AVAudioFormat
    private let converter: AVAudioConverter?
    private(set) var sampleCount = 0
    /// The chunk stream has finished; the converter may still hold frames.
    private var ended = false
    /// The converter has returned its last frame.
    private var drained = false

    init(chunks: AsyncThrowingStream<[Float], Error>, format: AVAudioFormat) {
        iterator = chunks.makeAsyncIterator()
        self.format = format
        // The analyzer format is always Int16 (`analyzerInputFormat`), so the
        // Float32 dictation samples always convert, even at the same rate.
        converter = AVAudioConverter(from: AudioEngine.whisperFormat, to: format)
    }

    func next() async throws -> AnalyzerInput? {
        guard !drained else { return nil }
        var samples: [Float]?
        if !ended {
            // A single analyzer owns this iterator; move it out across the suspension.
            var currentIterator = iterator
            samples = try await currentIterator.next(isolation: self)
            iterator = currentIterator
            try Task.checkCancellation()
            if samples == nil { ended = true }
            if let samples, samples.isEmpty { return try await next() }
        }
        let count = samples?.count ?? 0
        sampleCount += count
        var input: AVAudioPCMBuffer?
        if let samples, !samples.isEmpty {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: AudioEngine.whisperFormat, frameCapacity: AVAudioFrameCount(count)),
                  let destination = buffer.floatChannelData?[0] else { throw TranscriptionError.audioFormatUnavailable }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { destination.update(from: base, count: count) }
            }
            input = buffer
        }
        guard let converter else { throw TranscriptionError.audioFormatUnavailable }
        let capacity = AVAudioFrameCount(ceil(Double(max(1, count)) * format.sampleRate / 16_000) + 1024)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw TranscriptionError.audioFormatUnavailable
        }
        let provider = SpeechConverterInput(buffer: input, isEnd: samples == nil)
        var error: NSError?
        let interval = PerformanceTrace.begin("AppleSpeechAudioConversion")
        let status = converter.convert(to: output, error: &error) { _, state in
            provider.next(state)
        }
        PerformanceTrace.end(interval)
        if let error { throw error }
        guard status != .error else { throw TranscriptionError.audioFormatUnavailable }
        // At EOF one call can return only part of what the converter holds.
        let isEmpty = output.frameLength == 0
        if status == .endOfStream || (ended && isEmpty) { drained = true }
        if isEmpty { return drained ? nil : try await next() }
        // The converter wrote into `output` and keeps no reference to it, so
        // handing it to the analyzer shares nothing with this actor.
        nonisolated(unsafe) let converted = output
        return AnalyzerInput(buffer: converted)
    }
}
/// AVAudioConverter invokes its input block synchronously and serially. This
/// holder owns the buffer until conversion returns; it never escapes to a task.
private final class SpeechConverterInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer?
    private let isEnd: Bool
    private var supplied = false
    init(buffer: AVAudioPCMBuffer?, isEnd: Bool) { self.buffer = buffer; self.isEnd = isEnd }
    func next(_ state: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard !supplied, let buffer else {
            state.pointee = isEnd ? .endOfStream : .noDataNow
            return nil
        }
        supplied = true
        state.pointee = .haveData
        return buffer
    }
}

#endif

/// Availability-erased session storage keeps the macOS 14 executable loadable.
private protocol PreparedSpeechSession: Sendable {
    func transcribe(
        _ chunks: AsyncThrowingStream<[Float], Error>,
        contextualStrings: [String],
        contextUpdates: LiveVocabulary?,
        onFinal: @escaping @Sendable (String, Double, [TimedWord]) -> Void
    ) async throws -> (String, Int)
    func cancel() async
}

/// Turns Apple Speech's finalized results into pieces as they arrive. Each
/// piece runs from where the previous result's audio ended to where its own
/// does; the last one is stretched to the end of the recording.
final class FinalizedPieceTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let language: String
    private let onPiece: @Sendable (Int, TranscribedPiece) -> Void
    private var finalized: [(text: String, end: Int)] = []
    private var words: [TimedWord] = []

    init(language: String, onPiece: @escaping @Sendable (Int, TranscribedPiece) -> Void) {
        self.language = language
        self.onPiece = onPiece
    }

    func finalized(_ text: String, endSeconds: Double, words: [TimedWord] = []) {
        let piece: (Int, TranscribedPiece)? = lock.withLock {
            self.words.append(contentsOf: words)
            let start = finalized.last?.end ?? 0
            let end = endSeconds.isFinite ? max(start, Int((endSeconds * 16_000).rounded())) : start
            finalized.append((text, end))
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard end > start, !trimmed.isEmpty else { return nil }
            return (finalized.count - 1, TranscribedPiece(range: start..<end, text: trimmed, language: language))
        }
        if let piece { onPiece(piece.0, piece.1) }
    }

    /// `segments` with each word Apple Speech timed placed in the segment
    /// its midpoint falls in; a word outside every segment goes to the
    /// nearest one.
    func attachingWords(to segments: [TimedSegment]) -> [TimedSegment] {
        let words = lock.withLock { self.words }
        guard !words.isEmpty, !segments.isEmpty else { return segments }
        var placed = segments.map { segment -> TimedSegment in
            var segment = segment
            segment.words = []
            return segment
        }
        for word in words {
            let middle = (word.start + word.end) / 2
            let index = placed.firstIndex { middle >= $0.start && middle < $0.end }
                ?? placed.indices.min { abs(placed[$0].start - middle) < abs(placed[$1].start - middle) }
                ?? 0
            placed[index].words.append(word)
        }
        return placed
    }

    /// The pieces covering `0..<sampleCount`, or none when the results'
    /// audio ranges don't line up with the recording.
    func pieces(sampleCount: Int) -> [TranscribedPiece] {
        lock.withLock {
            var pieces: [TranscribedPiece] = []
            var start = 0
            for (index, result) in finalized.enumerated() {
                let end = index == finalized.count - 1 ? sampleCount : result.end
                guard end > start, end <= sampleCount else { return [] }
                pieces.append(TranscribedPiece(
                    range: start..<end,
                    text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    language: language
                ))
                start = end
            }
            // Apple's own join keeps each result's leading space; pieces that
            // wouldn't read the same joined with spaces aren't usable.
            let joined = finalized.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard pieces.count >= 2, TranscribedPiece.join(pieces) == joined else { return [] }
            return pieces
        }
    }

    /// Segment timings from finalized results for history, even when they are
    /// not usable as live pieces (a single result, or a join mismatch). Each
    /// result becomes a segment; with no usable results, one segment covers
    /// the full audio using `fallbackText`.
    ///
    /// When Apple reports result ends past the recording, a plain clamp would
    /// hand the whole `[0, sampleCount]` range to the first overshooting
    /// result and drop later text. Keep in-bounds ends as reported, then
    /// split the space left after them evenly between the results that no
    /// longer fit — scaling overshooting ends against the last end can map
    /// one below an earlier in-bounds boundary and erase its range.
    func timedSegments(sampleCount: Int, fallbackText: String) -> [TimedSegment] {
        lock.withLock {
            var segments: [TimedSegment] = []
            var start = 0
            // Only non-last ends that already reach past the recording force a
            // remap: a plain clamp would consume `[0, sampleCount]` and drop
            // later text. If only the last result overshoots, stretching it to
            // `sampleCount` already keeps every earlier in-bounds range.
            let firstOvershoot = finalized.dropLast().firstIndex { $0.end > sampleCount }
            var keptNonEmpty = 0
            var seenNonEmpty = 0
            for (index, result) in finalized.enumerated() {
                let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { seenNonEmpty += 1 }
                let rawEnd: Int
                if index == finalized.count - 1 {
                    rawEnd = sampleCount
                } else if let first = firstOvershoot, index >= first {
                    // Results from the first overshoot onward share the
                    // remaining `[start, sampleCount]` tail evenly.
                    let left = finalized.count - index
                    rawEnd = start + Int((Double(sampleCount - start) / Double(left)).rounded())
                } else {
                    rawEnd = result.end
                }
                let end = min(max(rawEnd, start), sampleCount)
                if end > start, !trimmed.isEmpty {
                    segments.append(TimedSegment(
                        start: Double(start) / 16_000,
                        end: Double(end) / 16_000,
                        text: trimmed, words: []
                    ))
                    keptNonEmpty += 1
                }
                start = max(start, end)
            }
            // Scaling / rounding can still collapse a gap; never hide finalized
            // text that the transcript kept — fall back to one full-audio segment.
            if keptNonEmpty < seenNonEmpty {
                let trimmed = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, sampleCount > 0 else {
                    return segments.isEmpty ? [] : segments
                }
                return [TimedSegment(
                    start: 0, end: Double(sampleCount) / 16_000, text: trimmed, words: []
                )]
            }
            if segments.isEmpty {
                let trimmed = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, sampleCount > 0 else { return [] }
                return [TimedSegment(
                    start: 0, end: Double(sampleCount) / 16_000, text: trimmed, words: []
                )]
            }
            return segments
        }
    }
}
