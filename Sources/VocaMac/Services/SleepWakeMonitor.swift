// SleepWakeMonitor.swift
// VocaMac
//
// Subscribes to NSWorkspace sleep/wake notifications for recovery hooks.

import Foundation
import AppKit

/// Observes system sleep and wake to harden audio/hotkey/model keep-alive recovery.
@MainActor
final class SleepWakeMonitor {

    var onWillSleep: (() -> Void)?
    var onDidWake: (() -> Void)?

    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                VocaLogger.info(.general, "System will sleep")
                self?.onWillSleep?()
            }
        }

        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                VocaLogger.info(.general, "System did wake")
                self?.onDidWake?()
            }
        }
    }

    func stop() {
        isRunning = false
        let center = NSWorkspace.shared.notificationCenter
        if let sleepObserver {
            center.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        if let wakeObserver {
            center.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    deinit {
        // Observers removed on stop(); avoid touching MainActor state from deinit.
    }
}
