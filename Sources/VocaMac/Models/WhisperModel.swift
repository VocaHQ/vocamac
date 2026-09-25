// WhisperModel.swift
// VocaMac
//
// Model metadata types for whisper model variants and their runtime state.

import Foundation

// MARK: - ModelSize

/// Model variants across all supported engines with their properties.
///
/// Raw values are persisted in user preferences, so they must remain stable.
enum ModelSize: String, CaseIterable, Codable, Identifiable {
    // Whisper (WhisperKit)
    case tiny                         = "tiny"
    case base                         = "base"
    case small                        = "small"
    case largeV3LatestTurboCompact    = "large-v3-v20240930_turbo_632MB"
    case distilLargeV3Compact         = "distil-large-v3_594MB"
    case distilLargeV3TurboCompact    = "distil-large-v3_turbo_600MB"
    case largeV3LatestCompact         = "large-v3-v20240930_626MB"
    case largeV3Latest                = "large-v3-v20240930"
    case largeV3LatestTurbo           = "large-v3-v20240930_turbo"
    case largeV3                      = "large-v3"
    case largeV3Turbo                 = "large-v3_turbo"
    case medium                       = "medium"
    case vocaHinglish                 = "voca-hinglish"

    // Parakeet (FluidAudio)
    case parakeetV3                   = "parakeet-tdt-0.6b-v3"
    case parakeetV2                   = "parakeet-tdt-0.6b-v2"
    case parakeetTdtCtc110m           = "parakeet-tdt-ctc-110m"

    // Apple Speech (macOS 26+ system engine)
    case appleSpeech                  = "apple-speech"

    // Specialized ONNX models (sherpa-onnx, CPU-only)
    case moonshineTiny                = "moonshine-v2-tiny-en"
    case moonshineBase                = "moonshine-v2-base-en"
    case senseVoiceSmall              = "sense-voice-small"
    case gigaamV3                     = "gigaam-v3-russian"
    case canary180mFlash              = "canary-180m-flash"
    case qwen3Asr06B                  = "qwen3-asr-0.6b"

    var id: String { rawValue }

    /// Which engine runs this model.
    var engine: TranscriptionEngine {
        switch self {
        case .parakeetV3, .parakeetV2, .parakeetTdtCtc110m:
            return .parakeet
        case .appleSpeech:
            return .appleSpeech
        case .moonshineTiny, .moonshineBase, .senseVoiceSmall, .gigaamV3, .canary180mFlash,
             .qwen3Asr06B:
            return .sherpaOnnx
        default:
            return .whisperKit
        }
    }

