// TranscriptionRouter.swift
// VocaMac
//
// Routes model loading and transcription to the engine that owns the
// requested model. AppState talks to this single SpeechTranscribing facade
// and never needs to know which engine is active.

import Foundation
import os

/// A load or decode that missed its deadline (`Deadline`). The model was
/// dropped, so the next dictation loads a fresh copy.
enum TranscriptionDeadlineError: LocalizedError, Equatable {
    case loadTimedOut
    case decodeTimedOut

    var errorDescription: String? {
        switch self {
        case .loadTimedOut:
            return "The speech model took too long to load. VocaMac stopped waiting and will try again on the next dictation."
        case .decodeTimedOut:
            return "Transcription took too long. VocaMac stopped waiting and reloads the model on the next dictation."
        }
    }
}

final class TranscriptionRouter: @unchecked Sendable {

    // MARK: - Engines

    private let whisper = WhisperService()
    private let parakeet = ParakeetService()
    private let appleSpeech = AppleSpeechService()
    private let sherpa = SherpaService()
    private let customEndpoint = CustomEndpointService()

    /// Trims silence before batch decodes; see `SpeechActivityTrimmer`.
    private let voiceActivity = VoiceActivityDetector()

    private struct RouterState {
        var activeEngine: TranscriptionEngine = .whisperKit
        var consecutiveFailures = 0
    }

    /// Written by loads and decodes off the main actor and read from it
    /// (`isModelLoaded`, `startStreaming`), so it sits behind a lock.
    private let state = OSAllocatedUnfairLock(initialState: RouterState())

    /// Engine that owns the currently loaded model.
    private(set) var activeEngine: TranscriptionEngine {
        get { state.withLock { $0.activeEngine } }
        set { state.withLock { $0.activeEngine = newValue } }
    }

    /// Decodes in a row that failed on the loaded model; see
    /// `isModelFailure(_:)`. Only changed inside `operationSerializer`.
    private var consecutiveFailures: Int {
        get { state.withLock { $0.consecutiveFailures } }
        set { state.withLock { $0.consecutiveFailures = newValue } }
    }

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

    /// The languages the user speaks (Settings → Language), so Whisper can
    /// catch an auto-detected language outside them.
    private let spokenLanguagesProvider: () -> [String]

