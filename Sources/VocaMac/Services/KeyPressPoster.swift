// KeyPressPoster.swift
// VocaMac
//
// Presses a key in the app in front, for Silent Mode's mouthed commands
// ("Send" presses Return). Uses the same Accessibility-backed event posting
// as the paste that delivers a dictation.

import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// A key and its modifiers, to press once.
struct SyntheticKeyPress: Equatable, Sendable {
    var keyCode: CGKeyCode
    var flags: CGEventFlags

    static let returnKey = SyntheticKeyPress(keyCode: CGKeyCode(kVK_Return), flags: [])
    static let shiftReturn = SyntheticKeyPress(keyCode: CGKeyCode(kVK_Return), flags: [.maskShift])
    static let tab = SyntheticKeyPress(keyCode: CGKeyCode(kVK_Tab), flags: [])
    static let escape = SyntheticKeyPress(keyCode: CGKeyCode(kVK_Escape), flags: [])
    static let optionDelete = SyntheticKeyPress(keyCode: CGKeyCode(kVK_Delete), flags: [.maskAlternate])

    /// ⌘Z on the active keyboard layout (Z moves on AZERTY and QWERTZ).
    static var undo: SyntheticKeyPress {
        SyntheticKeyPress(keyCode: TextInjector.keyCode(forCharacter: "z") ?? CGKeyCode(kVK_ANSI_Z), flags: [.maskCommand])
    }
}

protocol KeyPressPosting: AnyObject {
    func press(_ key: SyntheticKeyPress)
}

final class SystemKeyPresser: KeyPressPosting {
    func press(_ key: SyntheticKeyPress) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key.keyCode, keyDown: false) else {
            VocaLogger.error(.silentMode, "Couldn't create a key event for keycode \(key.keyCode)")
            return
        }
        down.flags = key.flags
        up.flags = key.flags
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}
