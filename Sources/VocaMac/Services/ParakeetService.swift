// ParakeetService.swift
// VocaMac
//
// Swift wrapper around FluidAudio for NVIDIA Parakeet TDT transcription.
// Models are CoreML and run on the Apple Neural Engine, which makes them
// dramatically faster than Whisper for short dictation clips.

import AVFoundation
import Foundation
import FluidAudio
import os

// MARK: - ParakeetError

enum ParakeetError: LocalizedError {
    case modelNotLoaded
    case initializationFailed(reason: String)
    case transcriptionFailed(reason: String)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No Parakeet model is loaded. Please load a model first."
        case .initializationFailed(let reason):
            return "Failed to initialize Parakeet: \(reason)"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .emptyAudio:
            return "No audio data to transcribe."
        }
    }
}

// MARK: - ParakeetService

/// Unchecked: the loaded model and its bookkeeping live in `state`, behind a
/// lock, because the router reads them from the main actor and drops them
/// (`abandonEngines`) while a decode or load it gave up on is still running
/// elsewhere. Everything else is immutable or an actor.
final class ParakeetService: @unchecked Sendable {

    // MARK: - Properties

    /// A loaded FluidAudio pipeline: the TDT models, or a Unified
    /// checkpoint's batch or streaming export.
    private enum LoadedManager: Sendable {
        case tdt(AsrManager)
        case unified(UnifiedAsrManager)
        case streamingUnified(StreamingUnifiedAsrManager)
        case senseVoice(SenseVoiceManager)

        func cleanup() async {
            switch self {
            case .tdt(let manager): await manager.cleanup()
            case .unified(let manager): await manager.cleanup()
            case .streamingUnified(let manager): await manager.cleanup()
            // Holds only its CoreML models, released with the manager.
            case .senseVoice: break
            }
        }
    }

    private struct State: Sendable {
        var manager: LoadedManager?
        var loadedSize: ModelSize?
        /// Bumped whenever the model is dropped, so a load that started
        /// before cannot install its model afterwards.
        var generation = 0
        /// Cleanup `unloadModel` started without waiting. The next load waits
        /// for it, so it cannot release shared CoreML state after the new
        /// model has started using it.
        var pendingCleanup: Task<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Dictionary vocabulary boost; loads its CTC model on first use.
    private let vocabularyBoost = ParakeetVocabularyBoost()

    /// Whether a model is currently loaded and ready
    var isModelLoaded: Bool { state.withLock { $0.manager != nil } }

    /// Whether the loaded model is a Unified checkpoint's streaming export,
    /// which transcribes while the user speaks (`transcribe(chunks:)`).
    var isStreamingLoaded: Bool {
        state.withLock { state in
            if case .streamingUnified? = state.manager { return true }
            return false
        }
    }

    /// The identifier of the currently loaded model
    var loadedModelName: String? { state.withLock { $0.loadedSize?.rawValue } }

    // MARK: - Model Catalog

    /// Which FluidAudio pipeline runs a Parakeet catalog entry.
    enum Family: Equatable {
        /// `AsrManager` with this TDT model version.
        case tdt(AsrModelVersion)
        /// Parakeet Unified (English) through the Unified managers.
        case unified
        /// Nemotron Unified ASR (25 languages) through the Unified managers.
        case nemotronUnified
        /// SenseVoiceSmall on the Neural Engine (`SenseVoiceManager`).
        case senseVoice

        /// The Unified checkpoint, or nil for a TDT model.
        var unifiedCheckpoint: ParakeetUnifiedModel.Checkpoint? {
            switch self {
            case .tdt, .senseVoice: return nil
            case .unified: return .parakeetEnglish
            case .nemotronUnified: return .nemotronMultilingual
            }
        }
    }

    static func family(for size: ModelSize) -> Family? {
        if size == .parakeetUnified { return .unified }
        if size == .nemotronUnified { return .nemotronUnified }
        if size == .senseVoiceNeuralEngine { return .senseVoice }
        return modelVersion(for: size).map(Family.tdt)
    }

    /// Whether a catalog entry can transcribe while the user speaks: the
    /// Unified checkpoints, which FluidAudio ships with a streaming encoder.
    static func supportsStreaming(_ size: ModelSize) -> Bool {
        size.transcribesWhileSpeaking && family(for: size)?.unifiedCheckpoint != nil
    }

