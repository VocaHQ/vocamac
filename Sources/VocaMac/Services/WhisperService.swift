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
    ///   - includeWordTimestamps: When true, WhisperKit runs DTW word alignment so
    ///     history Timestamps can show per-word ranges. Off by default — that path
    ///     is a latency cost and is not needed for streaming/commit piece decodes
    ///     that only need the transcript text.
    /// - Returns: VocaTranscription with the transcribed text and metadata
    func transcribe(
        audioData: [Float],
        language: String? = nil,
        translate: Bool = false,
        vocabulary: String = "",
        includeWordTimestamps: Bool = false
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

        // Low-latency dictation defaults: no temperature fallback. Word-level
        // timestamps ask WhisperKit for DTW alignment — only when the caller
        // needs them for history Timestamps (batch/final), not on every
        // streaming or commit-piece decode.
        var options = DecodingOptions(
            task: translate ? .translate : .transcribe,
            language: language,
            temperature: 0.0,
            temperatureFallbackCount: 0,  // No fallback for speed
            usePrefillPrompt: language != nil || promptTokens != nil,
            detectLanguage: language == nil,
            wordTimestamps: includeWordTimestamps,
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
            if options.promptTokens != nil,
               TranscriptRepetition.containsLoop(fullText, audioSeconds: audioLengthSeconds) {
                VocaLogger.warning(
                    .whisperService,
                    "Prompted transcription repeated itself for \(loadedModelName ?? "unknown model"); retrying without custom vocabulary"
                )
                var unprompted = options
                unprompted.promptTokens = nil
                unprompted.usePrefillPrompt = language != nil
                // The looped text still holds the phrase, and collapsing it
                // below recovers it; only a real answer replaces it.
                do {
                    let retried = try await Self.transcribeInChunks(kit: kit, audioData: audioData, options: unprompted)
                    let retriedRaw = retried.map { $0.text }.joined(separator: " ")
                    let retriedText = Self.filterHallucinationTokens(retriedRaw)
                    if Self.isUsableRetry(retriedText) {
                        results = retried
                        rawText = retriedRaw
                        fullText = retriedText
                        options = unprompted
                    } else {
                        VocaLogger.warning(.whisperService, "Unprompted retry was empty; keeping the first transcription")
                    }
                } catch {
                    VocaLogger.warning(
                        .whisperService,
                        "Unprompted retry failed (\(error.localizedDescription)); keeping the first transcription"
                    )
                }
            }
            // Greedy decoding at temperature 0 repeats the same loop every
            // time, with or without the prompt. Sampling once at a slightly
            // higher temperature, Whisper's own escape from a loop, usually
            // finishes the sentence instead.
            if TranscriptRepetition.containsLoop(fullText, audioSeconds: audioLengthSeconds) {
                VocaLogger.warning(
                    .whisperService,
                    "Transcription repeated itself for \(loadedModelName ?? "unknown model"); retrying at temperature \(Self.loopRetryTemperature)"
                )
                var warmer = options
                warmer.temperature = Self.loopRetryTemperature
                do {
                    let retried = try await Self.transcribeInChunks(kit: kit, audioData: audioData, options: warmer)
                    let retriedRaw = retried.map { $0.text }.joined(separator: " ")
                    let retriedText = Self.filterHallucinationTokens(retriedRaw)
                    if Self.isLoopFreeRetry(retriedText, audioSeconds: audioLengthSeconds) {
                        results = retried
                        rawText = retriedRaw
                        fullText = retriedText
                    } else {
                        VocaLogger.warning(.whisperService, "Warmer retry still repeated itself or was empty; keeping the first transcription")
                    }
                } catch {
                    VocaLogger.warning(
                        .whisperService,
                        "Warmer retry failed (\(error.localizedDescription)); keeping the first transcription"
                    )
                }
            }
            if TranscriptRepetition.containsLoop(fullText, audioSeconds: audioLengthSeconds) {
                let collapsed = TranscriptRepetition.collapsingLoops(in: fullText, audioSeconds: audioLengthSeconds)
                VocaLogger.warning(
                    .whisperService,
                    "Transcription repeated itself; kept one copy (\(fullText.count) → \(collapsed.count) characters)"
                )
                fullText = collapsed
            }

            let modelUsed = modelSizeFromName(loadedModelName ?? "tiny")

            let scriptChecked = Self.removingUnexpectedScripts(from: fullText, model: modelUsed)
            if scriptChecked != fullText {
                VocaLogger.warning(
                    .whisperService,
                    "Dropped words in scripts \(modelUsed.rawValue) does not write (\(fullText.count) → \(scriptChecked.count) characters)"
                )
                fullText = scriptChecked
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime

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
                modelUsed: modelUsed,
                segments: Self.filteredTimedSegments(
                    from: results.flatMap(\.segments),
                    model: modelUsed,
                    audioSeconds: audioLengthSeconds
                )
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

        let chunker = VADAudioChunker(vad: EnergyVAD())
        let chunks = try await chunker.chunkAll(
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
                chunkOptions.windowClipTime = chunkWindowClipTime(
                    chunkIndex: index,
                    chunkCount: chunks.count,
                    sampleCount: chunk.audioSamples.count
                )
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
        // Every result above is a success (a failure throws): shift each
        // chunk's segment and word times onto the recording's timeline.
        return chunker.updateSeekOffsetsForResults(
            chunkedResults: ordered.map { .success($0) },
            audioChunks: chunks
        )
    }

    /// The segments of `results` as engine-neutral timings for the
    /// transcript: each segment's range and, when WhisperKit aligned them,
    /// its words' ranges. Seconds on the decoded audio's timeline.
    /// Special tokens are stripped from segment text; hallucination / loop /
    /// script filtering happens in `filteredTimedSegments` so Timestamps
    /// matches the cleaned transcript.
    static func timedSegments(from segments: [TranscriptionSegment]) -> [TimedSegment] {
        segments.map { segment in
            let words = (segment.words ?? []).map { word in
                TimedWord(
                    word: word.word, start: Double(word.start), end: Double(word.end),
                    probability: Double(word.probability)
                )
            }
            return TimedSegment(
                start: Double(segment.start), end: Double(segment.end),
                text: Self.removingSpecialTokens(from: segment.text), words: words
            )
        }
    }

    /// `timedSegments` after the same post-processing `transcribe` applies to
    /// `fullText`, so history Timestamps never shows content the main
    /// transcript already hid. Empty-after-filter segments are dropped.
    /// Loop collapse runs per segment and again across the joined result so
    /// repeats that only appear across boundaries match the main transcript.
    static func filteredTimedSegments(
        from segments: [TranscriptionSegment],
        model: ModelSize,
        audioSeconds: Double
    ) -> [TimedSegment] {
        let filtered = timedSegments(from: segments).compactMap { segment in
            filteredTimedSegment(segment, model: model, audioSeconds: audioSeconds)
        }
        return collapsingCrossSegmentLoops(in: filtered, audioSeconds: audioSeconds)
    }

    /// One timing segment with hallucination tokens, loops, and unexpected
    /// scripts removed from its text and words.
    static func filteredTimedSegment(
        _ segment: TimedSegment,
        model: ModelSize,
        audioSeconds: Double
    ) -> TimedSegment? {
        let words = segment.words.compactMap { word -> TimedWord? in
            guard let cleaned = filteredTimingWord(word.word, model: model) else { return nil }
            return TimedWord(
                word: cleaned, start: word.start, end: word.end,
                probability: word.probability
            )
        }
        let text: String
        if words.isEmpty {
            text = filteredTimingText(segment.text, model: model, audioSeconds: audioSeconds)
        } else {
            // Rebuild from kept words so text and the word list stay aligned,
            // then collapse any phrase loop the same way fullText does.
            let joined = words.map(\.word).joined()
            text = filteredTimingText(joined, model: model, audioSeconds: audioSeconds)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // When a phrase loop was collapsed out of the joined words, keep the
        // words that still appear in the collapsed text (first copy plus any
        // trailing words after the loop, not only a leading prefix).
        let keptWords: [TimedWord]
        if words.isEmpty {
            keptWords = []
        } else if words.map(\.word).joined() == text {
            keptWords = words
        } else {
            keptWords = wordsAligning(with: text, from: words)
        }
        return TimedSegment(start: segment.start, end: segment.end, text: text, words: keptWords)
    }

    /// Collapse phrase loops that only show up once segments are joined, the
    /// same way `transcribe` collapses `fullText`. Within-segment loops are
    /// already handled in `filteredTimedSegment`.
    static func collapsingCrossSegmentLoops(
        in segments: [TimedSegment], audioSeconds: Double
    ) -> [TimedSegment] {
        guard segments.count >= 2 else { return segments }
        let joined = segments.map(\.text).joined()
        let collapsed = TranscriptRepetition.collapsingLoops(in: joined, audioSeconds: audioSeconds)
        let joinedTrimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsedTrimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsedTrimmed != joinedTrimmed else { return segments }

        let allWords = segments.flatMap(\.words)
        if allWords.isEmpty {
            return [TimedSegment(
                start: segments.first!.start, end: segments.last!.end,
                text: collapsed, words: []
            )]
        }
        let kept = wordsAligning(with: collapsed, from: allWords)
        let keptJoined = kept.map(\.word).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // If word realignment could not rebuild the collapsed text, keep one
        // segment spanning the whole range rather than partial timings.
        if keptJoined != collapsedTrimmed {
            return [TimedSegment(
                start: segments.first!.start, end: segments.last!.end,
                text: collapsed, words: kept
            )]
        }
        // Re-bucket kept words into the original segments by their times so
        // Timestamps still shows multiple ranges when speech spans them.
        return segments.compactMap { segment -> TimedSegment? in
            let words = kept.filter { word in
                word.end > segment.start && word.start < segment.end
            }
            guard !words.isEmpty else { return nil }
            let text = words.map(\.word).joined()
            let start = min(segment.start, words.map(\.start).min() ?? segment.start)
            let end = max(segment.end, words.map(\.end).max() ?? segment.end)
            return TimedSegment(start: start, end: end, text: text, words: words)
        }
    }

    /// Hallucination filter + loop collapse + unexpected-script strip — the
    /// same pipeline `transcribe` runs on `fullText`.
    static func filteredTimingText(_ text: String, model: ModelSize, audioSeconds: Double) -> String {
        var cleaned = filterHallucinationTokens(text)
        cleaned = TranscriptRepetition.collapsingLoops(in: cleaned, audioSeconds: audioSeconds)
        return removingUnexpectedScripts(from: cleaned, model: model)
    }

    /// A single timing word after hallucination and unexpected-script strip.
    /// Preserves a leading space when Whisper embedded one so joining words
    /// still reads naturally. Returns nil when nothing usable remains.
    static func filteredTimingWord(_ word: String, model: ModelSize) -> String? {
        let hadLeadingSpace = word.first?.isWhitespace == true
        var cleaned = removingSpecialTokens(from: word)
        for pattern in hallucinationPatterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: .caseInsensitive)
        }
        cleaned = removingUnexpectedScripts(from: cleaned, model: model)
        let core = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty else { return nil }
        return hadLeadingSpace ? " " + core : core
    }

    /// Leading words whose concatenation is a prefix of `text` (after the
    /// same whitespace the joined words use). Used when loop collapse
    /// shortened the segment text and there is no trailing remainder.
    static func wordsPrefix(_ words: [TimedWord], matching text: String) -> [TimedWord] {
        var kept: [TimedWord] = []
        var built = ""
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for word in words {
            let next = built + word.word
            let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
            guard target.hasPrefix(trimmed) || trimmed.hasPrefix(target) else { break }
            kept.append(word)
            built = next
            if trimmed == target || trimmed.count >= target.count { break }
        }
        return kept
    }

    /// Words from `words` whose concatenation matches collapsed `text`.
    /// Loop collapse keeps the first copy of a repeated phrase and anything
    /// said after it; a leading-only prefix would drop that trailing tail
    /// (e.g. "go go… go home" -> "go home" must keep timing for "home").
    static func wordsAligning(with text: String, from words: [TimedWord]) -> [TimedWord] {
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return [] }
        if words.map(\.word).joined().trimmingCharacters(in: .whitespacesAndNewlines) == target {
            return words
        }
        var best = wordsPrefix(words, matching: text)
        if best.map(\.word).joined().trimmingCharacters(in: .whitespacesAndNewlines) == target {
            return best
        }
        // Try every split: a leading match for the head of the collapsed
        // text, plus a trailing run of original words for the remainder.
        for suffixCount in 1...words.count {
            let headLimit = words.count - suffixCount
            let suffixWords = Array(words.suffix(suffixCount))
            let suffixJoined = suffixWords.map(\.word).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !suffixJoined.isEmpty, target.hasSuffix(suffixJoined) else { continue }
            let remainder = String(target.dropLast(suffixJoined.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let headWords = headLimit == 0
                ? []
                : wordsPrefix(Array(words.prefix(headLimit)), matching: remainder)
            let headJoined = headWords.map(\.word).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard headJoined == remainder else { continue }
            // Skip overlap: the suffix must start after the last head word.
            if let lastHead = headWords.last,
               let firstSuffix = suffixWords.first,
               firstSuffix.start < lastHead.end {
                continue
            }
            let combined = headWords + suffixWords
            let combinedJoined = combined.map(\.word).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard combinedJoined == target else { continue }
            if combined.count > best.count { best = combined }
        }
        return best
    }

    /// `TranscriptionSegment.text` still carries the decoder's control
    /// tokens — `<|startoftranscript|>`, `<|en|>`, `<|transcribe|>`, and a
    /// `<|0.00|>` time marker every few seconds — where `result.text` is
    /// already cleaned. Drop them so a segment's text is words only.
    static func removingSpecialTokens(from text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
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

    /// Scripts a romanizing fine-tune may write besides Latin: the native
    /// script of the language it romanizes, which it falls back to now and
    /// then.
    private static let nativeScripts: [String: String] = ["hi": "Devanagari"]

    /// `text` without the letters a romanizing model cannot mean.
    ///
    /// Voca Hinglish writes Latin letters, and now and then Devanagari. When
    /// it derails it can write another script entirely: one dictation ended
    /// in "в ктттт…". Letters from any other script are decoder garbage and
    /// are removed; a word keeps whatever it held besides them
    /// ("amazing.в" stays "amazing."), and a word left without letters or
    /// digits is dropped. Other models write every language they know and
    /// are left alone.
    static func removingUnexpectedScripts(from text: String, model: ModelSize) -> String {
        guard let romanized = model.romanizedLanguage else { return text }
        let allowed = (["Latin"] + [nativeScripts[romanized]].compactMap { $0 })
            .map { "\\p{Script=\($0)}" }
            .joined()
        // A run of disallowed letters, with the marks attached to them.
        guard let offScript = try? NSRegularExpression(pattern: "(?:(?=\\p{L})[^\(allowed)]\\p{M}*)+"),
              let words = try? NSRegularExpression(pattern: "\\S+") else { return text }
        guard offScript.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else {
            return text
        }

        var result = ""
        var copiedUpTo = text.startIndex
        for match in words.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let word = String(text[range])
            let wordRange = NSRange(word.startIndex..., in: word)
            guard offScript.firstMatch(in: word, range: wordRange) != nil else { continue }
            let kept = offScript.stringByReplacingMatches(in: word, range: wordRange, withTemplate: "")
            result += text[copiedUpTo..<range.lowerBound]
            if kept.contains(where: { $0.isLetter || $0.isNumber }) {
                result += kept
            }
            copiedUpTo = range.upperBound
        }
        result += text[copiedUpTo...]
        return result
            .replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a retry's text can replace the transcription it retried.
    static func isUsableRetry(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The temperature for the one retry of a transcription that looped.
    /// WhisperKit steps its own fallback by 0.2; one step is enough to leave
    /// a loop without letting the decoder wander.
    static let loopRetryTemperature: Float = 0.2

    /// Whether a retry of a looped transcription can replace it: it has text
    /// and no loop of its own.
    static func isLoopFreeRetry(_ text: String, audioSeconds: Double) -> Bool {
        isUsableRetry(text) && !TranscriptRepetition.containsLoop(text, audioSeconds: audioSeconds)
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

    /// Window clip for a VAD chunk. Intermediate artificial splits must not
    /// discard trailing speech; only the final chunk is the true recording end.
    static func chunkWindowClipTime(chunkIndex: Int, chunkCount: Int, sampleCount: Int) -> Float {
        guard chunkCount > 0, chunkIndex == chunkCount - 1 else { return 0 }
        return windowClipTime(sampleCount: sampleCount)
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
    /// The protocol's word-timestamp-free entry point: live and commit piece
    /// decodes land here, so DTW stays off the latency-sensitive path. The
    /// batch `transcribe` call opts in via `includeWordTimestamps`.
    func transcribe(
        audioData: [Float], language: String?, translate: Bool, vocabulary: String
    ) async throws -> VocaTranscription {
        try await transcribe(
            audioData: audioData, language: language, translate: translate,
            vocabulary: vocabulary, includeWordTimestamps: false
        )
    }

    func _loadModel(name: String?, folder: URL?, onPhaseChange: ((String) -> Void)?) async throws {
        try await loadModel(name: name, folder: folder, onPhaseChange: onPhaseChange)
    }
}
