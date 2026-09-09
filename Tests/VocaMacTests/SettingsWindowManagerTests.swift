// SettingsWindowManagerTests.swift
// VocaMac Tests
//
// Durable Settings navigation: requested page and pair-phone presentation
// must survive until SettingsView / GatewaySettingsTab consume them.

import XCTest
@testable import VocaMac

@MainActor
final class SettingsWindowManagerTests: XCTestCase {

    func testRequestedPageIsDurableUntilConsumed() {
        let manager = SettingsWindowManager()
        manager.recordOpenRequest(page: .gateway)

        XCTAssertEqual(manager.requestedPage, .gateway)
        XCTAssertEqual(manager.consumeRequestedPage(), .gateway)
        XCTAssertNil(manager.requestedPage)
        XCTAssertNil(manager.consumeRequestedPage())
    }

    func testPairingPresentationIsDurableUntilConsumed() {
        let manager = SettingsWindowManager()
        manager.recordOpenRequest(page: .gateway, showPairing: true)

        XCTAssertTrue(manager.pendingPairingPresentation)
        XCTAssertTrue(manager.consumePendingPairingPresentation(canPresent: true))
        XCTAssertFalse(manager.pendingPairingPresentation)
        XCTAssertFalse(manager.consumePendingPairingPresentation(canPresent: true))
    }

    func testPairingPresentationIsNotConsumedUntilPresentable() {
        let manager = SettingsWindowManager()
        manager.recordOpenRequest(page: .gateway, showPairing: true)

        XCTAssertTrue(manager.pendingPairingPresentation)
        XCTAssertFalse(manager.consumePendingPairingPresentation(canPresent: false))
        XCTAssertTrue(manager.pendingPairingPresentation)
        XCTAssertTrue(manager.consumePendingPairingPresentation(canPresent: true))
        XCTAssertFalse(manager.pendingPairingPresentation)
    }

    func testPairingRequestDefaultsToGatewayPage() {
        let manager = SettingsWindowManager()
        manager.recordOpenRequest(showPairing: true)

        XCTAssertEqual(manager.requestedPage, .gateway)
        XCTAssertTrue(manager.pendingPairingPresentation)
        XCTAssertEqual(manager.consumeRequestedPage(), .gateway)
        XCTAssertTrue(manager.consumePendingPairingPresentation(canPresent: true))
    }

    func testPageRequestDoesNotImplyPairing() {
        let manager = SettingsWindowManager()
        manager.recordOpenRequest(page: .audio)

        XCTAssertEqual(manager.requestedPage, .audio)
        XCTAssertFalse(manager.pendingPairingPresentation)
    }
}
