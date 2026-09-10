// AudioDuckerTests.swift
// VocaMac Tests
//
// The mute-while-dictating policy against a fake output device. The output
// is shared system state, so most of these pin down when the ducker must
// *not* touch it, and that whatever it did touch always comes back.

import CoreAudio
import XCTest
@testable import VocaMac

// MARK: - Fake output

final class FakeOutputAudioControl: OutputAudioControlling {
    struct Device {
        var id: AudioDeviceID
        /// `nil`: the device has no mute control.
        var muted: Bool?
        /// `nil`: the device has no software volume.
        var volume: Float?
        var isOtherAudioPlaying = true
    }

    /// Devices by UID. A device missing here is not connected.
    var devices: [String: Device] = [:]
    var defaultUID: String? = "speakers"

    var setMutedShouldFail = false
    /// Drivers that acknowledge a mute write and do nothing.
    var muteWritesAreIgnored = false
    /// Drivers that mute by zeroing the volume, and leave it at zero on unmute.
    var muteZeroesVolume = false
    var setVolumeShouldFail = false

    private(set) var muteWrites: [(uid: String, muted: Bool)] = []
    private(set) var volumeWrites: [(uid: String, volume: Float)] = []

    var writeCount: Int { muteWrites.count + volumeWrites.count }

    private func uid(of deviceID: AudioDeviceID) -> String? {
        devices.first { $0.value.id == deviceID }?.key
    }

    func defaultOutputDevice() -> OutputDevice? {
        guard let uid = defaultUID, let device = devices[uid] else { return nil }
        return OutputDevice(id: device.id, uid: uid)
    }

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        devices[uid]?.id
    }

    func isOtherAudioPlaying(on deviceID: AudioDeviceID) -> Bool {
        uid(of: deviceID).flatMap { devices[$0]?.isOtherAudioPlaying } ?? false
    }

    func isMuted(_ deviceID: AudioDeviceID) -> Bool? {
        uid(of: deviceID).flatMap { devices[$0]?.muted }
    }

    @discardableResult
    func setMuted(_ muted: Bool, on deviceID: AudioDeviceID) -> Bool {
        guard let uid = uid(of: deviceID), devices[uid]?.muted != nil else { return false }
        muteWrites.append((uid, muted))
        guard !setMutedShouldFail else { return false }
        guard !muteWritesAreIgnored else { return true }
        devices[uid]?.muted = muted
        if muted && muteZeroesVolume {
            devices[uid]?.volume = 0
        }
        return true
    }

    func volume(of deviceID: AudioDeviceID) -> Float? {
        uid(of: deviceID).flatMap { devices[$0]?.volume }
    }

    @discardableResult
    func setVolume(_ volume: Float, of deviceID: AudioDeviceID) -> Bool {
        guard let uid = uid(of: deviceID), devices[uid]?.volume != nil else { return false }
        volumeWrites.append((uid, volume))
        guard !setVolumeShouldFail else { return false }
        devices[uid]?.volume = volume
        return true
    }
}

// MARK: - Tests

