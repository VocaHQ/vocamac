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

    /// Total silence `prepare` adds to a segment, in seconds.
    ///
    /// Callers that cap segment length must subtract this: the models' limits
    /// apply to what actually reaches the decoder, not to the speech alone.
    static let addedSilenceSeconds = Double(2 * edgeSilenceSampleCount) / 16_000

    /// Reject malformed input before segmentation or any native inference.
    static func validate(_ samples: [Float]) throws {
        guard !samples.isEmpty else { throw SherpaError.emptyAudio }
        guard samples.allSatisfy({ $0.isFinite }) else {
            throw SherpaError.transcriptionFailed(reason: "Audio contains non-finite samples.")
        }
    }

    /// Alternative ways to distribute the same silence, used to retry a decode
    /// that came back empty.
    ///
    /// The decoders are chaotically sensitive to exact framing. Measured on a
    /// real 4s recording that decoded to nothing: scaling every sample by
    /// 1.001 recovered the whole sentence and 0.999 did not, and shifting the
    /// speech by 100ms flipped the result either way. No perturbation is right
    /// in general — but a decode that returned nothing has nothing to lose,
    /// and reframing recovers it.
    ///
    /// Every layout adds exactly as much silence as the first attempt, so a
    /// retry can never push a segment past the one-pass limit the segmenter
    /// exists to respect.
    static let recoveryLayouts: [(lead: Int, tail: Int)] = [
        (lead: 2 * edgeSilenceSampleCount, tail: 0),
        (lead: 0, tail: 2 * edgeSilenceSampleCount),
        (lead: edgeSilenceSampleCount / 2, tail: 3 * edgeSilenceSampleCount / 2),
    ]

    static func prepare(
        _ samples: [Float],
        lead: Int = edgeSilenceSampleCount,
        tail: Int = edgeSilenceSampleCount
    ) -> [Float] {
        // Do not ask generative decoders to invent words for digital silence.
        guard samples.contains(where: { $0 != 0 }) else { return [] }

        let paddedCount = samples.count + lead + tail
        var prepared: [Float] = []
        prepared.reserveCapacity(max(minimumSampleCount, paddedCount))
        prepared.append(contentsOf: repeatElement(Float.zero, count: lead))
        prepared.append(contentsOf: samples)
        prepared.append(contentsOf: repeatElement(Float.zero, count: tail))

        if prepared.count < minimumSampleCount {
            prepared.append(
                contentsOf: repeatElement(Float.zero, count: minimumSampleCount - prepared.count)
            )
        }
        return prepared
    }
}
