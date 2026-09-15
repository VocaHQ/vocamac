// HotKeyManager.swift
// VocaMac
//
// Listens for global hotkey events using CGEventTap.
// Supports push-to-talk (hold key) and double-tap toggle modes.

import Foundation
import AppKit
import Carbon.HIToolbox

final class HotKeyManager {

    // MARK: - Properties

    /// Event tap Mach port
    private(set) var eventTap: CFMachPort?

    /// Run loop source for the event tap
    private var runLoopSource: CFRunLoopSource?

    /// Whether the event tap is currently active
    private(set) var isListening = false

    /// The key code to listen for
    private var targetKeyCode: Int = 61  // Right Option

    /// Current activation mode
    private var mode: ActivationMode = .pushToTalk

    /// Double-tap threshold in seconds
    private var doubleTapThreshold: Double = 0.4

    /// Timestamp of the last key down event for the target key
    private var lastKeyDownTime: CFAbsoluteTime = 0

    /// Whether the key is currently held down (for push-to-talk)
    private var isKeyHeld = false

    /// Whether we are currently in a "recording" toggle state (for double-tap mode)
    private var isToggled = false

    /// Whether the configured modifier key is physically held.
    /// This is tracked separately from recording state so modifier double-tap
    /// mode can distinguish press/release even when another same-group modifier
    /// keeps the shared modifier flag set.
    private var isModifierKeyHeld = false

    /// Safety timer that auto-fires key-up if a real key-up event is missed.
    /// macOS can drop flagsChanged events when multiple modifiers interact,
    /// leaving push-to-talk stuck in the "recording" state.
    private var keyHeldSafetyTimer: DispatchWorkItem?

    /// Maximum duration (seconds) before the safety timer forces a key-up.
    /// Set via `startListening(safetyTimeout:)` — should match (or slightly
    /// exceed) the app's max recording duration so the safety timer acts as
    /// a last-resort backstop *after* AudioEngine's own max-duration callback
    /// has had a chance to fire.
    private var safetyTimeoutSeconds: Double = 65.0

    // MARK: - Callbacks

    /// Called when recording should start
    var onRecordingStart: (() -> Void)?

    /// Called when recording should stop
    var onRecordingStop: (() -> Void)?

    // MARK: - Accessibility Permission

    /// Check if the app has Accessibility permission
    /// - Parameter prompt: Whether to show the system prompt if not trusted
    /// - Returns: true if the app is trusted for Accessibility
    static func checkAccessibilityPermission(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Lifecycle

    /// Start listening for global hotkey events
    /// - Parameters:
    ///   - keyCode: The virtual key code to listen for (default: 61 = Right Option)
    ///   - mode: The activation mode (push-to-talk or double-tap toggle)
    ///   - doubleTapThreshold: Time window for double-tap detection (seconds)
    ///   - safetyTimeout: Maximum seconds before the safety timer forces a key-up
    ///     in push-to-talk mode. Should be slightly longer than the app's max
    ///     recording duration so AudioEngine's own limit fires first. The safety
    ///     timer is a last-resort backstop for when a key-up event is lost entirely.
    func startListening(
        keyCode: Int = 61,
        mode: ActivationMode = .pushToTalk,
        doubleTapThreshold: Double = 0.4,
        safetyTimeout: Double = 65.0
    ) {
        guard !isListening else {
            VocaLogger.debug(.hotKeyManager, "Already listening")
            return
        }

        self.targetKeyCode = keyCode
        self.mode = mode
        self.doubleTapThreshold = doubleTapThreshold
        self.safetyTimeoutSeconds = safetyTimeout
        self.lastKeyDownTime = 0
        self.isKeyHeld = false
        self.isToggled = false
        self.isModifierKeyHeld = false

        // Create event tap for key events and flags changed (modifier keys)
        let eventMask: CGEventMask = (
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        )

        // We need to pass `self` as a raw pointer to the C callback
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: HotKeyManager.eventTapCallback,
            userInfo: userInfo
        ) else {
            VocaLogger.error(.hotKeyManager, "FAILED to create event tap! Check Accessibility & Input Monitoring permissions.")
            return
        }

        self.eventTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        isListening = true
        VocaLogger.info(.hotKeyManager, "Event tap created successfully. Listening for keyCode \(keyCode) in \(mode.rawValue) mode")
    }

