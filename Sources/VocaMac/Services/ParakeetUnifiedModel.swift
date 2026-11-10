// ParakeetUnifiedModel.swift
// VocaMac
//
// Files for NVIDIA's Unified FastConformer-RNNT checkpoints, which FluidAudio
// runs through `UnifiedAsrManager` (batch) and `StreamingUnifiedAsrManager`
// (streaming) rather than the TDT `AsrManager` the other Parakeet models use:
//
// - Parakeet Unified 0.6B (English). Writes punctuation, capitals, and
//   numbers as digits ("35.3%").
// - Nemotron Unified ASR 0.6B: the same architecture trained on 25 European
//   languages, with a language prompt fed to the encoder.
//
// The batch export is a full-attention 15 s encoder, with longer audio
// decoded in overlapping windows. The streaming export is a separate encoder
// with a chunked attention mask baked in; the decoder, joint and vocabulary
// are shared, so streaming costs one more encoder download.

import Foundation
import FluidAudio

enum ParakeetUnifiedModel {

    /// Which Unified checkpoint a catalog entry runs.
    enum Checkpoint: Equatable, Sendable {
        /// `nvidia/parakeet-unified-en-0.6b`, English only.
        case parakeetEnglish
        /// `nvidia/nemotron-labs-unified-asr-0.6b`, 25 European languages.
        case nemotronMultilingual

        var repo: Repo {
            switch self {
            case .parakeetEnglish: return .parakeetUnified
            case .nemotronMultilingual: return .nemotronUnified
            }
        }

        /// The FluidAudio family, with the language prompt for Nemotron.
        func family(language: String?) -> UnifiedModelFamily {
            switch self {
            case .parakeetEnglish:
                return .parakeetEnglish
            case .nemotronMultilingual:
                return .nemotronMultilingual(ParakeetUnifiedModel.nemotronLanguage(for: language))
            }
        }
    }

    /// int8 is FluidAudio's default: the same LibriSpeech WER as fp16 and the
    /// same Neural Engine speed on M-series Macs, at half the download.
    /// FluidInference's Nemotron card saw French WER rise from 6.9 % to 8.6 %
    /// at int8 on five FLEURS clips, a sample too small to justify doubling
    /// the download and memory for every language.
    static let encoderPrecision: UnifiedEncoderPrecision = .int8

    /// The FluidAudio download variant with the batch (offline) encoder.
    static let downloadVariant = "offline"

    /// FluidAudio's model cache; each repository folder sits inside it.
    static var modelsRoot: URL { MLModelConfigurationUtils.defaultModelsDirectory() }

    /// Where Parakeet Unified's files are, the same place `UnifiedAsrManager`
    /// loads from and downloads to.
    static var directory: URL { directory(for: .parakeetEnglish) }

    static func directory(for checkpoint: Checkpoint) -> URL {
        MLModelConfigurationUtils.defaultModelsDirectory(for: checkpoint.repo)
    }

    /// The files a Parakeet Unified batch load reads.
    static var requiredFiles: [String] { requiredFiles(for: .parakeetEnglish, streaming: false) }

    /// The files a load reads: the batch or the streaming encoder, plus the
    /// decoder, joint and vocabulary both share. The language does not
    /// change the files, only the prompt given to the encoder.
    static func requiredFiles(for checkpoint: Checkpoint, streaming: Bool) -> [String] {
        let family = checkpoint.family(language: nil)
        let encoder = streaming
            ? family.streamingEncoderFile(precision: encoderPrecision, contextSuffix: UnifiedConfig().contextSuffix)
            : family.offlineEncoderFile(precision: encoderPrecision)
        return [encoder, family.decoderFile, family.jointDecisionFile, family.vocab]
    }

    /// Whether every file a load reads is on disk, and no compiled model is
    /// missing its program (an interrupted download).
    static func modelsExist(at directory: URL = directory) -> Bool {
        modelsExist(for: .parakeetEnglish, streaming: false, at: directory)
    }

    static func modelsExist(for checkpoint: Checkpoint, streaming: Bool, at directory: URL? = nil) -> Bool {
        let directory = directory ?? self.directory(for: checkpoint)
        let manager = FileManager.default
        return requiredFiles(for: checkpoint, streaming: streaming).allSatisfy {
            manager.fileExists(atPath: directory.appendingPathComponent($0).path)
        } && CoreMLModelCache.isComplete(directory)
    }

    /// Download a checkpoint's batch files into FluidAudio's cache without
    /// loading them.
    static func download(
        _ checkpoint: Checkpoint = .parakeetEnglish,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await ModelHub.download(checkpoint.repo, to: modelsRoot, variant: downloadVariant) { progress in
            onProgress(progress.fractionCompleted)
        }
    }

    /// A batch manager, not yet loaded.
    static func makeManager(_ checkpoint: Checkpoint = .parakeetEnglish, language: String? = nil) -> UnifiedAsrManager {
        UnifiedAsrManager(
            config: UnifiedConfig(family: checkpoint.family(language: language)),
            encoderPrecision: encoderPrecision
        )
    }

    /// A streaming manager at FluidAudio's default context (2.08 s
    /// latency, the model card's lowest-WER streaming mode), not yet loaded.
    static func makeStreamingManager(
        _ checkpoint: Checkpoint = .parakeetEnglish,
        language: String? = nil
    ) -> StreamingUnifiedAsrManager {
        StreamingUnifiedAsrManager(
            config: UnifiedConfig(family: checkpoint.family(language: language)),
            encoderPrecision: encoderPrecision
        )
    }

    // MARK: - Nemotron language prompt

    /// The prompt for a VocaMac language code: the language itself when
    /// Nemotron was trained on it, otherwise automatic language ID.
    /// NVIDIA recommends naming the language for low-latency streaming.
    static func nemotronLanguage(for code: String?) -> NemotronUnifiedLanguage {
        guard let code, let base = code.split(separator: "-").first.map(String.init)?.lowercased(),
              let language = NemotronUnifiedLanguage(rawValue: base) else { return .auto }
        return language
    }
}