    /// Map a catalog entry to FluidAudio's TDT model version. Nil for
    /// Parakeet Unified, which is not a TDT model.
    static func modelVersion(for size: ModelSize) -> AsrModelVersion? {
        switch size {
        case .parakeetUltra:      return .ultra
        case .parakeetV3:         return .v3
        case .parakeetV2:         return .v2
        case .parakeetTdtCtc110m: return .tdtCtc110m
        default:                  return nil
        }
    }

    /// Where FluidAudio keeps a Parakeet model's files.
    static func modelDirectory(for size: ModelSize) -> URL? {
        switch family(for: size) {
        case .tdt(let version): return AsrModels.defaultCacheDirectory(for: version)
        case .unified, .nemotronUnified:
            return family(for: size)?.unifiedCheckpoint.map(ParakeetUnifiedModel.directory(for:))
        case .senseVoice: return SenseVoiceNeuralEngineModel.directory
        case nil: return nil
        }
    }

    /// Whether a Parakeet model's files are on disk. For a Unified
    /// checkpoint, the batch export: the streaming encoder is fetched the
    /// first time live transcription is turned on and the model loads.
    static func modelFilesExist(for size: ModelSize) -> Bool {
        switch family(for: size) {
        case .tdt(let version):
            return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
        case .unified, .nemotronUnified:
            guard let checkpoint = family(for: size)?.unifiedCheckpoint else { return false }
            return ParakeetUnifiedModel.modelsExist(for: checkpoint, streaming: false)
        case .senseVoice:
            return SenseVoiceNeuralEngineModel.modelsExist()
        case nil:
            return false
        }
    }

    /// Download a Parakeet model's files without loading it.
    static func downloadModel(for size: ModelSize, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        switch family(for: size) {
        case .tdt(let version):
            try await AsrModels.download(version: version) { progress in
                onProgress(progress.fractionCompleted)
            }
        case .unified, .nemotronUnified:
            guard let checkpoint = family(for: size)?.unifiedCheckpoint else { return }
            try await ParakeetUnifiedModel.download(checkpoint, onProgress: onProgress)
        case .senseVoice:
            try await SenseVoiceNeuralEngineModel.download(onProgress: onProgress)
        case nil:
            throw ParakeetError.initializationFailed(reason: "Unknown Parakeet variant: \(size.rawValue)")
        }
    }

    /// Every directory a Parakeet model can occupy, for disk usage.
    static var modelDirectories: [URL] {
        ModelSize.allCases.filter { $0.engine == .parakeet }.compactMap(modelDirectory(for:))
    }

    /// Whether the model writes numbers and symbols ("35.3%") rather than
    /// spelling them out, which the vocabulary boost rescores differently.
    static func writesNumbers(_ size: ModelSize) -> Bool {
        family(for: size) == .unified
    }

    /// Spoken-language codes a Nemotron Unified load can be prompted with.
    static var nemotronLanguageCodes: Set<String> {
        Set(NemotronUnifiedLanguage.allCases.filter { $0 != .auto }.map(\.rawValue))
    }

    // MARK: - Model Management

