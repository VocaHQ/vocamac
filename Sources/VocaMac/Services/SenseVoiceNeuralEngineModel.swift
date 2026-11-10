// SenseVoiceNeuralEngineModel.swift
// VocaMac
//
// SenseVoiceSmall as CoreML on the Neural Engine, through FluidAudio
// (FluidInference/sensevoice-small-coreml). The same model as the
// sherpa-onnx SenseVoice entry, which runs on the CPU and decodes at most
// 8 s at a time; this build takes up to about 108 s in one pass, so most
// dictations decode without a seam.

import Foundation
import FluidAudio

enum SenseVoiceNeuralEngineModel {

    /// int8 encoder: FluidInference measured LibriSpeech test-clean WER
    /// 3.22 → 3.25 % and AISHELL-1 CER 3.09 → 3.09 % against fp16, at half
    /// the download and peak memory 0.54 → 0.32 GB.
    static let precision: SenseVoiceEncoderPrecision = .int8

    /// `textnorm` embed index 14 ("withitn"): punctuation and written
    /// numbers, as the sherpa-onnx entry asks for with `use_itn`.
    static let textNormWithITN: Int32 = 14

    /// Where FluidAudio keeps the model.
    static var directory: URL { MLModelConfigurationUtils.defaultModelsDirectory(for: .senseVoiceSmall) }

    static func modelsExist() -> Bool {
        SenseVoiceModels.modelsExist(at: directory, precision: precision)
    }

    static func download(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await SenseVoiceModels.download(precision: precision) { progress in
            onProgress(progress.fractionCompleted)
        }
    }

    /// Download what is missing, load, and bind the language.
    static func load(language: String?) async throws -> SenseVoiceManager {
        let models = try await SenseVoiceModels.downloadAndLoad(precision: precision)
        return SenseVoiceManager(models: models, language: languageID(for: language), textNorm: textNormWithITN)
    }

    /// The encoder's language embed index for a VocaMac language code, from
    /// the model card's `lid_int_dict`; 0 is automatic language ID.
    static func languageID(for code: String?) -> Int32 {
        switch code?.split(separator: "-").first.map({ $0.lowercased() }) {
        case "zh": return 3
        case "en": return 4
        case "yue": return 7
        case "ja": return 11
        case "ko": return 12
        default: return 0
        }
    }

    // MARK: - Long recordings

    /// The most audio one pass takes: the encoder's largest bucket is 1,800
    /// feature frames (60 ms each, about 108 s). Windows stay under it.
    static let maxWindowSamples = 100 * 16_000

    /// How far back from a window's limit to look for a quiet place to cut.
    static let cutSearchSamples = 10 * 16_000

    /// Ranges covering `samples` in windows no longer than `maxSamples`,
    /// each cut at the quietest 100 ms in the last `searchSamples` before
    /// the limit, so a word is rarely split. One range when it fits.
    static func windows(
        for samples: [Float],
        maxSamples: Int = maxWindowSamples,
        searchSamples: Int = cutSearchSamples
    ) -> [Range<Int>] {
        guard samples.count > maxSamples, maxSamples > 0 else {
            return samples.isEmpty ? [] : [0..<samples.count]
        }
        let frame = 1_600
        var ranges: [Range<Int>] = []
        var start = 0
        while samples.count - start > maxSamples {
            let limit = start + maxSamples
            let searchStart = max(start + frame, limit - max(frame, searchSamples))
            var cut = limit
            var quietest = Float.greatestFiniteMagnitude
            var position = searchStart
            while position + frame <= limit {
                var energy: Float = 0
                for index in position..<(position + frame) { energy += samples[index] * samples[index] }
                if energy < quietest {
                    quietest = energy
                    cut = position + frame / 2
                }
                position += frame
            }
            ranges.append(start..<cut)
            start = cut
        }
        ranges.append(start..<samples.count)
        return ranges
    }
}
