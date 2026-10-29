// CalibrationTests.swift
// VocaMac
//
// The accuracy test: scoring, the stored result, the runner, and which
// models the app offers to test.

import XCTest
@testable import VocaMac

final class CalibrationScoringTests: XCTestCase {

    private let passage = CalibrationPassage.technical

    func testAPerfectTranscriptScoresZero() {
        let row = CalibrationScoring.row(
            modelID: "tiny", modelName: "Tiny", passage: passage, hypothesis: passage.text, seconds: 0.4
        )
        XCTAssertEqual(row.wordErrorRate, 0)
        XCTAssertEqual(row.lostTerms, [])
        XCTAssertEqual(row.errorRateText, "0.0%")
        XCTAssertNil(row.failure)
    }

    func testLostTermsAreCountedTheWayWordsAre() {
        let hypothesis = passage.text
            .replacingOccurrences(of: "PostgreSQL", with: "Postgres QL")
            .replacingOccurrences(of: "Priya", with: "Maria")
        let row = CalibrationScoring.row(
            modelID: "base", modelName: "Base", passage: passage, hypothesis: hypothesis, seconds: 1
        )
        XCTAssertEqual(row.lostTerms, ["PostgreSQL", "Priya"])
        XCTAssertGreaterThan(row.wordErrorRate ?? 0, 0)
        // Case and punctuation don't make a term lost.
        XCTAssertEqual(CalibrationScoring.lostTerms(["GitHub"], in: "check github."), [])
        XCTAssertEqual(CalibrationScoring.lostTerms(["API"], in: ""), ["API"])
    }

    func testRankingIsByErrorsThenLostTermsThenSpeed() {
        func row(_ id: String, _ rate: Double?, lost: Int = 0, seconds: Double = 1) -> CalibrationRow {
            CalibrationRow(
                modelID: id, modelName: id, wordErrorRate: rate, seconds: rate == nil ? nil : seconds,
                lostTerms: Array(repeating: "x", count: lost), transcript: "", failure: rate == nil ? "failed" : nil
            )
        }
        let ranked = CalibrationScoring.ranked([
            row("failed", nil),
            row("slow", 0.05, seconds: 3),
            row("worse", 0.12),
            row("fast", 0.05, seconds: 1),
            row("lossy", 0.05, lost: 2, seconds: 0.5),
        ])
        XCTAssertEqual(ranked.map(\.modelID), ["fast", "slow", "lossy", "worse", "failed"])
    }

    func testRecordingProblems() {
        XCTAssertNotNil(CalibrationScoring.recordingProblem([], deviceName: "Mic"))
        let silent = [Float](repeating: 0, count: 16_000 * 10)
        XCTAssertTrue(CalibrationScoring.recordingProblem(silent, deviceName: "Mic")?.hasPrefix("No sound came from Mic") == true)
        let short = [Float](repeating: 0.1, count: 16_000)
        XCTAssertTrue(CalibrationScoring.recordingProblem(short, deviceName: "Mic")?.hasPrefix("That was too short") == true)
        let good = [Float](repeating: 0.1, count: 16_000 * 10)
        XCTAssertNil(CalibrationScoring.recordingProblem(good, deviceName: "Mic"))
    }

    func testPassagesOfferedFollowTheLanguages() {
        XCTAssertEqual(CalibrationPassage.offered(for: ["en"]).map(\.id), ["everyday", "technical"])
        XCTAssertEqual(CalibrationPassage.offered(for: ["en", "hi"]).map(\.id), ["everyday", "technical", "hinglish"])
        XCTAssertEqual(CalibrationPassage.offered(for: []).map(\.id), ["everyday", "technical"])
    }

    func testPassagesHaveNoDigitsAndKeepTheirTerms() {
        for passage in CalibrationPassage.all {
            XCTAssertFalse(passage.text.contains(where: \.isNumber), "\(passage.id) must not contain digits")
            XCTAssertEqual(CalibrationScoring.lostTerms(passage.mustKeep, in: passage.text), [], passage.id)
            XCTAssertGreaterThan(passage.wordCount, 40)
        }
    }
}

final class CalibrationResultTests: XCTestCase {

    private func result(device: String) -> CalibrationResult {
        CalibrationResult(
            date: Date(timeIntervalSince1970: 1_800_000_000),
            passageID: "everyday",
            deviceUID: device,
            deviceName: "Studio Mic",
            rows: [
                CalibrationRow(modelID: "tiny", modelName: "Tiny", wordErrorRate: 0.2, seconds: 0.3,
                               lostTerms: ["Lisbon"], transcript: "…", failure: nil),
                .failed(modelID: "large", modelName: "Large", reason: "Needs more memory"),
            ]
        )
    }

    func testRoundTrip() {
        let original = result(device: "usb-1")
        XCTAssertEqual(CalibrationResult.decode(original.encoded()), original)
        XCTAssertNil(CalibrationResult.decode(""))
        XCTAssertNil(CalibrationResult.decode("{"))
    }

