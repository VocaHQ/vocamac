// Eventually.swift
// VocaMac
//
// Waiting in tests for something to happen, instead of sleeping for a
// fixed time and hoping it did.

import Foundation
import XCTest

/// Wait until `condition` holds, checking every few milliseconds, and fail
/// the test if it hasn't within `timeout`. A fixed sleep is either longer
/// than needed or, on a loaded CI runner, too short; this waits exactly as
/// long as it takes.
@MainActor
func eventually(
    _ message: @autoclosure () -> String = "condition never became true",
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            XCTFail(message(), file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

/// `eventually` for a condition that has to be awaited, such as an actor's
/// state.
func eventuallyAsync(
    _ message: @autoclosure () -> String = "condition never became true",
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while await !condition() {
        guard Date() < deadline else {
            XCTFail(message(), file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

/// `eventually` for a synchronous test: blocks the calling thread while it
/// waits, so only for work that finishes on another queue (a log write).
@discardableResult
func eventuallyBlocking(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { return false }
        Thread.sleep(forTimeInterval: 0.002)
    }
    return true
}
