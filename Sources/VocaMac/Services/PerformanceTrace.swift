// PerformanceTrace.swift
// VocaMac

import Foundation
import os

/// Instruments-visible intervals for user-perceived dictation latency.
enum PerformanceTrace {
    struct Interval: @unchecked Sendable {
        fileprivate let name: StaticString
        fileprivate let id: OSSignpostID
    }

    private static let log = OSLog(subsystem: "com.vocamac", category: "Performance")

    static func begin(_ name: StaticString) -> Interval {
        let interval = Interval(name: name, id: OSSignpostID(log: log))
        os_signpost(.begin, log: log, name: name, signpostID: interval.id)
        return interval
    }

    static func end(_ interval: Interval) {
        os_signpost(.end, log: log, name: interval.name, signpostID: interval.id)
    }

    static func event(_ name: StaticString) {
        os_signpost(.event, log: log, name: name)
    }
}
