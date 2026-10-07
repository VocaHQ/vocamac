// SpotifyPauser.swift
// VocaMac
//
// Pauses Spotify while a recording is open and resumes it afterwards — the
// piece of "mute other audio" that muting cannot cover: Spotify Connect
// plays through another device entirely, so the Mac's mixer never sees it.
// Only a transport pause reaches it.

import AppKit
import Foundation

// MARK: - SpotifyPlayerState

/// Spotify's `player state` AppleScript value.
enum SpotifyPlayerState: Equatable {
    case playing
    case paused
    case stopped
}

// MARK: - SpotifyControlling

/// The Spotify surface `SpotifyPauser` depends on, kept behind a protocol so
/// the policy can be tested without Apple events or a running Spotify.
protocol SpotifyControlling: AnyObject {
    /// Whether Spotify.app is running. Cheap, and — unlike an Apple event —
    /// never launches it.
    func isSpotifyRunning() -> Bool

    /// The player state, or `nil` when it cannot be read (e.g. macOS denied
    /// the Automation permission).
    func spotifyPlayerState() -> SpotifyPlayerState?

    /// Sends pause. Returns `false` on failure.
    @discardableResult
    func pauseSpotify() -> Bool

    /// Sends play. Returns `false` on failure.
    @discardableResult
    func playSpotify() -> Bool
}

// MARK: - AppleScriptSpotifyControl

/// NSAppleScript implementation of `SpotifyControlling`. Policy is covered by
/// unit tests against an injectable fake; this AppleScript path is verified
/// manually against a real Spotify (no live e2e in CI). Behaviour depends on
/// Spotify being installed and on the user granting Automation permission
/// (one consent prompt per Mac; denial comes back as error -1743).
final class AppleScriptSpotifyControl: SpotifyControlling {

    private static let bundleID = "com.spotify.client"

    /// `tell application "Spotify"` launches it when it is not running, so the
    /// process check is answered without an Apple event.
    func isSpotifyRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
            .contains { !$0.isTerminated }
    }

    func spotifyPlayerState() -> SpotifyPlayerState? {
        guard let result = run("get player state"),
              result.descriptorType == typeEnumerated else { return nil }
        switch result.enumCodeValue {
        case Self.fourCharCode("kPSP"):
            return .playing
        case Self.fourCharCode("kPSp"):
            return .paused
        case Self.fourCharCode("kPSS"):
            return .stopped
        default:
            VocaLogger.warning(.spotifyPauser, "Unknown Spotify player state \(result.enumCodeValue)")
            return nil
        }
    }

    @discardableResult
    func pauseSpotify() -> Bool {
        run("pause") != nil
    }

    @discardableResult
    func playSpotify() -> Bool {
        run("play") != nil
    }

    /// Runs `command` inside `tell application "Spotify"` and returns the
    /// result, or `nil` on a compile or execution error.
    private func run(_ command: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: "tell application \"Spotify\" to \(command)") else {
            return nil
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] ?? errorInfo
            VocaLogger.warning(.spotifyPauser, "Spotify AppleScript failed: \(message)")
            return nil
        }
        return result
    }

    /// The four-character code `abcd` as an OSType, for AppleScript enum
    /// values like `kPSP` ("player state playing").
    private static func fourCharCode(_ code: String) -> OSType {
        code.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }
}

// MARK: - SpotifyPauser

/// Pauses Spotify for the duration of a recording and resumes it afterwards.
/// The player state is shared system state, so the rules are conservative:
///
/// - Only pause when Spotify is running and actually playing.
/// - Only resume a pause this class made, and only while Spotify is still
///   paused — playback the user restarted is left alone.
/// - A pause is persisted until undone, so a quit or crash mid-recording is
///   still resumed on the next launch.
///
/// The work runs on a serial queue rather than the caller's thread: a first
/// run can block on macOS's Automation consent prompt, which must never stall
/// dictation. Ordering pause before resume is the queue's job. Quit is the
/// exception: `resumeSynchronouslyForTermination` waits on that queue so
/// AppleScript play can finish before process exit, but only up to a short
/// hard timeout so Automation consent or a hung Spotify cannot stall quit
/// indefinitely. A pause that does not finish in time stays pending for
/// next-launch recovery.
///
/// A pause the user undoes mid-recording and a pause the user makes
/// mid-recording look identical to ours — the resume at recording end sends
/// `play` either way, the same trade-off `AudioDucker` accepts for mutes.
final class SpotifyPauser: SpotifyPausing {

    static let pendingPauseKey = "vocamac.pauseSpotify.pendingPause"

    /// A pending pause older than this is dropped rather than applied: the
    /// user has had plenty of time to reach for Spotify themselves.
    static let maxPendingAge: TimeInterval = 24 * 60 * 60

    /// Default bound for quit-path resume: long enough for a normal AppleScript
    /// round-trip, short enough that Automation consent / hung Spotify cannot
    /// hold termination open.
    static let terminationResumeTimeout: TimeInterval = 1.5

