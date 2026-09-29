// SherpaModelCatalog.swift
// VocaMac
//
// Registry of the specialized ONNX models served by the sherpa-onnx engine:
// where each model's archive lives, what files it contains, and which
// sherpa-onnx recognizer configuration it needs.

import Foundation

/// Describes one downloadable sherpa-onnx model.
struct SherpaModelSpec: Sendable {

    /// Which recognizer configuration the model uses, with file names
    /// relative to the extracted model directory.
    enum Kind: Sendable {
        /// Moonshine v2 (encoder + merged decoder, .ort format)
        case moonshine(encoder: String, mergedDecoder: String)
        /// SenseVoice (single model file)
        case senseVoice(model: String)
        /// NeMo CTC models such as GigaAM (single model file)
        case nemoCtc(model: String)
        /// NVIDIA Canary (encoder + decoder, with a fixed language set)
        case canary(encoder: String, decoder: String, supportedLanguages: Set<String>)
        /// Qwen3-ASR (audio frontend + encoder + autoregressive decoder)
        case qwen3Asr(convFrontend: String, encoder: String, decoder: String, tokenizer: String)
    }

    /// The catalog entry this spec belongs to
    let size: ModelSize

    /// Download URL of the .tar.bz2 archive
    let archiveURL: URL

    /// Name of the top-level directory inside the archive
    let directoryName: String

    /// SHA-256 of the archive, checked before anything is extracted.
    ///
    /// These files are unpacked and fed straight to native ONNX code, so a
    /// replaced release asset would otherwise be trusted on the strength of
    /// its URL alone.
    let sha256: String

    /// Recognizer configuration details
    let kind: Kind

    /// Token table file, relative to the model directory
    let tokensFile = "tokens.txt"

    /// Whether the recognizer is built around a specific language, so a
    /// change to the transcription language only takes effect on reload.
    ///
    /// SenseVoice takes a recognition language and Canary a source language,
    /// both fixed when the recognizer is created. Moonshine is English-only
    /// and GigaAM Russian-only, so neither has anything to rebind.
    var bindsLanguageAtLoadTime: Bool {
        switch kind {
        case .senseVoice, .canary: return true
        case .moonshine, .nemoCtc, .qwen3Asr: return false
        }
    }

    /// Longest audio, in seconds, that a single decode should be given.
    ///
    /// These are offline models that consume an utterance in one pass, and
    /// they degrade past a certain length rather than chunking internally the
    /// way Whisper and Parakeet do. Measured on Apple Silicon: Moonshine
    /// returns nothing at all beyond ~8s, and SenseVoice starts dropping
    /// characters, while the NeMo models hold up much longer. sherpa-onnx's
    /// own examples segment audio before decoding for the same reason.
    var maxSegmentSeconds: Double {
        switch kind {
        case .moonshine:  return 8
        case .senseVoice: return 8
        case .nemoCtc:    return 20
        case .canary, .qwen3Asr: return 20
        }
    }

    /// All files that must exist for the model to count as downloaded,
    /// relative to the model directory.
    var requiredFiles: [String] {
        switch kind {
        case .moonshine(let encoder, let mergedDecoder):
            return [tokensFile, encoder, mergedDecoder]
        case .senseVoice(let model), .nemoCtc(let model):
            return [tokensFile, model]
        case .canary(let encoder, let decoder, _):
            return [tokensFile, encoder, decoder]
        case .qwen3Asr(let convFrontend, let encoder, let decoder, let tokenizer):
            return [
                convFrontend,
                encoder,
                decoder,
                tokenizer + "/tokenizer_config.json",
                tokenizer + "/merges.txt",
                tokenizer + "/vocab.json",
            ]
        }
    }
}

/// All sherpa-onnx models VocaMac offers.
enum SherpaModelCatalog {

    private static let releaseBase =
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"

    private static func spec(
        _ size: ModelSize,
        directory: String,
        sha256: String,
        kind: SherpaModelSpec.Kind
    ) -> SherpaModelSpec {
        SherpaModelSpec(
            size: size,
            archiveURL: URL(string: releaseBase + directory + ".tar.bz2")!,
            directoryName: directory,
            sha256: sha256,
            kind: kind
        )
    }

    static let specs: [SherpaModelSpec] = [
        spec(
            .moonshineTiny,
            directory: "sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27",
            sha256: "9ec31b342d8fa3240c3b81b8f82e1cf7e3ac467c93ca5a999b741d5887164f8d",
            kind: .moonshine(
                encoder: "encoder_model.ort",
                mergedDecoder: "decoder_model_merged.ort"
            )
        ),
        spec(
            .moonshineBase,
            directory: "sherpa-onnx-moonshine-base-en-quantized-2026-02-27",
            sha256: "43232c1d13013d37317163baec3135bd771a186a4356f28c889bab453bb0e891",
            kind: .moonshine(
                encoder: "encoder_model.ort",
                mergedDecoder: "decoder_model_merged.ort"
            )
        ),
        // Pinned to the 2024-07-17 build. The newer 2025-09-09 export decodes
        // to mangled text against the sherpa-onnx runtime pinned in
        // Package.swift ("ODAY WNT TO REVIEW" for "today I want to review"),
        // dropping characters at every length. Revisit when the runtime pin
        // moves; verify transcription before switching builds.
        spec(
            .senseVoiceSmall,
            directory: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17",
            sha256: "7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e",
            kind: .senseVoice(model: "model.int8.onnx")
        ),
        spec(
            .gigaamV3,
            directory: "sherpa-onnx-nemo-ctc-punct-giga-am-v3-russian-2025-12-16",
            sha256: "20e41e160efa6f2460a7ef6554cdbbb9e8fffb2b92e6bc708e9406bd8b9256ea",
            kind: .nemoCtc(model: "model.int8.onnx")
        ),
        spec(
            .canary180mFlash,
            directory: "sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8",
            sha256: "7a38ed8b13f014ad632b09ff8d22e0c6f1359dd046af9235d281dfae841b9ab9",
            kind: .canary(
                encoder: "encoder.int8.onnx",
                decoder: "decoder.int8.onnx",
                supportedLanguages: ["en", "es", "de", "fr"]
            )
        ),
        spec(
            .qwen3Asr06B,
            directory: "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25",
            sha256: "393f8a14e2f5fb96746aaab342997a40641001fbd5bf9592a080a8329178ee96",
            kind: .qwen3Asr(
                convFrontend: "conv_frontend.onnx",
                encoder: "encoder.int8.onnx",
                decoder: "decoder.int8.onnx",
                tokenizer: "tokenizer"
            )
        ),
    ]

    /// Look up the spec for a catalog entry, if it is a sherpa-onnx model.
    static func spec(for size: ModelSize) -> SherpaModelSpec? {
        specs.first { $0.size == size }
    }
}
