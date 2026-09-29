// HotKeyManagerToggleResetTests.swift
// VocaMac
//
// A double-tap session that ended some other way (silence, the time limit,
// the menu) must not turn the next double-tap into a stop.

import XCTest
@testable import VocaMac

final class HotKeyManagerToggleResetTests: XCTestCase {

    private func f5Event(keyDown: Bool) throws -> CGEvent {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 96, keyDown: keyDown) else {
            throw XCTSkip("Could not create keyboard event")
        }
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        return event
    }

    private func pause(_ seconds: TimeInterval) {
        let paused = expectation(description: "Pause between taps")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { paused.fulfill() }
        wait(for: [paused], timeout: seconds + 1)
    }

    private func doubleTap(_ manager: HotKeyManager) throws {
        XCTAssertTrue(manager._handleTestEvent(type: .keyDown, event: try f5Event(keyDown: true)))
        XCTAssertTrue(manager._handleTestEvent(type: .keyUp, event: try f5Event(keyDown: false)))
        pause(0.08)
        XCTAssertTrue(manager._handleTestEvent(type: .keyDown, event: try f5Event(keyDown: true)))
        XCTAssertTrue(manager._handleTestEvent(type: .keyUp, event: try f5Event(keyDown: false)))
    }

    func testDoubleTapStartsAgainAfterTheSessionEndedElsewhere() throws {
        let manager = HotKeyManager()
        manager.updateConfiguration(keyCode: 96, mode: .doubleTapToggle, doubleTapThreshold: 1.0, safetyTimeout: 5.0)

        var starts = 0
        var stops = 0
        manager.onRecordingStart = { starts += 1 }
        manager.onRecordingStop = { stops += 1 }

        try doubleTap(manager)
        pause(0.1)
        XCTAssertEqual(starts, 1)

        // The recording stopped on silence, not on a double-tap.
        manager.resetKeyState()
        pause(0.1)

        try doubleTap(manager)
        pause(0.1)
        XCTAssertEqual(starts, 2, "The next double-tap must start a new recording")
        XCTAssertEqual(stops, 0)
    }

    func testEventsFromAnotherThreadWhileReconfiguringDoNotCrash() throws {
        let manager = HotKeyManager()
        manager.updateConfiguration(keyCode: 96, mode: .pushToTalk, safetyTimeout: 5.0)
        let down = try f5Event(keyDown: true)
        let up = try f5Event(keyDown: false)

        let done = expectation(description: "Background events handled")
        DispatchQueue.global(qos: .userInteractive).async {
            for _ in 0..<500 {
                _ = manager._handleTestEvent(type: .keyDown, event: down)
                _ = manager._handleTestEvent(type: .keyUp, event: up)
            }
            done.fulfill()
        }
        for index in 0..<500 {
            manager.updateConfiguration(mode: index.isMultiple(of: 2) ? .pushToTalk : .doubleTapToggle)
            manager.updateShortcuts([:])
            manager.resetKeyState()
        }
        wait(for: [done], timeout: 10)
        manager.resetKeyState()
    }
}
