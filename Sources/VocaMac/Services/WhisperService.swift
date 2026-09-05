// WhisperService.swift
// VocaMac
//
// Swift wrapper around WhisperKit for local speech-to-text transcription.
// Uses CoreML with Metal/Neural Engine acceleration on Apple Silicon.

import Foundation
import WhisperKit

// MARK: - WhisperError

enum WhisperError: LocalizedError {
    case modelNotLoaded
    case initializationFailed(reason: String)
    case transcriptionFailed(reason: String)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No whisper model is loaded. Please load a model first."
        case .initializationFailed(let reason):
            return "Failed to initialize WhisperKit: \(reason)"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .emptyAudio:
            return "No audio data to transcribe."
        }
    }
}

// MARK: - WhisperService

final class WhisperService: @unchecked Sendable {

    // MARK: - Properties

    /// The WhisperKit instance (initialized when a model is loaded)
    private var whisperKit: WhisperKit?

    /// Whether a model is currently loaded and ready
    var isModelLoaded: Bool { whisperKit != nil }

    /// The name/variant of the currently loaded model
    private(set) var loadedModelName: String?

    /// Lock to prevent concurrent transcription
    private let transcriptionLock = NSLock()

    // MARK: - Lifecycle

    deinit {
        whisperKit = nil
    }

    // MARK: - Model Management