    /// Load a Parakeet model. Downloads model files on first use; subsequent
    /// loads read from FluidAudio's local cache.
    /// - Parameters:
    ///   - language: The language prompt for Nemotron Unified, which binds
    ///     it at load (nil or an unsupported code: automatic language ID).
    ///     Ignored by the other models.
    ///   - streaming: Load a Unified checkpoint's streaming export, which
    ///     decodes while the user speaks. Ignored by the TDT models.
    func loadModel(
        name modelName: String? = nil,
        language: String? = nil,
        streaming: Bool = false,
        onPhaseChange: ((String) -> Void)? = nil
    ) async throws {
        // Wait for the previous manager to release its CoreML state before
        // building a new one, so cleanup cannot land on the new model.
        await unloadModelAndWait()
        let generation = state.withLock { $0.generation }

        let size = modelName.flatMap(ModelSize.init(rawValue:)) ?? .parakeetV3
        guard let family = Self.family(for: size) else {
            throw ParakeetError.initializationFailed(reason: "Unknown Parakeet variant: \(modelName ?? "nil")")
        }

        VocaLogger.info(.parakeetService, "Loading Parakeet model: \(size.rawValue)...")
        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            onPhaseChange?("Preparing Parakeet…")
            let manager: LoadedManager
            switch family {
            case .tdt(let version):
                let models = try await AsrModels.downloadAndLoad(version: version)
                onPhaseChange?("Compiling neural engine…")
                let tdt = AsrManager(config: .default)
                try await tdt.loadModels(models)
                manager = .tdt(tdt)
            case .unified, .nemotronUnified:
                guard let checkpoint = family.unifiedCheckpoint else {
                    throw ParakeetError.initializationFailed(reason: "Unknown Parakeet variant: \(size.rawValue)")
                }
                onPhaseChange?("Compiling neural engine…")
                // Downloads only what is missing, then loads; a cache that
                // fails to load is fetched again once.
                if streaming {
                    let streamer = ParakeetUnifiedModel.makeStreamingManager(checkpoint, language: language)
                    try await streamer.loadModels(to: nil, configuration: nil, progressHandler: nil)
                    manager = .streamingUnified(streamer)
                } else {
                    let unified = ParakeetUnifiedModel.makeManager(checkpoint, language: language)
                    try await unified.loadModels(to: nil, configuration: nil, progressHandler: nil)
                    manager = .unified(unified)
                }
            case .senseVoice:
                onPhaseChange?("Compiling neural engine…")
                manager = .senseVoice(try await SenseVoiceNeuralEngineModel.load(language: language))
            }
            // A load the router gave up on (`Deadline`), or one the model was
            // dropped under since, may still finish later; it must not
            // replace whatever was loaded since. Checked and installed under
            // the lock, so an unload cannot slip between the two.
            let installed = state.withLock { state -> Bool in
                guard state.generation == generation, !Task.isCancelled else { return false }
                state.manager = manager
                state.loadedSize = size
                return true
            }
            guard installed else {
                await manager.cleanup()
                throw CancellationError()
            }
            // Warm the vocabulary boost model, if downloaded, in the background.
            await vocabularyBoost.prepare()

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            VocaLogger.info(.parakeetService, "Parakeet model loaded in \(String(format: "%.2f", elapsed))s")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            VocaLogger.error(.parakeetService, "ERROR loading Parakeet model: \(error)")
            throw ParakeetError.initializationFailed(reason: error.localizedDescription)
        }
    }

