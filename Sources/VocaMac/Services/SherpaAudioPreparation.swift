// SherpaAudioPreparation.swift
// VocaMac

/// Conditions individual 16 kHz segments before they reach native ONNX code.
/// Very short waveforms can have too few frames for feature extraction or
/// encoder subsampling. Padding preserves the speech and gives the decoder
/// trailing context without changing the recording's reported duration.
enum SherpaAudioPreparation {
    static let minimumSampleCount = 16_000

    /// Reject malformed input before segmentation or any native inference.
    static func validate(_ samples: [Float]) throws {
        guard !samples.isEmpty else { throw SherpaError.emptyAudio }
        guard samples.allSatisfy({ $0.isFinite }) else {
            throw SherpaError.transcriptionFailed(reason: "Audio contains non-finite samples.")
        }
    }

    static func prepare(_ samples: [Float]) -> [Float] {
        // Do not ask generative decoders to invent words for digital silence.
        guard samples.contains(where: { $0 != 0 }) else { return [] }
        guard samples.count < minimumSampleCount else { return samples }
        return samples + [Float](repeating: 0, count: minimumSampleCount - samples.count)
    }
}