    func testStaleAfterTheMicrophoneChanges() {
        let measured = result(device: "usb-1")
        XCTAssertFalse(measured.isStale(currentDeviceUID: "usb-1"))
        XCTAssertTrue(measured.isStale(currentDeviceUID: ""))
    }

    func testBestAndRowsSkipUntestedModels() {
        let measured = result(device: "")
        XCTAssertEqual(measured.best?.modelID, "tiny")
        XCTAssertNotNil(measured.row(for: "tiny"))
        XCTAssertNil(measured.row(for: "large"), "An untested model has no measurement")
    }
}

@MainActor
final class CalibrationRunnerTests: XCTestCase {

    private let samples = [Float](repeating: 0.1, count: 16_000 * 5)

    private func candidate(_ size: ModelSize) -> CalibrationCandidate {
        CalibrationCandidate(size: size, name: size.displayName, identifier: size.rawValue, folder: nil)
    }

    func testEachModelIsLoadedTranscribedAndUnloadedInTurn() async {
        let passage = CalibrationPassage.everyday
        var made: [MockWhisperService] = []
        let texts = [passage.text, "The quiet harbor town wakes early."]
        let runner = CalibrationRunner(makeTranscriber: { language in
            XCTAssertEqual(language, "en")
            let service = MockWhisperService()
            service.mockTranscriptionResult = VocaTranscription(
                text: texts[made.count], duration: 0.1, detectedLanguage: "en", audioLengthSeconds: 5, modelUsed: .tiny
            )
            made.append(service)
            return service
        })
        var progress: [CalibrationProgress] = []
        var loaded: [ModelSize] = []

        let rows = await runner.run(
            candidates: [candidate(.base), candidate(.tiny)],
            samples: samples, passage: passage, language: "en",
            isFirstLoad: { $0 == .tiny },
            didLoad: { loaded.append($0) },
            progress: { progress.append($0) }
        )

        XCTAssertEqual(rows.map(\.modelID), [ModelSize.base.rawValue, ModelSize.tiny.rawValue], "Best first")
        XCTAssertEqual(rows.first?.wordErrorRate, 0)
        XCTAssertGreaterThan(rows.last?.wordErrorRate ?? 0, 0.5)
        XCTAssertEqual(loaded, [.base, .tiny])
        XCTAssertEqual(progress.map(\.index), [0, 1])
        XCTAssertEqual(progress.map(\.isFirstLoad), [false, true])
        XCTAssertEqual(made.map { $0.loadRequests.first?.name }, [ModelSize.base.rawValue, ModelSize.tiny.rawValue])
        XCTAssertTrue(made.allSatisfy { !$0.isModelLoaded }, "Each test model is unloaded")
        XCTAssertTrue(made.allSatisfy { $0.lastTranscribedAudioData?.count == samples.count })
    }

    func testAFailingModelIsReportedAndTheRestStillRun() async {
        var count = 0
        let runner = CalibrationRunner(makeTranscriber: { _ in
            let service = MockWhisperService()
            service.shouldThrow = count == 0
            count += 1
            return service
        })
        let rows = await runner.run(
            candidates: [candidate(.tiny), candidate(.base)], samples: samples,
            passage: .everyday, language: "en"
        )
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.last?.modelID, ModelSize.tiny.rawValue, "Failures go last")
        XCTAssertNotNil(rows.last?.failure)
        XCTAssertNotNil(rows.first?.wordErrorRate)
    }

    func testAModelThatNoLongerFitsIsReportedNotLoaded() async {
        var made = 0
        let runner = CalibrationRunner(makeTranscriber: { _ in
            made += 1
            return MockWhisperService()
        })
        let rows = await runner.run(
            candidates: [candidate(.largeV3Latest), candidate(.tiny)], samples: samples,
            passage: .everyday, language: "en", canLoad: { $0 != .largeV3Latest }
        )
        XCTAssertEqual(made, 1, "The model that doesn't fit is never loaded")
        XCTAssertEqual(rows.last?.modelID, ModelSize.largeV3Latest.rawValue)
        XCTAssertEqual(rows.last?.failure, "Needs more free memory than this Mac has right now.")
    }

    func testCancelStopsBeforeTheNextModel() async {
        var runner: CalibrationRunner?
        runner = CalibrationRunner(makeTranscriber: { _ in MockWhisperService() })
        let rows = await runner?.run(
            candidates: [candidate(.tiny), candidate(.base), candidate(.small)], samples: samples,
            passage: .everyday, language: "en",
            progress: { progress in if progress.index == 1 { runner?.cancel() } }
        )
        // Cancelled while the second model was starting: it still finishes.
        XCTAssertEqual(rows?.count, 2)
    }
}

