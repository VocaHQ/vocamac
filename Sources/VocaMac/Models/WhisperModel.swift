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

    var id: String { rawValue }

    /// Which engine runs this model.
    var engine: TranscriptionEngine {
        switch self {
        case .parakeetV3, .parakeetV2, .parakeetTdtCtc110m:
            return .parakeet
        case .appleSpeech:
            return .appleSpeech
        case .moonshineTiny, .moonshineBase, .senseVoiceSmall, .gigaamV3, .canary180mFlash:
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
        .appleSpeech,
        .moonshineTiny,
        .moonshineBase,
        .senseVoiceSmall,
        .gigaamV3,
        .canary180mFlash,
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
        case .parakeetV3:                return "Parakeet v3 (Multilingual)"
        case .parakeetV2:                return "Parakeet v2 (English)"
        case .parakeetTdtCtc110m:        return "Parakeet 110M (English)"
        case .appleSpeech:               return "Apple Speech (System)"
        case .moonshineTiny:             return "Moonshine v2 Tiny (English)"
        case .moonshineBase:             return "Moonshine v2 Base (English)"
        case .senseVoiceSmall:           return "SenseVoice (Chinese +4)"
        case .gigaamV3:                  return "GigaAM v3 (Russian)"
        case .canary180mFlash:           return "Canary 180M (EN/ES/DE/FR)"
        }
    }

    /// Approximate file size on disk in bytes
    var fileSizeBytes: Int64 {
        switch self {
        case .tiny:                      return 39_000_000
        case .base:                      return 142_000_000
        case .small:                     return 466_000_000
        case .largeV3LatestTurboCompact: return 632_000_000
        case .distilLargeV3Compact:      return 594_000_000
        case .distilLargeV3TurboCompact: return 600_000_000
        case .largeV3LatestCompact:      return 626_000_000
        case .largeV3Latest:             return 3_100_000_000
        case .largeV3LatestTurbo:        return 1_000_000_000
        case .largeV3:                   return 3_100_000_000
        case .largeV3Turbo:              return 954_000_000
        case .medium:                    return 1_500_000_000
        case .parakeetV3:                return 700_000_000
        case .parakeetV2:                return 1_200_000_000
        case .parakeetTdtCtc110m:        return 220_000_000
        case .appleSpeech:               return 0
        case .moonshineTiny:             return 60_000_000
        case .moonshineBase:             return 190_000_000
        case .senseVoiceSmall:           return 240_000_000
        case .gigaamV3:                  return 270_000_000
        case .canary180mFlash:           return 320_000_000
        }
    }

    /// Human-readable file size string
    var fileSizeDescription: String {
        if isSystemManaged { return "Managed by macOS" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSizeBytes)
    }

    /// Approximate RAM required for inference in GB
    var ramRequiredGB: Double {
        switch self {
        case .tiny:                      return 1.0
        case .base:                      return 1.5
        case .small:                     return 2.0
        case .largeV3LatestTurboCompact: return 4.0
        case .distilLargeV3Compact:      return 4.0
        case .distilLargeV3TurboCompact: return 4.0
        case .largeV3LatestCompact:      return 5.0
        case .largeV3Latest:             return 10.0
        case .largeV3LatestTurbo:        return 6.0
        case .largeV3:                   return 10.0
        case .largeV3Turbo:              return 6.0
        case .medium:                    return 5.0
        case .parakeetV3:                return 2.0
        case .parakeetV2:                return 2.5
        case .parakeetTdtCtc110m:        return 1.0
        case .appleSpeech:               return 1.0
        case .moonshineTiny:             return 0.5
        case .moonshineBase:             return 1.0
        case .senseVoiceSmall:           return 1.5
        case .gigaamV3:                  return 1.5
        case .canary180mFlash:           return 1.5
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
        case .parakeetV3:                return 1
        case .parakeetV2:                return 1
        case .parakeetTdtCtc110m:        return 1
        case .appleSpeech:               return 2
        case .moonshineTiny:             return 2
        case .moonshineBase:             return 3
        case .senseVoiceSmall:           return 3
        case .gigaamV3:                  return 3
        case .canary180mFlash:           return 4
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
        case .parakeetV3:                return "Excellent"
        case .parakeetV2:                return "Excellent"
        case .parakeetTdtCtc110m:        return "Great"
        case .appleSpeech:               return "Excellent"
        case .moonshineTiny:             return "Good"
        case .moonshineBase:             return "Better"
        case .senseVoiceSmall:           return "Great"
        case .gigaamV3:                  return "Great"
        case .canary180mFlash:           return "Great"
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