    /// Run one short decode right after a load, so the user's first
    /// dictation does not pay for CoreML's first prediction (program
    /// instantiation, weights paged in). The result is discarded.
    func warmUp() async {
        guard let manager = state.withLock({ $0.manager }) else { return }
        let start = CFAbsoluteTimeGetCurrent()
        do {
            switch manager {
            case .tdt(let manager):
                var decoderState = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
                _ = try await manager.transcribe(WhisperService.warmUpAudio, decoderState: &decoderState, language: nil)
            case .unified(let manager):
                _ = try await manager.transcribe(WhisperService.warmUpAudio)
            case .streamingUnified(let manager):
                _ = try await Self.streamingTranscript(of: WhisperService.warmUpAudio, with: manager)
            case .senseVoice(let manager):
                _ = try await manager.transcribeDetailed(audio: WhisperService.warmUpAudio)
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            VocaLogger.info(.parakeetService, "Warm-up decode took \(String(format: "%.2f", elapsed))s")
        } catch {
            VocaLogger.debug(.parakeetService, "Warm-up decode failed: \(error.localizedDescription)")
        }
    }

    /// Unload the current model and free memory, waiting for FluidAudio to
    /// release its CoreML state.
    ///
    /// Prefer this over `unloadModel()` when another load is about to start:
    /// cleanup releases shared caches, and if it runs loose it can tear those
    /// down after the next model has begun using them.
    func unloadModelAndWait() async {
        await finishPendingCleanup()
        guard let manager = takeManager() else { return }
        await manager.cleanup()
        await vocabularyBoost.unload()
        VocaLogger.info(.parakeetService, "Parakeet model unloaded")
    }

    /// Unload the current model without waiting for cleanup to finish.
    /// Used on teardown paths where there is nothing to race with.
    func unloadModel() {
        let vocabularyBoost = vocabularyBoost
        let unloaded = state.withLock { state -> Bool in
            state.generation &+= 1
            guard let manager = state.manager else { return false }
            state.manager = nil
            state.loadedSize = nil
            let previous = state.pendingCleanup
            state.pendingCleanup = Task {
                await previous?.value
                await manager.cleanup()
                await vocabularyBoost.unload()
            }
            return true
        }
        if unloaded {
            VocaLogger.info(.parakeetService, "Parakeet model unloaded")
        }
    }

    /// How long a load waits for that cleanup. A model the router gave up on
    /// (`Deadline`) may be stuck in the very call it was abandoned in, and
    /// its cleanup with it; the load then goes ahead rather than hang too.
    static let pendingCleanupWaitSeconds: TimeInterval = 15

    private func finishPendingCleanup() async {
        let cleanup = state.withLock { state -> Task<Void, Never>? in
            defer { state.pendingCleanup = nil }
            return state.pendingCleanup
        }
        guard let cleanup else { return }
        do {
            try await Deadline.run(seconds: Self.pendingCleanupWaitSeconds, operation: "Parakeet cleanup") {
                await cleanup.value
            }
        } catch {
            VocaLogger.warning(.parakeetService, "Previous Parakeet model is still cleaning up; loading anyway")
        }
    }

    /// Detach the current manager so only one caller can clean it up, and
    /// retire any load still running.
    private func takeManager() -> LoadedManager? {
        state.withLock { state in
            state.generation &+= 1
            let manager = state.manager
            state.manager = nil
            state.loadedSize = nil
            return manager
        }
    }

    // MARK: - Transcription

    /// Transcribe audio data to text.
    /// - Parameters:
    ///   - audioData: Array of Float32 PCM samples at 16kHz mono
    ///   - language: ISO 639-1 language code used as a script hint for the
    ///     multilingual v3 model, or nil/unknown for automatic detection.
    ///     Parakeet does not support translation.
    ///   - vocabulary: Dictionary terms (comma/newline separated). Boosted
    ///     with the CTC model when it is downloaded; ignored otherwise.
    func transcribe(
        audioData: [Float],
        language: String? = nil,
        vocabulary: String = ""
    ) async throws -> VocaTranscription {
        try await transcribe(audioData: audioData, language: language, vocabularyAfterDecode: { vocabulary })
    }

    /// Transcribe, reading the Dictionary terms only once the decode is done:
    /// they are used for the boost after it, so a caller still gathering them
    /// (the screen's terms) need not hold the decode back.
    func transcribe(
        audioData: [Float],
        language: String?,
        vocabularyAfterDecode: @Sendable () async -> String
    ) async throws -> VocaTranscription {
        let loaded = state.withLock { state in state.manager.flatMap { manager in state.loadedSize.map { (manager, $0) } } }
        guard let (manager, size) = loaded else {
            throw ParakeetError.modelNotLoaded
        }

        guard !audioData.isEmpty else {
            throw ParakeetError.emptyAudio
        }

        let audioLengthSeconds = Double(audioData.count) / 16000.0
        VocaLogger.info(.parakeetService, "Parakeet transcribing \(String(format: "%.1f", audioLengthSeconds))s of audio...")

        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let decodedText: String
            let tokenTimings: [TokenTiming]?
            var detectedLanguage = language
            switch manager {
            case .tdt(let manager):
                // Size the LSTM state to the loaded model: TDT-CTC 110M has one
                // decoder layer, v2/v3 have two. The default of 2 makes 110M fail
                // every decode with a (2 x 1 x 640) vs (1 x 1 x 640) shape mismatch.
                var decoderState = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
                let languageHint = language.flatMap { Language(rawValue: $0) }
                let result = try await manager.transcribe(
                    audioData,
                    decoderState: &decoderState,
                    language: languageHint
                )
                decodedText = result.text
                tokenTimings = result.tokenTimings
            case .unified(let manager):
                // Parakeet Unified is English only; Nemotron's language is
                // its load-time prompt. Neither takes a per-call hint.
                let result = try await manager.transcribeWithTimings(audioData)
                decodedText = result.text
                tokenTimings = result.tokenTimings
            case .streamingUnified(let manager):
                // Live transcription is on but this recording comes whole
                // (a fallback, a file, or a warm-up): stream it through.
                let result = try await Self.streamingTranscript(of: audioData, with: manager)
                decodedText = result.text
                tokenTimings = result.tokenTimings
            case .senseVoice(let manager):
                let result = try await Self.senseVoiceTranscript(of: audioData, with: manager)
                decodedText = result.text
                tokenTimings = nil
                detectedLanguage = result.language ?? language
            }

            var text = decodedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let boostTerms = RecognitionHints.boostTerms(from: await vocabularyAfterDecode())
            if !text.isEmpty, !boostTerms.isEmpty,
               let boosted = await vocabularyBoost.boost(
                   text: text, tokenTimings: tokenTimings, audio: audioData, terms: boostTerms,
                   language: language, writesNumbers: Self.writesNumbers(size)
               ) {
                text = boosted.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime

            VocaLogger.info(.parakeetService, "Parakeet transcription completed in \(String(format: "%.2f", elapsed))s")
            VocaLogger.info(.parakeetService, "Result: \(text.count) characters")

            return VocaTranscription(
                text: text,
                duration: elapsed,
                detectedLanguage: detectedLanguage ?? "auto",
                audioLengthSeconds: audioLengthSeconds,
                modelUsed: size,
                segments: Self.timedSegments(from: tokenTimings ?? [], text: text)
            )
        } catch is CancellationError {
            // Cancelling a dictation is not a model failure; wrapped, the
            // router would count it toward reloading the model.
            throw CancellationError()
        } catch {
            throw ParakeetError.transcriptionFailed(reason: error.localizedDescription)
        }
    }
}

// MARK: - SenseVoice

extension ParakeetService {