final class AudioDuckerTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var control: FakeOutputAudioControl!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var scheduled: [(delay: TimeInterval, work: () -> Void)] = []

    override func setUp() {
        super.setUp()
        suiteName = "AudioDuckerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        control = FakeOutputAudioControl()
        control.devices = ["speakers": .init(id: 10, muted: false, volume: 0.8)]
        scheduled = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        control = nil
        super.tearDown()
    }

    private func makeDucker() -> AudioDucker {
        AudioDucker(
            control: control,
            defaults: defaults,
            now: { [unowned self] in self.clock },
            schedule: { [unowned self] delay, work in self.scheduled.append((delay, work)) }
        )
    }

    /// Runs the settle check the ducker scheduled, as if its delay had passed.
    private func runScheduled() {
        let work = scheduled
        scheduled = []
        work.forEach { $0.work() }
    }

    private func persistedRecords() -> [AudioDucker.PendingRestore] {
        guard let data = defaults.data(forKey: AudioDucker.pendingRestoreKey) else { return [] }
        return (try? JSONDecoder().decode([AudioDucker.PendingRestore].self, from: data)) ?? []
    }

    private func speakers() -> FakeOutputAudioControl.Device? {
        control.devices["speakers"]
    }

    // MARK: Happy path

    func testMutesWhileDictatingAndUnmutesAfterwards() {
        let ducker = makeDucker()

        ducker.duck()
        XCTAssertEqual(speakers()?.muted, true)

        ducker.restore()
        XCTAssertEqual(speakers()?.muted, false)
        XCTAssertEqual(speakers()?.volume, 0.8, "Muting never touches the volume")
        XCTAssertTrue(control.volumeWrites.isEmpty)
    }

    func testRestoreSchedulesOneSettleCheck() {
        let ducker = makeDucker()
        ducker.duck()
        ducker.restore()

        XCTAssertEqual(scheduled.count, 1)
        XCTAssertEqual(scheduled.first?.delay, AudioDucker.settleDelay)

        runScheduled()
        XCTAssertEqual(speakers()?.muted, false)
        XCTAssertEqual(control.muteWrites.count, 2, "Mute, unmute — the settle check finds nothing left to do")
    }

    // MARK: Leave the output alone when…

    func testNothingPlayingMeansTheOutputIsNotTouched() {
        control.devices["speakers"]?.isOtherAudioPlaying = false
        let ducker = makeDucker()

        ducker.duck()
        ducker.restore()

        XCTAssertEqual(control.writeCount, 0)
        XCTAssertTrue(scheduled.isEmpty)
        XCTAssertNil(defaults.data(forKey: AudioDucker.pendingRestoreKey))
    }

    func testAMuteTheUserSetStaysTheirs() {
        control.devices["speakers"]?.muted = true
        let ducker = makeDucker()

        ducker.duck()
        ducker.restore()
        runScheduled()

        XCTAssertEqual(speakers()?.muted, true, "VocaMac did not mute it, so it must not unmute it")
        XCTAssertEqual(control.writeCount, 0)
    }

    func testUnmutingMidDictationIsRespected() {
        let ducker = makeDucker()
        ducker.duck()

        control.devices["speakers"]?.muted = false  // volume key mid-dictation

        ducker.restore()
        runScheduled()

        XCTAssertEqual(speakers()?.muted, false)
        XCTAssertEqual(control.muteWrites.count, 1, "Only the original mute — nothing re-muted or re-unmuted")
    }

    func testNoDefaultOutputMeansNothingHappens() {
        control.defaultUID = nil
        let ducker = makeDucker()

        ducker.duck()
        ducker.restore()

        XCTAssertEqual(control.writeCount, 0)
    }

    func testOutputWithNeitherMuteNorVolumeIsSkipped() {
        control.devices["speakers"] = .init(id: 10, muted: nil, volume: nil)
        let ducker = makeDucker()

        ducker.duck()
        ducker.restore()

        XCTAssertEqual(control.writeCount, 0)
        XCTAssertNil(defaults.data(forKey: AudioDucker.pendingRestoreKey))
    }

    // MARK: Bluetooth headsets (the reported bug)

    /// AirPods report a separate volume while their microphone is open, and
    /// return to the music-mode volume a couple of seconds after it closes.
    /// The volume-lowering version read the call-mode volume at restore,
    /// decided the user had moved the slider, and left music quiet; every
    /// dictation then lowered it further until it was silent.
    func testHeadsetVolumeSwitchingProfilesDoesNotStrandTheMute() {
        control.devices = ["airpods": .init(id: 88, muted: false, volume: 0.69)]
        control.defaultUID = "airpods"
        let ducker = makeDucker()

        ducker.duck()
        control.devices["airpods"]?.volume = 0.73  // mic open: call-mode volume

        ducker.restore()
        control.devices["airpods"]?.volume = 0.69  // mic closed: music volume is back
        runScheduled()

        XCTAssertEqual(control.devices["airpods"]?.muted, false)
        XCTAssertEqual(control.devices["airpods"]?.volume, 0.69)
        XCTAssertTrue(control.volumeWrites.isEmpty)
    }

    func testRepeatedDictationsNeverCompound() {
        let ducker = makeDucker()

        for _ in 0..<10 {
            ducker.duck()
            ducker.restore()
            runScheduled()
        }

        XCTAssertEqual(speakers()?.muted, false)
        XCTAssertEqual(speakers()?.volume, 0.8)
        XCTAssertNil(defaults.data(forKey: AudioDucker.pendingRestoreKey))
    }

    func testSettleCheckUnmutesIfTheRouteSwitchMutesAgain() {
        let ducker = makeDucker()
        ducker.duck()
        ducker.restore()

        control.devices["speakers"]?.muted = true  // profile switch brought the muted state back

        runScheduled()
        XCTAssertEqual(speakers()?.muted, false)
    }

    func testSettleCheckThatCannotUnmuteKeepsTheRecordForRelaunch() {
        let ducker = makeDucker()
        ducker.duck()
        ducker.restore()

        control.devices["speakers"]?.muted = true
        control.setMutedShouldFail = true
        runScheduled()
        XCTAssertEqual(persistedRecords().map(\.deviceUID), ["speakers"])
        XCTAssertNil(persistedRecords().first?.restoredAt, "Back to an ordinary pending mute, not a settle record")
        clock += AudioDucker.settleRecoveryWindow * 10

        control.setMutedShouldFail = false
        makeDucker().restoreAfterUnexpectedExit()
        XCTAssertEqual(speakers()?.muted, false)
    }

    func testANewRecordingRunsTheWaitingSettleCheckFirst() {
        let ducker = makeDucker()
        ducker.duck()
        ducker.restore()

        control.devices["speakers"]?.muted = true  // route switch re-muted it
        ducker.duck()  // next dictation, before the settle check fires

        XCTAssertEqual(speakers()?.muted, true)
        XCTAssertEqual(persistedRecords().map(\.deviceUID), ["speakers"], "Muted by VocaMac, not the user")
        ducker.restore()
        XCTAssertEqual(speakers()?.muted, false)
    }

    func testANewRecordingCancelsThePendingSettleCheck() {
        let ducker = makeDucker()
        ducker.duck()
        ducker.restore()

        ducker.duck()  // next dictation, before the settle check fires
        XCTAssertEqual(speakers()?.muted, true)

        runScheduled()
        XCTAssertEqual(speakers()?.muted, true, "The stale check must not unmute the new recording")
    }

    // MARK: Devices without a working mute

    func testNoMuteControlZeroesTheVolumeAndPutsTheExactLevelBack() {
        control.devices["speakers"] = .init(id: 10, muted: nil, volume: 0.57)
        let ducker = makeDucker()

        ducker.duck()
        XCTAssertEqual(speakers()?.volume, 0)

        ducker.restore()
        XCTAssertEqual(speakers()?.volume, 0.57)
    }

    func testZeroedVolumeTheUserTurnsUpIsLeftAlone() {
        control.devices["speakers"] = .init(id: 10, muted: nil, volume: 0.57)
        let ducker = makeDucker()
        ducker.duck()

        control.devices["speakers"]?.volume = 0.3

        ducker.restore()
        runScheduled()
        XCTAssertEqual(speakers()?.volume, 0.3)
    }

    func testAlreadySilentOutputWithoutMuteIsNotTouched() {
        control.devices["speakers"] = .init(id: 10, muted: nil, volume: 0)
        let ducker = makeDucker()

        ducker.duck()
        ducker.restore()

        XCTAssertEqual(control.writeCount, 0)
    }

    func testIgnoredMuteFallsBackToTheVolume() {
        control.muteWritesAreIgnored = true
        let ducker = makeDucker()

        ducker.duck()
        XCTAssertEqual(speakers()?.volume, 0)
        XCTAssertEqual(control.muteWrites.map(\.muted), [true, false], "Tried, then put the flag back")

        ducker.restore()
        XCTAssertEqual(speakers()?.volume, 0.8)
    }

    func testFailedVolumeRestoreAfterUnmuteIsRetried() {
        control.muteZeroesVolume = true
        let ducker = makeDucker()
        ducker.duck()

        control.setVolumeShouldFail = true
        ducker.restore()
        XCTAssertEqual(speakers()?.muted, false)
        XCTAssertEqual(speakers()?.volume, 0)
        XCTAssertNil(persistedRecords().first?.restoredAt, "Still owed a volume restore")

        control.setVolumeShouldFail = false
        runScheduled()
        XCTAssertEqual(speakers()?.volume, 0.8)
        XCTAssertTrue(persistedRecords().isEmpty)
    }

    func testDriverThatMutesByZeroingTheVolumeGetsItsVolumeBack() {
        control.muteZeroesVolume = true
        let ducker = makeDucker()

        ducker.duck()
        XCTAssertEqual(speakers()?.volume, 0)

        ducker.restore()
        XCTAssertEqual(speakers()?.muted, false)
        XCTAssertEqual(speakers()?.volume, 0.8)
    }

    // MARK: Device changes

    func testRestoresTheDeviceItMutedEvenAfterTheDefaultChanged() {
        control.devices["headphones"] = .init(id: 20, muted: false, volume: 0.5)
        let ducker = makeDucker()
        ducker.duck()

        control.defaultUID = "headphones"  // headphones connected mid-dictation

        ducker.restore()
        XCTAssertEqual(speakers()?.muted, false)
        XCTAssertEqual(control.devices["headphones"]?.muted, false)
        XCTAssertFalse(control.muteWrites.contains { $0.uid == "headphones" })
    }

    func testDisconnectedDeviceIsUnmutedWhenItComesBackUnderANewID() {
        control.devices = ["airpods": .init(id: 88, muted: false, volume: 0.7)]
        control.defaultUID = "airpods"
        let ducker = makeDucker()
        ducker.duck()

        let airpods = control.devices.removeValue(forKey: "airpods")
        ducker.restore()
        XCTAssertEqual(persistedRecords().map(\.deviceUID), ["airpods"], "Kept for when it returns")

        control.devices["airpods"] = airpods.map { .init(id: 131, muted: $0.muted, volume: $0.volume) }
        runScheduled()

        XCTAssertEqual(control.devices["airpods"]?.muted, false)
        XCTAssertTrue(persistedRecords().isEmpty)
    }

    func testFailedUnmuteIsRetriedAtTheSettleCheck() {
        let ducker = makeDucker()
        ducker.duck()

        control.setMutedShouldFail = true
        ducker.restore()
        XCTAssertEqual(speakers()?.muted, true)
        XCTAssertEqual(persistedRecords().count, 1)

        control.setMutedShouldFail = false
        runScheduled()
        XCTAssertEqual(speakers()?.muted, false)
        XCTAssertTrue(persistedRecords().isEmpty)
    }

    // MARK: Persistence and relaunch

    func testMuteIsPersistedUntilTheSettleCheckFinishes() {
        let ducker = makeDucker()

        ducker.duck()
        XCTAssertEqual(persistedRecords().map(\.deviceUID), ["speakers"])
        XCTAssertNil(persistedRecords().first?.restoredAt)

        ducker.restore()
        XCTAssertEqual(persistedRecords().first?.restoredAt, clock, "Kept, marked restored, for the settle check")

        runScheduled()
        XCTAssertNil(defaults.data(forKey: AudioDucker.pendingRestoreKey))
    }

    func testQuitDuringTheSettleWindowIsCoveredByAQuickRelaunch() {
        let ducker = makeDucker()
        ducker.duck()
        ducker.restore()  // willTerminate; the settle check never runs

        control.devices["speakers"]?.muted = true  // route switch re-muted it
        clock += 5

        makeDucker().restoreAfterUnexpectedExit()
        XCTAssertEqual(speakers()?.muted, false)
        XCTAssertNil(defaults.data(forKey: AudioDucker.pendingRestoreKey))
    }

    func testSettleRecordIsIgnoredByALateRelaunch() {
        let ducker = makeDucker()
        ducker.duck()
        ducker.restore()

        control.devices["speakers"]?.muted = true  // the user muted it later
        clock += AudioDucker.settleRecoveryWindow + 1
        let writes = control.writeCount

        makeDucker().restoreAfterUnexpectedExit()
        XCTAssertEqual(speakers()?.muted, true, "Already put back once; this mute is the user's")
        XCTAssertEqual(control.writeCount, writes)
        XCTAssertNil(defaults.data(forKey: AudioDucker.pendingRestoreKey))
    }

    func testRelaunchUnmutesWhatACrashLeftMuted() {
        makeDucker().duck()  // process dies here

        makeDucker().restoreAfterUnexpectedExit()

        XCTAssertEqual(speakers()?.muted, false)
        XCTAssertNil(defaults.data(forKey: AudioDucker.pendingRestoreKey))
    }

    func testRelaunchLeavesAnOutputTheUserAlreadyUnmuted() {
        makeDucker().duck()
        control.devices["speakers"]?.muted = false
        let writes = control.writeCount

        makeDucker().restoreAfterUnexpectedExit()

        XCTAssertEqual(control.writeCount, writes)
    }

    func testRelaunchDropsAMuteTooOldToTrust() {
        makeDucker().duck()
        clock += AudioDucker.maxPendingAge + 60

        makeDucker().restoreAfterUnexpectedExit()

        XCTAssertEqual(speakers()?.muted, true)
        XCTAssertNil(defaults.data(forKey: AudioDucker.pendingRestoreKey))
    }

    func testRelaunchWithNothingPendingDoesNothing() {
        makeDucker().restoreAfterUnexpectedExit()
        XCTAssertEqual(control.writeCount, 0)
    }

    func testRelaunchDiscardsTheOldVolumeRecord() {
        defaults.set(Data("[{\"deviceID\":88}]".utf8), forKey: AudioDucker.legacyPendingRestoreKey)

        makeDucker().restoreAfterUnexpectedExit()

        XCTAssertNil(defaults.data(forKey: AudioDucker.legacyPendingRestoreKey))
        XCTAssertEqual(control.writeCount, 0)
    }
}
