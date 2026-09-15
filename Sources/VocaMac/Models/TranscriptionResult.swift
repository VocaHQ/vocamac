// TranscriptionResult.swift
// VocaMac
//
// Represents the output of a VocaMac transcription.
// Named VocaTranscription to avoid collision with WhisperKit's TranscriptionResult.

import Foundation

struct VocaTranscription: Identifiable {
    /// Unique identifier for this transcription
    let id: UUID

    /// The transcribed text
    let text: String

    /// Time taken to perform the transcription (seconds)
    let duration: TimeInterval

    /// Detected or specified language (ISO 639-1 code)
    let detectedLanguage: String

    /// When the transcription was performed
    let timestamp: Date

    /// Length of the source audio in seconds
    let audioLengthSeconds: Double

    /// Which model was used for this transcription
    let modelUsed: ModelSize

    init(
        text: String,
        duration: TimeInterval,
        detectedLanguage: String,
        audioLengthSeconds: Double,
        modelUsed: ModelSize,
        timestamp: Date = Date()
    ) {
        self.id = UUID()
        self.text = text
        self.duration = duration
        self.detectedLanguage = detectedLanguage
        self.timestamp = timestamp
        self.audioLengthSeconds = audioLengthSeconds
        self.modelUsed = modelUsed
    }

    func replacingText(with text: String) -> VocaTranscription {
        VocaTranscription(
            text: text,
            duration: duration,
            detectedLanguage: detectedLanguage,
            audioLengthSeconds: audioLengthSeconds,
            modelUsed: modelUsed,
            timestamp: timestamp
        )
    }
}

struct CorrectionRule: Equatable {
    let source: String
    let replacement: String

    static func parseList(_ value: String) -> [CorrectionRule] {
        value.components(separatedBy: .newlines).compactMap { line in
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { return nil }
            let source = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty, !replacement.isEmpty else { return nil }
            return CorrectionRule(source: source, replacement: replacement)
        }
    }
}

enum TranscriptionPostProcessor {
    static func process(_ text: String, rules: [CorrectionRule]) -> String {
        rules.reduce(text) { result, rule in
            result.replacingOccurrences(
                of: "(?<![\\p{L}\\p{N}_])\(NSRegularExpression.escapedPattern(for: rule.source))(?![\\p{L}\\p{N}_])",
                with: NSRegularExpression.escapedTemplate(for: rule.replacement),
                options: [.regularExpression, .caseInsensitive]
            )
        }
    }
}
