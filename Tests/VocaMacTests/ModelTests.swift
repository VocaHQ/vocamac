// ModelTests.swift
// VocaMac Tests
//
// Tests for data models: SystemInfo, ModelSize, ModelManager,
// WhisperModelInfo, TranscriptionResult, AppStatus, ActivationMode.

import XCTest
import ServiceManagement
@testable import VocaMac

// MARK: - SystemInfo Tests

final class SystemInfoTests: XCTestCase {

    func testDetectSystemCapabilities() {
        let capabilities = SystemInfo.detect()
        XCTAssertGreaterThan(capabilities.physicalMemoryGB, 0)
        XCTAssertGreaterThan(capabilities.coreCount, 0)
        XCTAssertFalse(capabilities.processorName.isEmpty)
    }

    func testModelRecommendationAppleSilicon() {
        XCTAssertEqual(SystemInfo.recommendModel(isAppleSilicon: true, memoryGB: 4), .tiny)
        XCTAssertEqual(SystemInfo.recommendModel(isAppleSilicon: true, memoryGB: 8), .base)
        XCTAssertEqual(SystemInfo.recommendModel(isAppleSilicon: true, memoryGB: 16), .small)
        XCTAssertEqual(SystemInfo.recommendModel(isAppleSilicon: true, memoryGB: 24), .largeV3LatestTurboCompact)
        XCTAssertEqual(SystemInfo.recommendModel(isAppleSilicon: true, memoryGB: 48), .largeV3Latest)
    }

    func testModelRecommendationIntel() {
        XCTAssertEqual(SystemInfo.recommendModel(isAppleSilicon: false, memoryGB: 8), .tiny)
        XCTAssertEqual(SystemInfo.recommendModel(isAppleSilicon: false, memoryGB: 16), .base)
        XCTAssertEqual(SystemInfo.recommendModel(isAppleSilicon: false, memoryGB: 32), .small)
    }

    func testRecommendedThreadCount() {
        let threads = SystemInfo.recommendedThreadCount
        XCTAssertGreaterThanOrEqual(threads, 2)
        XCTAssertLessThanOrEqual(threads, 8)
    }

    func testModelIdentifier() {
        XCTAssertFalse(SystemInfo.modelIdentifier.isEmpty)
    }

    func testSummaryDescription() {
        let capabilities = SystemInfo.detect()
        let summary = capabilities.summaryDescription
        XCTAssertTrue(summary.contains("Processor:"))
        XCTAssertTrue(summary.contains("Architecture:"))
        XCTAssertTrue(summary.contains("Memory:"))
        XCTAssertTrue(summary.contains("Cores:"))
        XCTAssertTrue(summary.contains("Metal:"))
        XCTAssertTrue(summary.contains("Recommended Model:"))
    }
}

// MARK: - ModelSize Tests

final class ModelSizeTests: XCTestCase {

    func testModelSizesHavePositiveFileSizes() {
        for size in ModelSize.allCases where !size.isSystemManaged {
            XCTAssertGreaterThan(size.fileSizeBytes, 0)
        }
    }

    func testSystemManagedModelsReportNoDownloadSize() {
        for size in ModelSize.allCases where size.isSystemManaged {
            XCTAssertEqual(size.fileSizeBytes, 0)
            XCTAssertEqual(size.fileSizeDescription, "Managed by macOS")
        }
    }

    func testFileSizeDescription() {
        for size in ModelSize.allCases {
            XCTAssertFalse(size.fileSizeDescription.isEmpty)
        }
    }

    func testDisplayNames() {
        for size in ModelSize.allCases {
            XCTAssertFalse(size.displayName.isEmpty)
        }
    }

    func testRAMRequirementsPositive() {
        for size in ModelSize.allCases {
            XCTAssertGreaterThan(size.ramRequiredGB, 0)
        }
    }

    func testQualityDescriptions() {
        for size in ModelSize.allCases {
            XCTAssertFalse(size.qualityDescription.isEmpty)
        }
    }

    func testRelativeSpeedsPositive() {
        for size in ModelSize.allCases {
            XCTAssertGreaterThan(size.relativeSpeed, 0)
        }
    }

    func testAllCasesCount() {
        XCTAssertEqual(ModelSize.allCases.count, 20)
    }

