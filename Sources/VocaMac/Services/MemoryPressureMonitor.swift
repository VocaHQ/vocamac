// MemoryPressureMonitor.swift
// VocaMac
//
// Listens for the system's memory-pressure warnings so idle models can be
// handed back before macOS starts compressing and swapping other apps.

import Foundation

/// Reports when macOS says memory is running short.
///
/// A dispatch memory-pressure source fires on each change of level, not
/// continuously, so a warning arrives once per episode. Nothing is polled.
@MainActor
final class MemoryPressureMonitor {

    enum Level: String {
        case warning
        case critical
    }

    /// Called on the main actor when the system enters warning or critical.
    var onPressure: ((Level) -> Void)?

    private var source: DispatchSourceMemoryPressure?
    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            MainActor.assumeIsolated {
                guard let level = Self.level(for: event) else { return }
                VocaLogger.warning(.general, "System memory pressure: \(level.rawValue)")
                self?.onPressure?(level)
            }
        }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        isRunning = false
    }

    /// The level an event reports, or nil for a return to normal.
    nonisolated static func level(for event: DispatchSource.MemoryPressureEvent) -> Level? {
        if event.contains(.critical) { return .critical }
        if event.contains(.warning) { return .warning }
        return nil
    }
}
