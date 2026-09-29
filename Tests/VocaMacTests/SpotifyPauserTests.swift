// SpotifyPauserTests.swift
// VocaMac Tests
//
// The pause-while-dictating policy against a fake Spotify. The player state
// is shared state the user also controls, so most of these pin down when the
// pauser must *not* touch it, and that what it pauses always comes back —
// even across a relaunch.

import XCTest
@testable import VocaMac

// MARK: - Fake Spotify

final class FakeSpotifyControl: SpotifyControlling {
    var isRunning = true
    var playerState: SpotifyPlayerState? = .playing
    var pauseSucceeds = true
    var playSucceeds = true

    private(set) var runningChecks = 0
    private(set) var stateReads = 0
    private(set) var pauseCallCount = 0
    private(set) var playCallCount = 0

    func isSpotifyRunning() -> Bool {
        runningChecks += 1
        return isRunning
    }

    func spotifyPlayerState() -> SpotifyPlayerState? {
        stateReads += 1
        return playerState
    }

    func pauseSpotify() -> Bool {
        pauseCallCount += 1
        if pauseSucceeds {
            playerState = .paused
        }
        return pauseSucceeds
    }

    func playSpotify() -> Bool {
        playCallCount += 1
        if playSucceeds {
            playerState = .playing
        }
        return playSucceeds
    }
}

// MARK: - Tests