    init(
        languagePreferenceProvider: @escaping () -> String? = {
            let stored = UserDefaults.standard.string(forKey: PreferenceKey.selectedLanguage) ?? "auto"
            return stored == "auto" ? nil : stored
        },
        skipSilenceProvider: @escaping () -> Bool = {
            UserDefaults.standard.object(forKey: PreferenceKey.skipSilence) as? Bool ?? true
        },
        spokenLanguagesProvider: @escaping () -> [String] = {
            SpokenLanguages.resolve(
                stored: UserDefaults.standard.string(forKey: PreferenceKey.spokenLanguages),
                selectedLanguage: UserDefaults.standard.string(forKey: PreferenceKey.selectedLanguage) ?? "auto"
            )
        }
    ) {
        self.languagePreferenceProvider = languagePreferenceProvider
        self.skipSilenceProvider = skipSilenceProvider
        self.spokenLanguagesProvider = spokenLanguagesProvider
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
        case .customEndpoint: return customEndpoint.loadedModelName
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
        case .customEndpoint: return customEndpoint.isModelLoaded
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
    func _loadModel(name: String?, folder: URL?, onPhaseChange: (@Sendable (String) -> Void)?) async throws {
        let interval = PerformanceTrace.begin("ModelLoad")
        defer { PerformanceTrace.end(interval) }
        let seconds = Self.loadDeadlineSeconds(forModelIdentifier: name)
        try await operationSerializer.run { [self] in
            do {
                try await Deadline.run(
                    seconds: seconds,
                    abandonAfterCancel: Self.cancelledLoadGraceSeconds,
                    operation: "Loading \(name ?? "the speech model")"
                ) { [self] in
                    try await performLoad(name: name, folder: folder, onPhaseChange: onPhaseChange)
                }
            } catch is Deadline.Exceeded {
                abandonEngines()
                throw TranscriptionDeadlineError.loadTimedOut
            } catch is Deadline.Abandoned {
                // Cancelled (Force Recovery) and still not returning.
                abandonEngines()
                throw CancellationError()
            }
        }
    }

    // MARK: - Deadlines

    /// How long loading `identifier` may take before the router gives up.
    ///
    /// A first load that compiles for the Neural Engine can take minutes
    /// (Voca Hinglish took about five on an M1 Pro), and Apple Speech may
    /// download its assets, so those get far longer than a load from
    /// CoreML's cache.
    static func loadDeadlineSeconds(
        forModelIdentifier identifier: String?,
        record: CompiledModelRecord = CompiledModelRecord()
    ) -> TimeInterval {
        let size = identifier.flatMap(ModelSize.init(rawValue:))
            ?? identifier.map { WhisperService.modelSize(fromName: $0) }
        guard let size else { return firstLoadDeadlineSeconds }
        if size.engine == .appleSpeech { return firstLoadDeadlineSeconds }
        if size.engine.compilesForNeuralEngine, !record.hasLoaded(size) {
            return firstLoadDeadlineSeconds
        }
        return cachedLoadDeadlineSeconds
    }

    static let firstLoadDeadlineSeconds: TimeInterval = 30 * 60
    static let cachedLoadDeadlineSeconds: TimeInterval = 5 * 60

    /// Time allowed for one batch decode, including the queue wait. A remote
    /// endpoint gets its own request timeout plus the upload.
    static func decodeDeadlineSeconds(audioSeconds: Double, engine: TranscriptionEngine) -> TimeInterval {
        let local = Deadline.decodeSeconds(audioSeconds: audioSeconds)
        guard engine == .customEndpoint else { return local }
        return max(local, CustomEndpointService.requestTimeout + 30 + audioSeconds)
    }

    /// How long a cancelled load may keep the engine queue.
    static let cancelledLoadGraceSeconds: TimeInterval = 5

    /// How long a live session may keep the engine after it is cancelled.
    static let sessionAbandonGraceSeconds: TimeInterval = 3

    /// Drop every engine's model without waiting for it.
    ///
    /// Used when a load or decode missed its deadline: the engine may be
    /// stuck inside the very call that was given up on, and awaiting its
    /// cleanup could hang again. The call keeps its own reference and frees
    /// it if it ever returns; the next dictation loads a fresh model.
    /// Must run inside `operationSerializer`.
    private func abandonEngines() {
        VocaLogger.error(.general, "Giving up on \(loadedModelName ?? "the speech model"); it is reloaded on the next dictation")
        whisper.unloadModel()
        parakeet.unloadModel()
        sherpa.unloadModel()
        customEndpoint.unloadModel()
        let appleSpeech = self.appleSpeech
        Task { await appleSpeech.unloadModel() }
        consecutiveFailures = 0
    }

    /// Run a live session's work inside the engine queue, giving the engine
    /// back if the session is cancelled and the work does not stop.
    private func runSession(
        _ operation: @escaping @Sendable () async throws -> VocaTranscription
    ) async throws -> VocaTranscription {
        try await operationSerializer.run { [self] in
            do {
                return try await Deadline.run(
                    seconds: .infinity,
                    abandonAfterCancel: Self.sessionAbandonGraceSeconds,
                    operation: "Live transcription",
                    operation
                )
            } catch is Deadline.Abandoned {
                abandonEngines()
                throw CancellationError()
            }
        }
    }

    private func performLoad(
        name: String?,
        folder: URL?,
        onPhaseChange: (@Sendable (String) -> Void)?
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
        if engine != .customEndpoint {
            customEndpoint.unloadModel()
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
        case .customEndpoint:
            try await customEndpoint.loadModel(name: name, onPhaseChange: onPhaseChange)
        }

        // A load given up on (`Deadline`) must not make its engine active
        // over whatever loaded since.
        try Task.checkCancellation()
        activeEngine = engine
        if skipSilenceProvider() {
            await voiceActivity.prepare()
        }
        // The first prediction after a load is the slow one; take it now
        // rather than on the user's first dictation.
        switch engine {
        case .whisperKit: await whisper.warmUp()
        case .parakeet: await parakeet.warmUp()
        case .appleSpeech, .sherpaOnnx, .customEndpoint: break
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
        vocabulary: String,
        onPartial: (@Sendable (String) -> Void)?,
        commit: StreamingCommitOptions?
    ) -> RecordingTranscription? {
        // Apple Speech streams natively; in commit mode its finalized results
        // become the pieces, with no segmenter.
        if let commit, isModelLoaded, activeEngine != .appleSpeech {
            return startCommittedStreaming(
                language: language, vocabulary: vocabulary, onPartial: onPartial, commit: commit
            )
        }
        guard isModelLoaded else { return nil }
        // Whisper, Parakeet and sherpa-onnx are batch decoders: a live session
        // only earns its extra decodes when something shows the partial words.
        // Without a consumer the final decode is the same batch decode, so
        // skip the session and its second copy of the recording.
        guard activeEngine == .appleSpeech || onPartial != nil else { return nil }
        // A remote endpoint is batch-only — one upload per recording — so it
        // never gets a live session or per-piece decodes.
        guard activeEngine != .customEndpoint else { return nil }
        let expectedEngine = activeEngine
        let sherpaPreviewWindow = Self.sherpaPreviewWindowSamples(
            for: loadedModelName.flatMap(ModelSize.init(rawValue:))
        )
        return RecordingTranscription(language: language) { [self] chunks in
            try await runSession { [self] in
                guard activeEngine == expectedEngine else { throw RecordingTranscription.StreamError.incomplete }
                switch expectedEngine {
                case .appleSpeech:
                    return try await appleSpeech.transcribe(
                        chunks: chunks, language: language, vocabulary: vocabulary, onPiece: commit?.onPiece
                    )
                case .whisperKit:
                    // The final decode gets the batch path's silence trim, so
                    // showing live words never changes the pasted text: left
                    // untrimmed, trailing silence reached Whisper and it
                    // could add a "Thank you." the batch path never would.
                    return try await IncrementalAudioTranscriber.run(
                        chunks: chunks,
                        transcribe: { [whisper] samples in
                            try await whisper.transcribe(
                                audioData: samples, language: language,
                                translate: false, vocabulary: vocabulary
                            )
                        },
                        transcribeFinal: { [self, whisper] samples in
                            let spoken = spokenLanguagesProvider()
                            return try await finalDecode(samples, language: language) { speech, endsAtSpeech in
                                try await whisper.transcribe(
                                    audioData: speech, language: language, translate: false,
                                    vocabulary: vocabulary, includeWordTimestamps: true,
                                    endsAtSpeech: endsAtSpeech, expectedLanguages: spoken
                                )
                            }
                        },
                        onPartial: onPartial
                    )
                case .parakeet:
                    return try await IncrementalAudioTranscriber.run(
                        chunks: chunks,
                        transcribe: { [parakeet] samples in
                            try await parakeet.transcribe(audioData: samples, language: language)
                        },
                        transcribeFinal: { [self, parakeet] samples in
                            try await finalDecode(samples, language: language) { speech, _ in
                                try await parakeet.transcribe(audioData: speech, language: language, vocabulary: vocabulary)
                            }
                        },
                        onPartial: onPartial
                    )
                case .sherpaOnnx:
                    return try await Self.runSherpaLiveSession(
                        chunks: chunks, windowSamples: sherpaPreviewWindow,
                        language: language, model: loadedModelSize,
                        speechOnly: { [self] samples in await audioWithoutSilence(samples)?.samples },
                        decode: { [sherpa] samples, isPreview in
                            try await sherpa.transcribe(audioData: samples, language: language, isPreview: isPreview)
                        },
                        onPartial: onPartial
                    )
                case .customEndpoint:
                    throw RecordingTranscription.StreamError.incomplete
                }
            }
        }
    }

    /// The final decode of a live preview session, given the same silence
    /// trim and timing map as the batch path, and labelled with the complete
    /// recording's length, which `RecordingTranscription.finish` checks.
    /// `decode`'s second argument says whether trailing silence was trimmed.
    private func finalDecode(
        _ samples: [Float],
        language: String?,
        decode: ([Float], Bool) async throws -> VocaTranscription
    ) async throws -> VocaTranscription {
        let recordingSeconds = Double(samples.count) / 16_000
        guard let prepared = await audioWithoutSilence(samples) else {
            VocaLogger.info(.general, "No speech detected; skipping the decode")
            return VocaTranscription(
                text: "", duration: 0, detectedLanguage: language ?? "auto",
                audioLengthSeconds: recordingSeconds, modelUsed: loadedModelSize
            )
        }
        let result = try await decode(prepared.samples, !prepared.trimPieces.isEmpty)
        var segments = result.segments
        if !prepared.trimPieces.isEmpty {
            segments = segments.map {
                $0.mappingTimes { SpeechActivityTrimmer.sourceSeconds($0, pieces: prepared.trimPieces) }
            }
        }
        return VocaTranscription(
            text: result.text, duration: result.duration, detectedLanguage: result.detectedLanguage,
            audioLengthSeconds: recordingSeconds, modelUsed: result.modelUsed, segments: segments
        )
    }

    /// A live sherpa-onnx session: preview decodes of the recent audio while
    /// recording, then the final decode of the complete recording.
    ///
    /// The final decode gets the same silence trim (`speechOnly`) and decode
    /// the batch path gives the recording, so showing a preview never changes
    /// the text that is pasted. Its result is labelled with the complete
    /// recording's length, which `RecordingTranscription.finish` checks.
    /// `decode`'s second argument says whether the decode is a preview.
    static func runSherpaLiveSession(
        chunks: AsyncThrowingStream<[Float], Error>,
        windowSamples: Int,
        language: String?,
        model: ModelSize,
        speechOnly: @escaping @Sendable ([Float]) async -> [Float]?,
        decode: @escaping @Sendable (_ samples: [Float], _ isPreview: Bool) async throws -> VocaTranscription,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> VocaTranscription {
        try await IncrementalAudioTranscriber.run(
            chunks: chunks,
            updateEverySamples: sherpaPreviewIntervalSamples,
            partialWindowSamples: windowSamples,
            transcribe: { samples in try await decode(samples, true) },
            transcribeFinal: { samples in
                let recordingSeconds = Double(samples.count) / 16_000
                guard let speech = await speechOnly(samples) else {
                    VocaLogger.info(.general, "No speech detected; skipping the decode")
                    return VocaTranscription(
                        text: "", duration: 0, detectedLanguage: language ?? "auto",
                        audioLengthSeconds: recordingSeconds, modelUsed: model
                    )
                }
                let result = try await decode(speech, false)
                return VocaTranscription(
                    text: result.text, duration: result.duration, detectedLanguage: result.detectedLanguage,
                    audioLengthSeconds: recordingSeconds, modelUsed: result.modelUsed
                )
            },
            onPartial: onPartial
        )
    }

    /// sherpa-onnx previews refresh every second. On an M1 Pro, Canary 180M
    /// decodes an 8 s window in about half a second on CPU, so a preview
    /// is usually done before the next one is due.
    static let sherpaPreviewIntervalSamples = 16_000

    /// Trailing audio one sherpa-onnx preview decodes: 8 s, or less when the
    /// model's single-pass limit is shorter, so a preview is one native
    /// decode. That decode can't be stopped halfway, and one still running
    /// at stop delays the final text by whatever it has left.
    static func sherpaPreviewWindowSamples(for model: ModelSize?) -> Int {
        let seconds = min(8, maxPieceSeconds(for: model))
        return Int(seconds * 16_000)
    }

    /// Engine limit for one piece. Whisper's window is 30 s and Parakeet
    /// chunks internally, but a piece that long would defeat the purpose.
    static let defaultMaxPieceSeconds = 25.0

    /// The longest piece `model` should decode in one pass.
    static func maxPieceSeconds(for model: ModelSize?) -> Double {
        guard let model, model.engine == .sherpaOnnx,
              let limit = SherpaModelCatalog.spec(for: model)?.maxSegmentSeconds else {
            return defaultMaxPieceSeconds
        }
        // Leave room for the silence SherpaService pads each decode with, so a
        // piece is never split again inside the engine.
        return limit - SherpaAudioPreparation.addedSilenceSeconds
    }

    /// Decode each finished piece with the engine's batch decoder while the
    /// user keeps talking. The session holds the operation serializer for its
    /// whole life, like the preview session, so a model switch cannot unload
    /// the engine between pieces.
    private func startCommittedStreaming(
        language: String?,
        vocabulary: String,
        onPartial: (@Sendable (String) -> Void)?,
        commit: StreamingCommitOptions
    ) -> RecordingTranscription {
        let expectedEngine = activeEngine
        let loadedSize = loadedModelName.flatMap(ModelSize.init(rawValue:))
        let configuration = commit.segmenterConfiguration(
            maxPieceSeconds: Self.maxPieceSeconds(for: expectedEngine == .sherpaOnnx ? loadedSize : nil)
        )
        let transcribe: @Sendable ([Float]) async throws -> VocaTranscription
        var previewTranscribe: (@Sendable ([Float]) async throws -> VocaTranscription)?
        switch expectedEngine {
        case .whisperKit:
            let spoken = spokenLanguagesProvider()
            transcribe = { [whisper] samples in
                try await whisper.transcribe(
                    audioData: samples, language: language, translate: false,
                    vocabulary: commit.vocabulary?() ?? vocabulary, expectedLanguages: spoken
                )
            }
            previewTranscribe = { [whisper] samples in
                try await whisper.transcribe(
                    audioData: samples, language: language, translate: false, vocabulary: vocabulary
                )
            }
        case .parakeet:
            transcribe = { [parakeet] samples in
                // Each piece is a kept decode, so it gets the same dictionary
                // boost the batch final decode would. Previews are not used.
                try await parakeet.transcribe(
                    audioData: samples, language: language,
                    vocabulary: commit.vocabulary?() ?? vocabulary
                )
            }
        case .sherpaOnnx:
            transcribe = { [sherpa] samples in
                try await sherpa.transcribe(audioData: samples, language: language)
            }
            previewTranscribe = { [sherpa] samples in
                try await sherpa.transcribe(audioData: samples, language: language, isPreview: true)
            }
        case .appleSpeech, .customEndpoint:
            transcribe = { _ in throw RecordingTranscription.StreamError.incomplete }
        }
        let preview = previewTranscribe
        return RecordingTranscription(language: language) { [self] chunks in
            try await runSession { [self] in
                guard activeEngine == expectedEngine else { throw RecordingTranscription.StreamError.incomplete }
                return try await IncrementalAudioTranscriber.runCommitted(
                    chunks: chunks, segmenter: configuration, onPiece: commit.onPiece,
                    onTentativePiece: commit.onTentativePiece,
                    earlyDecodeQuietSeconds: commit.earlyDecodeQuietSeconds,
                    isReadyForEarlyDecode: commit.isReadyForEarlyDecode,
                    revisesPrevious: commit.revisesPrevious,
                    transcribe: transcribe, previewTranscribe: preview, onPartial: onPartial
                )
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
        guard let prepared = await audioWithoutSilence(audioData) else {
            VocaLogger.info(.general, "No speech detected; skipping the decode")
            return VocaTranscription(
                text: "", duration: 0, detectedLanguage: language ?? "auto",
                audioLengthSeconds: Double(audioData.count) / 16_000, modelUsed: loadedModelSize
            )
        }
        let endsAtSpeech = !prepared.trimPieces.isEmpty
        let seconds = Self.decodeDeadlineSeconds(
            audioSeconds: Double(audioData.count) / 16_000, engine: activeEngine
        )
        var result = try await operationSerializer.run { [self] in
            do {
                let result = try await Deadline.run(seconds: seconds, operation: "Transcription") { [self] in
                    try await decode(
                        audioData: prepared.samples, language: language, translate: translate,
                        vocabulary: vocabulary, endsAtSpeech: endsAtSpeech
                    )
                }
                consecutiveFailures = 0
                return result
            } catch is Deadline.Exceeded {
                abandonEngines()
                throw TranscriptionDeadlineError.decodeTimedOut
            } catch {
                // A cancelled dictation says nothing about the model, however
                // the engine reported it.
                guard !Task.isCancelled, Self.isModelFailure(error) else { throw error }
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
        // Timings the decoder produced sit on the audio it heard; when
        // silence was trimmed out, move them back to the recording's timeline.
        if !prepared.trimPieces.isEmpty {
            result.segments = result.segments.map {
                $0.mappingTimes { SpeechActivityTrimmer.sourceSeconds($0, pieces: prepared.trimPieces) }
            }
        }
        return result
    }

    private func decode(
        audioData: [Float],
        language: String?,
        translate: Bool,
        vocabulary: String,
        endsAtSpeech: Bool
    ) async throws -> VocaTranscription {
        switch activeEngine {
        case .whisperKit:
            return try await whisper.transcribe(
                audioData: audioData,
                language: language,
                translate: translate,
                vocabulary: vocabulary,
                includeWordTimestamps: true,
                endsAtSpeech: endsAtSpeech,
                expectedLanguages: spokenLanguagesProvider()
            )
        case .parakeet:
            return try await parakeet.transcribe(audioData: audioData, language: language, vocabulary: vocabulary)
        case .appleSpeech:
            return try await appleSpeech.transcribe(audioData: audioData, language: language, vocabulary: vocabulary)
        case .sherpaOnnx:
            return try await sherpa.transcribe(audioData: audioData, language: language)
        case .customEndpoint:
            return try await customEndpoint.transcribe(
                audioData: audioData, language: language, translate: translate, vocabulary: vocabulary
            )
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
        case WhisperError.transcriptionFailed(let reason), ParakeetError.transcriptionFailed(let reason):
            // An engine that wrapped a cancellation still says nothing about
            // the model.
            return reason != CancellationError().localizedDescription
        case WhisperError.modelNotLoaded, WhisperError.emptyAudio,
             ParakeetError.modelNotLoaded, ParakeetError.emptyAudio,
             AppleSpeechError.modelNotLoaded, AppleSpeechError.emptyAudio,
             SherpaError.modelNotLoaded, SherpaError.emptyAudio,
             CustomEndpointError.modelNotLoaded, CustomEndpointError.emptyAudio:
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

    /// The recording with silence trimmed — or unchanged when trimming is
    /// off or unavailable — with the pieces the trim was built from so
    /// timings can be mapped back to the recording. Nil when nothing was said.
    private func audioWithoutSilence(
        _ audioData: [Float]
    ) async -> (samples: [Float], trimPieces: [SpeechActivityTrimmer.CopiedPiece])? {
        guard skipSilenceProvider() else { return (audioData, []) }
        let interval = PerformanceTrace.begin("VoiceActivityTrim")
        defer { PerformanceTrace.end(interval) }
        switch await voiceActivity.decision(for: audioData) {
        case .keep:
            return (audioData, [])
        case .trim(let ranges):
            let trimmed = SpeechActivityTrimmer.apply(ranges, to: audioData)
            VocaLogger.debug(.general, "Skipped silence: \(audioData.count) → \(trimmed.count) samples")
            return (trimmed, SpeechActivityTrimmer.copiedPieces(from: ranges, sampleCount: audioData.count))
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
        customEndpoint.unloadModel()
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
