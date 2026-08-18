// SystemAudioMuteManager.swift
// VocaMac
//
// Temporarily mutes the macOS default output device while recording.

import Foundation
import CoreAudio

/// Temporarily mutes the default output device and restores its original state.
///
/// The snapshot is kept for one recording session so an output that was already
/// muted remains muted after recording, and a user volume/mute change is not
/// replaced with an assumed default state.
final class SystemAudioMuteManager: SystemAudioMuting {

    private struct MuteSnapshot {
        let deviceID: AudioDeviceID
        let wasMuted: Bool
    }

    private let stateLock = NSLock()
    private var muteSnapshot: MuteSnapshot?

    deinit {
        restoreSystemAudio()
    }

    /// Mutes the current default output device once for the active recording.
    func muteSystemAudio() {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard muteSnapshot == nil else { return }
        guard let deviceID = Self.defaultOutputDeviceID() else {
            VocaLogger.warning(.systemAudio, "Unable to mute system audio: no default output device")
            return
        }
        guard let wasMuted = Self.muteState(for: deviceID) else {
            VocaLogger.warning(.systemAudio, "Unable to read mute state for default output device \(deviceID)")
            return
        }

        if !wasMuted && !Self.setMute(true, for: deviceID) {
            VocaLogger.warning(.systemAudio, "Unable to mute default output device \(deviceID)")
            return
        }

        muteSnapshot = MuteSnapshot(deviceID: deviceID, wasMuted: wasMuted)
        VocaLogger.debug(.systemAudio, "System audio muted for recording")
    }

    /// Restores the output device's mute state captured at recording start.
    func restoreSystemAudio() {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard let snapshot = muteSnapshot else { return }
        muteSnapshot = nil

        guard Self.setMute(snapshot.wasMuted, for: snapshot.deviceID) else {
            VocaLogger.warning(.systemAudio, "Unable to restore system audio mute state")
            return
        }
        VocaLogger.debug(.systemAudio, "System audio mute state restored")
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            return nil
        }
        return deviceID
    }

    private static func muteState(for deviceID: AudioDeviceID) -> Bool? {
        var address = mutePropertyAddress
        var muteValue = UInt32(0)
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &muteValue
        )

        guard status == noErr else { return nil }
        return muteValue != 0
    }

    private static func setMute(_ muted: Bool, for deviceID: AudioDeviceID) -> Bool {
        var address = mutePropertyAddress
        var muteValue = muted ? UInt32(1) : UInt32(0)
        let dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            dataSize,
            &muteValue
        )
        return status == noErr
    }

    private static var mutePropertyAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
