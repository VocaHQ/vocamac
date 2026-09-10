// AudioDucker.swift
// VocaMac
//
// Mutes the default output while a recording is open so music or a video
// does not play into the microphone, then unmutes it — what other dictation
// apps (Wispr Flow, VoiceInk) do. macOS offers third parties no per-app
// ducking, and lowering the main volume cannot be undone reliably: Bluetooth
// headsets keep a separate volume while their microphone is open, so the
// lowered level can neither be read back nor put back until well after the
// recording ends. Mute is a single flag that survives that switch.

import AudioToolbox
import CoreAudio
import Foundation

// MARK: - OutputAudioControlling

/// An output device: its CoreAudio ID for this session, and its UID, which
/// stays the same across reconnects and relaunches.
struct OutputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
}

/// The CoreAudio surface `AudioDucker` depends on, kept behind a protocol so
/// the policy can be tested without touching real hardware.
protocol OutputAudioControlling: AnyObject {
    /// The current default output device, or `nil` if there is none.
    func defaultOutputDevice() -> OutputDevice?

    /// The current ID of the device with `uid`, or `nil` if it is not connected.
    func deviceID(forUID uid: String) -> AudioDeviceID?

    /// Whether any other process is playing audio right now.
    func isOtherAudioPlaying(on deviceID: AudioDeviceID) -> Bool

    /// The device's mute state, or `nil` when it has no settable mute control.
    func isMuted(_ deviceID: AudioDeviceID) -> Bool?

    /// Sets the device's mute state. Returns `false` on failure.
    @discardableResult
    func setMuted(_ muted: Bool, on deviceID: AudioDeviceID) -> Bool

    /// The device's main volume in `0...1`, or `nil` when it has no
    /// software-settable volume.
    func volume(of deviceID: AudioDeviceID) -> Float?

    /// Sets the device's main volume. Returns `false` on failure.
    @discardableResult
    func setVolume(_ volume: Float, of deviceID: AudioDeviceID) -> Bool
}

// MARK: - SystemOutputAudioControl

/// CoreAudio implementation of `OutputAudioControlling`. Not unit-tested:
/// it is thin, and its behaviour depends on the output device in use.
final class SystemOutputAudioControl: OutputAudioControlling {

    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    func defaultOutputDevice() -> OutputDevice? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        guard read(systemObject, kAudioHardwarePropertyDefaultOutputDevice, into: &deviceID),
              deviceID != kAudioObjectUnknown,
              let uid = uid(of: deviceID) else { return nil }
        return OutputDevice(id: deviceID, uid: uid)
    }

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        objectList(kAudioHardwarePropertyDevices).first { self.uid(of: $0) == uid }
    }

    func isOtherAudioPlaying(on deviceID: AudioDeviceID) -> Bool {
        // Process objects let VocaMac's own cue be told apart from other
        // apps' audio. Before macOS 14.2, fall back to whether anything at
        // all is running on the device.
        if #available(macOS 14.2, *) {
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let processes = objectList(kAudioHardwarePropertyProcessObjectList)
            if !processes.isEmpty {
                return processes.contains { process in
                    var pid: pid_t = 0
                    var isRunningOutput: UInt32 = 0
                    return read(process, kAudioProcessPropertyPID, into: &pid)
                        && pid != ownPID
                        && read(process, kAudioProcessPropertyIsRunningOutput, into: &isRunningOutput)
                        && isRunningOutput != 0
                }
            }
        }
        var isRunning: UInt32 = 0
        guard read(deviceID, kAudioDevicePropertyDeviceIsRunningSomewhere, into: &isRunning) else {
            // Unknown: muting something silent is harmless, missing music is not.
            return true
        }
        return isRunning != 0
    }

    func isMuted(_ deviceID: AudioDeviceID) -> Bool? {
        guard isSettable(deviceID, kAudioDevicePropertyMute) else { return nil }
        var muted: UInt32 = 0
        guard read(deviceID, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, into: &muted) else {
            return nil
        }
        return muted != 0
    }

    @discardableResult
    func setMuted(_ muted: Bool, on deviceID: AudioDeviceID) -> Bool {
        write(deviceID, kAudioDevicePropertyMute, value: UInt32(muted ? 1 : 0))
    }

    func volume(of deviceID: AudioDeviceID) -> Float? {
        guard isSettable(deviceID, kAudioHardwareServiceDeviceProperty_VirtualMainVolume) else { return nil }
        var volume: Float32 = 0
        guard read(
            deviceID,
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioDevicePropertyScopeOutput,
            into: &volume
        ) else { return nil }
        return volume
    }

    @discardableResult
    func setVolume(_ volume: Float, of deviceID: AudioDeviceID) -> Bool {
        write(
            deviceID,
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            value: Float32(min(max(volume, 0), 1))
        )
    }

    // MARK: Property access

    private func uid(of deviceID: AudioDeviceID) -> String? {
        var uid: Unmanaged<CFString>?
        guard read(deviceID, kAudioDevicePropertyDeviceUID, into: &uid), let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private func objectList(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = Self.address(selector, scope: kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return [] }
        let stride = MemoryLayout<AudioObjectID>.stride
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / stride)
        guard !objects.isEmpty,
              AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / stride))
    }

    private func isSettable(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = Self.address(selector, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr && settable.boolValue
    }

    private func read<Value>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        into value: inout Value
    ) -> Bool {
        var address = Self.address(selector, scope: scope)
        var size = UInt32(MemoryLayout<Value>.size)
        return withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr
        }
    }

    private func write<Value>(
        _ deviceID: AudioDeviceID,
        _ selector: AudioObjectPropertySelector,
        value: Value
    ) -> Bool {
        var address = Self.address(selector, scope: kAudioDevicePropertyScopeOutput)
        let size = UInt32(MemoryLayout<Value>.size)
        return withUnsafePointer(to: value) { pointer in
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, pointer) == noErr
        }
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

