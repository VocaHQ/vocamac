// WhisperService.swift
// VocaMac
//
// Swift wrapper around WhisperKit for local speech-to-text transcription.
// Uses CoreML with Metal/Neural Engine acceleration on Apple Silicon.

import Foundation
import NaturalLanguage
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

    /// Guards the loaded model, which the main thread reads through
    /// `isModelLoaded` while loads and transcriptions run elsewhere.
    private let stateLock = NSLock()
    private var loadedKit: WhisperKit?
    private var loadedName: String?

    /// The WhisperKit instance (initialized when a model is loaded)
    private var whisperKit: WhisperKit? {
        stateLock.withLock { loadedKit }
    }

    /// Whether a model is currently loaded and ready
    var isModelLoaded: Bool { whisperKit != nil }

    /// The name/variant of the currently loaded model
    var loadedModelName: String? {
        stateLock.withLock { loadedName }
    }

    /// Key the retired prewarm ledger wrote to. Prewarm is no longer used —
    /// loading specializes the models on its own — so the stored dictionary is
    /// dead weight in every upgrading install's preferences.
    static let legacyPrewarmLedgerKey = "whisperPrewarmedModels"

    /// Drop the retired prewarm ledger. Safe to call when it was never written.
    static func removeLegacyPrewarmLedger(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: legacyPrewarmLedgerKey) != nil else { return }
        defaults.removeObject(forKey: legacyPrewarmLedgerKey)
        VocaLogger.info(.whisperService, "Removed the retired Whisper prewarm ledger")
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
            #if DEBUG
            config.verbose = true
            #else
            config.verbose = false
            #endif

            // Always load the CoreML models, which is what specializes them
            // for this chip and keeps them resident. WhisperKit otherwise
            // decides with `config.load ?? (config.modelFolder != nil)`, and
            // `config.modelFolder` is only set below for a model already in
            // our own cache. Leaving it to that default meant a model
            // WhisperKit had to fetch itself was downloaded and then never
            // loaded: `init` returned a kit whose encoder, decoder and
            // tokenizer were all nil, which we stored and reported as ready.
            config.load = true

            // Prewarm is deliberately left off. It runs the same load and
            // throws the result away (`model = prewarmMode ? nil : loaded`),
            // so with `load` on it only repeats work; the real load above
            // already pays the specialization cost once.
            config.prewarm = false

            // If a local model folder is specified, use it
            if let folder = modelFolder {
                config.modelFolder = folder.path
                config.download = false
            }

            onPhaseChange?("Loading model…")
            let kit = try await WhisperKit(config)

            onPhaseChange?("Compiling neural engine…")
            stateLock.withLock {
                loadedKit = kit
                loadedName = modelName ?? kit.modelVariant.description
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            VocaLogger.info(.whisperService, "Model loaded in \(String(format: "%.2f", elapsed))s")
        } catch {
            VocaLogger.error(.whisperService, "ERROR loading model: \(error)")
            throw WhisperError.initializationFailed(reason: error.localizedDescription)
        }
    }

    /// Unload the current model and free memory
    func unloadModel() {
        let didUnload = stateLock.withLock {
            guard loadedKit != nil else { return false }
            loadedKit = nil
            loadedName = nil
            return true
        }
        if didUnload {
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

        // A fine-tune trained on one decoder language ignores the setting.
        let language = modelSizeFromName(loadedModelName ?? "tiny").pinnedLanguage ?? language

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
            windowClipTime: Self.windowClipTime(sampleCount: audioData.count),
            promptTokens: promptTokens,
            chunkingStrategy: nil
        )

        do {
            var results = try await Self.transcribeInChunks(kit: kit, audioData: audioData, options: options)

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
                results = try await Self.transcribeInChunks(kit: kit, audioData: audioData, options: options)
                rawText = results.map { $0.text }.joined(separator: " ")
                fullText = Self.filterHallucinationTokens(rawText)
            }

            // Whisper can lock onto a phrase and repeat it to the token limit,
            // most often on short clips with a vocabulary prompt. Try once
            // without the prompt, then cut any loop that remains to one copy.
            if options.promptTokens != nil, TranscriptRepetition.containsLoop(fullText) {
                VocaLogger.warning(
                    .whisperService,
                    "Prompted transcription repeated itself for \(loadedModelName ?? "unknown model"); retrying without custom vocabulary"
                )
                options.promptTokens = nil
                options.usePrefillPrompt = language != nil
                results = try await Self.transcribeInChunks(kit: kit, audioData: audioData, options: options)
                rawText = results.map { $0.text }.joined(separator: " ")
                fullText = Self.filterHallucinationTokens(rawText)
            }
            if TranscriptRepetition.containsLoop(fullText) {
                let collapsed = TranscriptRepetition.collapsingLoops(in: fullText)
                VocaLogger.warning(
                    .whisperService,
                    "Transcription repeated itself; kept one copy (\(fullText.count) → \(collapsed.count) characters)"
                )
                fullText = collapsed
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime

            let modelUsed = modelSizeFromName(loadedModelName ?? "tiny")

            // Get detected language from first result
            let decodedLanguage = results.first?.language ?? language ?? "en"
            let detectedLanguage = Self.reportedLanguage(for: fullText, model: modelUsed, decoded: decodedLanguage)

            VocaLogger.info(.whisperService, "Transcription completed in \(String(format: "%.2f", elapsed))s")
            VocaLogger.info(.whisperService, "Result: \(fullText.count) characters")

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

    // MARK: - Long Audio

    /// One Whisper window (30 s at 16 kHz), the longest chunk.
    static let maxChunkSamples = 480_000

    /// Only long files and meetings are split (2 min at 16 kHz). Dictations
    /// keep WhisperKit's sequential windows, which carry context across them.
    static let chunkingThresholdSamples = 1_920_000

    /// How many chunks decode at once. The encoder shares one accelerator,
    /// so more workers mostly add memory.
    private static let chunkWorkerCount = 4

    /// Transcribe audio, splitting anything longer than one window at
    /// silences and decoding the pieces concurrently.
    ///
    /// Sequential windowed decoding of a 20-minute file runs one window at a
    /// time. WhisperKit's own `.vad` strategy parallelizes but logs and drops
    /// any chunk that fails, which would silently remove text, so the chunks
    /// are decoded here and a failure fails the whole transcription.
    private static func transcribeInChunks(
        kit: WhisperKit,
        audioData: [Float],
        options: DecodingOptions
    ) async throws -> [TranscriptionResult] {
        guard audioData.count > chunkingThresholdSamples else {
            return try await kit.transcribe(audioArray: audioData, decodeOptions: options)
        }

        let chunks = try await VADAudioChunker(vad: EnergyVAD()).chunkAll(
            audioArray: audioData,
            maxChunkLength: maxChunkSamples,
            decodeOptions: options
        )
        VocaLogger.info(.whisperService, "Decoding \(chunks.count) chunks of long audio")

        var ordered = [[TranscriptionResult]](repeating: [], count: chunks.count)
        try await withThrowingTaskGroup(of: (Int, [TranscriptionResult]).self) { group in
            var running = 0
            for (index, chunk) in chunks.enumerated() {
                if running == chunkWorkerCount, let (finished, results) = try await group.next() {
                    ordered[finished] = results
                    running -= 1
                }
                var chunkOptions = options
                chunkOptions.windowClipTime = windowClipTime(sampleCount: chunk.audioSamples.count)
                let samples = chunk.audioSamples
                group.addTask {
                    (index, try await kit.transcribe(audioArray: samples, decodeOptions: chunkOptions))
                }
                running += 1
            }
            while let (finished, results) = try await group.next() {
                ordered[finished] = results
            }
        }
        return ordered.flatMap { $0 }
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
        RecognitionHints.vocabularyTerms(from: vocabulary)
    }

    /// The language to report for a transcript.
    ///
    /// A model that writes a language in Latin letters under a pinned decoder
    /// language (Voca Hinglish: Hindi, decoded as English) reports that
    /// language with a Latin script tag, "hi-Latn", unless the text is
    /// plainly English. Cleanup then treats it as the language it is rather
    /// than as English to correct.
    static func reportedLanguage(for text: String, model: ModelSize, decoded: String) -> String {
        guard let romanized = model.romanizedLanguage else { return decoded }
        return isConfidentlyEnglish(text) ? "en" : "\(romanized)-Latn"
    }

    /// Whether the language recognizer is at least 60% sure `text` is
    /// English. Romanized Hindi never gets there (it reads as Indonesian or
    /// Vietnamese at low confidence), while English sentences, including
    /// ones with a Hindi word or two, score 0.7 and up.
    static func isConfidentlyEnglish(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return (recognizer.languageHypotheses(withMaximum: 3)[.english] ?? 0) >= 0.6
    }

    static func shouldRetryWithoutVocabulary(rawText: String, promptTokens: [Int]?) -> Bool {
        promptTokens != nil && rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// WhisperKit only decodes while seek < end - windowClipTime. Its default
    /// one-second exclusion skips the entire clip at or below 16,000 samples.
    /// Retain the default trailing-window protection for longer recordings.
    static func windowClipTime(sampleCount: Int) -> Float {
        sampleCount <= 16_000 ? 0 : 1
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
    func modelSizeFromName(_ name: String) -> ModelSize {
        let lowered = name.lowercased()
        if lowered.contains("hinglish") { return .vocaHinglish }
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