    func testRawValues() {
        XCTAssertEqual(ModelSize.tiny.rawValue, "tiny")
        XCTAssertEqual(ModelSize.base.rawValue, "base")
        XCTAssertEqual(ModelSize.small.rawValue, "small")
        XCTAssertEqual(ModelSize.largeV3LatestTurboCompact.rawValue, "large-v3-v20240930_turbo_632MB")
        XCTAssertEqual(ModelSize.distilLargeV3Compact.rawValue, "distil-large-v3_594MB")
        XCTAssertEqual(ModelSize.distilLargeV3TurboCompact.rawValue, "distil-large-v3_turbo_600MB")
        XCTAssertEqual(ModelSize.largeV3LatestCompact.rawValue, "large-v3-v20240930_626MB")
        XCTAssertEqual(ModelSize.largeV3Latest.rawValue, "large-v3-v20240930")
        XCTAssertEqual(ModelSize.largeV3LatestTurbo.rawValue, "large-v3-v20240930_turbo")
        XCTAssertEqual(ModelSize.largeV3.rawValue, "large-v3")
        XCTAssertEqual(ModelSize.largeV3Turbo.rawValue, "large-v3_turbo")
        XCTAssertEqual(ModelSize.medium.rawValue, "medium")
        XCTAssertEqual(ModelSize.parakeetV3.rawValue, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(ModelSize.parakeetV2.rawValue, "parakeet-tdt-0.6b-v2")
        XCTAssertEqual(ModelSize.appleSpeech.rawValue, "apple-speech")
        XCTAssertEqual(ModelSize.moonshineTiny.rawValue, "moonshine-v2-tiny-en")
        XCTAssertEqual(ModelSize.moonshineBase.rawValue, "moonshine-v2-base-en")
        XCTAssertEqual(ModelSize.senseVoiceSmall.rawValue, "sense-voice-small")
        XCTAssertEqual(ModelSize.gigaamV3.rawValue, "gigaam-v3-russian")
        XCTAssertEqual(ModelSize.canary180mFlash.rawValue, "canary-180m-flash")
    }

    func testStandardCatalogExcludesLegacyMedium() {
        XCTAssertFalse(ModelSize.standardCatalog.contains(.medium))
        XCTAssertTrue(ModelSize.medium.isLegacy)
    }

    func testStandardCatalogIncludesNewEngines() {
        XCTAssertTrue(ModelSize.standardCatalog.contains(.parakeetV3))
        XCTAssertTrue(ModelSize.standardCatalog.contains(.parakeetV2))
        XCTAssertTrue(ModelSize.standardCatalog.contains(.appleSpeech))
        XCTAssertTrue(ModelSize.standardCatalog.contains(.moonshineTiny))
        XCTAssertTrue(ModelSize.standardCatalog.contains(.senseVoiceSmall))
        XCTAssertTrue(ModelSize.standardCatalog.contains(.gigaamV3))
        XCTAssertTrue(ModelSize.standardCatalog.contains(.canary180mFlash))
    }

    func testEngineAssignment() {
        XCTAssertEqual(ModelSize.parakeetV3.engine, .parakeet)
        XCTAssertEqual(ModelSize.parakeetV2.engine, .parakeet)
        XCTAssertEqual(ModelSize.appleSpeech.engine, .appleSpeech)
        XCTAssertEqual(ModelSize.moonshineTiny.engine, .sherpaOnnx)
        XCTAssertEqual(ModelSize.moonshineBase.engine, .sherpaOnnx)
        XCTAssertEqual(ModelSize.senseVoiceSmall.engine, .sherpaOnnx)
        XCTAssertEqual(ModelSize.gigaamV3.engine, .sherpaOnnx)
        XCTAssertEqual(ModelSize.canary180mFlash.engine, .sherpaOnnx)

        // Everything else is a WhisperKit model.
        let whisperCases = ModelSize.allCases.filter { $0.engine == .whisperKit }
        XCTAssertEqual(whisperCases.count, 12)
    }

    func testEngineCapabilities() {
        XCTAssertTrue(TranscriptionEngine.whisperKit.supportsTranslation)
        XCTAssertTrue(TranscriptionEngine.whisperKit.supportsCustomVocabulary)
        XCTAssertFalse(TranscriptionEngine.parakeet.supportsTranslation)
        XCTAssertFalse(TranscriptionEngine.appleSpeech.supportsTranslation)
    }
}

// MARK: - TranscriptionRouter Tests

final class TranscriptionRouterTests: XCTestCase {

