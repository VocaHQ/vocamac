// SecureInputFallback.swift
// VocaMac
//
// Keeps keyed shortcuts working while macOS Secure Event Input is on.
//
// A password field, Terminal's Secure Keyboard Entry, or a stuck login
// window turns on Secure Event Input. Event taps then stop receiving
// key-down and key-up events, while modifier changes (flagsChanged) still
// arrive. A modifier-only hotkey such as Right Option keeps working; a keyed
// one such as ⌥Space, the extra shortcuts, and Escape-to-cancel go silent.
//
// Carbon hot keys are not affected, so while Secure Event Input is on the
// keyed bindings are also registered through `RegisterEventHotKey` and fed
// into the same handlers. They are removed again when it turns off.

import AppKit
import Carbon.HIToolbox

// MARK: - SecureInputMonitor

/// Reports when Secure Event Input turns on or off.
///
/// macOS has no notification for it, so the state is read when an app is
/// activated (the usual trigger) and every five seconds, the same cadence
/// as `ProcessMonitor`. The check is a single cheap system call.
final class SecureInputMonitor {

    static let pollInterval: TimeInterval = 5

    /// Called on the main thread with the new state.
    var onChange: ((Bool) -> Void)?

    private(set) var isEnabled = false
    private var activationObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private let isSecureInputEnabled: () -> Bool

    init(isSecureInputEnabled: @escaping () -> Bool = { IsSecureEventInputEnabled() }) {
        self.isSecureInputEnabled = isSecureInputEnabled
    }

    func start() {
        guard pollTimer == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        refresh()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        if isEnabled {
            isEnabled = false
            onChange?(false)
        }
    }

    /// Read the current state and report a change.
    func refresh() {
        let enabled = isSecureInputEnabled()
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        VocaLogger.info(.hotKeyManager, "Secure Event Input \(enabled ? "on" : "off")")
        onChange?(enabled)
    }
}

// MARK: - CarbonHotKeyRegistry

/// A set of Carbon hot keys with press and release callbacks on the main
/// thread. Registering replaces the whole set.
final class CarbonHotKeyRegistry {

    var onPress: ((UInt32) -> Void)?
    var onRelease: ((UInt32) -> Void)?

    private var registered: [UInt32: EventHotKeyRef] = [:]
    private var registeredCombos: [UInt32: HotKeyCombo] = [:]
    private var handler: EventHandlerRef?

    /// VocaMac's hot key signature, "VcMc".
    private static let signature: OSType = 0x5663_4D63

    deinit {
        unregisterAll()
        if let handler { RemoveEventHandler(handler) }
    }

    /// Register exactly these combos, keyed by caller-chosen identifiers.
    /// Combos Carbon cannot express (the Fn modifier, bare modifier keys)
    /// are skipped.
    func register(_ combos: [UInt32: HotKeyCombo]) {
        let usable = combos.filter { Self.isRegistrable($0.value) }
        guard usable != registeredCombos else { return }
        unregisterAll()
        guard !usable.isEmpty else { return }
        installHandlerIfNeeded()
        for (id, combo) in usable {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(combo.keyCode), Self.carbonModifiers(combo.modifiers),
                EventHotKeyID(signature: Self.signature, id: id),
                GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr, let ref {
                registered[id] = ref
                registeredCombos[id] = combo
            } else {
                VocaLogger.warning(.hotKeyManager, "Fallback shortcut \(KeyCodeReference.displayName(for: combo)) unavailable (\(status))")
            }
        }
    }

    func unregisterAll() {
        for ref in registered.values { UnregisterEventHotKey(ref) }
        registered = [:]
        registeredCombos = [:]
    }

    static func isRegistrable(_ combo: HotKeyCombo) -> Bool {
        !combo.modifiers.contains(.function) && !KeyCodeReference.isModifierKeyCode(combo.keyCode)
    }

    static func carbonModifiers(_ modifiers: HotKeyModifiers) -> UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == CarbonHotKeyRegistry.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let registry = Unmanaged<CarbonHotKeyRegistry>.fromOpaque(userData).takeUnretainedValue()
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) {
                registry.onPress?(hotKeyID.id)
            } else {
                registry.onRelease?(hotKeyID.id)
            }
            return noErr
        }, types.count, &types, userData, &handler)
    }
}
