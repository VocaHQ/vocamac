// SherpaServiceTests.swift
// VocaMac Tests
//
// Integration coverage for the sherpa-onnx engine. These tests need a real
// model on disk, so they skip when one has not been downloaded — CI has no
// models, while a developer who has downloaded Moonshine gets the coverage.
//
// The load path is worth exercising for real: the recognizer config holds C
// strings pointing into autoreleased buffers, so building it on one thread
// and consuming it on another would leave dangling pointers.

import AVFoundation
import XCTest

@testable import VocaMac

final class SherpaServiceTests: XCTestCase {

    /// A downloaded sherpa model to test against, if any.
    private var installedModel: ModelSize? {
        SherpaModelCatalog.specs
            .first { SherpaService.modelFilesExist(for: $0) }?
            .size
    }

    /// One second of 440Hz tone at 16kHz — enough to drive a decode without
    /// depending on any audio fixture being checked in.
    private func toneSamples() -> [Float] {
        (0..<16_000).map { sin(2.0 * .pi * 440.0 * Float($0) / 16_000.0) * 0.2 }
    }

    func testLoadingRejectsUnknownModel() async {
        let service = SherpaService()
        do {
            try await service.loadModel(name: "not-a-real-model")
            XCTFail("Expected an error for an unknown model")
        } catch {
            XCTAssertFalse(service.isModelLoaded)
        }
    }

    func testTranscribingWithoutAModelThrows() async {
        let service = SherpaService()
        do {
            _ = try await service.transcribe(audioData: toneSamples())
            XCTFail("Expected an error when no model is loaded")
        } catch {
            // Expected — nothing is loaded.
        }
    }

    func testStorageRootIsUnderApplicationSupport() {
        let path = SherpaService.storageRoot.path
        XCTAssertTrue(path.contains("Application Support"))
        XCTAssertTrue(path.hasSuffix("VocaMac/models/sherpa-onnx"))
    }

    /// A truncated archive must fail loudly. `tar` writes entries as it goes,
    /// so a partial extraction can leave real-looking files behind; if this
    /// stopped throwing, the app would treat a half-downloaded model as
    /// installed and fail to load it with no way for the user to recover.
    func testExtractingCorruptArchiveThrows() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let corrupt = temp.appendingPathComponent("truncated.tar.bz2")
        // A valid bzip2 header followed by garbage — what a cut-off download
        // looks like on disk.
        try (Data([0x42, 0x5A, 0x68, 0x39]) + Data(repeating: 0xAB, count: 4096))
            .write(to: corrupt)