    /// Decode a recording with SenseVoice in windows of up to 100 s, joined
    /// the way process-while-speaking pieces are (no space between two
    /// unspaced-script pieces). A window the model calls `nospeech` adds
    /// nothing. The language is the first one the model named.
    static func senseVoiceTranscript(
        of audio: [Float],
        with manager: SenseVoiceManager
    ) async throws -> (text: String, language: String?) {
        var pieces: [String] = []
        var language: String?
        for window in SenseVoiceNeuralEngineModel.windows(for: audio) {
            try Task.checkCancellation()
            let result = try await manager.transcribeDetailed(audio: Array(audio[window]))
            if result.language == "nospeech" { continue }
            if language == nil { language = result.language }
            pieces.append(result.text)
        }
        return (TranscribedPiece.join(pieces), language)
    }
}

// MARK: - Streaming

extension ParakeetService {

    /// A transcript and the token timings behind it.
    struct StreamedText: Sendable {
        var text: String
        var tokenTimings: [TokenTiming]
    }

    /// Decode a whole recording through the streaming export: the same
    /// windows a live session would decode, fed at once. Leaves the manager
    /// reset for the next session.
    static func streamingTranscript(
        of audio: [Float],
        with manager: StreamingUnifiedAsrManager
    ) async throws -> StreamedText {
        try await manager.reset()
        var timings: [TokenTiming] = []
        var offset = 0
        // One second at a time, so the rolling buffer the manager trims
        // stays small however long the recording.
        while offset < audio.count {
            try Task.checkCancellation()
            let end = min(audio.count, offset + Self.streamingStepSamples)
            try await manager.appendAudio(try Self.pcmBuffer(audio[offset..<end]))
            try await manager.processBufferedAudio()
            timings += await manager.consumeTokenTimings()
            offset = end
        }
        let text = try await manager.finish()
        timings += await manager.consumeTokenTimings()
        try await manager.reset()
        return StreamedText(text: text, tokenTimings: timings)
    }

    /// Audio handed to the streaming manager per step: one second at 16 kHz.
    static let streamingStepSamples = 16_000

