// PermissionManagerTests.swift
// VocaMac
//
// Tests for the PermissionManager service.

import XCTest
import IOKit.hid
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

    func testNoAdviceWhileTheUserMayStillBeGranting() {
        // Asked, but VocaMac hasn't been reactivated since: nothing returned.
        XCTAssertFalse(PermissionManager.mayNeedRelaunch(
            accessibility: .denied, inputMonitoring: .denied,
            returnedAfterRequest: [], hotKeyStuckAfterGrant: false
        ))
    }

    func testNoAdviceBeforeTheUserWentToSystemSettings() {
        XCTAssertFalse(PermissionManager.mayNeedRelaunch(
            accessibility: .notDetermined, inputMonitoring: .notDetermined,
            returnedAfterRequest: [], hotKeyStuckAfterGrant: false
        ))
    }

    func testAdvisesARelaunchWhileARequestedPermissionIsStillOff() {
        XCTAssertTrue(PermissionManager.mayNeedRelaunch(
            accessibility: .granted, inputMonitoring: .denied,
            returnedAfterRequest: [.inputMonitoring], hotKeyStuckAfterGrant: false
        ))
    }

    func testIgnoresAMissingPermissionTheUserHasNotRequestedYet() {
        XCTAssertFalse(PermissionManager.mayNeedRelaunch(
            accessibility: .granted, inputMonitoring: .notDetermined,
            returnedAfterRequest: [.accessibility], hotKeyStuckAfterGrant: false
        ))
    }

    func testAwaitingGrantIgnoresTheHotKey() {
        XCTAssertFalse(PermissionManager.isAwaitingGrant(
            accessibility: .granted, inputMonitoring: .granted, returnedAfterRequest: [.accessibility]
        ))
        XCTAssertTrue(PermissionManager.isAwaitingGrant(
            accessibility: .denied, inputMonitoring: .granted, returnedAfterRequest: [.accessibility]
        ))
    }

    func testAdvisesARelaunchWhenTheHotKeyNeverCameUp() {
        XCTAssertTrue(PermissionManager.mayNeedRelaunch(
            accessibility: .granted, inputMonitoring: .granted,
            returnedAfterRequest: [], hotKeyStuckAfterGrant: true
        ))
    }

    func testForgettingRequestsClearsTheAskedFlags() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PermissionRelaunchAdviceTests"))
        defer { defaults.removePersistentDomain(forName: "PermissionRelaunchAdviceTests") }
        defaults.set(true, forKey: PreferenceKey.askedForAccessibility)
        defaults.set(true, forKey: PreferenceKey.askedForInputMonitoring)

        PermissionManager.forgetPermissionRequests(defaults: defaults)

        XCTAssertFalse(PermissionManager.hasAsked(for: .accessibility, defaults: defaults))
        XCTAssertFalse(PermissionManager.hasAsked(for: .inputMonitoring, defaults: defaults))
    }

    func testAnInstallFromBeforeTheFlagsCountsFinishedOnboardingAsAsked() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PermissionRelaunchAdviceTests.legacy"))
        defer { defaults.removePersistentDomain(forName: "PermissionRelaunchAdviceTests.legacy") }

        XCTAssertFalse(PermissionManager.hasAsked(for: .accessibility, defaults: defaults))
        defaults.set(true, forKey: PreferenceKey.onboardingCompleted)
        XCTAssertTrue(PermissionManager.hasAsked(for: .accessibility, defaults: defaults))
    }

    func testAResetStillReadsAsNotAskedAfterOnboarding() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PermissionRelaunchAdviceTests.reset"))
        defer { defaults.removePersistentDomain(forName: "PermissionRelaunchAdviceTests.reset") }
        defaults.set(true, forKey: PreferenceKey.onboardingCompleted)

        PermissionManager.forgetPermissionRequests(defaults: defaults)

        XCTAssertFalse(PermissionManager.hasAsked(for: .inputMonitoring, defaults: defaults))
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

// MARK: - Input Monitoring Request

@MainActor
final class InputMonitoringRequestTests: XCTestCase {

    func testAsksMacOSWhenItHasNotAskedYet() {
        XCTAssertEqual(PermissionManager.inputMonitoringRequest(for: kIOHIDAccessTypeUnknown), .askMacOS)
    }

    func testOpensSettingsOnceMacOSHasAsked() {
        XCTAssertEqual(PermissionManager.inputMonitoringRequest(for: kIOHIDAccessTypeDenied), .openSettings)
    }
}

// MARK: - Returning After A Grant

@MainActor
final class OnboardingReturnAfterGrantTests: XCTestCase {

    func testReturnsWhenAccessibilityTurnsOnWhileAway() {
        XCTAssertTrue(PermissionManager.shouldReturnAfterGrant(
            old: .denied, new: .granted, requestedThisLaunch: true, isActive: false
        ))
    }

    func testStaysPutWhenAlreadyInFront() {
        XCTAssertFalse(PermissionManager.shouldReturnAfterGrant(
            old: .denied, new: .granted, requestedThisLaunch: true, isActive: true
        ))
    }

    func testStaysPutForAGrantVocaMacDidNotAskFor() {
        XCTAssertFalse(PermissionManager.shouldReturnAfterGrant(
            old: .notDetermined, new: .granted, requestedThisLaunch: false, isActive: false
        ))
    }

    func testStaysPutWhenNothingChanged() {
        XCTAssertFalse(PermissionManager.shouldReturnAfterGrant(
            old: .granted, new: .granted, requestedThisLaunch: true, isActive: false
        ))
    }
}
