// HotKeyValidationTests.swift
// VocaMac
//
// Tests for the dictation hotkey rules, the recording-limit countdown, and
// the onboarding permission warnings.

import XCTest
@testable import VocaMac

final class HotKeyValidationTests: XCTestCase {

    private let keyA = 0
    private let keyV = 9
    private let keyReturn = 36
    private let keyTab = 48
    private let keySpace = 49
    private let keyF5 = 96
    private let rightOption = 61
    private let fn = 63

    // MARK: - Fires while typing

    func testBareTypingKeysAreRejected() {
        for keyCode in [keyA, keyReturn, keyTab, keySpace] {
            let combo = HotKeyCombo(keyCode: keyCode, modifiers: [])
            XCTAssertTrue(HotKeyComboRules.firesWhileTyping(combo), "key \(keyCode)")
            XCTAssertNotNil(HotKeyComboRules.dictationHotKeyProblem(combo, existingShortcuts: [:]), "key \(keyCode)")
        }
    }

    func testShiftOrFnAloneDoesNotMakeATypingKeySafe() {
        XCTAssertTrue(HotKeyComboRules.firesWhileTyping(HotKeyCombo(keyCode: keyA, modifiers: .shift)))
        XCTAssertTrue(HotKeyComboRules.firesWhileTyping(HotKeyCombo(keyCode: keySpace, modifiers: .function)))
    }

    func testLoneModifierAndFunctionKeyHotkeysStayValid() {
        for combo in [
            HotKeyCombo(keyCode: rightOption, modifiers: []),
            HotKeyCombo(keyCode: fn, modifiers: []),
            HotKeyCombo(keyCode: keyF5, modifiers: []),
        ] {
            XCTAssertNil(HotKeyComboRules.dictationHotKeyProblem(combo, existingShortcuts: [:]), "\(combo)")
        }
    }

    func testEveryPresetIsAValidDictationHotkey() {
        for preset in KeyCodeReference.commonHotKeys {
            let combo = HotKeyCombo(keyCode: preset.keyCode, modifiers: preset.modifiers)
            XCTAssertNil(
                HotKeyComboRules.dictationHotKeyProblem(combo, existingShortcuts: [:]),
                "Preset \(preset.name) should stay selectable"
            )
        }
    }

    func testCombosWithCommandControlOrOptionAreValid() {
        for modifiers: HotKeyModifiers in [.command, .control, .option, [.control, .shift]] {
            let combo = HotKeyCombo(keyCode: keySpace, modifiers: modifiers)
            XCTAssertFalse(HotKeyComboRules.firesWhileTyping(combo))
        }
    }

    // MARK: - Conflicts

    func testHotkeyMatchingASecondaryShortcutIsRejected() {
        let pasteLast = HotKeyCombo(keyCode: keyV, modifiers: [.control, .command])
        let problem = HotKeyComboRules.dictationHotKeyProblem(
            pasteLast,
            existingShortcuts: [.pasteLastDictation: pasteLast]
        )
        XCTAssertEqual(problem, "That's already the paste last dictation shortcut.")
    }

    func testSystemShortcutsGetANoteButOrdinaryCombosDoNot() {
        XCTAssertNotNil(HotKeyComboRules.systemConflict(HotKeyCombo(keyCode: keySpace, modifiers: .command)))
        XCTAssertNotNil(HotKeyComboRules.systemConflict(HotKeyCombo(keyCode: keySpace, modifiers: .control)))
        XCTAssertNotNil(HotKeyComboRules.systemConflict(HotKeyCombo(keyCode: keySpace, modifiers: [.control, .option])))
        XCTAssertNil(HotKeyComboRules.systemConflict(HotKeyCombo(keyCode: keySpace, modifiers: .option)))
        XCTAssertNil(HotKeyComboRules.systemConflict(HotKeyCombo(keyCode: rightOption, modifiers: [])))
    }
}

// MARK: - Recording Countdown

final class RecordingCountdownTests: XCTestCase {

    func testNoCountdownWithoutALimit() {
        XCTAssertNil(RecordingCountdown.secondsRemaining(elapsed: 59, limit: nil))
        XCTAssertNil(RecordingCountdown.secondsRemaining(elapsed: 5, limit: 0))
    }

    func testCountdownStartsTenSecondsBeforeTheLimit() {
        XCTAssertNil(RecordingCountdown.secondsRemaining(elapsed: 49, limit: 60))
        XCTAssertEqual(RecordingCountdown.secondsRemaining(elapsed: 50, limit: 60), 10)
        XCTAssertEqual(RecordingCountdown.secondsRemaining(elapsed: 59, limit: 60), 1)
        XCTAssertEqual(RecordingCountdown.secondsRemaining(elapsed: 59.5, limit: 60), 1)
    }

    func testCountdownNeverGoesNegative() {
        XCTAssertEqual(RecordingCountdown.secondsRemaining(elapsed: 65, limit: 60), 0)
    }
}

// MARK: - Onboarding Permission Gaps

final class OnboardingPermissionGapsTests: XCTestCase {

    func testNoWarningsWhenEverythingIsGranted() {
        XCTAssertTrue(OnboardingPermissionGaps.consequences(
            microphone: .granted, accessibility: .granted, inputMonitoring: .granted
        ).isEmpty)
    }

    func testEachMissingPermissionExplainsWhatStopsWorking() {
        let gaps = OnboardingPermissionGaps.consequences(
            microphone: .denied, accessibility: .notDetermined, inputMonitoring: .granted
        )
        XCTAssertEqual(gaps.count, 2)
        XCTAssertTrue(gaps[0].contains("Microphone"))
        XCTAssertTrue(gaps[1].contains("Accessibility"))
    }
}
