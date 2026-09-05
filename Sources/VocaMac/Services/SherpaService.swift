// SherpaService.swift
// VocaMac
//
// Transcription via sherpa-onnx (ONNX Runtime, CPU-only). Serves the
// specialized community models: Moonshine v2 (English), SenseVoice
// (Chinese/Asian), GigaAM (Russian), and Canary (European languages).
//
// Uses the sherpa-onnx C API directly for recognizer lifecycle and decoding
// so failures surface as thrown errors; the vendored config builders in
// Vendor/SherpaOnnxConfigBuilders.swift construct the C config structs.

import Foundation
import SherpaOnnxC

// MARK: - SherpaError

enum SherpaError: LocalizedError {
    case modelNotLoaded
    case unknownModel(String)
    case modelFilesMissing(String)
    case initializationFailed(reason: String)
    case transcriptionFailed(reason: String)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No ONNX model is loaded. Please load a model first."
        case .unknownModel(let name):
            return "Unknown ONNX model: \(name)"
        case .modelFilesMissing(let path):
            return "Model files are missing at: \(path)"
        case .initializationFailed(let reason):
            return "Failed to initialize the ONNX model: \(reason)"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .emptyAudio:
            return "No audio data to transcribe."
        }
    }
}

// MARK: - SherpaService

final class SherpaService: @unchecked Sendable {

    // MARK: - Storage

