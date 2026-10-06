// DictationPhaseTests.swift
// VocaMac Tests
//
// The dictation phase read from AppState's flags, the contradictions the
// state check reports, and that every start, stop, and cancel path leaves
// none behind.

import XCTest
@testable import VocaMac

final class DictationFlagsTests: XCTestCase {

    private func flags(
        _ status: AppStatus = .idle,
        recording: Bool = false,
        starting: Bool = false,
        stopping: Bool = false,
        loading: Bool = false,
        transcribing: Bool = false,
        media: Bool = false,
        pendingStart: Bool = false,
        pendingLoad: Bool = false
    ) -> DictationFlags {
        DictationFlags(
            appStatus: status, isRecording: recording, isStartingAudio: starting,
            isStoppingAudio: stopping, isLoadingModel: loading, isTranscribing: transcribing,
            isTranscribingMedia: media, hasPendingStopDuringStart: pendingStart,
            hasPendingStopDuringModelLoad: pendingLoad
        )
    }

    func testPhases() {
        XCTAssertEqual(flags().phase, .idle)
        XCTAssertEqual(flags(.processing, loading: true).phase, .loadingModel)
        XCTAssertEqual(flags(.recording, recording: true, starting: true).phase, .startingAudio)
        XCTAssertEqual(flags(.recording, recording: true).phase, .recording)
        XCTAssertEqual(flags(.recording, recording: true, stopping: true).phase, .stopping)
        XCTAssertEqual(flags(.processing, transcribing: true).phase, .transcribing)
        XCTAssertEqual(flags(.error).phase, .error)
        // Either recording flag alone still counts, as `isCapturingAudio` does.
        XCTAssertEqual(flags(.recording).phase, .recording)
        XCTAssertEqual(flags(.idle, recording: true).phase, .recording)
    }

    func testConsistentStatesHaveNoViolations() {
        XCTAssertEqual(flags().violations, [])
        XCTAssertEqual(flags(.recording, recording: true).violations, [])
        XCTAssertEqual(flags(.processing, transcribing: true).violations, [])
        XCTAssertEqual(flags(.processing, loading: true).violations, [])
        XCTAssertEqual(flags(.processing, media: true).violations, [])
        XCTAssertEqual(flags(.processing, loading: true, pendingLoad: true).violations, [])
        XCTAssertEqual(flags(.error).violations, [])
    }

    func testMicrophoneAndStatusDisagreeing() {
        XCTAssertEqual(flags(.idle, recording: true).violations, ["microphone is on but status is idle"])
        XCTAssertEqual(flags(.recording).violations, ["status is recording but the microphone is off"])
    }

    func testStaleProcessingStatus() {
        // The stuck "processing" state startRecording has to clear by hand.
        XCTAssertEqual(flags(.processing).violations, ["status is processing with nothing being processed"])
    }

    func testLeftoverStartAndStopFlags() {
        XCTAssertTrue(flags(.recording, recording: true, starting: true).violations
            .contains("a microphone start never finished"))
        XCTAssertTrue(flags(.recording, recording: true, stopping: true).violations
            .contains("a microphone stop never finished"))
        XCTAssertEqual(flags(pendingStart: true).violations, ["a stop is still waiting on a start that finished"])
        XCTAssertEqual(flags(pendingLoad: true).violations, ["a stop is still waiting on a model load that finished"])
    }

    func testDescriptionListsOnlyTheFlagsThatAreSet() {
        XCTAssertEqual(flags(.processing, transcribing: true).description, "status=processing transcribing")
        XCTAssertEqual(flags().description, "status=idle")
    }
}

/// Every path through start, stop, and cancel must leave the flags agreeing.
/// These are the paths the stuck-recording bugs came from.
@MainActor
final class DictationStateCheckTests: XCTestCase {

    private let speech = [Float](repeating: 0.2, count: 8_000)

    private func assertClean(_ appState: AppState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(appState.lastDictationStateViolations, [], file: file, line: line)
        XCTAssertEqual(appState.dictationFlags.violations, [], "\(appState.dictationFlags)", file: file, line: line)
    }

