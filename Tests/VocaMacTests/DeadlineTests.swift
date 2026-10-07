// DeadlineTests.swift
// VocaMac Tests
//
// A load or decode that never returns must not hold the engine queue.

import XCTest
@testable import VocaMac

final class DeadlineTests: XCTestCase {

    func testReturnsTheOperationsValue() async throws {
        let value = try await Deadline.run(seconds: 5, operation: "Quick") { 42 }
        XCTAssertEqual(value, 42)
    }

    func testRethrowsTheOperationsError() async {
        struct Failure: Error {}
        do {
            _ = try await Deadline.run(seconds: 5, operation: "Failing") { () async throws -> Int in throw Failure() }
            XCTFail("Expected the operation's error")
        } catch {
            XCTAssertTrue(error is Failure)
        }
    }

    func testGivesUpOnAnOperationThatNeverReturns() async {
        let started = Date()
        do {
            _ = try await Deadline.run(seconds: 0.1, operation: "Stuck") { () async throws -> Int in
                await Self.neverReturns()
                return 0
            }
            XCTFail("Expected a deadline error")
        } catch let error as Deadline.Exceeded {
            XCTAssertEqual(error.operation, "Stuck")
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "Returned at the deadline, not when the work ended")
    }

    func testCancelledCallerWaitsForACooperativeOperation() async throws {
        let finished = Flag()
        let task = Task {
            try await Deadline.run(seconds: .infinity, abandonAfterCancel: 5, operation: "Cooperative") {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch {
                    finished.set()
                    throw error
                }
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let result = await task.result
        XCTAssertTrue(finished.isSet, "The operation stopped before the caller moved on")
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
    }

    func testCancelledCallerAbandonsAnOperationThatIgnoresIt() async throws {
        let task = Task {
            try await Deadline.run(seconds: .infinity, abandonAfterCancel: 0.1, operation: "Deaf") {
                await Self.neverReturns()
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let started = Date()
        task.cancel()
        let result = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is Deadline.Abandoned) }
    }

    func testDecodeAllowanceGrowsWithTheAudio() {
        XCTAssertEqual(Deadline.decodeSeconds(audioSeconds: 2), 60)
        XCTAssertEqual(Deadline.decodeSeconds(audioSeconds: 120), 390)
    }

    /// Ignores cancellation and never finishes, like a CoreML call that hung.
    private static func neverReturns() async {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    }
}

/// Set once from any thread.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
