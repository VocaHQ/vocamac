// SpeedReliabilityTests.swift
// VocaMac Tests
//
// Pure rules behind the speed and reliability changes: Whisper's prompt cap
// and end-of-audio guard, the router's deadlines, and the download check.

import XCTest
@testable import VocaMac

final class WhisperPromptCapTests: XCTestCase {

    /// One token per character keeps the arithmetic visible.
    private let encode: (String) -> [Int] = { $0.unicodeScalars.map { Int($0.value) } }

    func testShortGlossaryIsKeptWhole() {
        let tokens = WhisperService.cappedPromptTokens(terms: ["VocaMac", "Namrata"], encode: encode)
        XCTAssertEqual(tokens.map { String(String.UnicodeScalarView($0.compactMap(Unicode.Scalar.init))) },
                       "Glossary: VocaMac, Namrata")
    }

    func testLongGlossaryDropsTheFirstTermsAndKeepsTheLast() throws {
        let screenTerms = (0..<40).map { "ScreenTerm\($0)" }
        let tokens = try XCTUnwrap(WhisperService.cappedPromptTokens(terms: screenTerms + ["Namrata"], encode: encode))
        XCTAssertLessThanOrEqual(tokens.count, WhisperService.maximumPromptTokens)
        let text = String(String.UnicodeScalarView(tokens.compactMap(Unicode.Scalar.init)))
        XCTAssertTrue(text.hasPrefix("Glossary: "))
        XCTAssertTrue(text.hasSuffix("Namrata"), "The user's own words, last, are the last to go")
        XCTAssertFalse(text.contains("ScreenTerm0,"), "The earliest screen terms are dropped first")
    }

    func testNoTermsMeansNoPrompt() {
        XCTAssertNil(WhisperService.cappedPromptTokens(terms: [], encode: encode))
    }

    func testATermTooLongOnItsOwnIsDropped() {
        let huge = String(repeating: "x", count: 500)
        XCTAssertNil(WhisperService.cappedPromptTokens(terms: [huge], encode: encode))
    }
}

final class WhisperEndOfAudioTests: XCTestCase {

    func testTrimmedAudioOnlyGuardsTheTrimPadding() {
        let clip = WhisperService.windowClipTime(sampleCount: 30 * 16_000 + 8_000, endsAtSpeech: true)
        XCTAssertGreaterThan(Double(clip), SpeechActivityTrimmer.speechPadding)
        XCTAssertLessThan(clip, 1, "The last words of a 30–31 s dictation must be decoded")
    }

    func testUntrimmedAudioKeepsTheOneSecondGuard() {
        XCTAssertEqual(WhisperService.windowClipTime(sampleCount: 30 * 16_000 + 8_000), 1)
    }

    func testShortClipsAreNeverClipped() {
        XCTAssertEqual(WhisperService.windowClipTime(sampleCount: 16_000, endsAtSpeech: true), 0)
    }
}

final class TranscriptionDeadlineTests: XCTestCase {

    func testFirstNeuralEngineLoadGetsTheLongAllowance() {
        let defaults = UserDefaults(suiteName: "TranscriptionDeadlineTests-\(UUID())")!
        let record = CompiledModelRecord(defaults: defaults, osBuild: "26A1", compileCacheExists: { true })
        XCTAssertEqual(
            TranscriptionRouter.loadDeadlineSeconds(forModelIdentifier: ModelSize.parakeetV3.rawValue, record: record),
            TranscriptionRouter.firstLoadDeadlineSeconds
        )
        record.recordLoad(.parakeetV3)
        XCTAssertEqual(
            TranscriptionRouter.loadDeadlineSeconds(forModelIdentifier: ModelSize.parakeetV3.rawValue, record: record),
            TranscriptionRouter.cachedLoadDeadlineSeconds
        )
    }

    func testAppleSpeechMayDownloadItsAssets() {
        XCTAssertEqual(
            TranscriptionRouter.loadDeadlineSeconds(forModelIdentifier: ModelSize.appleSpeech.rawValue),
            TranscriptionRouter.firstLoadDeadlineSeconds
        )
    }

    func testRemoteEndpointGetsItsRequestTimeoutAndTheUpload() {
        let local = TranscriptionRouter.decodeDeadlineSeconds(audioSeconds: 10, engine: .parakeet)
        let remote = TranscriptionRouter.decodeDeadlineSeconds(audioSeconds: 10, engine: .customEndpoint)
        XCTAssertEqual(local, Deadline.decodeSeconds(audioSeconds: 10))
        XCTAssertGreaterThan(remote, CustomEndpointService.requestTimeout)
    }

    func testCancellationWrappedByAnEngineIsNotAModelFailure() {
        let wrapped = WhisperError.transcriptionFailed(reason: CancellationError().localizedDescription)
        XCTAssertFalse(TranscriptionRouter.isModelFailure(wrapped))
        XCTAssertFalse(TranscriptionRouter.isModelFailure(
            ParakeetError.transcriptionFailed(reason: CancellationError().localizedDescription)
        ))
        XCTAssertTrue(TranscriptionRouter.isModelFailure(WhisperError.transcriptionFailed(reason: "MPS error")))
    }
}