        XCTAssertThrowsError(try ModelManager.extractTarArchive(at: corrupt, into: temp))
    }

    func testCancelledModelPreparationStopsBeforeFileOperations() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                _ = try ModelManager.sha256Hex(ofFileAt: missing)
                XCTFail("Expected checksum cancellation")
            } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            do {
                try ModelManager.extractTarArchive(at: missing, into: missing)
                XCTFail("Expected extraction cancellation")
            } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        }
        await task.value
    }

    func testCompletionMarkerIsHidden() {
        // Hidden so it never shows up as a stray file in the model folder.
        XCTAssertTrue(SherpaService.completionMarkerName.hasPrefix("."))
    }

    func testExplicitLoadLanguageDoesNotFallBackToSavedPreference() {
        XCTAssertEqual(SherpaService.normalizedLoadLanguage("de"), "de")
        XCTAssertEqual(SherpaService.normalizedLoadLanguage(nil), "auto")
    }

    func testLoadAndTranscribeAcrossThreads() async throws {
        guard let model = installedModel else {
            throw XCTSkip("No sherpa-onnx model downloaded on this machine")
        }

        let audio = toneSamples()

        // Repeat: a dangling-pointer bug is timing dependent, so one pass can
        // pass by luck. Each iteration builds the config on the calling
        // context and consumes it on a background queue.
        for iteration in 1...3 {
            let service = SherpaService()
            try await service.loadModel(name: model.rawValue)

            XCTAssertTrue(service.isModelLoaded, "iteration \(iteration)")
            XCTAssertEqual(service.loadedModelName, model.rawValue)

            // A tone is not speech, so the text may be empty — what matters is
            // that the decode completes without crashing on freed paths.
            let result = try await service.transcribe(audioData: audio, language: "en")
            XCTAssertEqual(result.modelUsed, model)
            XCTAssertGreaterThan(result.audioLengthSeconds, 0)

            service.unloadModel()
            XCTAssertFalse(service.isModelLoaded)
        }
    }

    func testRouterActivatesSherpaEngine() async throws {
        guard let model = installedModel else {
            throw XCTSkip("No sherpa-onnx model downloaded on this machine")
        }

        let router = TranscriptionRouter()
        try await router.loadModel(name: model.rawValue)

        XCTAssertEqual(router.activeEngine, .sherpaOnnx)
        XCTAssertTrue(router.isModelLoaded)
        XCTAssertEqual(router.loadedModelName, model.rawValue)
    }

    func testUnloadDuringLoadDoesNotReinstallModel() async throws {
        guard let model = installedModel else { throw XCTSkip("No ONNX model installed") }
        let service = SherpaService()
        do {
            try await service.loadModel(name: model.rawValue, language: "en") { _ in
                service.unloadModel()
            }
            XCTFail("An invalidated load must not become active")
        } catch is CancellationError {
            XCTAssertFalse(service.isModelLoaded)
            XCTAssertNil(service.loadedModelName)
        }
    }

    func testCancellationStopsDecodingBetweenSegments() async {
        let worker = Task {
            var calls = 0
            do {
                _ = try SherpaService.decodeSegments([[0.1], [0.2]], language: "en") { _ in
                    calls += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                    return ("discard this cancelled result", "en")
                }
                XCTFail("Expected cancellation instead of a partial transcript")
            } catch is CancellationError {
                XCTAssertEqual(calls, 1)
            } catch { XCTFail("Unexpected error: \(error)") }
        }
        await worker.value
    }

    func testSegmentProcessingPadsShortTailsAndSkipsSilence() throws {
        var counts: [Int] = []
        let result = try SherpaService.decodeSegments(
            [[Float](repeating: 0.1, count: 32_000), [0, 0], [0.2]], language: "ko"
        ) { samples in
            counts.append(samples.count)
            return counts.count == 1 ? ("안녕하세요", "ko") : ("반갑습니다", "ko")
        }
        XCTAssertEqual(counts, [32_000, 16_000])
        XCTAssertEqual(result.text, "안녕하세요 반갑습니다")
    }

    func testFailedLaterSegmentDoesNotReturnPartialSuccess() {
        var calls = 0
        XCTAssertThrowsError(try SherpaService.decodeSegments([[0.1], [0.2]], language: "en") { _ in
            calls += 1
            if calls == 2 { throw SherpaError.transcriptionFailed(reason: "test failure") }
            return ("first segment", "en")
        })
        XCTAssertEqual(calls, 2)
    }

    func testShortWordsWithInstalledEnglishModels() async throws {
        let models: [ModelSize] = [.moonshineTiny, .moonshineBase, .senseVoiceSmall, .canary180mFlash]
        let installed = models.filter { size in
            SherpaModelCatalog.spec(for: size).map(SherpaService.modelFilesExist) ?? false
        }
        guard !installed.isEmpty else { throw XCTSkip("No English ONNX model installed") }
        for model in installed {
            let service = SherpaService()
            try await service.loadModel(name: model.rawValue, language: "en")
            for word in ["yes", "stop"] {
                let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                    .appendingPathComponent("Fixtures/short-\(word).wav")
                let audio = try AudioFileLoader().loadAudio(at: url).samples
                let result = try await service.transcribe(audioData: audio, language: "en")
                let normalized = result.text.lowercased().filter { $0.isLetter }
                XCTAssertEqual(normalized, word, "\(model): \(result.text)")
                XCTAssertEqual(result.audioLengthSeconds, Double(audio.count) / 16_000)
                XCTAssertLessThan(result.audioLengthSeconds, 0.5)
            }
        }
    }

    func testTinySilenceAndInvalidAudioWithInstalledModels() async throws {
        let installed = SherpaModelCatalog.specs.filter(SherpaService.modelFilesExist)
        guard !installed.isEmpty else { throw XCTSkip("No ONNX model installed") }
        for spec in installed {
            let service = SherpaService()
            try await service.loadModel(name: spec.size.rawValue, language: "en")
            // A one-sample nonzero input previously crashed the native Canary decoder.
            let tiny = try await service.transcribe(audioData: [0.001])
            XCTAssertEqual(tiny.audioLengthSeconds, 1.0 / 16_000)
            let silence = try await service.transcribe(audioData: [Float](repeating: 0, count: 100))
            XCTAssertEqual(silence.text, "")
            let invalidInputs: [[Float]] = [[], [.nan], [.infinity], [-.infinity]]
            for invalid in invalidInputs {
                do {
                    _ = try await service.transcribe(audioData: invalid)
                    XCTFail("Expected invalid audio to fail for \(spec.size)")
                } catch let error as SherpaError {
                    switch error {
                    case .emptyAudio, .transcriptionFailed: break
                    default: XCTFail("Unexpected error: \(error)")
                    }
                }
            }
        }
    }

    func testJoinTranscriptPiecesInsertsSpacesForWesternLanguages() {
        let joined = SherpaService.joinTranscriptPieces(["hello", "world"], language: "en")
        XCTAssertEqual(joined, "hello world")
    }

    func testJoinTranscriptPiecesOmitsSpacesForCJK() {
        XCTAssertEqual(
            SherpaService.joinTranscriptPieces(["你好", "世界"], language: "zh"),
            "你好世界"
        )
        XCTAssertEqual(
            SherpaService.joinTranscriptPieces(["こんにちは", "世界"], language: "ja"),
            "こんにちは世界"
        )
        XCTAssertEqual(
            SherpaService.joinTranscriptPieces(["你好", "世界"], language: "<|yue|>"),
            "你好世界"
        )
    }

    func testKoreanSegmentsKeepWordBoundaries() {
        XCTAssertEqual(
            SherpaService.joinTranscriptPieces(["안녕하세요", "반갑습니다"], language: "ko-KR"),
            "안녕하세요 반갑습니다"
        )
    }
}
