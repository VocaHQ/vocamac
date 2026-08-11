// TranscriptionEngine.swift
// VocaMac
//
// Identifies which speech-to-text engine runs a given model. Each engine has
// its own model format, storage layout, and runtime service.

import Foundation

/// Preference keys shared between `AppState`'s `@AppStorage` properties and
/// services that must read the same setting outside the view layer.
enum PreferenceKey {
    static let selectedLanguage = "vocamac.selectedLanguage"
    static let appendTrailingSpace = "vocamac.appendTrailingSpace"
    static let autoCapitalize = "vocamac.autoCapitalize"
    static let autoPauseEnabled = "vocamac.autoPause.enabled"
    static let autoPauseApps = "vocamac.autoPause.apps"
    static let autoPausePollInterval = "vocamac.autoPause.pollIntervalSeconds"
    static let modelKeepAliveEnabled = "vocamac.modelKeepAlive.enabled"
    static let modelKeepAliveIdleTimeout = "vocamac.modelKeepAlive.idleTimeoutSeconds"
}

/// The on-device inference engine backing a model in the catalog.
enum TranscriptionEngine: String, CaseIterable, Codable, Identifiable {
    /// NVIDIA Parakeet TDT via FluidAudio — CoreML on the Neural Engine.
    case parakeet

    /// OpenAI Whisper via WhisperKit — CoreML with Metal/ANE acceleration.
    case whisperKit

    /// Apple's SpeechAnalyzer/SpeechTranscriber — built into macOS 26+,
    /// assets are downloaded and managed by the system.
    case appleSpeech

    /// Community ONNX models via sherpa-onnx — CPU-only specialists
    /// (tiny English models, Chinese, Russian, European languages).
    case sherpaOnnx

    var id: String { rawValue }

    /// Section title shown in the model picker.
    var displayName: String {
        switch self {
        case .parakeet:    return "Parakeet"
        case .whisperKit:  return "Whisper"
        case .appleSpeech: return "Apple Speech"
        case .sherpaOnnx:  return "Specialized (ONNX)"
        }
    }

    /// One-line description shown under the section title.
    var summary: String {
        switch self {
        case .parakeet:
            return "NVIDIA's dictation models on the Neural Engine — fastest transcription with excellent accuracy."
        case .whisperKit:
            return "OpenAI's Whisper models — widest language coverage (100+ languages) and translation to English."
        case .appleSpeech:
            return "Managed by macOS — no model files in VocaMac's folder, though the system may download language assets the first time you use one."
        case .sherpaOnnx:
            return "Community models for specific needs — tiny English models for low-RAM Macs, plus Chinese, Russian, and European language specialists. Runs on CPU."
        }
    }

    /// Whether the engine can translate speech to English.
    var supportsTranslation: Bool {
        self == .whisperKit
    }

    /// Whether the engine biases transcription toward user-provided vocabulary.
    var supportsCustomVocabulary: Bool {
        self == .whisperKit
    }

}
