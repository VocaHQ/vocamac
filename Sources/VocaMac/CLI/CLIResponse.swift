// CLIResponse.swift
// VocaMac
//
// Stable JSON types and error categories for local integrations.

import Foundation

/// Stable machine-readable failure categories exposed by the CLI.
enum CLIErrorCategory: String, Codable {
    case invalidArguments = "invalid_arguments"
    case invalidAudio = "invalid_audio"
    case modelNotFound = "model_not_found"
    case modelNotDownloaded = "model_not_downloaded"
    case modelUnsupported = "model_unsupported"
    case transcriptionFailed = "transcription_failed"
}

/// A categorized error with a stable process exit code.
struct CLIError: LocalizedError {
    let category: CLIErrorCategory
    let message: String

    init(_ category: CLIErrorCategory, _ message: String) {
        self.category = category
        self.message = message
    }

    var errorDescription: String? { message }

    var exitCode: Int32 {
        switch category {
        case .invalidArguments: return 2
        case .invalidAudio: return 3
        case .modelNotFound, .modelNotDownloaded, .modelUnsupported: return 4
        case .transcriptionFailed: return 5
        }
    }
}

/// Successful file-transcription output.
struct CLITranscriptionResponse: Codable, Equatable {
    let text: String
    let model: String
    let engine: String
    let detectedLanguage: String
    let durationSeconds: Double
    let audioLengthSeconds: Double

    enum CodingKeys: String, CodingKey {
        case text
        case model
        case engine
        case detectedLanguage = "detected_language"
        case durationSeconds = "duration_seconds"
        case audioLengthSeconds = "audio_length_seconds"
    }
}

/// One catalog entry returned by `--list-models`.
struct CLIModelResponse: Codable, Equatable {
    let id: String
    let name: String
    let engine: String
    let selected: Bool
    let downloaded: Bool
    let supported: Bool
    let systemManaged: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case engine
        case selected
        case downloaded
        case supported
        case systemManaged = "system_managed"
    }
}

/// Model-list envelope, allowing the schema to grow without changing the
/// meaning of each model entry.
struct CLIModelListResponse: Codable, Equatable {
    let models: [CLIModelResponse]
}

/// Error envelope written to stderr.
struct CLIErrorResponse: Codable, Equatable {
    let error: CLIErrorCategory
    let message: String
}

extension TranscriptionEngine {
    /// Stable spelling used by external JSON clients.
    var cliIdentifier: String {
        switch self {
        case .whisperKit: return "whisperkit"
        case .parakeet: return "parakeet"
        case .appleSpeech: return "apple_speech"
        case .sherpaOnnx: return "sherpa_onnx"
        case .customEndpoint: return "custom_endpoint"
        }
    }
}
