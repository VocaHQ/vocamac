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

        async let first: Void = serializer.run {
            append("a-start")
            try await Task.sleep(nanoseconds: 50_000_000)
            append("a-end")
        }

        // Give the first operation a moment to claim the queue.
        try await Task.sleep(nanoseconds: 5_000_000)

        async let second: Int = serializer.run {
            append("b-start")
            return 42
        }

        try await first
        let value = try await second

        XCTAssertEqual(value, 42)
        XCTAssertEqual(events, ["a-start", "a-end", "b-start"])
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