    /// Stop listening for global hotkey events
    func stopListening() {
        guard isListening else { return }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        isListening = false
        isKeyHeld = false
        isToggled = false
        isModifierKeyHeld = false
        cancelSafetyTimer()

        VocaLogger.info(.hotKeyManager, "Stopped listening")
    }

    /// Reset internal key tracking state without stopping the listener.
    /// Used when the app forcibly recovers from a stuck recording state
    /// (e.g., after an audio device change) so that the next keypress
    /// is treated as a fresh key-down rather than a recovery key-down.
    func resetKeyState() {
        isKeyHeld = false
        isToggled = false
        isModifierKeyHeld = false
        cancelSafetyTimer()
        VocaLogger.debug(.hotKeyManager, "Key state reset")
    }

    /// Update the configuration while listening
    /// - Parameters:
    ///   - keyCode: New key code to listen for
    ///   - mode: New activation mode
    ///   - doubleTapThreshold: New double-tap detection window (seconds)
    ///   - safetyTimeout: New safety timer duration (seconds). Should be
    ///     `maxRecordingDuration + 5` to act as a backstop after AudioEngine's
    ///     own max-duration callback.
    func updateConfiguration(
        keyCode: Int? = nil,
        mode: ActivationMode? = nil,
        doubleTapThreshold: Double? = nil,
        safetyTimeout: Double? = nil
    ) {
        if let keyCode = keyCode { self.targetKeyCode = keyCode }
        if let mode = mode { self.mode = mode }
        if let threshold = doubleTapThreshold { self.doubleTapThreshold = threshold }
        if let timeout = safetyTimeout { self.safetyTimeoutSeconds = timeout }
    }

    // MARK: - Event Tap Callback