    func testDictationRoundTrip() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.audioEngine.stopRecordingResult = speech

        await appState.startRecording()
        XCTAssertEqual(appState.dictationPhase, .recording)
        XCTAssertTrue(appState.isCapturingAudio)
        assertClean(appState)

        await appState.stopRecordingAndTranscribe()
        XCTAssertEqual(appState.dictationPhase, .idle)
        XCTAssertFalse(appState.isCapturingAudio)
        assertClean(appState)
    }

    func testCancelledRecording() async {
        let (appState, _) = AppState.makeTestState()
        await appState.startRecording()
        await appState.cancelRecording()
        XCTAssertEqual(appState.dictationPhase, .idle)
        assertClean(appState)
    }

    func testFailedTranscription() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.whisperService.shouldThrow = true
        mocks.audioEngine.stopRecordingResult = speech
        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()
        XCTAssertEqual(appState.dictationPhase, .error)
        assertClean(appState)
    }

    func testSilentRecording() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.audioEngine.stopRecordingResult = [Float](repeating: 0, count: 8_000)
        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()
        assertClean(appState)
    }

    func testMicrophoneThatNeverStarts() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.audioEngine.startRecordingResult = false
        await appState.startRecording()
        XCTAssertFalse(appState.isCapturingAudio)
        assertClean(appState)
    }

    func testStopWhileTheMicrophoneIsConnecting() async {
        let (appState, mocks) = AppState.makeTestState()
        let gate = StepGate()
        mocks.audioEngine.startRecordingGate = gate
        let start = Task { await appState.startRecording() }
        let reachedGate = await gate.waitUntilReached()
        XCTAssertTrue(reachedGate)
        XCTAssertEqual(appState.dictationPhase, .startingAudio)
        await appState.stopRecordingAndTranscribe()
        gate.open()
        await start.value
        assertClean(appState)
    }

    func testCancelWhileTheMicrophoneIsConnecting() async {
        let (appState, mocks) = AppState.makeTestState()
        let gate = StepGate()
        mocks.audioEngine.startRecordingGate = gate
        let start = Task { await appState.startRecording() }
        let reachedGate = await gate.waitUntilReached()
        XCTAssertTrue(reachedGate)
        XCTAssertEqual(appState.dictationPhase, .startingAudio)
        await appState.cancelRecording()
        XCTAssertEqual(mocks.audioEngine.cancelPendingStartCallCount, 1, "Cancelled the start, not a running recording")
        gate.open()
        await start.value
        assertClean(appState)
    }

    func testReleaseWhileTheModelLoads() async {
        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.tiny]
        let whisperService = MockWhisperService()
        whisperService.loadedModelName = nil
        whisperService.isModelLoaded = false
        let gate = StepGate()
        whisperService.loadGate = gate
        let (appState, _) = AppState.makeTestState(modelManager: modelManager, whisperService: whisperService)
        let originalModel = appState.selectedModelSize
        defer { appState.selectedModelSize = originalModel }
        appState.selectedModelSize = ModelSize.tiny.rawValue

        let start = Task { await appState.startRecording() }
        let reachedGate = await gate.waitUntilReached()
        XCTAssertTrue(reachedGate)
        XCTAssertEqual(appState.dictationPhase, .loadingModel)
        await appState.stopRecordingAndTranscribe()
        gate.open()
        await start.value
        assertClean(appState)
    }

    func testEscapeWhileTranscribing() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.audioEngine.stopRecordingResult = speech
        let gate = StepGate()
        mocks.whisperService.transcribeGate = gate
        await appState.startRecording()
        let stop = Task { await appState.stopRecordingAndTranscribe() }
        let reachedGate = await gate.waitUntilReached()
        XCTAssertTrue(reachedGate)
        XCTAssertEqual(appState.dictationPhase, .transcribing)
        await appState.cancelDictation()
        gate.open()
        await stop.value
        XCTAssertEqual(appState.dictationPhase, .idle)
        assertClean(appState)
    }
}
