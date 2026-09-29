// HotKeyShortcutTests.swift
// VocaMac
//
// Extra shortcuts, the Escape cancel key, and the mouse trigger.

import XCTest
@testable import VocaMac

final class HotKeyShortcutTests: XCTestCase {

    private func keyEvent(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags = []) throws -> CGEvent {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else {
            throw XCTSkip("Could not create keyboard event")
        }
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        event.flags = flags
        return event
    }

    private func mouseEvent(_ type: CGEventType, button: CGMouseButton) throws -> CGEvent {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: .zero, mouseButton: button) else {
            throw XCTSkip("Could not create mouse event")
        }
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        return event
    }

    func testShortcutFiresAndConsumesItsKeys() throws {
        let manager = HotKeyManager()
        manager.updateShortcuts([.pasteLastDictation: .defaultPasteLast])
        let fired = expectation(description: "Shortcut fires")
        manager.onShortcut = { action in
            XCTAssertEqual(action, .pasteLastDictation)
            fired.fulfill()
        }

        XCTAssertTrue(manager._handleTestEvent(type: .keyDown, event: try keyEvent(9, down: true, flags: [.maskControl, .maskCommand])))
        XCTAssertTrue(manager._handleTestEvent(type: .keyUp, event: try keyEvent(9, down: false, flags: [.maskControl, .maskCommand])))
        wait(for: [fired], timeout: 1)
    }

    func testShortcutNeedsExactModifiers() throws {
        let manager = HotKeyManager()
        manager.updateShortcuts([.pasteLastDictation: .defaultPasteLast])
        manager.onShortcut = { _ in XCTFail("⌘V alone must reach the app") }

        XCTAssertFalse(manager._handleTestEvent(type: .keyDown, event: try keyEvent(9, down: true, flags: .maskCommand)))
        XCTAssertFalse(manager._handleTestEvent(type: .keyUp, event: try keyEvent(9, down: false, flags: .maskCommand)))
    }

    func testShortcutMatchingTheActivationHotkeyIsIgnored() throws {
        let manager = HotKeyManager()
        manager.updateConfiguration(keyCode: 49, mode: .pushToTalk, safetyTimeout: 5, modifiers: .command)
        manager.updateShortcuts([.handsFreeToggle: HotKeyCombo(keyCode: 49, modifiers: .command)])
        let started = expectation(description: "Activation hotkey still starts recording")
        manager.onRecordingStart = { started.fulfill() }
        manager.onShortcut = { _ in XCTFail("Shortcut must not shadow the hotkey") }

        XCTAssertTrue(manager._handleTestEvent(type: .keyDown, event: try keyEvent(49, down: true, flags: .maskCommand)))
        wait(for: [started], timeout: 1)
        manager.resetKeyState()
    }

    func testEscapeOnlyCancelsWhileArmed() throws {
        let manager = HotKeyManager()
        manager.onCancel = { XCTFail("Escape must pass through when nothing is recording") }
        XCTAssertFalse(manager._handleTestEvent(type: .keyDown, event: try keyEvent(53, down: true)))
        XCTAssertFalse(manager._handleTestEvent(type: .keyUp, event: try keyEvent(53, down: false)))

        manager.setCancelKeyArmed(true)
        let cancelled = expectation(description: "Escape cancels")
        manager.onCancel = { cancelled.fulfill() }
        // Held modifiers (push-to-talk) don't stop Escape from cancelling.
        XCTAssertTrue(manager._handleTestEvent(type: .keyDown, event: try keyEvent(53, down: true, flags: .maskAlternate)))
        manager.setCancelKeyArmed(false)
        XCTAssertTrue(manager._handleTestEvent(type: .keyUp, event: try keyEvent(53, down: false)),
                      "The release of a consumed Escape is consumed too")
        wait(for: [cancelled], timeout: 1)
    }

    func testMouseButtonActsAsPushToTalk() throws {
        let manager = HotKeyManager()
        manager.updateConfiguration(mode: .pushToTalk, safetyTimeout: 5)
        let started = expectation(description: "Start")
        let stopped = expectation(description: "Stop")
        manager.onRecordingStart = { started.fulfill() }
        manager.onRecordingStop = { stopped.fulfill() }

        let down = try mouseEvent(.otherMouseDown, button: .center)
        let up = try mouseEvent(.otherMouseUp, button: .center)
        XCTAssertFalse(manager._handleTestEvent(type: .otherMouseDown, event: down), "Off by default")

        manager.updateMouseTrigger(button: MouseTriggerButton.middle.rawValue)
        XCTAssertTrue(manager._handleTestEvent(type: .otherMouseDown, event: down))
        XCTAssertTrue(manager._handleTestEvent(type: .otherMouseUp, event: up))
        wait(for: [started, stopped], timeout: 1, enforceOrder: true)
    }

    func testComboStorageRoundTrips() {
        let combo = HotKeyCombo(keyCode: 9, modifiers: [.control, .command])
        XCTAssertEqual(HotKeyCombo(storageString: combo.storageString), combo)
        XCTAssertNil(HotKeyCombo(storageString: ""))
        XCTAssertNil(HotKeyCombo(storageString: "garbage"))
    }
}
