// SilentInputMonitor.swift
// VocaMac
//
// Notices a microphone that delivers only silence: muted in hardware, a dead
// route, the wrong input. Pure, so the timing is testable without audio.

import Foundation

/// Decides, level by level, whether the recording has had nothing but
/// silence for long enough to say so.
///
/// One-sided: the floor is far below the noise of any working microphone in
/// a quiet room, so only a microphone that sends (nearly) digital silence is
/// reported. One loud enough level clears the warning for the rest of the
/// recording.
struct SilentInputMonitor: Equatable {
    /// Seconds of silence before the warning shows.
    static let window: TimeInterval = 2.0
    /// Normalised level (RMS / 0.3, as `AudioEngine.onAudioLevel` reports
    /// it) below which a buffer counts as silence: about -84 dBFS.
    static let floor: Float = 0.0002

    private(set) var firstLevelAt: Date?
    private(set) var heardSound = false
    private(set) var isWarning = false

    /// Take one level report; returns whether to warn now.
    mutating func observe(level: Float, at now: Date) -> Bool {
        guard !heardSound else { return false }
        if level >= Self.floor {
            heardSound = true
            isWarning = false
            return false
        }
        guard let firstLevelAt else {
            firstLevelAt = now
            return false
        }
        isWarning = now.timeIntervalSince(firstLevelAt) >= Self.window
        return isWarning
    }
}