    func testEngineResolutionFromIdentifier() {
        XCTAssertEqual(TranscriptionRouter.engine(forModelIdentifier: nil), .whisperKit)
        XCTAssertEqual(TranscriptionRouter.engine(forModelIdentifier: "openai_whisper-tiny"), .whisperKit)
        XCTAssertEqual(TranscriptionRouter.engine(forModelIdentifier: "tiny"), .whisperKit)
        XCTAssertEqual(TranscriptionRouter.engine(forModelIdentifier: "parakeet-tdt-0.6b-v3"), .parakeet)
        XCTAssertEqual(TranscriptionRouter.engine(forModelIdentifier: "parakeet-tdt-0.6b-v2"), .parakeet)
        XCTAssertEqual(TranscriptionRouter.engine(forModelIdentifier: "apple-speech"), .appleSpeech)
        XCTAssertEqual(TranscriptionRouter.engine(forModelIdentifier: "unknown-model"), .whisperKit)
    }

    func testRouterStartsWithWhisperKitEngine() {
        let router = TranscriptionRouter()
        XCTAssertEqual(router.activeEngine, .whisperKit)
        XCTAssertFalse(router.isModelLoaded)
        XCTAssertNil(router.loadedModelName)
    }

    func testEngineResolutionForSherpaModels() {
        XCTAssertEqual(TranscriptionRouter.engine(forModelIdentifier: "moonshine-v2-tiny-en"), .sherpaOnnx)
        XCTAssertEqual(TranscriptionRouter.engine(forModelIdentifier: "moonshine-v2-base-en"), .sherpaOnnx)
        XCTAssertEqual(TranscriptionRouter.engine(forModelIdentifier: "sense-voice-small"), .sherpaOnnx)
        XCTAssertEqual(TranscriptionRouter.engine(forModelIdentifier: "gigaam-v3-russian"), .sherpaOnnx)
        XCTAssertEqual(TranscriptionRouter.engine(forModelIdentifier: "canary-180m-flash"), .sherpaOnnx)
    }
}

// MARK: - SherpaModelCatalog Tests

final class SherpaModelCatalogTests: XCTestCase {

    func testEverySherpaModelHasASpec() {
        for size in ModelSize.allCases where size.engine == .sherpaOnnx {
            XCTAssertNotNil(SherpaModelCatalog.spec(for: size), "\(size.rawValue) is missing a catalog spec")
        }
    }

    func testNonSherpaModelsHaveNoSpec() {
        for size in ModelSize.allCases where size.engine != .sherpaOnnx {
            XCTAssertNil(SherpaModelCatalog.spec(for: size))
        }
    }

    func testSpecsAreWellFormed() {
        for spec in SherpaModelCatalog.specs {
            XCTAssertEqual(spec.size.engine, .sherpaOnnx)
            XCTAssertEqual(spec.archiveURL.host, "github.com")
            XCTAssertTrue(spec.archiveURL.lastPathComponent.hasSuffix(".tar.bz2"))
            XCTAssertEqual(spec.archiveURL.lastPathComponent, spec.directoryName + ".tar.bz2")
            XCTAssertFalse(spec.requiredFiles.isEmpty)
            XCTAssertTrue(spec.requiredFiles.contains(spec.tokensFile))
        }
    }
}

// MARK: - ModelManager Tests

final class ModelManagerTests: XCTestCase {

    func testWhisperKitModelNames() {
        let manager = ModelManager()
        XCTAssertEqual(manager.whisperKitModelName(for: .tiny), "openai_whisper-tiny")
        XCTAssertEqual(manager.whisperKitModelName(for: .base), "openai_whisper-base")
        XCTAssertEqual(manager.whisperKitModelName(for: .small), "openai_whisper-small")
        XCTAssertEqual(manager.whisperKitModelName(for: .largeV3LatestTurboCompact), "openai_whisper-large-v3-v20240930_turbo_632MB")
        XCTAssertEqual(manager.whisperKitModelName(for: .distilLargeV3Compact), "distil-whisper_distil-large-v3_594MB")
        XCTAssertEqual(manager.whisperKitModelName(for: .distilLargeV3TurboCompact), "distil-whisper_distil-large-v3_turbo_600MB")
        XCTAssertEqual(manager.whisperKitModelName(for: .largeV3LatestCompact), "openai_whisper-large-v3-v20240930_626MB")
        XCTAssertEqual(manager.whisperKitModelName(for: .largeV3Latest), "openai_whisper-large-v3-v20240930")
        XCTAssertEqual(manager.whisperKitModelName(for: .largeV3LatestTurbo), "openai_whisper-large-v3-v20240930_turbo")
        XCTAssertEqual(manager.whisperKitModelName(for: .largeV3), "openai_whisper-large-v3")
        XCTAssertEqual(manager.whisperKitModelName(for: .largeV3Turbo), "openai_whisper-large-v3_turbo")
        XCTAssertEqual(manager.whisperKitModelName(for: .medium), "openai_whisper-medium")
    }