    /// Initialize WhisperKit with a specific model (or auto-select best for device)
    /// - Parameters:
    ///   - modelName: The model variant to load (e.g., "openai_whisper-tiny"), or nil for auto-select
    ///   - modelFolder: Optional local folder containing pre-downloaded models
    func loadModel(
        name modelName: String? = nil,
        folder modelFolder: URL? = nil,
        onPhaseChange: ((String) -> Void)? = nil
    ) async throws {
        // Unload any existing model
        unloadModel()

        let displayName = modelName ?? "auto-detect"
        VocaLogger.info(.whisperService, "Loading model: \(displayName)...")
        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            onPhaseChange?("Configuring…")
            let config = WhisperKitConfig()

            // Set model if specified, otherwise WhisperKit auto-selects
            if let name = modelName {
                config.model = name
            }

            // Store models in Application Support, not the default ~/Documents
            // path, to avoid triggering a Documents folder permission prompt.
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            config.downloadBase = appSupport
                .appendingPathComponent("VocaMac")
                .appendingPathComponent("models")

            // Verbose logging for debugging
            config.verbose = true

            // Prewarm the model so the CoreML pipeline (Metal/ANE) is compiled
            // at load time rather than on the first transcription request.
            // Without this, the first transcription after switching models is
            // extremely slow as CoreML compiles shaders and optimizes the graph.
            config.prewarm = true

            // If a local model folder is specified, use it
            if let folder = modelFolder {
                config.modelFolder = folder.path
                config.download = false
            }

            onPhaseChange?("Loading model…")
            let kit = try await WhisperKit(config)

            onPhaseChange?("Compiling neural engine…")
            self.whisperKit = kit
            self.loadedModelName = modelName ?? kit.modelVariant.description

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            VocaLogger.info(.whisperService, "Model loaded in \(String(format: "%.2f", elapsed))s")
        } catch {
            VocaLogger.error(.whisperService, "ERROR loading model: \(error)")
            throw WhisperError.initializationFailed(reason: error.localizedDescription)
        }
    }

    /// Unload the current model and free memory
    func unloadModel() {
        if whisperKit != nil {
            whisperKit = nil
            loadedModelName = nil
            VocaLogger.info(.whisperService, "Model unloaded")
        }
    }

    // MARK: - Transcription

    /// Transcribe audio data to text.
    /// - Parameters:
    ///   - audioData: Array of Float32 PCM samples at 16kHz mono
    ///   - language: ISO 639-1 language code (e.g., "en"), or nil for auto-detection
    ///   - translate: Whether to translate to English (if true) or transcribe as-is (if false)
    ///   - vocabulary: Custom terms (newline/comma separated) to bias transcription toward,
    ///     e.g. proper nouns and jargon like names. Empty string disables it.
    /// - Returns: VocaTranscription with the transcribed text and metadata
    func transcribe(
        audioData: [Float],
        language: String? = nil,
        translate: Bool = false,
        vocabulary: String = ""
    ) async throws -> VocaTranscription {
        guard let kit = whisperKit else {
            throw WhisperError.modelNotLoaded
        }

        guard !audioData.isEmpty else {
            throw WhisperError.emptyAudio
        }

        let audioLengthSeconds = Double(audioData.count) / 16000.0
        VocaLogger.info(.whisperService, "Transcribing \(String(format: "%.1f", audioLengthSeconds))s of audio...")

        let startTime = CFAbsoluteTimeGetCurrent()

        // Encode the user's custom vocabulary into conditioning tokens so the
        // model biases toward their proper nouns / jargon (e.g. names like
        // "Namrata"). WhisperKit only applies promptTokens when usePrefillPrompt
        // is true, so we force it on whenever vocabulary is present — otherwise
        // the terms would be silently ignored in auto-detect mode.
        let promptTokens = Self.promptTokens(for: vocabulary, tokenizer: kit.tokenizer)

        // Configure decoding options — optimized for low latency dictation
        var options = DecodingOptions(
            task: translate ? .translate : .transcribe,
            language: language,
            temperature: 0.0,
            temperatureFallbackCount: 0,  // No fallback for speed
            usePrefillPrompt: language != nil || promptTokens != nil,
            detectLanguage: language == nil,
            wordTimestamps: false,
            promptTokens: promptTokens,
            chunkingStrategy: nil  // No chunking for short dictation clips
        )

        do {
            var results = try await kit.transcribe(
                audioArray: audioData,
                decodeOptions: options
            )

            // Concatenate all segment texts
            var rawText = results.map { $0.text }.joined(separator: " ")

            // Filter out WhisperKit hallucination tokens that should not be
            // exposed to the user (e.g. "[BLANK_AUDIO]", "(blank audio)", etc.)
            var fullText = Self.filterHallucinationTokens(rawText)

            // WhisperKit can exit during prompt prefill and return no text for
            // some models. Preserve vocabulary bias normally, but recover the
            // dictation by retrying once without custom prompt tokens.
            if Self.shouldRetryWithoutVocabulary(rawText: rawText, promptTokens: promptTokens) {
                VocaLogger.warning(
                    .whisperService,
                    "Prompted transcription was empty for \(loadedModelName ?? "unknown model"); retrying without custom vocabulary"
                )
                options.promptTokens = nil
                options.usePrefillPrompt = language != nil
                results = try await kit.transcribe(audioArray: audioData, decodeOptions: options)
                rawText = results.map { $0.text }.joined(separator: " ")
                fullText = Self.filterHallucinationTokens(rawText)
            }

            // Whisper Tiny can return no tokens for valid sub-second speech.
            // Retry only an empty short result with trailing silence so normal
            // successful dictation keeps the single-pass fast path.
            if let paddedAudio = Self.paddedAudioForShortEmptyTranscription(
                audioData,
                transcription: fullText
            ) {
                VocaLogger.warning(
                    .whisperService,
                    "Short transcription was empty for \(loadedModelName ?? "unknown model"); retrying with trailing silence"
                )
                results = try await kit.transcribe(audioArray: paddedAudio, decodeOptions: options)
                rawText = results.map { $0.text }.joined(separator: " ")
                fullText = Self.filterHallucinationTokens(rawText)
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime

            // Get detected language from first result
            let detectedLanguage = results.first?.language ?? language ?? "en"

            let modelUsed = modelSizeFromName(loadedModelName ?? "tiny")

            VocaLogger.info(.whisperService, "Transcription completed in \(String(format: "%.2f", elapsed))s")
            VocaLogger.info(.whisperService, "Result: \(fullText.prefix(100))...")

            return VocaTranscription(
                text: fullText,
                duration: elapsed,
                detectedLanguage: detectedLanguage,
                audioLengthSeconds: audioLengthSeconds,
                modelUsed: modelUsed
            )
        } catch {
            throw WhisperError.transcriptionFailed(reason: error.localizedDescription)
        }
    }

    // MARK: - Device Recommendations

    /// Get recommended models for the current device
    static func recommendedModels() -> (defaultModel: String, supported: [String]) {
        let recommendation = WhisperKit.recommendedModels()
        return (
            defaultModel: recommendation.default,
            supported: recommendation.supported
        )
    }

    /// Get the device name (e.g., "MacBookPro18,1")
    static func deviceName() -> String {
        WhisperKit.deviceName()
    }

    // MARK: - Utilities

    // MARK: - Hallucination Filtering

    /// Tokens that WhisperKit may emit when the audio contains silence,
    /// background noise, or is too short to produce real speech. These are
    /// internal model artifacts and should never be shown to the user.
    private static let hallucinationPatterns: [String] = [
        "[BLANK_AUDIO]",
        "(blank audio)",
        "[NO_SPEECH]",
        "(no speech)",
        "[ Silence ]",
        "[silence]",
        "(silence)",
        "[Music]",
        "(music)",
        "[Applause]",
        "(applause)",
    ]

    /// Remove hallucination tokens from transcribed text.
    /// Returns the cleaned string, which may be empty if the entire output
    /// consisted of hallucination tokens.
    static func filterHallucinationTokens(_ text: String) -> String {
        var cleaned = text
        for pattern in hallucinationPatterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: .caseInsensitive)
        }
        // Collapse multiple spaces left behind by removed tokens
        cleaned = cleaned.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Custom Vocabulary

    /// Parse a raw vocabulary string into individual terms. Terms are separated
    /// by newlines or commas; surrounding whitespace and blank entries are dropped.
    static func vocabularyTerms(from vocabulary: String) -> [String] {
        vocabulary
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func shouldRetryWithoutVocabulary(rawText: String, promptTokens: [Int]?) -> Bool {
        promptTokens != nil && rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Some Whisper models return no tokens for otherwise valid sub-second
    /// speech. A small trailing-silence pad gives the retry more context without
    /// changing the reported audio length.
    static func paddedAudioForShortEmptyTranscription(
        _ audio: [Float],
        transcription: String
    ) -> [Float]? {
        let minimumSampleCount = 17_600 // 1.1 seconds at 16 kHz
        guard transcription.isEmpty,
              !audio.isEmpty,
              audio.count < minimumSampleCount else {
            return nil
        }
        var padded = audio
        padded.append(contentsOf: repeatElement(0, count: minimumSampleCount - audio.count))
        return padded
    }

    /// Encode custom vocabulary into WhisperKit conditioning tokens.
    /// Returns nil when there are no terms or the tokenizer isn't ready yet.
    /// Framed as a "Glossary:" prompt, which nudges Whisper to treat the terms
    /// as domain vocabulary without confusing it about the audio. WhisperKit
    /// trims to its own token budget and strips special tokens internally.
    private static func promptTokens(for vocabulary: String, tokenizer: WhisperTokenizer?) -> [Int]? {
        guard let tokenizer else { return nil }
        let terms = vocabularyTerms(from: vocabulary)
        guard !terms.isEmpty else { return nil }
        let tokens = tokenizer.encode(text: "Glossary: " + terms.joined(separator: ", "))
        return tokens.isEmpty ? nil : tokens
    }

    /// Map a model name string to our ModelSize enum
    private func modelSizeFromName(_ name: String) -> ModelSize {
        let lowered = name.lowercased()
        if lowered.contains("v20240930") && lowered.contains("turbo") { return .largeV3LatestTurbo }
        if lowered.contains("v20240930") { return .largeV3Latest }
        if lowered.contains("distil") && lowered.contains("turbo") { return .distilLargeV3TurboCompact }
        if lowered.contains("distil") { return .distilLargeV3Compact }
        if lowered.contains("large") && lowered.contains("turbo") { return .largeV3Turbo }
        if lowered.contains("large") { return .largeV3 }
        if lowered.contains("medium") { return .medium }
        if lowered.contains("small") { return .small }
        if lowered.contains("base") { return .base }
        return .tiny
    }

    /// Get WhisperKit system info for debugging
    func systemInfo() -> String {
        if whisperKit != nil {
            return "WhisperKit loaded | Model: \(loadedModelName ?? "unknown") | Device: \(WhisperKit.deviceName())"
        }
        return "WhisperKit not loaded | Device: \(WhisperKit.deviceName())"
    }
}

// MARK: - SpeechTranscribing Conformance

extension WhisperService: SpeechTranscribing {
    func _loadModel(name: String?, folder: URL?, onPhaseChange: ((String) -> Void)?) async throws {
        try await loadModel(name: name, folder: folder, onPhaseChange: onPhaseChange)
    }
}