    /// Static C callback for CGEventTap — dispatches to the instance method
    private static let eventTapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
        guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }

        let manager = Unmanaged<HotKeyManager>.fromOpaque(userInfo).takeUnretainedValue()

        // Handle tap being disabled (system can disable taps if they're too slow)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = manager.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let shouldConsumeEvent = manager.handleEvent(type: type, event: event)
        if shouldConsumeEvent {
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Event Handling

    /// Handle an incoming key event
    /// - Returns: `true` when the event belongs to the configured hotkey and
    ///   should be consumed so it doesn't also affect the frontmost app.
    private func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard !isSelfGeneratedEvent(event) else { return false }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        // For modifier keys (like Option), we use flagsChanged events
        // For regular keys, we use keyDown/keyUp events
        if type == .flagsChanged {
            if keyCode == targetKeyCode {
                VocaLogger.debug(.hotKeyManager, "flagsChanged event for target keyCode \(keyCode)")
            }
            return handleModifierKeyEvent(keyCode: keyCode, event: event)
        } else if type == .keyDown || type == .keyUp {
            return handleRegularKeyEvent(keyCode: keyCode, isKeyDown: type == .keyDown, event: event)
        }

        return false
    }

    private func isSelfGeneratedEvent(_ event: CGEvent) -> Bool {
        let eventPID = event.getIntegerValueField(.eventSourceUnixProcessID)
        return eventPID == Int64(ProcessInfo.processInfo.processIdentifier)
    }

    /// Handle modifier key events (Option, Command, Control, Shift, Fn)
    /// Modifier keys generate flagsChanged events, not keyDown/keyUp.
    ///
    /// **Key insight:** Modifier flags like `.maskAlternate` are shared between
    /// left and right variants (e.g., Left Option and Right Option both set
    /// `.maskAlternate`). A `flagsChanged` event fires whenever *any* modifier
    /// changes, so we can't simply check the flag — pressing Left Option while
    /// Right Option is already held would still show `.maskAlternate` as set,
    /// and releasing Right Option while Left Option is held would *not* clear
    /// the flag, causing the key-up to be missed.
    ///
    /// **Fix:** We track the target modifier's physical held state. When a
    /// `flagsChanged` event arrives for the target key code, a transition from
    /// not-held to set flags is a press; any later target-key event while held
    /// is a release, even if another same-group modifier keeps the shared flag set.

    private func handleModifierKeyEvent(keyCode: Int, event: CGEvent) -> Bool {
        guard keyCode == targetKeyCode else { return false }

        let flags = event.flags

        // The flag mask that corresponds to this key's modifier group
        let relevantMask: CGEventFlags
        switch keyCode {
        case 61, 58:  // Right Option (61) or Left Option (58)
            relevantMask = .maskAlternate
        case 54, 55:  // Right Command (54) or Left Command (55)
            relevantMask = .maskCommand
        case 60, 56:  // Right Shift (60) or Left Shift (56)
            relevantMask = .maskShift
        case 62, 59:  // Right Control (62) or Left Control (59)
            relevantMask = .maskControl
        case 63:      // Fn key
            relevantMask = .maskSecondaryFn
        default:
            return false
        }

        // A flagsChanged event for this keyCode means the key was either
        // pressed or released. Modifier flags are shared by left/right pairs,
        // so we cannot rely on the flag being cleared to detect release.
        let flagIsSet = flags.contains(relevantMask)

        let isPressed: Bool
        if flagIsSet && !isModifierKeyHeld {
            isPressed = true
            isModifierKeyHeld = true
        } else if isModifierKeyHeld {
            isPressed = false
            isModifierKeyHeld = false
        } else {
            return true
        }

        if isPressed {
            handleKeyDown()
        } else {
            handleKeyUp()
        }

        return true
    }

    /// Handle regular (non-modifier) key events
    private func handleRegularKeyEvent(keyCode: Int, isKeyDown: Bool, event: CGEvent) -> Bool {
        guard keyCode == targetKeyCode else { return false }

        if isKeyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return true
        }

        if isKeyDown {
            handleKeyDown()
        } else {
            handleKeyUp()
        }

        return true
    }

    /// Process a key-down event for the target hotkey
    private func handleKeyDown() {
        let currentTime = CFAbsoluteTimeGetCurrent()
        VocaLogger.debug(.hotKeyManager, "Key DOWN detected (mode=\(mode.rawValue))")

        switch mode {
        case .pushToTalk:
            if !isKeyHeld {
                // Normal case: start recording on key down
                isKeyHeld = true
                VocaLogger.debug(.hotKeyManager, "Push-to-talk: START recording")
                startSafetyTimer()
                DispatchQueue.main.async { [weak self] in
                    self?.onRecordingStart?()
                }
            } else {
                // Recovery: key-down while already held means the previous
                // key-up was missed (macOS dropped the flagsChanged event).
                // Treat this as a stop → the user is pressing the key again
                // because recording is stuck.
                VocaLogger.warning(.hotKeyManager, "Push-to-talk: key DOWN while already held — forcing STOP (recovery)")
                isKeyHeld = false
                cancelSafetyTimer()
                DispatchQueue.main.async { [weak self] in
                    self?.onRecordingStop?()
                }
            }

        case .singlePressToggle:
            isToggled.toggle()
            let shouldStart = isToggled
            DispatchQueue.main.async { [weak self] in
                if shouldStart {
                    self?.onRecordingStart?()
                } else {
                    self?.onRecordingStop?()
                }
            }

        case .doubleTapToggle:
            // Double-tap: check if this is the second tap within threshold
            let timeSinceLastTap = currentTime - lastKeyDownTime

            if timeSinceLastTap < doubleTapThreshold && timeSinceLastTap > 0.05 {
                // This is a double-tap!
                isToggled.toggle()
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if self.isToggled {
                        self.onRecordingStart?()
                    } else {
                        self.onRecordingStop?()
                    }
                }
                // Reset to avoid triple-tap triggering
                lastKeyDownTime = 0
            } else {
                lastKeyDownTime = currentTime
            }
        }
    }

    /// Process a key-up event for the target hotkey
    private func handleKeyUp() {
        VocaLogger.debug(.hotKeyManager, "Key UP detected (mode=\(mode.rawValue))")

        switch mode {
        case .pushToTalk:
            // Push-to-talk: stop recording on key release
            if isKeyHeld {
                isKeyHeld = false
                cancelSafetyTimer()
                VocaLogger.debug(.hotKeyManager, "Push-to-talk: STOP recording")
                DispatchQueue.main.async { [weak self] in
                    self?.onRecordingStop?()
                }
            }

        case .singlePressToggle, .doubleTapToggle:
            // No action on key up for toggle modes
            break
        }
    }

    // MARK: - Safety Timer

    /// Start a safety timer that forces a key-up if the real event is never received.
    /// This prevents the app from getting stuck in a "recording" state indefinitely.
    ///
    /// The timeout is set via `startListening(safetyTimeout:)` and should be
    /// slightly longer than `maxRecordingDuration` so that AudioEngine's own
    /// max-duration callback fires first under normal conditions. The safety
    /// timer only kicks in when a key-up event is completely lost.
    private func startSafetyTimer() {
        cancelSafetyTimer()

        let timeout = safetyTimeoutSeconds
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isKeyHeld else { return }
            VocaLogger.warning(.hotKeyManager, "Safety timer fired — forcing key-up (key held for >\(timeout)s)")
            self.isKeyHeld = false
            DispatchQueue.main.async { [weak self] in
                self?.onRecordingStop?()
            }
        }
        keyHeldSafetyTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    /// Cancel the safety timer (called on normal key-up)
    private func cancelSafetyTimer() {
        keyHeldSafetyTimer?.cancel()
        keyHeldSafetyTimer = nil
    }

    // MARK: - Deinit

    deinit {
        stopListening()
    }
}