    func testModelSizeFromWhisperKitNameUsesExactVariant() {
        let manager = ModelManager()
        XCTAssertEqual(manager.modelSize(from: "openai_whisper-large-v3-v20240930"), .largeV3Latest)
        XCTAssertEqual(manager.modelSize(from: "openai_whisper-large-v3-v20240930_626MB"), .largeV3LatestCompact)
        XCTAssertEqual(manager.modelSize(from: "openai_whisper-large-v3"), .largeV3)
        XCTAssertEqual(manager.modelSize(from: "openai_whisper-large-v3_turbo"), .largeV3Turbo)
        XCTAssertNil(manager.modelSize(from: "openai_whisper-large-v3-v20240930_extra"))
    }

    func testModelIdentifiersForNonWhisperEngines() {
        let manager = ModelManager()
        XCTAssertEqual(manager.modelIdentifier(for: .parakeetV3), "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(manager.modelIdentifier(for: .parakeetV2), "parakeet-tdt-0.6b-v2")
        XCTAssertEqual(manager.modelIdentifier(for: .appleSpeech), "apple-speech")
        XCTAssertEqual(manager.modelIdentifier(for: .tiny), "openai_whisper-tiny")

        XCTAssertEqual(manager.modelSize(from: "parakeet-tdt-0.6b-v3"), .parakeetV3)
        XCTAssertEqual(manager.modelSize(from: "parakeet-tdt-0.6b-v2"), .parakeetV2)
        XCTAssertEqual(manager.modelSize(from: "apple-speech"), .appleSpeech)
    }

    func testAppleSpeechIsSystemManaged() {
        let manager = ModelManager()
        // System-managed assets always report as downloaded and have no
        // local folder for the app to manage.
        XCTAssertTrue(manager.isModelDownloaded(.appleSpeech))
        XCTAssertNil(manager.modelFolder(for: .appleSpeech))
    }

    func testUsableCoreMLComponentRequiresWeights() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let component = root.appendingPathComponent("AudioEncoder.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(
            at: component,
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: component.appendingPathComponent("metadata.json"))
        try Data("mil".utf8).write(to: component.appendingPathComponent("model.mil"))

        XCTAssertFalse(ModelManager.hasUsableCoreMLComponent(at: component))

        let weights = component.appendingPathComponent("weights", isDirectory: true)
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: weights.appendingPathComponent("weight.bin"))

        XCTAssertTrue(ModelManager.hasUsableCoreMLComponent(at: component))
    }

    func testDownloadedModelsReturnsArray() {
        let manager = ModelManager()
        let downloaded = manager.downloadedModels()
        XCTAssertGreaterThanOrEqual(downloaded.count, 0)
    }

    func testDiskUsageDescriptionNotEmpty() {
        let manager = ModelManager()
        XCTAssertFalse(manager.diskUsageDescription().isEmpty)
    }

    func testTotalDiskUsageNonNegative() {
        let manager = ModelManager()
        XCTAssertGreaterThanOrEqual(manager.totalDiskUsage(), 0)
    }

    func testDiskUsageIsCachedBetweenReads() {
        let manager = ModelManager()

        // Warm the cache, then confirm repeated reads agree. The settings UI
        // calls this from a view body, so the cached path must be stable.
        let first = manager.totalDiskUsage()
        for _ in 0..<50 {
            XCTAssertEqual(manager.totalDiskUsage(), first)
        }
    }

    func testInvalidatingDiskUsageCacheStillReportsUsage() {
        let manager = ModelManager()
        let measured = manager.totalDiskUsage()

        manager.invalidateDiskUsageCache()

        // Nothing changed on disk, so a fresh measurement must agree with the
        // cached one — this guards the cache against reporting a stale zero.
        XCTAssertEqual(manager.totalDiskUsage(), measured)
    }
}

