// AudioDeviceMonitor.swift
// VocaMac
//
// Watches Core Audio for input-device hot-plug and default-input changes.

import Foundation
import CoreAudio

extension Notification.Name {
    /// Posted on the main queue when the set of audio input devices, or the
    /// system default input, changes.
    static let vocaAudioDevicesChanged = Notification.Name("com.vocamac.audioDevicesChanged")
}

/// Keeps the microphone pickers honest. Without this, the device list is only
/// rebuilt when a view appears, so a headset connected (or removed) while the
/// menu or Settings window is open leaves the user picking from a stale list —
/// or staring at a device that is no longer there.
final class AudioDeviceMonitor {

    static let shared = AudioDeviceMonitor()

    /// Bluetooth profile switches fire several property changes in a row;
    /// coalesce them so the pickers rebuild once.
    static let coalesceInterval: TimeInterval = 0.3

    private static let observedSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultInputDevice,
    ]

    private let queue = DispatchQueue(label: "com.vocamac.audio-device-monitor")
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var isRunning = false
    private var pendingNotification: DispatchWorkItem?

    func start() {
        queue.sync {
            guard !isRunning else { return }

            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.scheduleNotification()
            }
            listenerBlock = block

            var added = 0
            for selector in Self.observedSelectors {
                var address = Self.address(for: selector)
                let status = AudioObjectAddPropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    queue,
                    block
                )
                if status == noErr {
                    added += 1
                } else {
                    VocaLogger.warning(.audioEngine, "Failed to observe Core Audio property \(selector): OSStatus \(status)")
                }
            }

            isRunning = added > 0
            if isRunning {
                VocaLogger.debug(.audioEngine, "Audio device monitor started")
            } else {
                listenerBlock = nil
            }
        }
    }

    func stop() {
        queue.sync {
            guard isRunning, let listenerBlock else { return }

            for selector in Self.observedSelectors {
                var address = Self.address(for: selector)
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    queue,
                    listenerBlock
                )
            }

            self.listenerBlock = nil
            isRunning = false
            pendingNotification?.cancel()
            pendingNotification = nil
        }
    }

    /// Must be called on `queue` (Core Audio delivers listener blocks there).
    private func scheduleNotification() {
        pendingNotification?.cancel()

        let workItem = DispatchWorkItem {
            NotificationCenter.default.post(name: .vocaAudioDevicesChanged, object: nil)
        }
        pendingNotification = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceInterval, execute: workItem)
    }

    private static func address(for selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