    /// Whether this model's engine can run on the current system at all
    /// (independent of per-device model recommendations).
    var isAvailableOnThisSystem: Bool {
        switch engine {
        case .whisperKit:
            return true
        case .parakeet:
            // FluidAudio's Parakeet CoreML models require Apple Silicon.
            #if arch(arm64)
            return true
            #else
            return false
            #endif
        case .appleSpeech:
            if #available(macOS 26.0, *) {
                return AppleSpeechService.isRuntimeSupported
            }
            return false
        case .sherpaOnnx:
            // ONNX Runtime ships universal binaries; runs on any Mac.
            return true
        }
    }

    /// Whether the model's assets are owned by the OS rather than downloaded
    /// and stored by VocaMac.
    var isSystemManaged: Bool {
        self == .appleSpeech
    }

    /// Whether the transcription language is fixed when this model loads, so
    /// changing it only takes effect after a reload.
    ///
    /// Whisper and Parakeet take the language per transcription. Among the
    /// ONNX models only SenseVoice and Canary bind it, so the rest should not
    /// pay for a reload.
    var bindsLanguageAtLoadTime: Bool {
        SherpaModelCatalog.spec(for: self)?.bindsLanguageAtLoadTime ?? false
    }

    /// The WhisperKit model a fine-tune was trained from, whose device
    /// support it shares.
    var whisperKitBaseModel: ModelSize? {
        switch self {
        case .vocaHinglish:       return .largeV3LatestCompact
        default:                  return nil
        }
    }

    /// The decoder language a fine-tuned model was trained on, used in place
    /// of the user's language setting.
    ///
    /// Voca Hinglish writes romanized Hindi only when decoded as English;
    /// asked for Hindi, or left to detect, it falls back to Devanagari or
    /// translates.
    var pinnedLanguage: String? {
        switch self {
        case .vocaHinglish:       return "en"
        default:                  return nil
        }
    }

    /// Whether the user's vocabulary is passed to the decoder as a prompt.
    ///
    /// Voca Hinglish was fine-tuned without prompts. Given the vocabulary as a
    /// "Glossary:" prompt it returned nothing on 77 of 141 dictations, each
    /// then decoded again without it (about 0.8 s more), and on 12 recordings
    /// with names from the vocabulary it spelled none of them better.
    var acceptsVocabularyPrompt: Bool {
        switch self {
        case .vocaHinglish:       return false
        default:                  return true
        }
    }

    /// The language a fine-tune writes in Latin letters under its pinned
    /// decoder language.
    ///
    /// Voca Hinglish decodes as English but writes spoken Hindi romanized.
    /// Reported as English, that text got English cleanup: Hindi words were
    /// "corrected" to English spellings and reworded.
    var romanizedLanguage: String? {
        switch self {
        case .vocaHinglish:       return "hi"
        default:                  return nil
        }
    }

    /// Models shown by default in the app's Mac-focused model picker.
    ///
    /// `medium` remains a legacy value for stored preferences and explicit
    /// support from WhisperKit, but is not part of the normal Apple Silicon
    /// catalog because WhisperKit does not list it for M-series Macs.
    static let standardCatalog: [ModelSize] = [
        .parakeetV3,
        .parakeetV2,
        .parakeetTdtCtc110m,
        .tiny,
        .base,
        .small,
        .largeV3LatestTurboCompact,
        .distilLargeV3Compact,
        .distilLargeV3TurboCompact,
        .largeV3LatestCompact,
        .largeV3Latest,
        .vocaHinglish,
        .appleSpeech,
        .moonshineTiny,
        .moonshineBase,
        .senseVoiceSmall,
        .gigaamV3,
        .canary180mFlash,
        .qwen3Asr06B,
    ]

    /// Whether this model is kept only for compatibility or explicit support.
    var isLegacy: Bool {
        self == .medium
    }

    /// Human-readable display name
    var displayName: String {
        switch self {
        case .tiny:                      return "Tiny (Fastest)"
        case .base:                      return "Base"
        case .small:                     return "Small"
        case .largeV3LatestTurboCompact: return "Large v3 Turbo (Compact)"
        case .distilLargeV3Compact:      return "Distil Large v3 (Compact)"
        case .distilLargeV3TurboCompact: return "Distil Large v3 Turbo"
        case .largeV3LatestCompact:      return "Large v3 Latest (Compact)"
        case .largeV3Latest:             return "Large v3 Latest (Best)"
        case .largeV3LatestTurbo:        return "Large v3 Latest Turbo"
        case .largeV3:                   return "Large v3"
        case .largeV3Turbo:              return "Large v3 Turbo"
        case .medium:                    return "Medium (Legacy)"
        case .vocaHinglish:              return "Voca Hinglish"
        case .parakeetV3:                return "Parakeet v3 (Multilingual)"
        case .parakeetV2:                return "Parakeet v2 (English)"
        case .parakeetTdtCtc110m:        return "Parakeet 110M (English)"
        case .appleSpeech:               return "Apple Speech (System)"
        case .moonshineTiny:             return "Moonshine v2 Tiny (English)"
        case .moonshineBase:             return "Moonshine v2 Base (English)"
        case .senseVoiceSmall:           return "SenseVoice (Chinese +4)"
        case .gigaamV3:                  return "GigaAM v3 (Russian)"
        case .canary180mFlash:           return "Canary 180M (EN/ES/DE/FR)"
        case .qwen3Asr06B:               return "Qwen3 ASR 0.6B (30 Languages)"
        }
    }

    /// Size on disk once installed, in bytes.
    ///
    /// `ramRequiredGB` is computed from this, so it must be the real size,
    /// not a guess. Read it without downloading:
    ///
    /// - WhisperKit: sum the model's folder in its Hugging Face repo:
    ///   `curl -s "https://huggingface.co/api/models/argmaxinc/whisperkit-coreml/tree/main/<folder>?recursive=true"`
    ///   and add up each file's `size`.
    /// - Parakeet: the same call on the FluidInference repo, counting only
    ///   the `.mlmodelc` folders and vocab files FluidAudio downloads.
    /// - sherpa-onnx: the unpacked archive, not the archive itself:
    ///   `curl -sL <archiveURL> | tar -tvjf -` and add up the file sizes.
    var fileSizeBytes: Int64 {
        switch self {
        case .tiny:                      return 76_635_397
        case .base:                      return 146_719_453
        case .small:                     return 486_487_465
        case .largeV3LatestTurboCompact: return 645_668_913
        case .distilLargeV3Compact:      return 594_534_261
        case .distilLargeV3TurboCompact: return 607_114_331
        case .largeV3LatestCompact:      return 626_718_238
        case .largeV3Latest:             return 1_619_531_263
        case .largeV3LatestTurbo:        return 1_638_464_446
        case .largeV3:                   return 3_090_319_899
        case .largeV3Turbo:              return 3_195_115_988
        case .medium:                    return 1_529_654_233
        case .vocaHinglish:              return 824_300_479
        case .parakeetV3:                return 483_257_242
        case .parakeetV2:                return 464_413_250
        case .parakeetTdtCtc110m:        return 227_468_698
        case .appleSpeech:               return 0
        case .moonshineTiny:             return 44_441_158
        case .moonshineBase:             return 141_498_518
        case .senseVoiceSmall:           return 240_506_435
        case .gigaamV3:                  return 225_266_401
        case .canary180mFlash:           return 207_476_042
        case .qwen3Asr06B:               return 1_000_089_677
        }
    }

    /// Human-readable file size string
    var fileSizeDescription: String {
        if isSystemManaged { return "Managed by macOS" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSizeBytes)
    }

    /// Approximate peak RAM in GB while this model loads from CoreML's cache
    /// and transcribes: what it needs on every load after the first.
    ///
    /// Computed from `fileSizeBytes` with the engine's measured line, so a
    /// new model needs only its real size on disk, except where
    /// `ModelRAMFit.handSetGB(for:)` fixes the value.
    var ramRequiredGB: Double {
        if let handSetGB = ModelRAMFit.handSetGB(for: self) { return handSetGB }
        guard let fit = ModelRAMFit.loaded(for: self) else { return 1.0 }
        return fit.estimateGB(fileSizeBytes: fileSizeBytes)
    }

    /// Approximate peak RAM in GB on the first load on a macOS build, while
    /// CoreML compiles the model for the Neural Engine. The same as
    /// `ramRequiredGB` for engines that do not compile.
    var firstLoadRAMRequiredGB: Double {
        if let handSetGB = ModelRAMFit.handSetGB(for: self) { return handSetGB }
        guard let fit = ModelRAMFit.firstLoad(for: self) else { return ramRequiredGB }
        return max(ramRequiredGB, fit.estimateGB(fileSizeBytes: fileSizeBytes))
    }

    /// Status shown while a model loads for the first time on this macOS
    /// build and CoreML compiles it for the Neural Engine.
    static let firstLoadStatus = "First load, can take minutes…"

    /// Why a first load is slow, for help text.
    static let firstLoadExplanation =
        "macOS compiles a model for this Mac's Neural Engine the first time it loads, "
        + "and again after a macOS update. That can take a few minutes; later loads take seconds."

    /// The status for a loading phase. On a first load that compiles for the
    /// Neural Engine, the engine's phase names ("Loading model…") hide a wait
    /// of minutes, so the first-load status replaces them.
    func loadingStatus(forPhase phase: String, isFirstLoad: Bool) -> String {
        isFirstLoad && engine.compilesForNeuralEngine ? Self.firstLoadStatus : phase
    }

    /// Whether the weights are palettized: the Compact builds and Voca
    /// Hinglish. The Neural Engine compiler expands them on the first load,
    /// which then needs far more memory than the file size suggests.
    var hasPalettizedWeights: Bool {
        switch self {
        case .largeV3LatestTurboCompact, .distilLargeV3Compact, .distilLargeV3TurboCompact,
             .largeV3LatestCompact, .vocaHinglish:
            return true
        default:
            return false
        }
    }

    /// Relative speed indicator (1 = fastest)
    var relativeSpeed: Int {
        switch self {
        case .tiny:                      return 1
        case .base:                      return 2
        case .small:                     return 4
        case .largeV3LatestTurboCompact: return 5
        case .distilLargeV3Compact:      return 6
        case .distilLargeV3TurboCompact: return 5
        case .largeV3LatestCompact:      return 8
        case .largeV3Latest:             return 14
        case .largeV3LatestTurbo:        return 9
        case .largeV3:                   return 16
        case .largeV3Turbo:              return 10
        case .medium:                    return 8
        case .vocaHinglish:              return 8
        case .parakeetV3:                return 1
        case .parakeetV2:                return 1
        case .parakeetTdtCtc110m:        return 1
        case .appleSpeech:               return 2
        case .moonshineTiny:             return 2
        case .moonshineBase:             return 3
        case .senseVoiceSmall:           return 3
        case .gigaamV3:                  return 3
        case .canary180mFlash:           return 4
        case .qwen3Asr06B:               return 4
        }
    }

    /// Accuracy quality descriptor
    var qualityDescription: String {
        switch self {
        case .tiny:                      return "Good"
        case .base:                      return "Better"
        case .small:                     return "Great"
        case .largeV3LatestTurboCompact: return "Excellent"
        case .distilLargeV3Compact:      return "Excellent"
        case .distilLargeV3TurboCompact: return "Excellent"
        case .largeV3LatestCompact:      return "Best"
        case .largeV3Latest:             return "Best"
        case .largeV3LatestTurbo:        return "Best"
        case .largeV3:                   return "Best"
        case .largeV3Turbo:              return "Best"
        case .medium:                    return "Legacy"
        case .vocaHinglish:              return "Best for Hindi"
        case .parakeetV3:                return "Excellent"
        case .parakeetV2:                return "Excellent"
        case .parakeetTdtCtc110m:        return "Great"
        case .appleSpeech:               return "Excellent"
        case .moonshineTiny:             return "Good"
        case .moonshineBase:             return "Better"
        case .senseVoiceSmall:           return "Great"
        case .gigaamV3:                  return "Great"
        case .canary180mFlash:           return "Great"
        case .qwen3Asr06B:               return "Excellent"
        }
    }
}

