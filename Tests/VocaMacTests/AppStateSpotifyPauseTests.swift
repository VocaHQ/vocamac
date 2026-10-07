// AppStateSpotifyPauseTests.swift
// VocaMac Tests
//
// Spotify is paused once the microphone is live and resumed on every way a
// recording can end — the same contract as mute-while-dictating, for the
// playback muting cannot reach (Spotify Connect).

import AppKit
import XCTest
@testable import VocaMac

@MainActor
final class AppStateSpotifyPauseTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PreferenceKey.pauseSpotifyEnabled)
        UserDefaults.standard.removeObject(forKey: PreferenceKey.duckOtherAudioEnabled)
        UserDefaults.standard.removeObject(forKey: "vocamac.soundEffectsEnabled")
        super.tearDown()
    }

    private func makePausingState() -> (AppState, TestMocks) {
        let (appState, mocks) = AppState.makeTestState()
        appState.pauseSpotifyEnabled = true
        mocks.audioEngine.stopRecordingResult = [Float](repeating: 0.5, count: 16_000)
        return (appState, mocks)
    }

    // MARK: Start

    func testStartPausesWhenEnabled() async {
        let (appState, mocks) = makePausingState()

        await appState.startRecording()

        XCTAssertEqual(mocks.spotifyPauser.pauseCallCount, 1)
        XCTAssertEqual(mocks.spotifyPauser.resumeCallCount, 0, "Still recording — nothing to resume yet")
    }

    func testSettingOffMeansSpotifyIsNeverPaused() async {
        let (appState, mocks) = makePausingState()
        appState.pauseSpotifyEnabled = false

        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.spotifyPauser.pauseCallCount, 0)
        XCTAssertEqual(
            mocks.spotifyPauser.resumeCallCount, 1,
            "Resume runs on every recording end — it is a no-op when nothing was paused"
        )
    }

    func testPauseIsNotHeldBackByTheCue() async {
        let (appState, mocks) = makePausingState()
        appState.duckOtherAudioEnabled = true
        appState.soundEffectsEnabled = true
        mocks.audioDucker.silencesOutput = false
        var cuesPlayedBeforePause: [MockSoundManager.PlayEvent]?
        mocks.audioDucker.onDuck = { cuesPlayedBeforePause = cuesPlayedBeforePause ?? mocks.soundManager.playLog }

        await appState.startRecording()

        XCTAssertEqual(mocks.spotifyPauser.pauseCallCount, 1)
        XCTAssertEqual(mocks.soundManager.startSoundAsyncCallCount, 0, "No awaited cue holds up the pause")
        XCTAssertEqual(cuesPlayedBeforePause, [], "Playback is silenced before the cue plays")
    }

    func testDeniedMicrophoneNeverPauses() async {
        let (appState, mocks) = makePausingState()
        mocks.permissionManager.micPermission = .denied

        await appState.startRecording()

        XCTAssertEqual(mocks.spotifyPauser.pauseCallCount, 0, "No microphone opened, so nothing to protect")
    }

    func testFailedAudioEngineStartNeverPauses() async {
        let (appState, mocks) = makePausingState()
        mocks.audioEngine.startRecordingResult = false

        await appState.startRecording()

        XCTAssertEqual(mocks.spotifyPauser.pauseCallCount, 0, "No live microphone, so playback is left alone")
        XCTAssertFalse(appState.isRecording)
    }

    // MARK: Every exit resumes

    func testStopResumes() async {
        let (appState, mocks) = makePausingState()

        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.spotifyPauser.resumeCallCount, 1)
    }

    func testCancelResumes() async {
        let (appState, mocks) = makePausingState()

        await appState.startRecording()
        await appState.cancelRecording()

        XCTAssertEqual(mocks.spotifyPauser.resumeCallCount, 1)
    }

    func testForceRecoveryResumes() async {
        let (appState, mocks) = makePausingState()

        await appState.startRecording()
        appState.forceRecovery()

        XCTAssertEqual(mocks.spotifyPauser.resumeCallCount, 1)
    }

    func testInputDeviceChangeMidRecordingResumes() async {
        let (appState, mocks) = makePausingState()

        await appState.startRecording()
        mocks.audioEngine.onAudioDeviceChanged?()
        // The handler hops to the main actor.
        for _ in 0..<5 { await Task.yield() }

        XCTAssertFalse(appState.isRecording)
        XCTAssertEqual(mocks.spotifyPauser.resumeCallCount, 1)
    }

    func testResumeHappensOncePerRecording() async {
        let (appState, mocks) = makePausingState()

        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()
        appState.forceRecovery()

        XCTAssertEqual(
            mocks.spotifyPauser.resumeCallCount, 1,
            "Setting isRecording to false while already false must not fire another resume"
        )
    }

    // MARK: Startup

    func testStartupUndoesAPauseTheLastRunLeftBehind() async {
        let (appState, mocks) = makePausingState()

        await appState.performStartup()

        XCTAssertEqual(mocks.spotifyPauser.resumeAfterUnexpectedExitCallCount, 1)
    }

    // MARK: Termination

    func testWillTerminateResumesWhileStillRecording() async {
        let (appState, mocks) = makePausingState()

        await appState.startRecording()
        XCTAssertTrue(appState.isRecording)
        XCTAssertEqual(mocks.spotifyPauser.resumeCallCount, 0)

        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

        XCTAssertEqual(mocks.spotifyPauser.resumeSynchronouslyForTerminationCallCount, 1)
        XCTAssertEqual(
            mocks.spotifyPauser.lastTerminationResumeTimeout,
            SpotifyPauser.terminationResumeTimeout,
            "Quit must use the bounded sync resume, not the in-session async path"
        )
        XCTAssertEqual(mocks.spotifyPauser.resumeCallCount, 0, "Terminate must not take the in-session async resume path")
        XCTAssertTrue(appState.isRecording, "Quit does not flip isRecording; resume runs from willTerminate")
    }
}
