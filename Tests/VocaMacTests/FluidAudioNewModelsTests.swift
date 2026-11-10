// FluidAudioNewModelsTests.swift
// VocaMac
//
// Catalog, file, language and routing checks for the models FluidAudio
// 0.18 added (Nemotron Unified, SenseVoice on the Neural Engine) and for
// the Unified streaming export. None of these download or load a model.

import AVFoundation
import XCTest
import FluidAudio
@testable import VocaMac

final class FluidAudioNewModelsTests: XCTestCase {

    // MARK: - Nemotron Unified

    func testNemotronCatalogEntry() {
        let nemotron = ModelSize.nemotronUnified
        XCTAssertEqual(nemotron.rawValue, "nemotron-unified-asr-0.6b")
        XCTAssertEqual(nemotron.engine, .parakeet)
        XCTAssertEqual(nemotron.creator, .nvidia)
        XCTAssertEqual(nemotron.languageCoverage, .only(ModelSize.parakeetV3Languages))
        XCTAssertTrue(nemotron.bindsLanguageAtLoadTime, "the language prompt is an encoder input")
        XCTAssertTrue(nemotron.transcribesWhileSpeaking)
        XCTAssertTrue(ModelSize.standardCatalog.contains(nemotron))
        XCTAssertFalse(nemotron.pickerSummary.isEmpty)
        // Batch export at int8: encoder, decoder, joint, vocab, metadata.
        XCTAssertEqual(nemotron.fileSizeBytes, 626_478_903)
    }

    func testNemotronIsNotTheDefaultOrAnOnboardingPick() {
        XCTAssertNotEqual(OnboardingModelGuidance.recommendation(
            for: "de",
            availableModels: ModelSize.standardCatalog.map {
                WhisperModelInfo(size: $0, isDownloaded: false, isActive: false, isSupported: true)
            }
        )?.model, .nemotronUnified)
    }

    func testNemotronRoutesToTheUnifiedPipeline() {
        XCTAssertEqual(ParakeetService.family(for: .nemotronUnified), .nemotronUnified)
        XCTAssertEqual(ParakeetService.family(for: .nemotronUnified)?.unifiedCheckpoint, .nemotronMultilingual)
        XCTAssertEqual(ParakeetService.family(for: .parakeetUnified)?.unifiedCheckpoint, .parakeetEnglish)
        XCTAssertNil(ParakeetService.family(for: .parakeetV3)?.unifiedCheckpoint)
        XCTAssertFalse(ParakeetService.writesNumbers(.nemotronUnified))
        XCTAssertEqual(
            ParakeetService.modelDirectory(for: .nemotronUnified)?.path,
            MLModelConfigurationUtils.defaultModelsDirectory(for: .nemotronUnified).path
        )
        XCTAssertTrue(ParakeetService.modelDirectories.contains(ParakeetUnifiedModel.directory(for: .nemotronMultilingual)))
    }

    func testNemotronFilesForBatchAndStreaming() {
        XCTAssertEqual(ParakeetUnifiedModel.requiredFiles(for: .nemotronMultilingual, streaming: false), [
            "nemotron_unified_encoder_int8.mlmodelc",
            "nemotron_unified_decoder.mlmodelc",
            "nemotron_unified_joint_decision_single_step.mlmodelc",
            "vocab.json",
        ])
        XCTAssertEqual(
            ParakeetUnifiedModel.requiredFiles(for: .nemotronMultilingual, streaming: true).first,
            "nemotron_unified_encoder_streaming_70_13_13_int8.mlmodelc"
        )
        XCTAssertEqual(
            ParakeetUnifiedModel.requiredFiles(for: .parakeetEnglish, streaming: true).first,
            "parakeet_unified_encoder_streaming_70_13_13_int8.mlmodelc"
        )
        XCTAssertEqual(
            ParakeetUnifiedModel.requiredFiles(for: .parakeetEnglish, streaming: false),
            ParakeetUnifiedModel.requiredFiles, "the English batch files are unchanged"
        )
    }

    func testNemotronLanguagePrompt() {
        XCTAssertEqual(ParakeetUnifiedModel.nemotronLanguage(for: "de"), .de)
        XCTAssertEqual(ParakeetUnifiedModel.nemotronLanguage(for: "pt-BR"), .pt)
        XCTAssertEqual(ParakeetUnifiedModel.nemotronLanguage(for: "ja"), .auto, "not a Nemotron language")
        XCTAssertEqual(ParakeetUnifiedModel.nemotronLanguage(for: nil), .auto)
        XCTAssertEqual(
            ParakeetUnifiedModel.Checkpoint.nemotronMultilingual.family(language: "fr"),
            .nemotronMultilingual(.fr)
        )
        XCTAssertEqual(ParakeetUnifiedModel.Checkpoint.parakeetEnglish.family(language: "fr"), .parakeetEnglish)
        XCTAssertEqual(ParakeetService.nemotronLanguageCodes, ModelSize.parakeetV3Languages)
    }