    /// Root directory where sherpa-onnx model directories are extracted.
    /// Lives next to the WhisperKit model storage under Application Support.
    static var storageRoot: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("VocaMac")
            .appendingPathComponent("models")
            .appendingPathComponent("sherpa-onnx")
    }

    /// Directory a spec's files live in once extracted.
    static func modelDirectory(for spec: SherpaModelSpec) -> URL {
        storageRoot.appendingPathComponent(spec.directoryName, isDirectory: true)
    }

    /// Marker written only after an archive has been fully extracted and
    /// verified. Its absence means the directory is a partial install.
    static let completionMarkerName = ".vocamac-complete"

    /// Whether the model is fully installed and usable.
    ///
    /// A download that is interrupted mid-extraction leaves real files behind
    /// — `tar` writes entries as it goes — so checking that files exist is not
    /// enough: the app would offer to load a model whose weights are
    /// truncated, and the load would fail with no way for the user to
    /// recover. The marker is written last, so it is the only reliable signal
    /// that extraction finished.
    static func modelFilesExist(for spec: SherpaModelSpec) -> Bool {
        let directory = modelDirectory(for: spec)
        let fileManager = FileManager.default

        guard fileManager.fileExists(
            atPath: directory.appendingPathComponent(completionMarkerName).path
        ) else {
            return false
        }

        return spec.requiredFiles.allSatisfy { file in
            let path = directory.appendingPathComponent(file).path
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? Int64 else {
                return false
            }
            return size > 0
        }
    }

    /// Record that a model directory is complete. Called after extraction has
    /// been verified.
    static func markModelComplete(for spec: SherpaModelSpec) throws {
        let marker = modelDirectory(for: spec).appendingPathComponent(completionMarkerName)
        try Data().write(to: marker)
    }

    // MARK: - Properties

    /// A request retains its native model even if Settings unloads or replaces it.
    /// The per-model lock serializes native decodes without blocking state reads.
    private final class LoadedRecognizer: @unchecked Sendable {
        let pointer: OpaquePointer
        let size: ModelSize
        let decodeLock = NSLock()

        init(pointer: OpaquePointer, size: ModelSize) {
            self.pointer = pointer
            self.size = size
        }

        deinit {
            SherpaOnnxDestroyOfflineRecognizer(pointer)
        }
    }

    private var loadedRecognizer: LoadedRecognizer?
    private var loadGeneration = UUID()
    private let recognizerLock = NSLock()

    var isModelLoaded: Bool { snapshot() != nil }
    var loadedModelName: String? { snapshot()?.size.rawValue }

    /// Retain the model atomically so its lifetime includes all request segments.
    private func snapshot() -> LoadedRecognizer? {
        recognizerLock.lock()
        defer { recognizerLock.unlock() }
        return loadedRecognizer
    }

    deinit {
        unloadModel()
    }

    // MARK: - Model Management

    /// Load a sherpa-onnx model using the GUI's saved language preference.
    /// Direct service callers retain the pre-headless behavior; the router
    /// uses the explicit-language overload below.
    func loadModel(
        name modelName: String? = nil,
        onPhaseChange: ((String) -> Void)? = nil
    ) async throws {
        let stored = UserDefaults.standard.string(forKey: PreferenceKey.selectedLanguage) ?? "auto"
        try await loadModel(
            name: modelName,
            language: stored == "auto" ? nil : stored,
            onPhaseChange: onPhaseChange
        )
    }

    /// Load a sherpa-onnx model with a caller-supplied one-request language.
    /// `nil` explicitly means automatic language selection and never falls
    /// back to the saved GUI preference.
    func loadModel(
        name modelName: String? = nil,
        language: String?,
        onPhaseChange: ((String) -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        let generation = clearModel()

        guard let size = modelName.flatMap(ModelSize.init(rawValue:)),
              let spec = SherpaModelCatalog.spec(for: size) else {
            throw SherpaError.unknownModel(modelName ?? "nil")
        }

        let directory = Self.modelDirectory(for: spec)
        guard Self.modelFilesExist(for: spec) else {
            throw SherpaError.modelFilesMissing(directory.path)
        }

        let preferredLanguage = Self.normalizedLoadLanguage(language)
        VocaLogger.info(
            .sherpaService,
            "Loading ONNX model: \(size.rawValue) (language: \(preferredLanguage))..."
        )
        let startTime = CFAbsoluteTimeGetCurrent()
        onPhaseChange?("Loading ONNX model…")

        let created: OpaquePointer? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Build the config and hand it to sherpa-onnx inside one
                // autorelease pool. The config's file paths are C strings
                // pointing into autoreleased buffers, so they must not outlive
                // the pool that created them — building the config on a
                // different thread from this call would leave them dangling.
                // sherpa-onnx copies the paths, so they are free after this.
                let recognizer: OpaquePointer? = autoreleasepool {
                    var config = Self.recognizerConfig(
                        for: spec,
                        in: directory,
                        language: preferredLanguage
                    )
                    return SherpaOnnxCreateOfflineRecognizer(&config)
                }
                continuation.resume(returning: recognizer)
            }
        }

        guard let created else {
            throw SherpaError.initializationFailed(reason: "sherpa-onnx rejected the model files at \(directory.path)")
        }

        guard !Task.isCancelled else {
            SherpaOnnxDestroyOfflineRecognizer(created)
            throw CancellationError()
        }
        guard adopt(recognizer: created, size: size, generation: generation) else {
            throw CancellationError()
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        VocaLogger.info(.sherpaService, "ONNX model loaded in \(String(format: "%.2f", elapsed))s")
    }

    /// Atomically install the model; existing requests retain their previous model.
    private func adopt(recognizer created: OpaquePointer, size: ModelSize, generation: UUID) -> Bool {
        let model = LoadedRecognizer(pointer: created, size: size)
        recognizerLock.lock()
        guard loadGeneration == generation else {
            recognizerLock.unlock()
            return false
        }
        let previous = loadedRecognizer
        loadedRecognizer = model
        recognizerLock.unlock()
        // Release native memory outside the state lock.
        withExtendedLifetime(previous) {}
        return true
    }

    /// Remove the active model. In-flight requests release it when decoding finishes.
    func unloadModel() {
        _ = clearModel()
    }

    /// Invalidate pending loads as well as removing the active model.
    private func clearModel() -> UUID {
        recognizerLock.lock()
        let generation = UUID()
        loadGeneration = generation
        let previous = loadedRecognizer
        loadedRecognizer = nil
        recognizerLock.unlock()
        withExtendedLifetime(previous) {}
        return generation
    }

    // MARK: - Transcription

    /// Transcribe audio data to text.
    /// - Parameters:
    ///   - audioData: Array of Float32 PCM samples at 16kHz mono
    ///   - language: ISO 639-1 language code; only used to label the result.
    ///     Model language behavior is fixed at load time (see loadModel).
    func transcribe(
        audioData: [Float],
        language: String? = nil
    ) async throws -> VocaTranscription {
        try Task.checkCancellation()
        guard let request = snapshot() else { throw SherpaError.modelNotLoaded }
        let size = request.size

        try SherpaAudioPreparation.validate(audioData)

        let audioLengthSeconds = Double(audioData.count) / 16000.0
        VocaLogger.info(.sherpaService, "ONNX transcribing \(String(format: "%.1f", audioLengthSeconds))s of audio...")

        let startTime = CFAbsoluteTimeGetCurrent()

        // These models decode an utterance in one pass and degrade past a
        // certain length — Moonshine returns nothing at all — so anything
        // longer is split at pauses and decoded segment by segment.
        let maxSeconds = SherpaModelCatalog.spec(for: size)?.maxSegmentSeconds
        let segments: [[Float]]
        if let maxSeconds, audioLengthSeconds > maxSeconds {
            segments = AudioSegmenter.segment(audioData, maxSeconds: maxSeconds)
            VocaLogger.info(
                .sherpaService,
                "Audio exceeds \(String(format: "%.0f", maxSeconds))s for \(size.rawValue) — split into \(segments.count) segments"
            )
        } else {
            segments = [audioData]
        }

        // Detached work stays off the UI executor while retaining Swift task
        // cancellation. Native inference is synchronous: finish the current
        // segment safely, then discard its result and stop before the next one.
        let worker = Task.detached(priority: .userInitiated) {
            try Self.decodeRequest(segments: segments, language: language, request: request)
        }
        let decoded = try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)

        VocaLogger.info(.sherpaService, "ONNX transcription completed in \(String(format: "%.2f", elapsed))s")
        VocaLogger.info(.sherpaService, "Result: \(text.prefix(100))...")

        // SenseVoice reports the detected language; other models are
        // monolingual or fixed at load time.
        let detectedLanguage = decoded.lang.isEmpty ? (language ?? "auto") : decoded.lang

        return VocaTranscription(
            text: text,
            duration: elapsed,
            detectedLanguage: detectedLanguage,
            audioLengthSeconds: audioLengthSeconds,
            modelUsed: size
        )
    }

    /// Serialize native decoding for a retained model without holding the state lock.
    private static func decodeRequest(
        segments: [[Float]], language: String?, request: LoadedRecognizer
    ) throws -> (text: String, lang: String) {
        try Task.checkCancellation()
        request.decodeLock.lock()
        defer { request.decodeLock.unlock() }
        return try decodeSegments(segments, language: language) { samples in
            try decode(samples: samples, recognizer: request.pointer)
        }
    }

    /// Application-level segment processing, shared by native decoding and regressions.
    static func decodeSegments(
        _ segments: [[Float]],
        language: String?,
        decodeSegment: ([Float]) throws -> (text: String, lang: String)
    ) throws -> (text: String, lang: String) {
        try Task.checkCancellation()
        var pieces: [String] = []
        var detected = ""
        for segment in segments {
            try Task.checkCancellation()
            let samples = SherpaAudioPreparation.prepare(segment)
            guard !samples.isEmpty else { continue }
            let result = try decodeSegment(samples)
            try Task.checkCancellation()
            let piece = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            if detected.isEmpty { detected = result.lang }
        }
        let joinLanguage = detected.isEmpty ? (language ?? "") : detected
        return (joinTranscriptPieces(pieces, language: joinLanguage), detected)
    }

    /// Join Chinese/Japanese segments without spaces. Korean, like Western
    /// languages, needs spaces between words. SenseVoice may wrap language
    /// tags in `<|…|>`.
    static func joinTranscriptPieces(_ pieces: [String], language: String) -> String {
        let lang = language.lowercased()
            .replacingOccurrences(of: "<|", with: "")
            .replacingOccurrences(of: "|>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let joinsWithoutSpaces = lang.hasPrefix("zh") || lang.hasPrefix("ja") || lang.hasPrefix("yue")
        return pieces.joined(separator: joinsWithoutSpaces ? "" : " ")
    }

    /// Decode while the caller holds the recognizer lock for the whole request.
    private static func decode(
        samples: [Float], recognizer: OpaquePointer
    ) throws -> (text: String, lang: String) {
        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
            throw SherpaError.transcriptionFailed(reason: "Could not create an ONNX audio stream.")
        }
        defer { SherpaOnnxDestroyOfflineStream(stream) }

        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxAcceptWaveformOffline(stream, 16000, buffer.baseAddress, Int32(buffer.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)

        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
            throw SherpaError.transcriptionFailed(reason: "The ONNX decoder returned no result.")
        }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }

        let text = result.pointee.text.map { String(cString: $0) } ?? ""
        let lang = result.pointee.lang.map { String(cString: $0) } ?? ""
        // SenseVoice language tags look like "<|zh|>" — strip the markers.
        let cleanLang = lang.replacingOccurrences(of: "<|", with: "").replacingOccurrences(of: "|>", with: "")
        return (text, cleanLang)
    }

    // MARK: - Configuration

    /// Convert the router's optional language into the value expected by the
    /// sherpa config builders. A nil override is intentional `auto`, not a
    /// request to reread persistent preferences.
    static func normalizedLoadLanguage(_ language: String?) -> String {
        language ?? "auto"
    }

    /// Build the C recognizer config for a model spec.
    private static func recognizerConfig(
        for spec: SherpaModelSpec,
        in directory: URL,
        language: String
    ) -> SherpaOnnxOfflineRecognizerConfig {
        let path = { (file: String) in directory.appendingPathComponent(file).path }
        let numThreads = min(4, max(2, SystemInfo.recommendedThreadCount))

        let modelConfig: SherpaOnnxOfflineModelConfig
        switch spec.kind {
        case .moonshine(let encoder, let mergedDecoder):
            modelConfig = sherpaOnnxOfflineModelConfig(
                tokens: path(spec.tokensFile),
                numThreads: numThreads,
                moonshine: sherpaOnnxOfflineMoonshineModelConfig(
                    encoder: path(encoder),
                    mergedDecoder: path(mergedDecoder)
                )
            )
        case .senseVoice(let model):
            let supported: Set<String> = ["zh", "en", "ja", "ko", "yue"]
            let senseVoiceLanguage = supported.contains(language) ? language : "auto"
            modelConfig = sherpaOnnxOfflineModelConfig(
                tokens: path(spec.tokensFile),
                numThreads: numThreads,
                senseVoice: sherpaOnnxOfflineSenseVoiceModelConfig(
                    model: path(model),
                    language: senseVoiceLanguage,
                    useInverseTextNormalization: true
                )
            )
        case .nemoCtc(let model):
            modelConfig = sherpaOnnxOfflineModelConfig(
                tokens: path(spec.tokensFile),
                nemoCtc: sherpaOnnxOfflineNemoEncDecCtcModelConfig(model: path(model)),
                numThreads: numThreads
            )
        case .canary(let encoder, let decoder, let supportedLanguages):
            let canaryLanguage = supportedLanguages.contains(language) ? language : "en"
            modelConfig = sherpaOnnxOfflineModelConfig(
                tokens: path(spec.tokensFile),
                numThreads: numThreads,
                canary: sherpaOnnxOfflineCanaryModelConfig(
                    encoder: path(encoder),
                    decoder: path(decoder),
                    srcLang: canaryLanguage,
                    tgtLang: canaryLanguage
                )
            )
        }

        return sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(),
            modelConfig: modelConfig
        )
    }
}
