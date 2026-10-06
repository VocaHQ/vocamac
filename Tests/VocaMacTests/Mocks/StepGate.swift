// StepGate.swift
// VocaMac Tests
//
// Holds a mock at a chosen step until the test lets it go, so a test can
// act at exactly that step instead of guessing with sleeps.

import Foundation

final class StepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var reached = false

    /// Let everything waiting at the gate continue.
    func open() {
        lock.withLock { isOpen = true }
    }

    private var shouldWait: Bool {
        lock.withLock {
            reached = true
            return !isOpen
        }
    }

    /// Wait at the gate from synchronous code running off the main thread.
    func waitBlocking() {
        while shouldWait { Thread.sleep(forTimeInterval: 0.005) }
    }

    /// Wait at the gate from async code.
    func wait() async {
        while shouldWait { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    /// For the test: wait until the code under test has reached the gate.
    func waitUntilReached(timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lock.withLock({ reached }) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }
}