@MainActor
final class AppStateCalibrationTests: XCTestCase {

    private func info(_ size: ModelSize, downloaded: Bool = true, supported: Bool = true) -> WhisperModelInfo {
        WhisperModelInfo(size: size, filePath: nil, isDownloaded: downloaded, isActive: false, isSupported: supported)
    }

    func testCandidatesAreDownloadedSupportedLocalModelsThatFit() {
        let (appState, _) = AppState.makeTestState()
        appState.availableModels = [
            info(.tiny), info(.base, downloaded: false), info(.small, supported: false),
            info(.largeV3Latest), info(.customEndpoint),
        ]
        appState.modelFitsInMemory = { size, _ in size != .largeV3Latest }

        let (candidates, skipped) = appState.calibrationCandidates()

        XCTAssertEqual(candidates.map(\.size), [.tiny])
        XCTAssertEqual(skipped.map(\.modelID), [ModelSize.largeV3Latest.rawValue])
        XCTAssertNotNil(skipped.first?.failure)
    }

    func testCandidatesCountTheMemoryTheDictationModelFrees() {
        let (appState, mocks) = AppState.makeTestState()
        appState.availableModels = [info(.base)]
        mocks.whisperService.isModelLoaded = true
        appState.currentModel = info(.largeV3Latest)
        // Fits only with the outgoing model's memory credited.
        appState.modelFitsInMemory = { _, freeing in freeing >= ModelSize.largeV3Latest.ramRequiredGB }
        XCTAssertEqual(appState.calibrationCandidates().candidates.map(\.size), [.base])

        mocks.whisperService.isModelLoaded = false
        XCTAssertTrue(appState.calibrationCandidates().candidates.isEmpty, "Nothing to free when nothing is loaded")
    }

    func testRunningStoresTheResultAndRestoresDictation() async throws {
        let (appState, mocks) = AppState.makeTestState()
        appState.availableModels = [info(.tiny)]
        appState.modelFitsInMemory = { _, _ in true }
        appState.inputDeviceUIDResolver = { _ in "usb-mic" }
        let runner = CalibrationRunner(makeTranscriber: { _ in
            let service = MockWhisperService()
            service.mockTranscriptionResult = VocaTranscription(
                text: CalibrationPassage.everyday.text, duration: 0.1, detectedLanguage: "en",
                audioLengthSeconds: 5, modelUsed: .tiny
            )
            return service
        })
        let token = try XCTUnwrap(appState.beginCalibration())

        let result = await appState.runCalibration(
            samples: [Float](repeating: 0.1, count: 80_000), passage: .everyday,
            input: CalibrationInput(uid: "usb-mic", name: "USB Mic"), token: token, runner: runner, progress: { _ in }
        )

        XCTAssertEqual(result.best?.modelID, ModelSize.tiny.rawValue)
        XCTAssertEqual(result.deviceUID, "usb-mic", "The input that recorded, not the saved choice")
        XCTAssertEqual(result.deviceName, "USB Mic")
        XCTAssertEqual(appState.lastCalibration, result)
        XCTAssertEqual(appState.calibrationNote(for: .tiny), "0.0% word errors on your voice")
        XCTAssertFalse(appState.isCalibrating, "The test gives back its claim")
        XCTAssertTrue(mocks.whisperService.isModelLoaded, "The dictation model is loaded again")

        // The system input moved to another device: the result is for the old one.
        appState.inputDeviceUIDResolver = { _ in "built-in" }
        XCTAssertNil(appState.calibrationNote(for: .tiny))
    }

    func testOnlyOneTestAtATimeAndOnlyItsOwnerEndsIt() throws {
        let (appState, _) = AppState.makeTestState()
        let first = try XCTUnwrap(appState.beginCalibration())
        XCTAssertNil(appState.beginCalibration(), "A second test waits for the first")
        appState.endCalibration(UUID())
        XCTAssertTrue(appState.isCalibrating, "Another dialog can't end someone else's test")
        appState.endCalibration(first)
        XCTAssertFalse(appState.isCalibrating)
        XCTAssertNotNil(appState.beginCalibration())
    }

    func testDictationWaitsForTheTest() async throws {
        let (appState, mocks) = AppState.makeTestState()
        let token = try XCTUnwrap(appState.beginCalibration())
        await appState.startRecording()
        XCTAssertFalse(appState.isRecording)
        XCTAssertEqual(mocks.audioEngine.lastPreferredInputChannelCount, nil, "The microphone was never opened")
        appState.endCalibration(token)
    }

    func testHinglishIsLabelledAsARomanScriptTest() {
        XCTAssertTrue(CalibrationPassage.hinglish.title.contains("Roman script"))
        XCTAssertTrue(CalibrationPassage.hinglish.note?.contains("Devanagari") == true)
        XCTAssertEqual(CalibrationPassage.everyday.winnerPhrase, "heard you best")
    }
}
