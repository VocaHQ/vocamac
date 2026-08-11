// ParakeetService.swift
// VocaMac
//
// Swift wrapper around FluidAudio for NVIDIA Parakeet TDT transcription.
// Models are CoreML and run on the Apple Neural Engine, which makes them
// dramatically faster than Whisper for short dictation clips.

import Foundation
import FluidAudio

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

final class ParakeetService: @unchecked Sendable {

    // MARK: - Properties

    /// The FluidAudio ASR manager (initialized when a model is loaded)
    private var asrManager: AsrManager?

    /// Which Parakeet variant is currently loaded
    private var loadedSize: ModelSize?

    /// Whether a model is currently loaded and ready
    var isModelLoaded: Bool { asrManager != nil }

    /// The identifier of the currently loaded model
    var loadedModelName: String? { loadedSize?.rawValue }

    // MARK: - Model Management

    /// Map a catalog entry to FluidAudio's model version.
    static func modelVersion(for size: ModelSize) -> AsrModelVersion? {
        switch size {
        case .parakeetV3:         return .v3
        case .parakeetV2:         return .v2
        case .parakeetTdtCtc110m: return .tdtCtc110m
        default:                  return nil
        }
    }

    /// Load a Parakeet model. Downloads model files on first use; subsequent
    /// loads read from FluidAudio's local cache.
    func loadModel(
        name modelName: String? = nil,
        onPhaseChange: ((String) -> Void)? = nil
    ) async throws {
        // Wait for the previous manager to release its CoreML state before
        // building a new one, so cleanup cannot land on the new model.
        await unloadModelAndWait()

        let size = modelName.flatMap(ModelSize.init(rawValue:)) ?? .parakeetV3
        guard let version = Self.modelVersion(for: size) else {
            throw ParakeetError.initializationFailed(reason: "Unknown Parakeet variant: \(modelName ?? "nil")")
        }

        VocaLogger.info(.parakeetService, "Loading Parakeet model: \(size.rawValue)...")
        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            onPhaseChange?("Preparing Parakeet…")
            let models = try await AsrModels.downloadAndLoad(version: version)

            onPhaseChange?("Compiling neural engine…")
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)

            self.asrManager = manager
            self.loadedSize = size

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            VocaLogger.info(.parakeetService, "Parakeet model loaded in \(String(format: "%.2f", elapsed))s")
        } catch {
            VocaLogger.error(.parakeetService, "ERROR loading Parakeet model: \(error)")
            throw ParakeetError.initializationFailed(reason: error.localizedDescription)
        }
    }

    /// Unload the current model and free memory, waiting for FluidAudio to
    /// release its CoreML state.
    ///
    /// Prefer this over `unloadModel()` when another load is about to start:
    /// cleanup releases shared caches, and if it runs loose it can tear those
    /// down after the next model has begun using them.
    func unloadModelAndWait() async {
        guard let manager = takeManager() else { return }
        await manager.cleanup()
        VocaLogger.info(.parakeetService, "Parakeet model unloaded")
    }

    /// Unload the current model without waiting for cleanup to finish.
    /// Used on teardown paths where there is nothing to race with.
    func unloadModel() {
        guard let manager = takeManager() else { return }
        Task { await manager.cleanup() }
        VocaLogger.info(.parakeetService, "Parakeet model unloaded")
    }

    /// Detach the current manager so only one caller can clean it up.
    private func takeManager() -> AsrManager? {
        guard let manager = asrManager else { return nil }
        asrManager = nil
        loadedSize = nil
        return manager
    }

    // MARK: - Transcription

    /// Transcribe audio data to text.
    /// - Parameters:
    ///   - audioData: Array of Float32 PCM samples at 16kHz mono
    ///   - language: ISO 639-1 language code used as a script hint for the
    ///     multilingual v3 model, or nil/unknown for automatic detection.
    ///     Parakeet does not support translation or custom vocabulary — those
    ///     options are ignored.
    func transcribe(
        audioData: [Float],
        language: String? = nil
    ) async throws -> VocaTranscription {
        guard let manager = asrManager, let size = loadedSize else {
            throw ParakeetError.modelNotLoaded
        }

        guard !audioData.isEmpty else {
            throw ParakeetError.emptyAudio
        }

        let audioLengthSeconds = Double(audioData.count) / 16000.0
        VocaLogger.info(.parakeetService, "Parakeet transcribing \(String(format: "%.1f", audioLengthSeconds))s of audio...")

        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            var decoderState = try TdtDecoderState()
            let languageHint = language.flatMap { Language(rawValue: $0) }
            let result = try await manager.transcribe(
                audioData,
                decoderState: &decoderState,
                language: languageHint
            )

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

            VocaLogger.info(.parakeetService, "Parakeet transcription completed in \(String(format: "%.2f", elapsed))s")
            VocaLogger.info(.parakeetService, "Result: \(text.prefix(100))...")

            return VocaTranscription(
                text: text,
                duration: elapsed,
                detectedLanguage: language ?? "auto",
                audioLengthSeconds: audioLengthSeconds,
                modelUsed: size
            )
        } catch {
            throw ParakeetError.transcriptionFailed(reason: error.localizedDescription)
        }
    }
}