// MARK: - HotKeyMonitoring Conformance

extension HotKeyManager: HotKeyMonitoring {
    func checkAccessibilityPermission(prompt: Bool) -> Bool {
        Self.checkAccessibilityPermission(prompt: prompt)
    }

    func _updateConfiguration(keyCode: Int?, mode: ActivationMode?, doubleTapThreshold: Double?, safetyTimeout: Double?) {
        updateConfiguration(keyCode: keyCode, mode: mode, doubleTapThreshold: doubleTapThreshold, safetyTimeout: safetyTimeout)
    }
}

// MARK: - Test Support

extension HotKeyManager {
    /// Exercise event handling without installing a process-wide event tap.
    func _handleTestEvent(type: CGEventType, event: CGEvent) -> Bool {
        handleEvent(type: type, event: event)
    }
}

// MARK: - Common Key Codes Reference

/// Reference for common macOS virtual key codes
/// Used for hotkey configuration UI
enum KeyCodeReference {
    static let escapeKeyCode = 53

    static let commonHotKeys: [(name: String, keyCode: Int)] = [
        ("Right Option (⌥)", 61),
        ("Left Option (⌥)", 58),
        ("Right Command (⌘)", 54),
        ("Right Shift (⇧)", 60),
        ("Right Control (⌃)", 62),
        ("Fn", 63),
        ("F5", 96),
        ("F6", 97),
        ("F7", 98),
        ("F8", 100),
        ("F9", 101),
        ("F10", 109),
        ("F11", 103),
        ("F12", 111),
    ]