// MARK: - AudioDucker

/// Mutes the default output for the duration of a recording and unmutes it
/// afterwards. The output is shared system state, so the rules are
/// conservative:
///
/// - Only touch the output when another app is actually playing.
/// - Never take over a mute the user set; if they unmute during the
///   recording, do not mute again.
/// - Undo only on the device that was muted, found by UID so a reconnect or
///   relaunch still finds it.
/// - Undoing is idempotent: it acts only while the device is still silenced
///   the way the ducker left it. That makes it safe to repeat once the output
///   route has settled — a Bluetooth headset leaves its call profile a couple
///   of seconds after the microphone closes — and after a crash.
///
/// Devices without a mute control get their volume set to zero and put back
/// to the exact previous level, which, unlike lowering it partway, needs no
/// tolerance to tell "still where we left it" from "the user moved it".
///
/// A mute the user switches off and on again during one recording looks the
/// same as VocaMac's own and is undone with it. Telling them apart needs a
/// mute-change listener, and a listener that took a headset's profile switch
/// for the user unmuting would leave the output muted for good — worse than
/// the double toggle it guards against.
final class AudioDucker: AudioDucking {

    /// How a device was silenced, which decides how it is undone.
    enum Silencing: Codable, Equatable {
        /// Muted with the device's mute control. `volume` is the main volume
        /// at that moment: some USB drivers mute by zeroing it and leave it
        /// there after unmuting.
        case muted(volume: Float?)
        /// The device has no working mute control, so its volume was set to
        /// zero from `volume`.
        case zeroedVolume(from: Float)
    }

    /// A device the ducker silenced.
    struct PendingRestore: Codable, Equatable {
        let deviceUID: String
        let silencing: Silencing
        let date: Date
        /// When the end-of-recording restore undid it, leaving only the
        /// settle check; `nil` while the device is still silenced.
        var restoredAt: Date? = nil
    }

    static let pendingRestoreKey = "vocamac.duckOtherAudio.pendingMute"
    /// Written by the volume-lowering version of this feature. Its records
    /// cannot be trusted (see the file header), so they are dropped.
    static let legacyPendingRestoreKey = "vocamac.duckOtherAudio.pendingRestore"

    /// Volumes at or below this count as silent.
    static let silentVolume: Float = 0.01

    /// How long after a recording ends to check the output once more. A
    /// Bluetooth headset takes about two seconds to leave its call profile
    /// after the microphone closes.
    static let settleDelay: TimeInterval = 3

    /// A pending restore older than this is dropped rather than applied: the
    /// device has been gone too long to assume its state is still ours.
    static let maxPendingAge: TimeInterval = 24 * 60 * 60

    /// A relaunch this soon after a restore still runs the settle check the
    /// previous process did not get to. Later, the record is dropped: the
    /// output was already put back, and any mute since is the user's.
    static let settleRecoveryWindow: TimeInterval = 60

    private let control: OutputAudioControlling
    private let defaults: UserDefaults
    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    /// Silenced and not yet undone, keyed by device UID. Persisted.
    private var pending: [String: PendingRestore] = [:]
    /// Undone at the end of the last recording, awaiting the settle check.
    /// Persisted, so a quit or crash inside the window is still covered.
    private var settling: [String: PendingRestore] = [:]
    /// Bumped to cancel a scheduled settle check.
    private var settleGeneration = 0

