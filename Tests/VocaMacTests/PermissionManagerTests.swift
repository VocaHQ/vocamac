// PermissionManagerTests.swift
// VocaMac
//
// Tests for the PermissionManager service.

import XCTest
@testable import VocaMac

// MARK: - PermissionStatus Tests

final class PermissionStatusTests: XCTestCase {

    func testRawValues() {
        XCTAssertEqual(PermissionStatus.notDetermined.rawValue, "notDetermined")
        XCTAssertEqual(PermissionStatus.granted.rawValue, "granted")
        XCTAssertEqual(PermissionStatus.denied.rawValue, "denied")
    }

    func testAllCasesAreDistinct() {
        let cases: [PermissionStatus] = [.notDetermined, .granted, .denied]
        let unique = Set(cases.map { $0.rawValue })
        XCTAssertEqual(unique.count, 3, "All PermissionStatus cases should have unique raw values")
    }

    func testEquality() {
        XCTAssertEqual(PermissionStatus.granted, PermissionStatus.granted)
        XCTAssertNotEqual(PermissionStatus.granted, PermissionStatus.denied)
        XCTAssertNotEqual(PermissionStatus.notDetermined, PermissionStatus.granted)
    }
}

// MARK: - PermissionManager Tests (with mocks)

@MainActor
final class PermissionManagerTests: XCTestCase {

    func testInitialPermissionStates() {
        let manager = MockPermissionManager()

        XCTAssertEqual(manager.micPermission, .granted)
        XCTAssertEqual(manager.accessibilityPermission, .granted)
        XCTAssertEqual(manager.inputMonitoringPermission, .granted)
    }

    func testAllPermissionsGrantedWhenNoneGranted() {
        let manager = MockPermissionManager()
        manager.micPermission = .denied
        manager.accessibilityPermission = .denied
        manager.inputMonitoringPermission = .denied

        XCTAssertFalse(manager.allPermissionsGranted,
                       "allPermissionsGranted should be false when no permissions are granted")
    }

    func testCheckPermissionsUpdatesCallCount() {
        let manager = MockPermissionManager()

        manager.checkPermissions()

        XCTAssertEqual(manager.checkPermissionsCallCount, 1,
                       "checkPermissions should increment call count")
    }

    func testStopPermissionPollingIsIdempotent() {
        let manager = MockPermissionManager()

        manager.stopPermissionPolling()
        manager.stopPermissionPolling()
        XCTAssertEqual(manager.stopPollingCallCount, 2)
    }

    func testOnAllPermissionsGrantedCallbackCanBeSet() {
        let manager = MockPermissionManager()

        var callbackCalled = false
        manager.onAllPermissionsGranted = {
            callbackCalled = true
        }

        XCTAssertNotNil(manager.onAllPermissionsGranted)
        manager.onAllPermissionsGranted?()
        XCTAssertTrue(callbackCalled, "Callback should be invokable")
    }

    func testPermissionManagerWithMockDeps() {
        let audioEngine = MockAudioEngine()
        let hotKeyManager = MockHotKeyManager()
        let manager = PermissionManager(audioEngine: audioEngine, hotKeyManager: hotKeyManager)

        XCTAssertEqual(manager.micPermission, .notDetermined)
        XCTAssertEqual(manager.accessibilityPermission, .notDetermined)
    }
}

// MARK: - Permission Polling Decision

@MainActor
final class PermissionPollingDecisionTests: XCTestCase {

    func testKeepsPollingWhileAPermissionIsMissing() {
        XCTAssertEqual(
            PermissionManager.pollingDecision(allPermissionsGranted: false, isHotKeyTapHealthy: false, hotKeyRestartPolls: 50),
            .keepPolling
        )
    }

    func testStopsOnceTheHotKeyWorks() {
        XCTAssertEqual(
            PermissionManager.pollingDecision(allPermissionsGranted: true, isHotKeyTapHealthy: true, hotKeyRestartPolls: 3),
            .stop
        )
    }

    func testRetriesAFailedHotKeyRestartForAWhile() {
        XCTAssertEqual(
            PermissionManager.pollingDecision(allPermissionsGranted: true, isHotKeyTapHealthy: false, hotKeyRestartPolls: 1),
            .keepPolling
        )
        XCTAssertEqual(
            PermissionManager.pollingDecision(
                allPermissionsGranted: true, isHotKeyTapHealthy: false,
                hotKeyRestartPolls: PermissionManager.maxHotKeyRestartPolls - 1
            ),
            .keepPolling
        )
    }

    func testGivesUpOnTheHotKeyAfterTheRetryWindow() {
        XCTAssertEqual(
            PermissionManager.pollingDecision(
                allPermissionsGranted: true, isHotKeyTapHealthy: false,
                hotKeyRestartPolls: PermissionManager.maxHotKeyRestartPolls
            ),
            .giveUpOnHotKey
        )
    }
}