    private static let namedKeyCodes: [Int: String] = [
        36: "Return",
        48: "Tab",
        49: "Space",
        51: "Delete",
        53: "Escape",
        54: "Right Command (⌘)",
        55: "Left Command (⌘)",
        56: "Left Shift (⇧)",
        57: "Caps Lock",
        58: "Left Option (⌥)",
        59: "Left Control (⌃)",
        60: "Right Shift (⇧)",
        61: "Right Option (⌥)",
        62: "Right Control (⌃)",
        63: "Fn",
        64: "F17",
        65: "Keypad .",
        67: "Keypad *",
        69: "Keypad +",
        71: "Clear",
        75: "Keypad /",
        76: "Keypad Enter",
        78: "Keypad -",
        79: "F18",
        80: "F19",
        81: "Keypad =",
        82: "Keypad 0",
        83: "Keypad 1",
        84: "Keypad 2",
        85: "Keypad 3",
        86: "Keypad 4",
        87: "Keypad 5",
        88: "Keypad 6",
        89: "Keypad 7",
        90: "F20",
        91: "Keypad 8",
        92: "Keypad 9",
        96: "F5",
        97: "F6",
        98: "F7",
        99: "F3",
        100: "F8",
        101: "F9",
        103: "F11",
        105: "F13",
        106: "F16",
        107: "F14",
        109: "F10",
        111: "F12",
        113: "F15",
        114: "Help",
        115: "Home",
        116: "Page Up",
        117: "Forward Delete",
        118: "F4",
        119: "End",
        120: "F2",
        121: "Page Down",
        122: "F1",
        123: "Left Arrow",
        124: "Right Arrow",
        125: "Down Arrow",
        126: "Up Arrow",
    ]

    /// Get the display name for a key code
    static func displayName(for keyCode: Int) -> String {
        commonHotKeys.first(where: { $0.keyCode == keyCode })?.name
            ?? namedKeyCodes[keyCode]
            ?? displayCharacter(for: keyCode)
            ?? "Key \(keyCode)"
    }

    /// Whether this key code is included in the curated preset list.
    static func isCommonHotKey(_ keyCode: Int) -> Bool {
        commonHotKeys.contains(where: { $0.keyCode == keyCode })
    }

    /// Whether this key code represents a modifier key that emits flagsChanged events.
    static func isModifierKeyCode(_ keyCode: Int) -> Bool {
        switch keyCode {
        case 54, 55, 56, 58, 59, 60, 61, 62, 63:
            return true
        default:
            return false
        }
    }

    private static func displayCharacter(for keyCode: Int) -> String? {
        let inputSource: TISInputSource? = {
            if let asciiSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
                return asciiSource
            }
            return TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        }()

        guard let source = inputSource,
              let layoutDataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return fallbackDisplayCharacter(for: keyCode)
        }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPointer).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> String? in
            guard let baseAddress = rawBuffer.baseAddress else {
                return fallbackDisplayCharacter(for: keyCode)
            }

            let keyboardLayout = baseAddress.assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            let maxStringLength = 4
            var actualStringLength = 0
            var unicodeString = [UniChar](repeating: 0, count: maxStringLength)

            let status = UCKeyTranslate(
                keyboardLayout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                maxStringLength,
                &actualStringLength,
                &unicodeString
            )

            guard status == noErr, actualStringLength > 0 else {
                return fallbackDisplayCharacter(for: keyCode)
            }

            let produced = String(utf16CodeUnits: unicodeString, count: actualStringLength)
            guard produced.rangeOfCharacter(from: .controlCharacters) == nil else {
                return fallbackDisplayCharacter(for: keyCode)
            }

            return produced.count == 1 ? produced.uppercased() : produced
        }
    }

    private static func fallbackDisplayCharacter(for keyCode: Int) -> String? {
        let qwertyNames: [Int: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G",
            6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
            12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
            24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
            43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
        ]

        return qwertyNames[keyCode]
    }
}
