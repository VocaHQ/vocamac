// SherpaAudioPreparation.swift
// VocaMac

/// Conditions individual 16 kHz segments before they reach native ONNX code.
/// Very short waveforms can have too few frames for feature extraction or
/// encoder subsampling. Padding preserves the speech and gives the decoder
/// trailing context without changing the recording's reported duration.
enum SherpaAudioPreparation {
    static let minimumSampleCount = 16_000

    /// Silence added on both sides of every segment — 200ms at 16kHz.
    ///
    /// A push-to-talk recording starts on the first frame the tap delivers, so
    /// speech often begins in sample zero. The NeMo-derived models decode that
    /// as an utterance already in progress and their attention decoder emits
    /// end-of-transcript as its very first token, which comes back as an empty
    /// result for perfectly good audio — the recording is simply dropped.
    /// Measured against Canary 180M, a lead-in as short as 50ms is enough to
    /// recover every clip that failed this way; 200ms leaves margin, and the
    /// matching tail keeps a final word from being cut off mid-decode.
    static let edgeSilenceSampleCount = 3_200

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

        let edge = repeatElement(Float.zero, count: edgeSilenceSampleCount)
        let paddedCount = samples.count + 2 * edgeSilenceSampleCount
        var prepared: [Float] = []
        prepared.reserveCapacity(max(minimumSampleCount, paddedCount))
        prepared.append(contentsOf: edge)
        prepared.append(contentsOf: samples)
        prepared.append(contentsOf: edge)

        if prepared.count < minimumSampleCount {
            prepared.append(
                contentsOf: repeatElement(Float.zero, count: minimumSampleCount - prepared.count)
            )
        }
        return prepared
    }
}
