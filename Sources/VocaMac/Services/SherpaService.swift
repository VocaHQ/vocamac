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

    /// The active C recognizer (created when a model is loaded)
    private var recognizer: OpaquePointer?

    /// Which model is currently loaded
    private var loadedSize: ModelSize?

    /// Serializes recognizer lifecycle against decoding
    private let recognizerLock = NSLock()

    var isModelLoaded: Bool { recognizer != nil }

    var loadedModelName: String? { loadedSize?.rawValue }

    deinit {
        unloadModel()
    }

    // MARK: - Model Management

    /// Load a sherpa-onnx model from its extracted directory.
    func loadModel(
        name modelName: String? = nil,
        onPhaseChange: ((String) -> Void)? = nil
    ) async throws {
        unloadModel()

        guard let size = modelName.flatMap(ModelSize.init(rawValue:)),
              let spec = SherpaModelCatalog.spec(for: size) else {
            throw SherpaError.unknownModel(modelName ?? "nil")
        }

        let directory = Self.modelDirectory(for: spec)
        guard Self.modelFilesExist(for: spec) else {
            throw SherpaError.modelFilesMissing(directory.path)
        }

        VocaLogger.info(.sherpaService, "Loading ONNX model: \(size.rawValue)...")
        let startTime = CFAbsoluteTimeGetCurrent()
        onPhaseChange?("Loading ONNX model…")

        // The user's language preference influences config for SenseVoice
        // (recognition language) and Canary (source language). Both are fixed
        // at load time by the C API, so AppState reloads the active model when
        // the preference changes (see reloadModelForLanguageChangeIfNeeded).
        let preferredLanguage = UserDefaults.standard.string(forKey: PreferenceKey.selectedLanguage) ?? "auto"

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

        adopt(recognizer: created, size: size)

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        VocaLogger.info(.sherpaService, "ONNX model loaded in \(String(format: "%.2f", elapsed))s")
    }

    /// Take ownership of a freshly created recognizer.
    ///
    /// Destroys whatever was installed before rather than overwriting it:
    /// the pointer is native memory, so dropping the reference would leak the
    /// model. Loads are serialized upstream, but this keeps the object safe
    /// on its own terms.
    private func adopt(recognizer created: OpaquePointer, size: ModelSize) {
        recognizerLock.lock()
        defer { recognizerLock.unlock() }
        if let existing = recognizer {
            SherpaOnnxDestroyOfflineRecognizer(existing)
        }
        recognizer = created
        loadedSize = size
    }

    /// Unload the current model and free memory
    func unloadModel() {
        recognizerLock.lock()
        if let recognizer {
            SherpaOnnxDestroyOfflineRecognizer(recognizer)
            VocaLogger.info(.sherpaService, "ONNX model unloaded")
        }
        recognizer = nil
        loadedSize = nil
        recognizerLock.unlock()
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
        guard isModelLoaded, let size = loadedSize else {
            throw SherpaError.modelNotLoaded
        }

        guard !audioData.isEmpty else {
            throw SherpaError.emptyAudio
        }

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

        let decoded: (text: String, lang: String)? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                var pieces: [String] = []
                var detected = ""
                for segment in segments {
                    guard let result = self.decodeLocked(samples: segment) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let piece = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !piece.isEmpty { pieces.append(piece) }
                    if detected.isEmpty { detected = result.lang }
                }
                // Prefer the model's detected language; fall back to the caller's
                // preference so CJK SenseVoice output is not space-joined.
                let joinLanguage = detected.isEmpty ? (language ?? "") : detected
                continuation.resume(
                    returning: (Self.joinTranscriptPieces(pieces, language: joinLanguage), detected)
                )
            }
        }

        guard let decoded else {
            throw SherpaError.transcriptionFailed(reason: "The model was unloaded during transcription.")
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

    /// Join segment transcripts. CJK scripts do not use spaces between
    /// phrases; Western languages do. SenseVoice tags look like `zh` / `ja`
    /// / `yue` / `ko` (sometimes wrapped in `<|…|>`).
    static func joinTranscriptPieces(_ pieces: [String], language: String) -> String {
        let lang = language.lowercased()
            .replacingOccurrences(of: "<|", with: "")
            .replacingOccurrences(of: "|>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cjk = lang.hasPrefix("zh") || lang.hasPrefix("ja")
            || lang.hasPrefix("yue") || lang.hasPrefix("ko")
        return pieces.joined(separator: cjk ? "" : " ")
    }

    /// Run one decode against the active recognizer. Returns nil if no model
    /// is loaded. Called off the main thread; holds the lock so the
    /// recognizer cannot be destroyed mid-decode.
    private func decodeLocked(samples: [Float]) -> (text: String, lang: String)? {
        recognizerLock.lock()
        defer { recognizerLock.unlock() }

        guard let recognizer,
              let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
            return nil
        }
        defer { SherpaOnnxDestroyOfflineStream(stream) }

        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxAcceptWaveformOffline(stream, 16000, buffer.baseAddress, Int32(buffer.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)

        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
            return ("", "")
        }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }

        let text = result.pointee.text.map { String(cString: $0) } ?? ""
        let lang = result.pointee.lang.map { String(cString: $0) } ?? ""
        // SenseVoice language tags look like "<|zh|>" — strip the markers.
        let cleanLang = lang.replacingOccurrences(of: "<|", with: "").replacingOccurrences(of: "|>", with: "")
        return (text, cleanLang)
    }

    // MARK: - Configuration

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