    /// 16 kHz mono Float32 samples as the buffer FluidAudio's streaming API
    /// takes. In this format its converter only copies them back out.
    static func pcmBuffer(_ samples: ArraySlice<Float>) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count))),
              let channel = buffer.floatChannelData?[0] else {
            throw ParakeetError.transcriptionFailed(reason: "Could not allocate an audio buffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        return buffer
    }

    /// Transcribe a recording while it is being made, through a Unified
    /// checkpoint's streaming export: each second of audio is decoded as it
    /// arrives (2.08 s behind the speaker), so at stop only the last window
    /// is left. The streamed transcript is the result, not a preview.
    ///
    /// - Parameters:
    ///   - chunks: The microphone's 16 kHz samples, in order.
    ///   - vocabulary: Read at the end, so screen terms that arrive while the
    ///     user speaks still reach the Dictionary boost.
    ///   - onPartial: The words so far, after every decoded step.
    ///   - screenText: Applied to the transcript before the Dictionary
    ///     boost, with the whole recording: the router's silence check and
    ///     hallucination guard, which the batch path runs before decoding.
    func transcribe(
        chunks: AsyncThrowingStream<[Float], Error>,
        language: String?,
        vocabulary: @escaping @Sendable () -> String,
        onPartial: (@Sendable (String) -> Void)?,
        screenText: @escaping @Sendable (_ audio: [Float], _ text: String) async -> String = { $1 }
    ) async throws -> VocaTranscription {
        let loaded = state.withLock { state -> (StreamingUnifiedAsrManager, ModelSize)? in
            guard case .streamingUnified(let manager)? = state.manager, let size = state.loadedSize else { return nil }
            return (manager, size)
        }
        guard let (manager, size) = loaded else { throw ParakeetError.modelNotLoaded }

        let started = CFAbsoluteTimeGetCurrent()
        var audio: [Float] = []
        var timings: [TokenTiming] = []
        var lastPartial = ""
        do {
            try await manager.reset()
            for try await chunk in chunks {
                try Task.checkCancellation()
                guard !chunk.isEmpty else { continue }
                audio.append(contentsOf: chunk)
                try await manager.appendAudio(try Self.pcmBuffer(chunk[...]))
                try await manager.processBufferedAudio()
                timings += await manager.consumeTokenTimings()
                if let onPartial {
                    let partial = await manager.getPartialTranscript().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !partial.isEmpty, partial != lastPartial {
                        lastPartial = partial
                        onPartial(partial)
                    }
                }
            }
            let finalText = try await manager.finish()
            timings += await manager.consumeTokenTimings()
            try await manager.reset()

            guard !audio.isEmpty else { throw ParakeetError.emptyAudio }
            var text = await screenText(audio, finalText).trimmingCharacters(in: .whitespacesAndNewlines)
            let boostTerms = RecognitionHints.boostTerms(from: vocabulary())
            if !text.isEmpty, !boostTerms.isEmpty,
               let boosted = await vocabularyBoost.boost(
                   text: text, tokenTimings: timings, audio: audio, terms: boostTerms,
                   language: language, writesNumbers: Self.writesNumbers(size)
               ) {
                text = boosted.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let audioSeconds = Double(audio.count) / 16_000
            VocaLogger.info(
                .parakeetService,
                "Parakeet streamed \(String(format: "%.1f", audioSeconds))s in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - started))s"
            )
            return VocaTranscription(
                text: text,
                duration: CFAbsoluteTimeGetCurrent() - started,
                detectedLanguage: language ?? "auto",
                audioLengthSeconds: audioSeconds,
                modelUsed: size,
                segments: text.isEmpty ? [] : Self.timedSegments(from: timings, text: text)
            )
        } catch is CancellationError {
            try? await manager.reset()
            throw CancellationError()
        } catch let error as RecordingTranscription.StreamError {
            try? await manager.reset()
            throw error
        } catch let error as ParakeetError {
            try? await manager.reset()
            throw error
        } catch {
            try? await manager.reset()
            throw ParakeetError.transcriptionFailed(reason: error.localizedDescription)
        }
    }
}

// MARK: - Word timings

extension ParakeetService {
    /// The decode's token timings as words, in one segment carrying `text`,
    /// for History Timestamps and paragraph layout. A token that starts with
    /// a space starts a word; any other continues the word before it, so
    /// "▁hel", "lo", "," make "hello,". Empty when there are no timings.
    static func timedSegments(from tokens: [TokenTiming], text: String) -> [TimedSegment] {
        var words: [TimedWord] = []
        for token in tokens {
            let piece = token.token.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            let startsWord = token.token.first?.isWhitespace ?? false
            if !startsWord, var last = words.popLast() {
                last.word += piece
                // A full stop is emitted late, often as the next word
                // starts: it must not stretch the word over the pause.
                if piece.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) {
                    last.end = max(last.end, token.endTime)
                }
                last.probability = min(last.probability ?? 1, Double(token.confidence))
                words.append(last)
            } else {
                words.append(TimedWord(
                    word: piece, start: token.startTime, end: token.endTime,
                    probability: Double(token.confidence)
                ))
            }
        }
        guard let first = words.first, let last = words.last else { return [] }
        return [TimedSegment(start: first.start, end: last.end, text: text, words: words)]
    }
}
