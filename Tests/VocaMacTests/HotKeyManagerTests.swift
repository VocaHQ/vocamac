// HotKeyManagerTests.swift
// VocaMac
//
// Tests for HotKeyManager configuration and state logic.

import XCTest
@testable import VocaMac

// MARK: - HotKeyManager Configuration Tests

final class HotKeyManagerConfigurationTests: XCTestCase {

    func testDefaultState() {
        let manager = HotKeyManager()

        XCTAssertFalse(manager.isListening, "Should not be listening initially")
        XCTAssertNil(manager.eventTap, "Should have no event tap initially")
    }

    func testUpdateConfigurationKeyCode() {
        let manager = HotKeyManager()

        manager.updateConfiguration(keyCode: 58) // Left Option
        // Configuration should be accepted without crashing
        // (keyCode is private, but the method should not throw)
    }

    func testUpdateConfigurationMode() {
        let manager = HotKeyManager()

        manager.updateConfiguration(mode: .doubleTapToggle)
        manager.updateConfiguration(mode: .pushToTalk)
        // Both modes should be accepted without issues
    }

    func testUpdateConfigurationDoubleTapThreshold() {
        let manager = HotKeyManager()

        manager.updateConfiguration(doubleTapThreshold: 0.3)
        manager.updateConfiguration(doubleTapThreshold: 0.5)
        manager.updateConfiguration(doubleTapThreshold: 1.0)
    }

    func testUpdateConfigurationSafetyTimeout() {
        let manager = HotKeyManager()

        manager.updateConfiguration(safetyTimeout: 30.0)
        manager.updateConfiguration(safetyTimeout: 65.0)
    }

    func testUpdateConfigurationMultipleParams() {
        let manager = HotKeyManager()

        // Should accept multiple parameters at once
        manager.updateConfiguration(
            keyCode: 55,
            mode: .doubleTapToggle,
            doubleTapThreshold: 0.5,
            safetyTimeout: 120.0
        )
    }

    func testUpdateConfigurationNilParams() {
        let manager = HotKeyManager()

        // Nil parameters should leave existing values unchanged
        manager.updateConfiguration(keyCode: nil, mode: nil, doubleTapThreshold: nil, safetyTimeout: nil)
        // Should not crash
    }

    func testCallbacksInitiallyNil() {
        let manager = HotKeyManager()

        XCTAssertNil(manager.onRecordingStart, "onRecordingStart should be nil initially")
        XCTAssertNil(manager.onRecordingStop, "onRecordingStop should be nil initially")
    }

    func testCallbacksCanBeSet() {
        let manager = HotKeyManager()
        var startCalled = false
        var stopCalled = false

        manager.onRecordingStart = { startCalled = true }
        manager.onRecordingStop = { stopCalled = true }

        manager.onRecordingStart?()
        manager.onRecordingStop?()

        XCTAssertTrue(startCalled, "Start callback should be invokable")
        XCTAssertTrue(stopCalled, "Stop callback should be invokable")
    }

    func testStopListeningWithoutStarting() {
        let manager = HotKeyManager()

        // Should not crash when stopping without having started
        manager.stopListening()
        XCTAssertFalse(manager.isListening)
    }

    func testStopListeningIdempotent() {
        let manager = HotKeyManager()

        manager.stopListening()
        manager.stopListening()
        manager.stopListening()
        XCTAssertFalse(manager.isListening)
    }

    func testRegularKeyAutoRepeatDoesNotStopPushToTalk() throws {
        let manager = HotKeyManager()
        manager.updateConfiguration(keyCode: 0, mode: .pushToTalk, safetyTimeout: 5.0)

        let startExpectation = expectation(description: "Recording starts once")
        let stopExpectation = expectation(description: "Auto-repeat should not stop recording")
        stopExpectation.isInverted = true

        var startCount = 0
        manager.onRecordingStart = {
            startCount += 1
            startExpectation.fulfill()
        }
        manager.onRecordingStop = {
            stopExpectation.fulfill()
        }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let repeatedKeyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        else {
            throw XCTSkip("Could not create keyboard events")
        }
        markAsExternal(keyDown)
        markAsExternal(repeatedKeyDown)
        repeatedKeyDown.setIntegerValueField(.keyboardEventAutorepeat, value: 1)

        XCTAssertTrue(manager._handleTestEvent(type: .keyDown, event: keyDown))
        wait(for: [startExpectation], timeout: 1.0)

        XCTAssertTrue(manager._handleTestEvent(type: .keyDown, event: repeatedKeyDown))
        wait(for: [stopExpectation], timeout: 0.1)
        XCTAssertEqual(startCount, 1)
        manager.resetKeyState()
    }

    func testSinglePressToggleStartsAndStopsOnSuccessivePresses() throws {
        let manager = HotKeyManager()
        manager.updateConfiguration(keyCode: 0, mode: .singlePressToggle)

        let startExpectation = expectation(description: "First press starts recording")
        let stopExpectation = expectation(description: "Second press stops recording")
        manager.onRecordingStart = { startExpectation.fulfill() }
        manager.onRecordingStop = { stopExpectation.fulfill() }

        guard let firstDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let firstUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false),
              let secondDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        else {
            throw XCTSkip("Could not create keyboard events")
        }
        [firstDown, firstUp, secondDown].forEach(markAsExternal)