    private let control: SpotifyControlling
    private let defaults: UserDefaults
    private let now: () -> Date
    /// Runs `work` for `pause`, `resume`, and `resumeAfterUnexpectedExit` in
    /// call order. Production passes a serial background queue; tests run the
    /// work inline so the policy is synchronous there.
    private let perform: (@escaping () -> Void) -> Void
    /// Runs `work` for `resumeSynchronouslyForTermination` on the same serial
    /// queue as `perform`, waiting up to `timeout` for it — and any earlier
    /// `perform` work — to finish. Production enqueues then `wait`s; tests
    /// run it inline (ignoring the timeout).
    private let performSync: (TimeInterval, @escaping () -> Void) -> Void

    /// Whether a `pause` is in effect, i.e. we told Spotify to pause and have
    /// not undone it. Touched only from inside `perform` / `performSync`.
    private var paused = false

    private static let workQueue = DispatchQueue(label: "com.vocamac.spotify-pauser")

    init(
        control: SpotifyControlling = AppleScriptSpotifyControl(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        perform: @escaping (@escaping () -> Void) -> Void = { work in
            // Everything the pauser does with its state runs on this one
            // serial queue, so the work may cross to it.
            nonisolated(unsafe) let work = work
            SpotifyPauser.workQueue.async { work() }
        },
        performSync: @escaping (TimeInterval, @escaping () -> Void) -> Void = { timeout, work in
            let item = DispatchWorkItem(block: work)
            SpotifyPauser.workQueue.async(execute: item)
            _ = item.wait(timeout: .now() + timeout)
        }
    ) {
        self.control = control
        self.defaults = defaults
        self.now = now
        self.perform = perform
        self.performSync = performSync
    }

    // MARK: SpotifyPausing

    func pause() {
        perform { [self] in
            guard !paused else {
                VocaLogger.debug(.spotifyPauser, "Spotify is already paused by us — leaving it")
                return
            }
            guard control.isSpotifyRunning() else {
                VocaLogger.debug(.spotifyPauser, "Spotify is not running — nothing to pause")
                return
            }
            guard let state = control.spotifyPlayerState() else {
                VocaLogger.warning(.spotifyPauser, "Could not read Spotify's player state — leaving it alone")
                return
            }
            guard state == .playing else {
                VocaLogger.debug(.spotifyPauser, "Spotify is not playing — nothing to pause")
                return
            }
            guard control.pauseSpotify() else {
                VocaLogger.warning(.spotifyPauser, "Could not pause Spotify")
                return
            }
            paused = true
            persistPause()
            VocaLogger.info(.spotifyPauser, "Paused Spotify while dictating")
        }
    }

    func resume() {
        perform { [self] in
            resumeIfPaused(reason: "recording ended")
        }
    }

    func resumeSynchronouslyForTermination(timeout: TimeInterval = SpotifyPauser.terminationResumeTimeout) {
        performSync(timeout) { [self] in
            resumeIfPaused(reason: "app terminating")
        }
    }

    func resumeAfterUnexpectedExit() {
        perform { [self] in
            guard let date = persistedPause() else { return }
            guard now().timeIntervalSince(date) <= Self.maxPendingAge else {
                clearPersistedPause()
                VocaLogger.info(.spotifyPauser, "Dropping a Spotify pause too old to undo safely")
                return
            }
            if resumeSpotify(reason: "previous run ended while paused") {
                clearPersistedPause()
            }
        }
    }

    // MARK: Undo

    /// Shared resume body for in-session `resume` and quit. Touched only from
    /// inside `perform` / `performSync`.
    private func resumeIfPaused(reason: String) {
        guard paused else { return }
        paused = false
        if resumeSpotify(reason: reason) {
            clearPersistedPause()
        }
    }

    /// Plays what `pause` paused, if Spotify is still paused — the same
    /// "undo only what is still as we left it" rule `AudioDucker` uses.
    /// - Returns: `true` when nothing is left to undo (played, user already
    ///   resumed, or Spotify is gone), `false` when the play failed and a
    ///   retry at next launch may still help.
    private func resumeSpotify(reason: String) -> Bool {
        guard control.isSpotifyRunning() else {
            VocaLogger.debug(.spotifyPauser, "Spotify is not running — nothing to resume (\(reason))")
            return true
        }
        guard let state = control.spotifyPlayerState() else {
            VocaLogger.warning(.spotifyPauser, "Could not read Spotify's player state — will retry at next launch (\(reason))")
            return false
        }
        guard state == .paused else {
            VocaLogger.debug(.spotifyPauser, "Spotify is no longer paused — leaving it as the user set it (\(reason))")
            return true
        }
        guard control.playSpotify() else {
            VocaLogger.warning(.spotifyPauser, "Could not resume Spotify — will retry at next launch (\(reason))")
            return false
        }
        VocaLogger.info(.spotifyPauser, "Resumed Spotify (\(reason))")
        return true
    }

    // MARK: Persistence

    /// Remembers the pause so a quit or crash before `resume` can still be
    /// undone on the next launch. A `Date` is a plist value, so no Codable
    /// record is needed.
    private func persistPause() {
        defaults.set(now(), forKey: Self.pendingPauseKey)
    }

    private func persistedPause() -> Date? {
        defaults.object(forKey: Self.pendingPauseKey) as? Date
    }

    private func clearPersistedPause() {
        defaults.removeObject(forKey: Self.pendingPauseKey)
    }
}
