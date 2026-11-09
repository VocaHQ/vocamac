// ParakeetService.swift
// VocaMac
//
// Swift wrapper around FluidAudio for NVIDIA Parakeet TDT transcription.
// Models are CoreML and run on the Apple Neural Engine, which makes them
// dramatically faster than Whisper for short dictation clips.

import Foundation
import FluidAudio
import os

// MARK: - ParakeetError

enum ParakeetError: LocalizedError {
    case modelNotLoaded
    case initializationFailed(reason: String)
    /// `underlying` is the error the engine threw, kept so the router can
    /// tell a model fault from a cancellation without comparing messages.
    case transcriptionFailed(reason: String, underlying: (any Error)? = nil)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No Parakeet model is loaded. Please load a model first."
        case .initializationFailed(let reason):
            return "Failed to initialize Parakeet: \(reason)"
        case .transcriptionFailed(let reason, _):
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

    /// A loaded FluidAudio pipeline: the TDT models, or Parakeet Unified.
    private enum LoadedManager: Sendable {
        case tdt(AsrManager)
        case unified(UnifiedAsrManager)

        func cleanup() async {
            switch self {
            case .tdt(let manager): await manager.cleanup()
            case .unified(let manager): await manager.cleanup()
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

    /// The identifier of the currently loaded model
    var loadedModelName: String? { state.withLock { $0.loadedSize?.rawValue } }

    // MARK: - Model Catalog

    /// Which FluidAudio pipeline runs a Parakeet catalog entry.
    enum Family: Equatable {
        /// `AsrManager` with this TDT model version.
        case tdt(AsrModelVersion)
        /// `UnifiedAsrManager`'s batch path.
        case unified
    }

    static func family(for size: ModelSize) -> Family? {
        if size == .parakeetUnified { return .unified }
        return modelVersion(for: size).map(Family.tdt)
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
        case .unified: return ParakeetUnifiedModel.directory
        case nil: return nil
        }
    }

    /// Whether a Parakeet model's files are on disk.
    static func modelFilesExist(for size: ModelSize) -> Bool {
        switch family(for: size) {
        case .tdt(let version):
            return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
        case .unified:
            return ParakeetUnifiedModel.modelsExist()
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
        case .unified:
            try await ParakeetUnifiedModel.download(onProgress: onProgress)
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

    // MARK: - Model Management

    /// Load a Parakeet model. Downloads model files on first use; subsequent
    /// loads read from FluidAudio's local cache.
    func loadModel(
        name modelName: String? = nil,
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
            case .unified:
                onPhaseChange?("Compiling neural engine…")
                let unified = ParakeetUnifiedModel.makeManager()
                // Downloads only what is missing, then loads; a cache that
                // fails to load is fetched again once.
                try await unified.loadModels(to: nil, configuration: nil, progressHandler: nil)
                manager = .unified(unified)
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
                // English only, so there is no language hint to give.
                let result = try await manager.transcribeWithTimings(audioData)
                decodedText = result.text
                tokenTimings = result.tokenTimings
            }

            var text = decodedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let boostTerms = RecognitionHints.boostTerms(from: vocabulary)
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
                detectedLanguage: language ?? "auto",
                audioLengthSeconds: audioLengthSeconds,
                modelUsed: size,
                segments: Self.timedSegments(from: tokenTimings ?? [], text: text)
            )
        } catch is CancellationError {
            // Cancelling a dictation is not a model failure; wrapped, the
            // router would count it toward reloading the model.
            throw CancellationError()
        } catch {
            throw ParakeetError.transcriptionFailed(reason: error.localizedDescription, underlying: error)
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
