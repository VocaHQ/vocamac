// TranscriptionRouter.swift
// VocaMac
//
// Routes model loading and transcription to the engine that owns the
// requested model. AppState talks to this single SpeechTranscribing facade
// and never needs to know which engine is active.

import Foundation

final class TranscriptionRouter: @unchecked Sendable {

    // MARK: - Engines

    private let whisper = WhisperService()
    private let parakeet = ParakeetService()
    private let appleSpeech = AppleSpeechService()
    private let sherpa = SherpaService()

    /// Engine that owns the currently loaded model.
    private(set) var activeEngine: TranscriptionEngine = .whisperKit

    /// Shared queue for loads and transcriptions so a hotkey cannot decode
    /// against an engine that a concurrent load just unloaded.
    private let operationSerializer = LoadSerializer()

    // MARK: - Engine Resolution

    /// Resolve which engine owns a model identifier.
    ///
    /// Parakeet and Apple Speech models are identified by their ModelSize raw
    /// value; anything else (WhisperKit variant names like
    /// "openai_whisper-tiny", or nil for auto-select) belongs to WhisperKit.
    static func engine(forModelIdentifier identifier: String?) -> TranscriptionEngine {
        guard let identifier,
              let size = ModelSize(rawValue: identifier) else {
            return .whisperKit
        }
        return size.engine
    }

    // MARK: - SpeechTranscribing state

    var loadedModelName: String? {
        switch activeEngine {
        case .whisperKit:  return whisper.loadedModelName
        case .parakeet:    return parakeet.loadedModelName
        case .appleSpeech: return appleSpeech.loadedModelName
        case .sherpaOnnx:  return sherpa.loadedModelName
        }
    }

    var isModelLoaded: Bool {
        switch activeEngine {
        case .whisperKit:  return whisper.isModelLoaded
        case .parakeet:    return parakeet.isModelLoaded
        case .appleSpeech: return appleSpeech.isModelLoaded
        case .sherpaOnnx:  return sherpa.isModelLoaded
        }
    }
}

// MARK: - SpeechTranscribing Conformance

extension TranscriptionRouter: SpeechTranscribing {

    /// Load a model, waiting for any load or transcription already in flight.
    ///
    /// Loading suspends, so without serialization two loads (easy to trigger
    /// by switching models or changing the language while one is still
    /// running) can overlap. Both would then finish, the later one setting
    /// `activeEngine`, while the other engine's model stayed resident.
    /// Transcription shares the same queue so a hotkey mid-switch cannot
    /// decode against an unloaded engine.
    func _loadModel(name: String?, folder: URL?, onPhaseChange: ((String) -> Void)?) async throws {
        try await operationSerializer.run { [self] in
            try await performLoad(name: name, folder: folder, onPhaseChange: onPhaseChange)
        }
    }

    private func performLoad(
        name: String?,
        folder: URL?,
        onPhaseChange: ((String) -> Void)?
    ) async throws {
        let engine = Self.engine(forModelIdentifier: name)

        // Free the other engines before loading, so only one model is ever
        // resident. Each engine also unloads itself before loading.
        if engine != .whisperKit {
            whisper.unloadModel()
        }
        if engine != .parakeet {
            // Awaited: FluidAudio's cleanup releases shared CoreML state, and
            // letting it run loose could tear that down after the next load
            // has started using it.
            await parakeet.unloadModelAndWait()
        }
        if engine != .appleSpeech {
            appleSpeech.unloadModel()
        }
        if engine != .sherpaOnnx {
            sherpa.unloadModel()
        }

        switch engine {
        case .whisperKit:
            try await whisper.loadModel(name: name, folder: folder, onPhaseChange: onPhaseChange)
        case .parakeet:
            try await parakeet.loadModel(name: name, onPhaseChange: onPhaseChange)
        case .appleSpeech:
            try await appleSpeech.loadModel(language: languagePreference, onPhaseChange: onPhaseChange)
        case .sherpaOnnx:
            try await sherpa.loadModel(name: name, onPhaseChange: onPhaseChange)
        }

        activeEngine = engine
    }

    /// The transcription language the user selected, or nil for auto-detect.
    private var languagePreference: String? {
        let stored = UserDefaults.standard.string(forKey: PreferenceKey.selectedLanguage) ?? "auto"
        return stored == "auto" ? nil : stored
    }

    func transcribe(
        audioData: [Float],
        language: String?,
        translate: Bool,
        vocabulary: String
    ) async throws -> VocaTranscription {
        try await operationSerializer.run { [self] in
            switch activeEngine {
            case .whisperKit:
                return try await whisper.transcribe(
                    audioData: audioData,
                    language: language,
                    translate: translate,
                    vocabulary: vocabulary
                )
            case .parakeet:
                return try await parakeet.transcribe(audioData: audioData, language: language)
            case .appleSpeech:
                return try await appleSpeech.transcribe(audioData: audioData, language: language)
            case .sherpaOnnx:
                return try await sherpa.transcribe(audioData: audioData, language: language)
            }
        }
    }
}