    func testLoadLanguageFallsBackToTheOnlySpokenLanguage() {
        XCTAssertEqual(TranscriptionRouter.loadLanguage(selected: "es", spoken: ["de"]), "es")
        XCTAssertEqual(TranscriptionRouter.loadLanguage(selected: nil, spoken: ["de"]), "de")
        XCTAssertNil(TranscriptionRouter.loadLanguage(selected: nil, spoken: ["de", "en"]))
        XCTAssertNil(TranscriptionRouter.loadLanguage(selected: nil, spoken: []))
    }

    // MARK: - Streaming export

    func testOnlyUnifiedCheckpointsStream() {
        let streaming = ModelSize.allCases.filter(ParakeetService.supportsStreaming)
        XCTAssertEqual(Set(streaming), [.parakeetUnified, .nemotronUnified])
        XCTAssertEqual(Set(ModelSize.allCases.filter(\.transcribesWhileSpeaking)), Set(streaming))
    }

    func testPCMBufferCarriesTheSamples() throws {
        let samples: [Float] = [0, 0.25, -0.5, 1]
        let buffer = try ParakeetService.pcmBuffer(samples[...])
        XCTAssertEqual(buffer.format.sampleRate, 16_000)
        XCTAssertEqual(buffer.format.channelCount, 1)
        XCTAssertEqual(Int(buffer.frameLength), samples.count)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: channel, count: samples.count)), samples)
    }

    func testStreamingStepIsOneSecond() {
        XCTAssertEqual(ParakeetService.streamingStepSamples, 16_000)
    }

    // MARK: - SenseVoice on the Neural Engine

    func testSenseVoiceCatalogEntry() {
        let senseVoice = ModelSize.senseVoiceNeuralEngine
        XCTAssertEqual(senseVoice.engine, .parakeet, "FluidAudio runs it")
        XCTAssertEqual(senseVoice.languageCoverage, ModelSize.senseVoiceSmall.languageCoverage)
        XCTAssertEqual(senseVoice.creator, .alibaba)
        XCTAssertTrue(senseVoice.bindsLanguageAtLoadTime)
        XCTAssertFalse(senseVoice.transcribesWhileSpeaking)
        XCTAssertEqual(senseVoice.fileSizeBytes, 239_913_642)
        XCTAssertTrue(ModelSize.standardCatalog.contains(.senseVoiceSmall), "the ONNX build stays")
        XCTAssertEqual(ParakeetService.family(for: senseVoice), .senseVoice)
        XCTAssertEqual(ParakeetService.modelDirectory(for: senseVoice), SenseVoiceNeuralEngineModel.directory)
        XCTAssertEqual(SenseVoiceNeuralEngineModel.precision, .int8)
    }

    func testSenseVoiceLanguageEmbedIndices() {
        XCTAssertEqual(SenseVoiceNeuralEngineModel.languageID(for: "zh"), 3)
        XCTAssertEqual(SenseVoiceNeuralEngineModel.languageID(for: "zh-Hans"), 3)
        XCTAssertEqual(SenseVoiceNeuralEngineModel.languageID(for: "en"), 4)
        XCTAssertEqual(SenseVoiceNeuralEngineModel.languageID(for: "yue"), 7)
        XCTAssertEqual(SenseVoiceNeuralEngineModel.languageID(for: "ja"), 11)
        XCTAssertEqual(SenseVoiceNeuralEngineModel.languageID(for: "ko"), 12)
        XCTAssertEqual(SenseVoiceNeuralEngineModel.languageID(for: "de"), 0)
        XCTAssertEqual(SenseVoiceNeuralEngineModel.languageID(for: nil), 0)
    }

    func testSenseVoiceShortAudioIsOneWindow() {
        XCTAssertEqual(SenseVoiceNeuralEngineModel.windows(for: [Float](repeating: 0.1, count: 32_000)), [0..<32_000])
        XCTAssertEqual(SenseVoiceNeuralEngineModel.windows(for: []), [])
    }

    func testSenseVoiceLongAudioCutsAtTheQuietestPlace() {
        // 25 s of "speech" with a silent 0.1 s gap at 8.0 s; windows of 10 s
        // searching the last 4 s.
        var samples = [Float](repeating: 0.5, count: 25 * 16_000)
        for index in (8 * 16_000)..<(8 * 16_000 + 1_600) { samples[index] = 0 }
        let windows = SenseVoiceNeuralEngineModel.windows(
            for: samples, maxSamples: 10 * 16_000, searchSamples: 4 * 16_000
        )
        XCTAssertEqual(windows.first, 0..<(8 * 16_000 + 800), "cut in the middle of the gap")
        XCTAssertEqual(windows.last?.upperBound, samples.count)
        for (previous, next) in zip(windows, windows.dropFirst()) {
            XCTAssertEqual(previous.upperBound, next.lowerBound, "contiguous")
        }
        XCTAssertTrue(windows.allSatisfy { $0.count <= 10 * 16_000 })
    }
}
