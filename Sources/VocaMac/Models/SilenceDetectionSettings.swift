// SilenceDetectionSettings.swift
// VocaMac

import Foundation

/// Validation shared by the Audio settings UI and recording startup.
enum SilenceDetectionSettings {
    static let defaultDuration: TimeInterval = 2.0
    static let durationRange: ClosedRange<TimeInterval> = 0.5...300.0

    static func clampedDuration(_ duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite else { return defaultDuration }
        return min(max(duration, durationRange.lowerBound), durationRange.upperBound)
    }
}
