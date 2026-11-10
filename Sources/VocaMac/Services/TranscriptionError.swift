// TranscriptionError.swift
// VocaMac
//
// The one error type the on-device engines throw. The custom endpoint keeps
// `CustomEndpointError` for its HTTP failures and uses this type only for
// the two failures every engine shares.

import Foundation

/// A failure from a speech engine.
///
/// Shared failures carry the engine so their wording stays what each engine
/// said before the per-engine enums were merged. `TranscriptionRouter`
/// reads the case, not the message, to decide whether the model is at fault.
enum TranscriptionError: LocalizedError {
    /// `transcribe` was called before the engine's model was ready.
    case modelNotLoaded(TranscriptionEngine)
    /// The engine could not load or start its model.
    case initializationFailed(TranscriptionEngine, reason: String)
    /// Decoding failed. `underlying` is the error the engine threw, kept so
    /// the router can tell a model fault from a cancellation without
    /// comparing messages.
    case transcriptionFailed(reason: String, underlying: (any Error)? = nil)
    /// Nothing was recorded to decode.
    case emptyAudio(TranscriptionEngine)

    // MARK: ONNX (sherpa-onnx)

    /// The ONNX catalog has no model by this name.
    case unknownModel(String)
    /// The model's files are not on disk at this path.
    case modelFilesMissing(String)

    // MARK: Apple Speech

    /// Apple Speech needs macOS 26.
    case unsupportedSystem
    /// Apple Speech has no model for this locale on this Mac.
    case localeNotSupported(String)
    /// Apple Speech and the recording could not agree on an audio format.
    case audioFormatUnavailable

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded(let engine):
            return Self.modelNotLoadedMessage(engine)
        case .initializationFailed(let engine, let reason):
            return "\(Self.initializationPrefix(engine)): \(reason)"
        case .transcriptionFailed(let reason, _):
            return "Transcription failed: \(reason)"
        case .emptyAudio(let engine):
            return engine == .customEndpoint ? "Nothing was recorded." : "No audio data to transcribe."
        case .unknownModel(let name):
            return "Unknown ONNX model: \(name)"
        case .modelFilesMissing(let path):
            return "Model files are missing at: \(path)"
        case .unsupportedSystem:
            return "Apple Speech requires macOS 26 or later."
        case .localeNotSupported(let locale):
            return "Apple Speech does not support the language '\(locale)' on this Mac."
        case .audioFormatUnavailable:
            return "Apple Speech could not negotiate an audio format."
        }
    }

    /// Whether this failure says the loaded model itself is broken, so that
    /// repeated ones should reload it. Missing models, empty input and
    /// setup problems do not; a decode failure does unless the engine's own
    /// error was a cancellation or a network fault.
    var indicatesModelFault: Bool {
        switch self {
        case .transcriptionFailed(_, let underlying?):
            return TranscriptionRouter.isModelFailure(underlying)
        case .transcriptionFailed:
            return true
        case .modelNotLoaded, .emptyAudio:
            return false
        case .initializationFailed, .unknownModel, .modelFilesMissing,
             .unsupportedSystem, .localeNotSupported, .audioFormatUnavailable:
            return true
        }
    }

    private static func modelNotLoadedMessage(_ engine: TranscriptionEngine) -> String {
        switch engine {
        case .whisperKit: return "No whisper model is loaded. Please load a model first."
        case .parakeet: return "No Parakeet model is loaded. Please load a model first."
        case .sherpaOnnx: return "No ONNX model is loaded. Please load a model first."
        case .appleSpeech: return "Apple Speech is not prepared. Please load the model first."
        case .customEndpoint: return "The custom endpoint is not loaded."
        }
    }

    private static func initializationPrefix(_ engine: TranscriptionEngine) -> String {
        switch engine {
        case .whisperKit: return "Failed to initialize WhisperKit"
        case .parakeet: return "Failed to initialize Parakeet"
        case .sherpaOnnx: return "Failed to initialize the ONNX model"
        case .appleSpeech: return "Failed to initialize Apple Speech"
        case .customEndpoint: return "Failed to initialize the custom endpoint"
        }
    }
}