final class DownloadCompletenessTests: XCTestCase {

    func testSizeWithinTwoPercentIsComplete() {
        XCTAssertTrue(ModelManager.isInstalledSizeComplete(actual: 76_635_397, expected: 76_635_397))
        XCTAssertTrue(ModelManager.isInstalledSizeComplete(actual: 1_538_811_966, expected: 824_300_479))
        XCTAssertTrue(ModelManager.isInstalledSizeComplete(actual: 990, expected: 1_000))
    }

    func testTruncatedDownloadIsNotComplete() {
        XCTAssertFalse(ModelManager.isInstalledSizeComplete(actual: 400_000_000, expected: 483_257_242))
        XCTAssertFalse(ModelManager.isInstalledSizeComplete(actual: 0, expected: 1))
    }

    func testModelsWithNothingToDownloadAreComplete() {
        XCTAssertTrue(ModelManager.isInstalledSizeComplete(actual: 0, expected: 0))
    }

    func testDirectorySizeFollowsLinksAndNestedFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DirectorySize-\(UUID())")
        let nested = root.appendingPathComponent("Encoder.mlmodelc/weights", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(count: 1_000).write(to: nested.appendingPathComponent("weight.bin"))
        try Data(count: 24).write(to: root.appendingPathComponent("config.json"))
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("DirectorySizeLink-\(UUID())")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: link) }

        XCTAssertEqual(ModelManager.directorySize(at: root), 1_024)
        XCTAssertEqual(ModelManager.directorySize(at: link), 1_024)
    }
}

final class LiveSessionEndOfInputTests: XCTestCase {

    func testInputEndedEarlyIsStillFinishedWithTheWholeRecording() async throws {
        let audio = [Float](repeating: 0.1, count: 32_000)
        let session = RecordingTranscription(language: "en") { chunks in
            var count = 0
            for try await chunk in chunks { count += chunk.count }
            return VocaTranscription(
                text: "done", duration: 0, detectedLanguage: "en",
                audioLengthSeconds: Double(count) / 16_000, modelUsed: .tiny
            )
        }
        session.append(audio, at: 0)
        XCTAssertTrue(session.endInput(expectedSampleCount: audio.count))
        XCTAssertTrue(session.endInput(expectedSampleCount: audio.count), "Asking again changes nothing")
        let result = try await session.finish(expectedSampleCount: audio.count)
        XCTAssertEqual(result.text, "done")
    }

    func testInputEndedShortIsRefused() async {
        let session = RecordingTranscription(language: "en") { chunks in
            for try await _ in chunks {}
            return VocaTranscription(text: "", duration: 0, detectedLanguage: "en", audioLengthSeconds: 0, modelUsed: .tiny)
        }
        session.append([Float](repeating: 0.1, count: 8_000), at: 0)
        XCTAssertFalse(session.endInput(expectedSampleCount: 16_000))
        do {
            _ = try await session.finish(expectedSampleCount: 16_000)
            XCTFail("A session missing audio must not be used")
        } catch {
            XCTAssertEqual(error as? RecordingTranscription.StreamError, .incomplete)
        }
    }

    func testFinishAllowanceGrowsWithTheRecording() {
        XCTAssertEqual(RecordingTranscription.finishDeadlineSeconds(expectedSampleCount: 16_000), 60)
        XCTAssertEqual(RecordingTranscription.finishDeadlineSeconds(expectedSampleCount: 16_000 * 60), 210)
    }
}

@MainActor
final class CleanupReloadTests: XCTestCase {

    func testOneRejectedAnswerKeepsTheLoadedModel() {
        XCTAssertFalse(TranscriptCleanupService.rebuildsLoadedModel(afterConsecutiveFailures: 0))
        XCTAssertFalse(
            TranscriptCleanupService.rebuildsLoadedModel(afterConsecutiveFailures: 1),
            "A routine rejection must not reload gigabytes of weights before the next dictation"
        )
    }

    func testAModelShownAsBrokenIsRebuiltOnReload() {
        XCTAssertTrue(TranscriptCleanupService.rebuildsLoadedModel(
            afterConsecutiveFailures: TranscriptCleanupService.failureLimit
        ))
    }
}

final class WhisperLanguageGuardTests: XCTestCase {

    func testDetectionOutsideTheUsersLanguagesIsDecodedInTheirFirst() {
        XCTAssertEqual(WhisperService.correctedLanguage(detected: "hi", expected: ["en"]), "en")
        XCTAssertEqual(WhisperService.correctedLanguage(detected: "ru", expected: ["de", "en"]), "de")
    }

    func testDetectionAmongTheUsersLanguagesIsKept() {
        XCTAssertNil(WhisperService.correctedLanguage(detected: "hi", expected: ["en", "hi"]))
    }

    func testNoListOrNoDetectionChangesNothing() {
        XCTAssertNil(WhisperService.correctedLanguage(detected: "hi", expected: []))
        XCTAssertNil(WhisperService.correctedLanguage(detected: nil, expected: ["en"]))
    }
}