// MARK: - WhisperModelInfo Tests

final class WhisperModelInfoTests: XCTestCase {

    func testStatusDescription() {
        var model = WhisperModelInfo(
            size: .tiny, filePath: nil, isDownloaded: false,
            isActive: false, isSupported: true
        )
        XCTAssertEqual(model.statusDescription, "Not Downloaded")

        model.isDownloaded = true
        XCTAssertEqual(model.statusDescription, "Downloaded")

        model.isActive = true
        XCTAssertEqual(model.statusDescription, "Active")

        model.isActive = false
        model.downloadProgress = 0.5
        XCTAssertEqual(model.statusDescription, "Downloading (50%)")
    }

    func testLoadingState() {
        var model = WhisperModelInfo(
            size: .base, filePath: nil, isDownloaded: true,
            isActive: false, isSupported: true
        )
        model.isLoading = true
        XCTAssertEqual(model.statusDescription, "Loading…")
        XCTAssertEqual(model.statusIconName, "arrow.trianglehead.2.clockwise")
    }

    func testDefaultIsLoading() {
        let model = WhisperModelInfo(
            size: .tiny, filePath: nil, isDownloaded: false,
            isActive: false, isSupported: true
        )
        XCTAssertFalse(model.isLoading)
    }

    func testStatusIcon() {
        var model = WhisperModelInfo(
            size: .base, filePath: nil, isDownloaded: false,
            isActive: false, isSupported: true
        )
        XCTAssertEqual(model.statusIconName, "arrow.down.to.line")

        model.isDownloaded = true
        XCTAssertEqual(model.statusIconName, "checkmark.circle")

        model.isActive = true
        XCTAssertEqual(model.statusIconName, "checkmark.circle.fill")

        model.isActive = false
        model.downloadProgress = 0.3
        XCTAssertEqual(model.statusIconName, "arrow.down.circle")
    }

    func testIDMatchesSize() {
        let model = WhisperModelInfo(
            size: .small, filePath: nil, isDownloaded: false,
            isActive: false, isSupported: true
        )
        XCTAssertEqual(model.id, "small")
    }
}

// MARK: - TranscriptionResult Tests

final class VocaTranscriptionTests: XCTestCase {

    func testCreationPreservesValues() {
        let result = VocaTranscription(
            text: "Hello world", duration: 1.5,
            detectedLanguage: "en", audioLengthSeconds: 3.0, modelUsed: .tiny
        )
        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.duration, 1.5)
        XCTAssertEqual(result.detectedLanguage, "en")
        XCTAssertEqual(result.audioLengthSeconds, 3.0)
        XCTAssertEqual(result.modelUsed, .tiny)
    }

    func testUniqueID() {
        let r1 = VocaTranscription(
            text: "Hello", duration: 1.0,
            detectedLanguage: "en", audioLengthSeconds: 2.0, modelUsed: .tiny
        )
        let r2 = VocaTranscription(
            text: "Hello", duration: 1.0,
            detectedLanguage: "en", audioLengthSeconds: 2.0, modelUsed: .tiny
        )
        XCTAssertNotEqual(r1.id, r2.id)
    }
}

// MARK: - AppStatus Tests

final class AppStatusTests: XCTestCase {

    func testRawValues() {
        XCTAssertEqual(AppStatus.idle.rawValue, "idle")
        XCTAssertEqual(AppStatus.recording.rawValue, "recording")
        XCTAssertEqual(AppStatus.processing.rawValue, "processing")
        XCTAssertEqual(AppStatus.error.rawValue, "error")
    }
}

// MARK: - ActivationMode Tests

final class ActivationModeTests: XCTestCase {

    func testDisplayNames() {
        for mode in ActivationMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty)
        }
    }

    func testDescriptions() {
        for mode in ActivationMode.allCases {
            XCTAssertFalse(mode.description.isEmpty)
        }
    }

    func testActivationModeCaseCount() {
        XCTAssertEqual(ActivationMode.allCases.count, 2)
    }

    func testRawValues() {
        XCTAssertEqual(ActivationMode.pushToTalk.rawValue, "pushToTalk")
        XCTAssertEqual(ActivationMode.doubleTapToggle.rawValue, "doubleTapToggle")
    }
}
