// AppStateDuckingTests.swift
// VocaMac Tests
//
// Other audio is muted once the microphone is live and restored on every way
// a recording can end — not only the happy path.

import AppKit
import XCTest
@testable import VocaMac

@MainActor
final class AppStateDuckingTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PreferenceKey.duckOtherAudioEnabled)
        UserDefaults.standard.removeObject(forKey: "vocamac.soundEffectsEnabled")
        super.tearDown()
    }

    private func makeDuckingState() -> (AppState, TestMocks) {
        let (appState, mocks) = AppState.makeTestState()
        appState.duckOtherAudioEnabled = true
        mocks.audioEngine.stopRecordingResult = [Float](repeating: 0.5, count: 16_000)
        return (appState, mocks)
    }

    // MARK: Start

    func testStartDucksWhenEnabled() async {
        let (appState, mocks) = makeDuckingState()

        await appState.startRecording()

        XCTAssertEqual(mocks.audioDucker.duckCallCount, 1)
        XCTAssertEqual(mocks.audioDucker.restoreCallCount, 0, "Still recording — nothing to restore yet")
    }

    func testSettingOffMeansOtherAudioIsNeverTouched() async {
        let (appState, mocks) = makeDuckingState()
        appState.duckOtherAudioEnabled = false

        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.audioDucker.duckCallCount, 0)
    }

    func testStartCueFinishesBeforeOtherAudioIsMuted() async {
        let (appState, mocks) = makeDuckingState()
        appState.soundEffectsEnabled = true
        var cuesPlayedBeforeMute: [MockSoundManager.PlayEvent] = []
        mocks.audioDucker.onDuck = { cuesPlayedBeforeMute = mocks.soundManager.playLog }

        await appState.startRecording()

        XCTAssertEqual(cuesPlayedBeforeMute, [.startAsync], "Muting first would silence the cue")
        XCTAssertEqual(mocks.soundManager.startSoundCallCount, 0)
    }

    func testCueStaysFireAndForgetWhenMutingIsOff() async {
        let (appState, mocks) = makeDuckingState()
        appState.duckOtherAudioEnabled = false
        appState.soundEffectsEnabled = true

        await appState.startRecording()

        XCTAssertEqual(mocks.soundManager.playLog, [.start])
    }

    func testRecordingThatEndsDuringTheCueIsNeverMuted() async {
        let (appState, mocks) = makeDuckingState()
        appState.soundEffectsEnabled = true
        mocks.soundManager.whileStartSoundAsyncPlays = { await appState.cancelRecording() }

        await appState.startRecording()

        XCTAssertFalse(appState.isRecording)
        XCTAssertEqual(mocks.audioDucker.duckCallCount, 0, "Muting after the recording ended would strand the mute")
    }

    func testDeniedMicrophoneNeverDucks() async {
        let (appState, mocks) = makeDuckingState()
        mocks.permissionManager.micPermission = .denied

        await appState.startRecording()

        XCTAssertEqual(mocks.audioDucker.duckCallCount, 0, "No microphone opened, so nothing to protect")
    }

    // MARK: Every exit restores

    func testStopRestores() async {
        let (appState, mocks) = makeDuckingState()

        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.audioDucker.restoreCallCount, 1)
    }

    func testCancelRestores() async {
        let (appState, mocks) = makeDuckingState()

        await appState.startRecording()
        await appState.cancelRecording()

        XCTAssertEqual(mocks.audioDucker.restoreCallCount, 1)
    }

    func testForceRecoveryRestores() async {
        let (appState, mocks) = makeDuckingState()

        await appState.startRecording()
        appState.forceRecovery()

        XCTAssertEqual(mocks.audioDucker.restoreCallCount, 1)
    }

    func testFailedAudioEngineStartNeverMutes() async {
        let (appState, mocks) = makeDuckingState()
        mocks.audioEngine.startRecordingResult = false

        await appState.startRecording()

        XCTAssertEqual(mocks.audioDucker.duckCallCount, 0, "No live microphone, so playback is left alone")
        XCTAssertFalse(appState.isRecording)
    }

    func testInputDeviceChangeMidRecordingRestores() async {
        let (appState, mocks) = makeDuckingState()

        await appState.startRecording()
        mocks.audioEngine.onAudioDeviceChanged?()
        // The handler hops to the main actor.
        for _ in 0..<5 { await Task.yield() }

        XCTAssertFalse(appState.isRecording)
        XCTAssertEqual(mocks.audioDucker.restoreCallCount, 1)
    }

    func testRestoreHappensOncePerRecording() async {
        let (appState, mocks) = makeDuckingState()

        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()
        appState.forceRecovery()

        XCTAssertEqual(
            mocks.audioDucker.restoreCallCount, 1,
            "Setting isRecording to false while already false must not fire another restore"
        )
    }

    // MARK: Startup

    func testStartupUndoesADuckTheLastRunLeftBehind() async {
        let (appState, mocks) = makeDuckingState()

        await appState.performStartup()

        XCTAssertEqual(mocks.audioDucker.restoreAfterUnexpectedExitCallCount, 1)
    }

    // MARK: Termination

    func testWillTerminateRestoresWhileStillRecording() async {
        let (appState, mocks) = makeDuckingState()

        await appState.startRecording()
        XCTAssertTrue(appState.isRecording)
        XCTAssertEqual(mocks.audioDucker.restoreCallCount, 0)

        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

        XCTAssertEqual(mocks.audioDucker.restoreCallCount, 1)
        XCTAssertEqual(mocks.statsManager.flushPendingSavesCallCount, 1)
        XCTAssertTrue(appState.isRecording, "Quit does not flip isRecording; restore runs from willTerminate")
    }

    func testCalendarChangesRefreshStatsStreak() {
        let (appState, mocks) = makeDuckingState()

        withExtendedLifetime(appState) {
            NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
            NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        }

        XCTAssertEqual(mocks.statsManager.refreshCurrentStreakCallCount, 2)
    }
}