final class SpotifyPauserTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var control: FakeSpotifyControl!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "SpotifyPauserTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        control = FakeSpotifyControl()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        control = nil
        super.tearDown()
    }

    /// A pauser whose work runs inline, so every test is synchronous.
    private func makePauser() -> SpotifyPauser {
        SpotifyPauser(
            control: control,
            defaults: defaults,
            now: { [unowned self] in self.clock },
            perform: { $0() },
            performSync: { $0() }
        )
    }

    // MARK: Pause

    func testPauseWhenPlaying() {
        makePauser().pause()

        XCTAssertEqual(control.pauseCallCount, 1)
        XCTAssertEqual(control.playerState, .paused)
    }

    func testPauseSkippedWhenSpotifyNotRunning() {
        control.isRunning = false

        makePauser().pause()

        XCTAssertEqual(control.pauseCallCount, 0)
        XCTAssertEqual(control.stateReads, 0, "A stopped Spotify must not get an Apple event — it would launch it")
    }

    func testPauseSkippedWhenAlreadyPaused() {
        control.playerState = .paused

        makePauser().pause()

        XCTAssertEqual(control.pauseCallCount, 0, "A pause the user made is not ours to resume")
    }

    func testPauseSkippedWhenStopped() {
        control.playerState = .stopped

        makePauser().pause()

        XCTAssertEqual(control.pauseCallCount, 0)
    }

    func testPauseSkippedWhenStateUnreadable() {
        control.playerState = nil

        makePauser().pause()

        XCTAssertEqual(control.pauseCallCount, 0, "Cannot tell playing from paused — leave it alone")
    }

    func testSecondPauseWhileOursIsPendingDoesNothing() {
        let pauser = makePauser()

        pauser.pause()
        pauser.pause()

        XCTAssertEqual(control.pauseCallCount, 1)
    }

    func testFailedPauseLeavesNothingToResume() {
        control.pauseSucceeds = false
        let pauser = makePauser()

        pauser.pause()
        pauser.resume()

        XCTAssertEqual(control.playCallCount, 0)
        XCTAssertNil(defaults.object(forKey: SpotifyPauser.pendingPauseKey))
    }

    // MARK: Resume

    func testResumePlaysWhatWePaused() {
        let pauser = makePauser()

        pauser.pause()
        pauser.resume()

        XCTAssertEqual(control.playCallCount, 1)
        XCTAssertEqual(control.playerState, .playing)
    }

    func testResumeWithoutAPauseIsNoOp() {
        makePauser().resume()

        XCTAssertEqual(control.playCallCount, 0)
        XCTAssertEqual(control.stateReads, 0)
    }

    func testResumeSkippedWhenSpotifyQuit() {
        let pauser = makePauser()
        pauser.pause()
        control.isRunning = false

        pauser.resume()

        XCTAssertEqual(control.playCallCount, 0, "A quit Spotify is left alone, not relaunched")
    }

    func testResumeSkippedWhenUserAlreadyResumed() {
        let pauser = makePauser()
        pauser.pause()
        control.playerState = .playing  // the user hit play mid-recording

        pauser.resume()

        XCTAssertEqual(control.playCallCount, 0, "Playback the user restarted is left alone")
    }

    func testResumeSkippedWhenUserStopped() {
        let pauser = makePauser()
        pauser.pause()
        control.playerState = .stopped

        pauser.resume()

        XCTAssertEqual(control.playCallCount, 0, "Play on a stopped Spotify would start a track — leave it")
    }

    func testResumePlaysWhenStillPaused() {
        // A pause the user made after ours is indistinguishable from ours —
        // the same trade-off AudioDucker accepts for mutes.
        let pauser = makePauser()
        pauser.pause()
        control.playerState = .playing
        control.playerState = .paused

        pauser.resume()

        XCTAssertEqual(control.playCallCount, 1)
    }

    func testPauseResumeCycles() {
        let pauser = makePauser()

        pauser.pause()
        pauser.resume()
        pauser.pause()
        pauser.resume()

        XCTAssertEqual(control.pauseCallCount, 2)
        XCTAssertEqual(control.playCallCount, 2)
        XCTAssertEqual(control.playerState, .playing)
    }

    // MARK: Unexpected exit

    func testPauseLeftPendingResumesOnNextLaunch() {
        makePauser().pause()
        // Process dies before resume: a new pauser over the same defaults is
        // the next launch.

        makePauser().resumeAfterUnexpectedExit()

        XCTAssertEqual(control.playCallCount, 1)
        XCTAssertNil(defaults.object(forKey: SpotifyPauser.pendingPauseKey))
    }

    func testResumeAfterUnexpectedExitWithoutAPauseDoesNothing() {
        makePauser().resumeAfterUnexpectedExit()

        XCTAssertEqual(control.playCallCount, 0)
        XCTAssertEqual(control.stateReads, 0)
    }

    func testStalePendingPauseIsDropped() {
        makePauser().pause()
        clock = clock.addingTimeInterval(SpotifyPauser.maxPendingAge + 1)

        makePauser().resumeAfterUnexpectedExit()

        XCTAssertEqual(control.playCallCount, 0)
        XCTAssertNil(defaults.object(forKey: SpotifyPauser.pendingPauseKey))
    }

    func testCleanResumeLeavesNoRecordForNextLaunch() {
        let pauser = makePauser()

        pauser.pause()
        pauser.resume()
        makePauser().resumeAfterUnexpectedExit()

        XCTAssertEqual(control.playCallCount, 1, "Only the one play from resume")
    }

    func testFailedResumeKeepsTheRecordForNextLaunch() {
        let pauser = makePauser()
        pauser.pause()
        control.playSucceeds = false

        pauser.resume()

        XCTAssertEqual(control.playCallCount, 1)
        XCTAssertNotNil(defaults.object(forKey: SpotifyPauser.pendingPauseKey))

        control.playSucceeds = true
        makePauser().resumeAfterUnexpectedExit()

        XCTAssertEqual(control.playCallCount, 2, "Next launch retries the play that failed")
        XCTAssertNil(defaults.object(forKey: SpotifyPauser.pendingPauseKey))
    }

    func testResumeWithUnreadableStateKeepsTheRecord() {
        let pauser = makePauser()
        pauser.pause()
        control.playerState = nil

        pauser.resume()

        XCTAssertEqual(control.playCallCount, 0)
        XCTAssertNotNil(defaults.object(forKey: SpotifyPauser.pendingPauseKey))
    }

    // MARK: Termination resume

    func testResumeSynchronouslyForTerminationDrainsBeforeReturning() {
        let queue = DispatchQueue(label: "SpotifyPauserTests.terminate")
        let pauser = SpotifyPauser(
            control: control,
            defaults: defaults,
            now: { [unowned self] in self.clock },
            perform: { work in queue.async(execute: work) },
            performSync: { work in queue.sync(execute: work) }
        )

        pauser.pause()
        queue.sync {}  // drain the async pause so `paused` is set

        XCTAssertEqual(control.pauseCallCount, 1)
        XCTAssertEqual(control.playerState, .paused)

        pauser.resumeSynchronouslyForTermination()

        XCTAssertEqual(control.playCallCount, 1, "play must have run before resumeSynchronouslyForTermination returns")
        XCTAssertEqual(control.playerState, .playing)
    }

    func testResumeSynchronouslyForTerminationWithoutAPauseIsNoOp() {
        makePauser().resumeSynchronouslyForTermination()

        XCTAssertEqual(control.playCallCount, 0)
        XCTAssertEqual(control.stateReads, 0)
    }
}
