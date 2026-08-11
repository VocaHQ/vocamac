// ModelKeepAliveTests.swift
// VocaMac Tests

import XCTest
@testable import VocaMac

@MainActor
final class ModelKeepAliveTests: XCTestCase {

    func testClampIdleTimeout() {
        XCTAssertEqual(ModelKeepAlive.clampIdleTimeout(10), 60)
        XCTAssertEqual(ModelKeepAlive.clampIdleTimeout(300), 300)
        XCTAssertEqual(ModelKeepAlive.clampIdleTimeout(99999), 3600)
        XCTAssertEqual(ModelKeepAlive.clampIdleTimeout(.nan), 300)
    }

    func testBumpArmsAndFireUnloadsWhenSafe() {
        var unloadCount = 0
        var enabled = true
        var safe = true

        let keepAlive = ModelKeepAlive(
            getConfig: { (enabled, 120) },
            onIdleUnload: { unloadCount += 1 },
            isSafeToUnload: { safe },
            useTimer: false
        )
        keepAlive.start()
        keepAlive.bump()
        XCTAssertTrue(keepAlive.isArmed)

        XCTAssertTrue(keepAlive.fireIfDue())
        XCTAssertEqual(unloadCount, 1)
        XCTAssertFalse(keepAlive.isArmed)
    }

    func testFireSkippedWhenUnsafe() {
        var unloadCount = 0
        let keepAlive = ModelKeepAlive(
            getConfig: { (true, 120) },
            onIdleUnload: { unloadCount += 1 },
            isSafeToUnload: { false },
            useTimer: false
        )
        keepAlive.start()
        keepAlive.bump()
        XCTAssertFalse(keepAlive.fireIfDue())
        XCTAssertEqual(unloadCount, 0)
        XCTAssertFalse(keepAlive.isArmed)
    }

    func testDisabledCancelsArm() {
        var enabled = true
        let keepAlive = ModelKeepAlive(
            getConfig: { (enabled, 120) },
            useTimer: false
        )
        keepAlive.start()
        keepAlive.bump()
        XCTAssertTrue(keepAlive.isArmed)

        enabled = false
        keepAlive.bump()
        XCTAssertFalse(keepAlive.isArmed)
        XCTAssertFalse(keepAlive.fireIfDue())
    }

    func testCancelDisarms() {
        let keepAlive = ModelKeepAlive(
            getConfig: { (true, 120) },
            useTimer: false
        )
        keepAlive.start()
        keepAlive.bump()
        keepAlive.cancel()
        XCTAssertFalse(keepAlive.isArmed)
        XCTAssertFalse(keepAlive.fireIfDue())
    }

    func testFireRequiresStart() {
        let keepAlive = ModelKeepAlive(
            getConfig: { (true, 120) },
            useTimer: false
        )
        keepAlive.bump()
        XCTAssertFalse(keepAlive.isArmed)
        XCTAssertFalse(keepAlive.fireIfDue())
    }
}