        XCTAssertTrue(manager._handleTestEvent(type: .keyDown, event: firstDown))
        wait(for: [startExpectation], timeout: 1.0)
        XCTAssertTrue(manager._handleTestEvent(type: .keyUp, event: firstUp))
        XCTAssertTrue(manager._handleTestEvent(type: .keyDown, event: secondDown))
        wait(for: [stopExpectation], timeout: 1.0)
        manager.resetKeyState()
    }

    func testTargetRegularKeyEventsAreConsumed() throws {
        let manager = HotKeyManager()
        manager.updateConfiguration(keyCode: 0, mode: .pushToTalk, safetyTimeout: 5.0)

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else {
            throw XCTSkip("Could not create keyboard events")
        }
        markAsExternal(keyDown)
        markAsExternal(keyUp)

        XCTAssertTrue(manager._handleTestEvent(type: .keyDown, event: keyDown))
        XCTAssertTrue(manager._handleTestEvent(type: .keyUp, event: keyUp))
        manager.resetKeyState()
    }

    func testNonTargetRegularKeyEventsPassThrough() throws {
        let manager = HotKeyManager()
        manager.updateConfiguration(keyCode: 0, mode: .pushToTalk)

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 1, keyDown: true) else {
            throw XCTSkip("Could not create keyboard event")
        }
        markAsExternal(keyDown)

        XCTAssertFalse(manager._handleTestEvent(type: .keyDown, event: keyDown))
    }

    func testTargetModifierEventIsConsumed() throws {
        let manager = HotKeyManager()
        manager.updateConfiguration(keyCode: 61, mode: .pushToTalk, safetyTimeout: 5.0)

        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 61, keyDown: true) else {
            throw XCTSkip("Could not create keyboard event")
        }
        markAsExternal(event)
        event.flags = .maskAlternate

        XCTAssertTrue(manager._handleTestEvent(type: .flagsChanged, event: event))
        manager.resetKeyState()
    }

    func testModifierReleaseStopsWhenSiblingModifierStillHeld() throws {
        let manager = HotKeyManager()
        manager.updateConfiguration(keyCode: 61, mode: .pushToTalk, safetyTimeout: 5.0)

        let startExpectation = expectation(description: "Recording starts")
        let stopExpectation = expectation(description: "Recording stops")

        manager.onRecordingStart = {
            startExpectation.fulfill()
        }
        manager.onRecordingStop = {
            stopExpectation.fulfill()
        }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 61, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 61, keyDown: false)
        else {
            throw XCTSkip("Could not create modifier events")
        }
        markAsExternal(keyDown)
        markAsExternal(keyUp)
        keyDown.flags = .maskAlternate
        keyUp.flags = .maskAlternate

        XCTAssertTrue(manager._handleTestEvent(type: .flagsChanged, event: keyDown))
        wait(for: [startExpectation], timeout: 1.0)

        XCTAssertTrue(manager._handleTestEvent(type: .flagsChanged, event: keyUp))
        wait(for: [stopExpectation], timeout: 1.0)
        manager.resetKeyState()
    }

    func testModifierReleaseWithSiblingModifierHeldDoesNotCountAsDoubleTap() throws {
        let manager = HotKeyManager()
        manager.updateConfiguration(keyCode: 61, mode: .doubleTapToggle, doubleTapThreshold: 1.0)

        let startExpectation = expectation(description: "Modifier release should not start recording")
        startExpectation.isInverted = true
        manager.onRecordingStart = {
            startExpectation.fulfill()
        }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 61, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 61, keyDown: false)
        else {
            throw XCTSkip("Could not create modifier events")
        }
        markAsExternal(keyDown)
        markAsExternal(keyUp)
        keyDown.flags = .maskAlternate
        keyUp.flags = .maskAlternate

        XCTAssertTrue(manager._handleTestEvent(type: .flagsChanged, event: keyDown))

        let releaseDelay = expectation(description: "Release after double-tap minimum interval")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            releaseDelay.fulfill()
        }
        wait(for: [releaseDelay], timeout: 1.0)

        XCTAssertTrue(manager._handleTestEvent(type: .flagsChanged, event: keyUp))
        wait(for: [startExpectation], timeout: 0.15)
        manager.resetKeyState()
    }

    func testSelfGeneratedEventsPassThrough() throws {
        let manager = HotKeyManager()
        manager.updateConfiguration(keyCode: 9, mode: .pushToTalk)

        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true) else {
            throw XCTSkip("Could not create keyboard event")
        }

        XCTAssertFalse(manager._handleTestEvent(type: .keyDown, event: event))
    }

    private func markAsExternal(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
    }
}

// MARK: - HotKeyManager Reset State Tests

final class HotKeyManagerResetStateTests: XCTestCase {

    func testResetKeyStateDoesNotCrash() {
        // resetKeyState should be safe to call in any state
        let manager = HotKeyManager()
        manager.resetKeyState()
        // No crash = pass
    }

    func testResetKeyStateMultipleTimes() {
        // Calling resetKeyState multiple times should be safe
        let manager = HotKeyManager()
        manager.resetKeyState()
        manager.resetKeyState()
        manager.resetKeyState()
        // No crash = pass
    }

}
