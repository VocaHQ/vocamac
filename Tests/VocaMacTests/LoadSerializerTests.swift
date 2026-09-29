// LoadSerializerTests.swift
// VocaMac Tests
//
// Verifies that queued operations run one at a time and preserve order.

import XCTest

@testable import VocaMac

final class LoadSerializerTests: XCTestCase {

    func testOperationsRunSeriallyInOrder() async throws {
        let serializer = LoadSerializer()
        let lock = NSLock()
        var events: [String] = []

        func append(_ event: String) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        // The first operation must reach the serializer before the second is
        // queued, or the recorded order says nothing about serialization.
        // Sleeping for a guess loses that race whenever the machine is busy,
        // so hold the operation open until the test has queued the second one.
        let claimedQueue = expectation(description: "first operation started")
        let release = SerializerTestGate()

        async let first: Void = serializer.run {
            append("a-start")
            claimedQueue.fulfill()
            await release.wait()
            append("a-end")
        }

        await fulfillment(of: [claimedQueue], timeout: 5)

        async let second: Int = serializer.run {
            append("b-start")
            return 42
        }

        await release.open()

        try await first
        let value = try await second

        XCTAssertEqual(value, 42)
        XCTAssertEqual(events, ["a-start", "a-end", "b-start"])
    }

    func testAlreadyCancelledCallerDoesNotRunOperation() async {
        let serializer = LoadSerializer()
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await serializer.run { XCTFail("Cancelled operation ran"); return 1 }
        }
        do {
            _ = try await caller.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCancellationReachesRunningOperationAndQueueRecovers() async throws {
        let serializer = LoadSerializer()
        let gate = SerializerTestGate()
        let started = expectation(description: "operation started")
        let caller = Task {
            try await serializer.run {
                started.fulfill()
                await gate.wait()
                try Task.checkCancellation()
                return 1
            }
        }
        await fulfillment(of: [started], timeout: 2)
        caller.cancel()
        await gate.open()
        do {
            _ = try await caller.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let next = try await serializer.run { 2 }
        XCTAssertEqual(next, 2)
    }

    func testCancelledCleanupStillRuns() async throws {
        let serializer = LoadSerializer()
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await serializer.run(cancellable: false) {
                XCTAssertFalse(Task.isCancelled)
                return 3
            }
        }
        let result = try await caller.value
        XCTAssertEqual(result, 3)
    }

    func testCancelledQueuedOperationDoesNotRunOrBlockNextOperation() async throws {
        let serializer = LoadSerializer()
        let gate = SerializerTestGate()
        let started = expectation(description: "first operation started")
        let first = Task {
            try await serializer.run {
                started.fulfill()
                await gate.wait()
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let queued = Task {
            try await serializer.run { XCTFail("Cancelled queued operation ran") }
        }
        queued.cancel()
        await gate.open()
        try await first.value
        do {
            try await queued.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let next = try await serializer.run { 4 }
        XCTAssertEqual(next, 4)
    }

    func testFailureDoesNotBlockLaterOperations() async throws {
        let serializer = LoadSerializer()

        do {
            try await serializer.run {
                throw NSError(domain: "LoadSerializerTests", code: 1)
            }
            XCTFail("Expected the first operation to throw")
        } catch {
            // Expected.
        }

        let value = try await serializer.run { 7 }
        XCTAssertEqual(value, 7)
    }
}

private actor SerializerTestGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
