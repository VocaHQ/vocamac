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

// MARK: - Relaunch Advice

@MainActor
final class PermissionRelaunchAdviceTests: XCTestCase {

    func testAPermissionNobodyAskedForIsNotDetermined() {
        XCTAssertEqual(PermissionManager.status(granted: false, asked: false), .notDetermined)
        XCTAssertEqual(PermissionManager.status(granted: false, asked: true), .denied)
        XCTAssertEqual(PermissionManager.status(granted: true, asked: false), .granted)
    }

    func testNoAdviceBeforeTheUserWentToSystemSettings() {
        XCTAssertFalse(PermissionManager.mayNeedRelaunch(
            accessibility: .notDetermined, inputMonitoring: .notDetermined,
            requestedThisLaunch: [], hotKeyStuckAfterGrant: false
        ))
    }

    func testAdvisesARelaunchWhileARequestedPermissionIsStillOff() {
        XCTAssertTrue(PermissionManager.mayNeedRelaunch(
            accessibility: .granted, inputMonitoring: .denied,
            requestedThisLaunch: [.inputMonitoring], hotKeyStuckAfterGrant: false
        ))
    }

    func testIgnoresAMissingPermissionTheUserHasNotRequestedYet() {
        XCTAssertFalse(PermissionManager.mayNeedRelaunch(
            accessibility: .granted, inputMonitoring: .notDetermined,
            requestedThisLaunch: [.accessibility], hotKeyStuckAfterGrant: false
        ))
    }

    func testAdvisesARelaunchWhenTheHotKeyNeverCameUp() {
        XCTAssertTrue(PermissionManager.mayNeedRelaunch(
            accessibility: .granted, inputMonitoring: .granted,
            requestedThisLaunch: [], hotKeyStuckAfterGrant: true
        ))
    }

    func testForgettingRequestsClearsTheAskedFlags() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PermissionRelaunchAdviceTests"))
        defer { defaults.removePersistentDomain(forName: "PermissionRelaunchAdviceTests") }
        defaults.set(true, forKey: PreferenceKey.askedForAccessibility)
        defaults.set(true, forKey: PreferenceKey.askedForInputMonitoring)

        PermissionManager.forgetPermissionRequests(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: PreferenceKey.askedForAccessibility))
        XCTAssertNil(defaults.object(forKey: PreferenceKey.askedForInputMonitoring))
    }
}

// MARK: - Onboarding Resume

final class OnboardingResumeStepTests: XCTestCase {

    func testStartsOnWelcomeWithNothingSaved() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OnboardingResumeStepTests.empty"))
        defer { defaults.removePersistentDomain(forName: "OnboardingResumeStepTests.empty") }
        XCTAssertEqual(OnboardingStep.resumeStep(defaults: defaults), .welcome)
    }

    func testResumesOnTheSavedStep() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OnboardingResumeStepTests.saved"))
        defer { defaults.removePersistentDomain(forName: "OnboardingResumeStepTests.saved") }
        defaults.set(OnboardingStep.permissions.rawValue, forKey: PreferenceKey.onboardingResumeStep)
        XCTAssertEqual(OnboardingStep.resumeStep(defaults: defaults), .permissions)
    }

    func testFallsBackToWelcomeForAStepThatNoLongerExists() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OnboardingResumeStepTests.stale"))
        defer { defaults.removePersistentDomain(forName: "OnboardingResumeStepTests.stale") }
        defaults.set(99, forKey: PreferenceKey.onboardingResumeStep)
        XCTAssertEqual(OnboardingStep.resumeStep(defaults: defaults), .welcome)
    }
}
