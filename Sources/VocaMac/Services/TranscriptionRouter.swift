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

    /// Trims silence before batch decodes; see `SpeechActivityTrimmer`.
    private let voiceActivity = VoiceActivityDetector()

    /// Engine that owns the currently loaded model.
    private(set) var activeEngine: TranscriptionEngine = .whisperKit

    /// Decodes in a row that failed on the loaded model; see
    /// `isModelFailure(_:)`.
    private var consecutiveFailures = 0

    /// Failures in a row after which the model is unloaded, so the next
    /// dictation loads a fresh copy instead of failing the same way.
    static let failuresBeforeReload = 2

    /// Shared queue for loads and transcriptions so a hotkey cannot decode
    /// against an engine that a concurrent load just unloaded.
    private let operationSerializer = LoadSerializer()

    /// Supplies the language engines with load-time language configuration
    /// must prepare before transcription. The GUI reads the normal app
    /// preference; headless callers inject the one-request language without
    /// changing that preference.
    private let languagePreferenceProvider: () -> String?

    /// Whether batch decodes skip silence first (Settings → Audio).
    private let skipSilenceProvider: () -> Bool

    init(
        languagePreferenceProvider: @escaping () -> String? = {
            let stored = UserDefaults.standard.string(forKey: PreferenceKey.selectedLanguage) ?? "auto"
            return stored == "auto" ? nil : stored
        },
        skipSilenceProvider: @escaping () -> Bool = {
            UserDefaults.standard.object(forKey: PreferenceKey.skipSilence) as? Bool ?? true
        }
    ) {
        self.languagePreferenceProvider = languagePreferenceProvider
        self.skipSilenceProvider = skipSilenceProvider
    }

    // MARK: - Engine Capabilities

    /// Languages Apple Speech supports on this Mac, or nil when it can't
    /// run here or the system reports none.
    static func appleSpeechLanguageCodes() async -> Set<String>? {
        await AppleSpeechService.supportedLanguageCodes()
    }

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

    /// Catalog entry of the loaded model, for results the router makes itself.
    private var loadedModelSize: ModelSize {
        switch activeEngine {
        case .whisperKit:
            return whisper.modelSizeFromName(whisper.loadedModelName ?? "tiny")
        default:
            return loadedModelName.flatMap(ModelSize.init(rawValue:)) ?? .tiny
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
        let interval = PerformanceTrace.begin("ModelLoad")
        defer { PerformanceTrace.end(interval) }
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
            await appleSpeech.unloadModel()
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
            try await sherpa.loadModel(
                name: name,
                language: languagePreference,
                onPhaseChange: onPhaseChange
            )
        }

        activeEngine = engine
        if skipSilenceProvider() {
            await voiceActivity.prepare()
        }
    }

    /// The transcription language the user selected, or nil for auto-detect.
    private var languagePreference: String? {
        languagePreferenceProvider()
    }

    /// Keep the normal operation serializer for the whole live session, so a
    /// model switch cannot unload an analyzer that is still consuming audio.
    func startStreaming(
        language: String?,
        vocabulary: String = "",
        onPartial: (@Sendable (String) -> Void)? = nil
    ) -> RecordingTranscription? {
        guard isModelLoaded, activeEngine != .sherpaOnnx else { return nil }
        // Whisper and Parakeet are batch decoders: a live session only earns
        // its extra decodes when something shows the partial words. Without a
        // consumer the final decode is the same batch decode, so skip the
        // session and its second copy of the recording.
        guard activeEngine == .appleSpeech || onPartial != nil else { return nil }
        let expectedEngine = activeEngine
        return RecordingTranscription(language: language) { [self] chunks in
            try await operationSerializer.run { [self] in
                guard activeEngine == expectedEngine else { throw RecordingTranscription.StreamError.incomplete }
                switch expectedEngine {
                case .appleSpeech:
                    return try await appleSpeech.transcribe(chunks: chunks, language: language, vocabulary: vocabulary)
                case .whisperKit:
                    return try await IncrementalAudioTranscriber.run(
                        chunks: chunks,
                        transcribe: { [whisper] samples in
                            try await whisper.transcribe(
                                audioData: samples, language: language,
                                translate: false, vocabulary: vocabulary
                            )
                        },
                        onPartial: onPartial
                    )
                case .parakeet:
                    return try await IncrementalAudioTranscriber.run(
                        chunks: chunks,
                        transcribe: { [parakeet] samples in
                            try await parakeet.transcribe(audioData: samples, language: language)
                        },
                        transcribeFinal: { [parakeet] samples in
                            try await parakeet.transcribe(audioData: samples, language: language, vocabulary: vocabulary)
                        },
                        onPartial: onPartial
                    )
                case .sherpaOnnx:
                    throw RecordingTranscription.StreamError.incomplete
                }
            }
        }
    }

    func transcribe(
        audioData: [Float],
        language: String?,
        translate: Bool,
        vocabulary: String
    ) async throws -> VocaTranscription {
        let interval = PerformanceTrace.begin("TranscriptionQueueAndDecode")
        defer { PerformanceTrace.end(interval) }
        guard let audioData = await audioWithoutSilence(audioData) else {
            VocaLogger.info(.general, "No speech detected; skipping the decode")
            return VocaTranscription(
                text: "", duration: 0, detectedLanguage: language ?? "auto",
                audioLengthSeconds: Double(audioData.count) / 16_000, modelUsed: loadedModelSize
            )
        }
        return try await operationSerializer.run { [self] in
            do {
                let result = try await decode(audioData: audioData, language: language, translate: translate, vocabulary: vocabulary)
                consecutiveFailures = 0
                return result
            } catch {
                guard Self.isModelFailure(error) else { throw error }
                consecutiveFailures += 1
                if consecutiveFailures >= Self.failuresBeforeReload {
                    VocaLogger.error(
                        .general,
                        "\(consecutiveFailures) decodes failed on \(loadedModelName ?? "the model"); unloading so the next dictation reloads it"
                    )
                    consecutiveFailures = 0
                    await unloadAllEngines()
                }
                throw error
            }
        }
    }

    private func decode(
        audioData: [Float],
        language: String?,
        translate: Bool,
        vocabulary: String
    ) async throws -> VocaTranscription {
        switch activeEngine {
        case .whisperKit:
            return try await whisper.transcribe(
                audioData: audioData,
                language: language,
                translate: translate,
                vocabulary: vocabulary
            )
        case .parakeet:
            return try await parakeet.transcribe(audioData: audioData, language: language, vocabulary: vocabulary)
        case .appleSpeech:
            return try await appleSpeech.transcribe(audioData: audioData, language: language, vocabulary: vocabulary)
        case .sherpaOnnx:
            return try await sherpa.transcribe(audioData: audioData, language: language)
        }
    }

    /// Whether a failed decode says the loaded model may be in a bad state.
    ///
    /// A model that fails this way twice in a row is dropped and reloaded on
    /// the next dictation. Cancellation, missing audio, and "not loaded" say
    /// nothing about the model, so they never count.
    static func isModelFailure(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        switch error {
        case WhisperError.modelNotLoaded, WhisperError.emptyAudio,
             ParakeetError.modelNotLoaded, ParakeetError.emptyAudio,
             AppleSpeechError.modelNotLoaded, AppleSpeechError.emptyAudio,
             SherpaError.modelNotLoaded, SherpaError.emptyAudio:
            return false
        default:
            return true
        }
    }

    // MARK: - Vocabulary Boost

    /// Whether Parakeet's vocabulary boost model is on disk.
    static var isVocabularyBoostDownloaded: Bool { ParakeetVocabularyBoost.isModelDownloaded }

    /// Download Parakeet's vocabulary boost model (~98 MB).
    static func downloadVocabularyBoost() async throws {
        try await ParakeetVocabularyBoost.downloadModel()
    }

    /// Delete Parakeet's vocabulary boost model, turning the boost off.
    static func removeVocabularyBoost() throws {
        try ParakeetVocabularyBoost.removeModel()
    }

    // MARK: - Silence

    /// The recording with silence trimmed, or nil when nothing was said.
    /// Returns the recording unchanged when trimming is off or unavailable.
    private func audioWithoutSilence(_ audioData: [Float]) async -> [Float]? {
        guard skipSilenceProvider() else { return audioData }
        let interval = PerformanceTrace.begin("VoiceActivityTrim")
        defer { PerformanceTrace.end(interval) }
        switch await voiceActivity.decision(for: audioData) {
        case .keep:
            return audioData
        case .trim(let ranges):
            let trimmed = SpeechActivityTrimmer.apply(ranges, to: audioData)
            VocaLogger.debug(.general, "Skipped silence: \(audioData.count) → \(trimmed.count) samples")
            return trimmed
        case .noSpeech:
            return nil
        }
    }

    /// Must run inside `operationSerializer`.
    private func unloadAllEngines() async {
        whisper.unloadModel()
        await parakeet.unloadModelAndWait()
        await appleSpeech.unloadModel()
        sherpa.unloadModel()
        await voiceActivity.unload()
        consecutiveFailures = 0
    }

    /// Clear preferences retired engine code left behind. Owned here so
    /// `AppState` asks the facade rather than an engine service directly.
    func removeRetiredEngineState() {
        WhisperService.removeLegacyPrewarmLedger()
    }

    /// Unload every engine so only cold-start memory remains.
    ///
    /// Serialized with load/transcribe so a hotkey cannot decode against an
    /// engine that is mid-teardown.
    func unloadModel() async {
        do {
            try await operationSerializer.run(cancellable: false) { [self] in
                await unloadAllEngines()
            }
        } catch {
            // Unload paths do not throw today; keep the queue resilient if that changes.
            VocaLogger.error(.general, "Model unload failed: \(error.localizedDescription)")
        }
    }
}
