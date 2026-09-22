// SecureInputFallbackTests.swift
// VocaMac
//
// Keyed shortcuts under macOS Secure Event Input.

import XCTest
import Carbon.HIToolbox
@testable import VocaMac

final class SecureInputFallbackTests: XCTestCase {

    func testMonitorReportsOnlyChanges() {
        var enabled = false
        var reported: [Bool] = []
        let monitor = SecureInputMonitor(isSecureInputEnabled: { enabled })
        monitor.onChange = { reported.append($0) }

        monitor.refresh()
        enabled = true
        monitor.refresh()
        monitor.refresh()
        enabled = false
        monitor.refresh()

        XCTAssertEqual(reported, [true, false])
        XCTAssertFalse(monitor.isEnabled)
    }

    func testStoppingWhileEnabledReportsOff() {
        let monitor = SecureInputMonitor(isSecureInputEnabled: { true })
        var reported: [Bool] = []
        monitor.onChange = { reported.append($0) }
        monitor.refresh()
        monitor.stop()
        XCTAssertEqual(reported, [true, false])
    }

    func testCarbonModifiers() {
        XCTAssertEqual(CarbonHotKeyRegistry.carbonModifiers([.command, .shift]), UInt32(cmdKey | shiftKey))
        XCTAssertEqual(CarbonHotKeyRegistry.carbonModifiers([.option, .control]), UInt32(optionKey | controlKey))
        XCTAssertEqual(CarbonHotKeyRegistry.carbonModifiers([]), 0)
    }

    func testOnlyKeyedCombosWithoutFnAreRegistrable() {
        XCTAssertTrue(CarbonHotKeyRegistry.isRegistrable(HotKeyCombo(keyCode: 49, modifiers: [.option])))
        XCTAssertTrue(CarbonHotKeyRegistry.isRegistrable(HotKeyCombo(keyCode: KeyCodeReference.escapeKeyCode, modifiers: [])))
        // Right Option alone never needs the fallback: flagsChanged still arrives.
        XCTAssertFalse(CarbonHotKeyRegistry.isRegistrable(HotKeyCombo(keyCode: 61, modifiers: [])))
        XCTAssertFalse(CarbonHotKeyRegistry.isRegistrable(HotKeyCombo(keyCode: 49, modifiers: [.function])))
    }
}