// MARK: - WhisperModelInfo

/// Runtime state for a specific model variant
struct WhisperModelInfo: Identifiable {
    /// Which model size this represents
    let size: ModelSize

    /// Local file/folder path if downloaded
    var filePath: URL?

    /// Whether the model is downloaded and available on disk
    var isDownloaded: Bool

    /// Whether this model is currently loaded and active
    var isActive: Bool

    /// Whether this model is supported on the current device (per WhisperKit recommendation)
    var isSupported: Bool

    /// Download progress (0.0 to 1.0), nil when not downloading
    var downloadProgress: Double?

    /// Whether this model is currently being loaded into memory
    var isLoading: Bool = false

    /// Descriptive loading phase (e.g., "Preparing…", "Compiling…")
    var loadingStatus: String = "Loading…"

    var id: String { size.id }

    /// Human-readable status description
    var statusDescription: String {
        if isActive { return "Active" }
        if isLoading { return loadingStatus }
        if let progress = downloadProgress {
            return "Downloading (\(Int(progress * 100))%)"
        }
        if isDownloaded { return "Downloaded" }
        return "Not Downloaded"
    }

    /// SF Symbol name for the status icon
    var statusIconName: String {
        if isActive { return "checkmark.circle.fill" }
        if isLoading { return "arrow.trianglehead.2.clockwise" }
        if downloadProgress != nil { return "arrow.down.circle" }
        if isDownloaded { return "checkmark.circle" }
        return "arrow.down.to.line"
    }
}