    init(
        control: OutputAudioControlling = SystemOutputAudioControl(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        self.control = control
        self.defaults = defaults
        self.now = now
        self.schedule = schedule
    }

    // MARK: AudioDucking

    func duck() {
        // Run a settle check still waiting on the last recording now, so a
        // device it would have unmuted is not mistaken for a user's mute.
        settleGeneration += 1
        runSettleCheck(reason: "before a new recording")

        guard let output = control.defaultOutputDevice() else {
            VocaLogger.info(.audioDucker, "No default output device — not muting")
            return
        }
        guard pending[output.uid] == nil else {
            VocaLogger.debug(.audioDucker, "Output is still muted from an earlier recording — leaving it")
            return
        }
        guard control.isOtherAudioPlaying(on: output.id) else {
            VocaLogger.debug(.audioDucker, "Nothing else is playing — leaving the output alone")
            return
        }

        let volume = control.volume(of: output.id)
        if let isMuted = control.isMuted(output.id) {
            if isMuted {
                VocaLogger.info(.audioDucker, "Output is already muted — leaving it as the user set it")
                return
            }
            if control.setMuted(true, on: output.id), control.isMuted(output.id) == true {
                record(output, .muted(volume: volume))
                VocaLogger.info(.audioDucker, "Muted device \(output.id) while dictating")
                return
            }
            // Some drivers acknowledge the write and do nothing. Put the flag
            // back in case it half-applied, then use the volume instead.
            control.setMuted(false, on: output.id)
            VocaLogger.warning(.audioDucker, "Mute did not take on device \(output.id) — using the volume instead")
        }

        guard let volume else {
            VocaLogger.info(.audioDucker, "Output has no mute or software volume (e.g. HDMI) — not muting")
            return
        }
        guard volume > Self.silentVolume else {
            VocaLogger.debug(.audioDucker, "Output volume is already at zero — nothing to mute")
            return
        }
        guard control.setVolume(0, of: output.id) else {
            VocaLogger.warning(.audioDucker, "Could not set the volume on device \(output.id)")
            return
        }
        record(output, .zeroedVolume(from: volume))
        VocaLogger.info(.audioDucker, "Set device \(output.id) to 0% while dictating (was \(Self.percent(volume)))")
    }

    func restore() {
        guard !pending.isEmpty else { return }
        undoPendingAndScheduleSettleCheck(reason: "recording ended")
    }

    func restoreAfterUnexpectedExit() {
        defaults.removeObject(forKey: Self.legacyPendingRestoreKey)
        for var record in loadPersisted() where pending[record.deviceUID] == nil {
            if let restoredAt = record.restoredAt {
                guard now().timeIntervalSince(restoredAt) <= Self.settleRecoveryWindow else { continue }
                record.restoredAt = nil
            }
            pending[record.deviceUID] = record
        }
        // The headset may still be leaving its call profile, so settle here too.
        undoPendingAndScheduleSettleCheck(reason: "previous run ended while muted")
    }

    // MARK: Undo

    /// Undoes the pending records, keeps the finished ones for the settle
    /// check, and schedules it while anything is left to check or retry.
    private func undoPendingAndScheduleSettleCheck(reason: String) {
        let restoredAt = now()
        for var record in undoPending(reason: reason) {
            record.restoredAt = restoredAt
            settling[record.deviceUID] = record
        }
        persistRecords()
        guard !settling.isEmpty || !pending.isEmpty else { return }
        scheduleSettleCheck()
    }

    /// Undoes every pending record whose device is connected, removing the
    /// ones that are finished. Records whose device is missing or whose
    /// write failed stay pending for a later retry; stale ones are dropped.
    /// - Returns: the records that were removed because they are finished.
    @discardableResult
    private func undoPending(reason: String) -> [PendingRestore] {
        var finished: [PendingRestore] = []
        for (uid, record) in pending {
            if now().timeIntervalSince(record.date) > Self.maxPendingAge {
                VocaLogger.info(.audioDucker, "Dropping a mute too old to undo safely")
                pending.removeValue(forKey: uid)
                continue
            }
            guard let deviceID = control.deviceID(forUID: uid) else {
                VocaLogger.info(.audioDucker, "The muted output is not connected — will unmute it when it is (\(reason))")
                continue
            }
            if undo(record, on: deviceID, reason: reason) {
                pending.removeValue(forKey: uid)
                finished.append(record)
            }
        }
        return finished
    }

    /// Puts `deviceID` back if it is still silenced the way `record` says.
    /// Idempotent: a device that is no longer silenced — already undone, or
    /// changed by the user — is left alone.
    /// - Returns: `true` when finished, `false` when a write failed and a
    ///   retry may still help.
    private func undo(_ record: PendingRestore, on deviceID: AudioDeviceID, reason: String) -> Bool {
        switch record.silencing {
        case .muted(let volume):
            if control.isMuted(deviceID) == true {
                guard control.setMuted(false, on: deviceID) else {
                    VocaLogger.warning(.audioDucker, "Could not unmute device \(deviceID) (\(reason))")
                    return false
                }
                VocaLogger.info(.audioDucker, "Unmuted device \(deviceID) (\(reason))")
            }
            guard let volume else { return true }
            return restoreVolumeIfZeroed(volume, on: deviceID, reason: reason)

        case .zeroedVolume(let volume):
            guard let current = control.volume(of: deviceID) else {
                VocaLogger.warning(.audioDucker, "Could not read the volume on device \(deviceID) (\(reason))")
                return false
            }
            guard current <= Self.silentVolume else { return true }
            guard control.setVolume(volume, of: deviceID) else {
                VocaLogger.warning(.audioDucker, "Could not restore the volume on device \(deviceID) (\(reason))")
                return false
            }
            VocaLogger.info(.audioDucker, "Restored device \(deviceID) to \(Self.percent(volume)) (\(reason))")
            return true
        }
    }

    /// Covers drivers that mute by zeroing the volume and leave it there.
    /// - Returns: `false` only when the volume is still zero and could not
    ///   be put back, so the record is kept for a retry.
    private func restoreVolumeIfZeroed(_ volume: Float, on deviceID: AudioDeviceID, reason: String) -> Bool {
        guard volume > Self.silentVolume,
              let current = control.volume(of: deviceID),
              current <= Self.silentVolume else { return true }
        guard control.setVolume(volume, of: deviceID) else {
            VocaLogger.warning(.audioDucker, "Unmuting left device \(deviceID) at 0% and it could not be restored (\(reason))")
            return false
        }
        VocaLogger.info(
            .audioDucker,
            "Unmuting left device \(deviceID) at 0% — restored \(Self.percent(volume)) (\(reason))"
        )
        return true
    }

    // MARK: Settle check

    /// Runs `runSettleCheck` after `settleDelay`, replacing any check
    /// already scheduled.
    private func scheduleSettleCheck() {
        settleGeneration += 1
        let generation = settleGeneration
        schedule(Self.settleDelay) { [weak self] in
            guard let self, self.settleGeneration == generation else { return }
            self.runSettleCheck(reason: "output settled")
        }
    }

    /// Undoes once more what the last recording's restore undid, in case the
    /// output route switched back to a silenced state, and retries anything
    /// still pending.
    private func runSettleCheck(reason: String) {
        if !pending.isEmpty {
            undoPending(reason: reason)
        }
        let records = settling
        settling = [:]
        for (uid, record) in records {
            if let deviceID = control.deviceID(forUID: uid),
               undo(record, on: deviceID, reason: reason) {
                continue
            }
            // The device left mid-switch, or the unmute failed: keep the
            // record so the next recording or launch tries again.
            var retry = record
            retry.restoredAt = nil
            pending[uid] = pending[uid] ?? retry
        }
        persistRecords()
    }

    // MARK: Persistence

    /// Takes ownership of what `duck` just did to `output`, and saves it.
    private func record(_ output: OutputDevice, _ silencing: Silencing) {
        pending[output.uid] = PendingRestore(deviceUID: output.uid, silencing: silencing, date: now())
        persistRecords()
    }

    /// Saves the pending and settling records so a crash or quit can be
    /// undone on the next launch. No records clears the key.
    private func persistRecords() {
        let records = pending.merging(settling) { pending, _ in pending }
            .values
            .sorted { $0.deviceUID < $1.deviceUID }
        guard !records.isEmpty else {
            defaults.removeObject(forKey: Self.pendingRestoreKey)
            return
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.pendingRestoreKey)
    }

    /// Records the previous process saved; empty if none or unreadable.
    private func loadPersisted() -> [PendingRestore] {
        guard let data = defaults.data(forKey: Self.pendingRestoreKey) else { return [] }
        return (try? JSONDecoder().decode([PendingRestore].self, from: data)) ?? []
    }

    /// Formats `volume` as a whole-number percent for log lines.
    private static func percent(_ volume: Float) -> String {
        "\(Int((volume * 100).rounded()))%"
    }
}
