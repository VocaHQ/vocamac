// AudioDuckerTests.swift
// VocaMac Tests
//
// The ducking policy against a fake output device. The volume is shared
// system state, so most of these pin down when the ducker must *not* touch it.

import XCTest
@testable import VocaMac

// MARK: - Fake output

final class FakeOutputVolumeControl: OutputVolumeControlling {
    /// Volumes by device. A device missing here "has no software volume".
    var volumes: [UInt32: Float] = [:]
    var defaultDeviceID: UInt32? = 1
    var setCalls: [(deviceID: UInt32, volume: Float)] = []
    var setShouldFail = false

    func defaultOutput() -> OutputVolumeSnapshot? {
        guard let id = defaultDeviceID, let volume = volumes[id] else { return nil }
        return OutputVolumeSnapshot(deviceID: id, volume: volume)
    }

    func volume(of deviceID: UInt32) -> Float? {
        volumes[deviceID]
    }

    @discardableResult
    func setVolume(_ volume: Float, of deviceID: UInt32) -> Bool {
        setCalls.append((deviceID, volume))
        guard !setShouldFail, volumes[deviceID] != nil else { return false }
        volumes[deviceID] = volume
        return true
    }
}

// MARK: - Tests

final class AudioDuckerTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var control: FakeOutputVolumeControl!

    override func setUp() {
        super.setUp()
        suiteName = "AudioDuckerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        control = FakeOutputVolumeControl()
        control.volumes = [1: 0.8]
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeDucker() -> AudioDucker {
        AudioDucker(control: control, defaults: defaults)
    }

    /// Production persists an array of records; older builds stored one object.
    private func persistedRecords() -> [AudioDucker.PendingRestore]? {
        guard let data = defaults.data(forKey: AudioDucker.pendingRestoreKey) else { return nil }
        if let records = try? JSONDecoder().decode([AudioDucker.PendingRestore].self, from: data) {
            return records
        }
        if let record = try? JSONDecoder().decode(AudioDucker.PendingRestore.self, from: data) {
            return [record]
        }
        return nil
    }

    // MARK: Happy path

    func testDuckLowersToAQuarterAndRestoreBringsItBack() {
        let ducker = makeDucker()

        ducker.duck()
        XCTAssertEqual(control.volumes[1]!, 0.2, accuracy: 0.001)

        ducker.restore()
        XCTAssertEqual(control.volumes[1]!, 0.8, accuracy: 0.001)
    }

    // MARK: Leave the volume alone when…

    func testNoSoftwareVolumeMeansNothingHappens() {
        control.volumes = [:]
        let ducker = makeDucker()

        ducker.duck()
        ducker.restore()

        XCTAssertTrue(control.setCalls.isEmpty)
        XCTAssertNil(defaults.data(forKey: AudioDucker.pendingRestoreKey))
    }

    func testAlreadyQuietOutputIsNotTouched() {
        control.volumes = [1: 0.0]
        let ducker = makeDucker()

        ducker.duck()
        ducker.restore()

        XCTAssertTrue(control.setCalls.isEmpty, "Ducking silence would only record a pointless restore")
    }

    func testUserMovingTheSliderWhileDuckedWinsOverRestore() {
        let ducker = makeDucker()
        ducker.duck()

        control.volumes[1] = 0.6  // the user turned it up mid-dictation

        ducker.restore()
        XCTAssertEqual(control.volumes[1]!, 0.6, accuracy: 0.001, "Their choice stands")
        XCTAssertNil(defaults.data(forKey: AudioDucker.pendingRestoreKey), "User-moved volume is terminal; drop the record")
    }

    func testRestoreTargetsTheDeviceThatWasDuckedNotTheNewDefault() {
        control.volumes = [1: 0.8, 2: 0.5]
        let ducker = makeDucker()
        ducker.duck()

        control.defaultDeviceID = 2  // headphones plugged in mid-dictation

        ducker.restore()
        XCTAssertEqual(control.volumes[1]!, 0.8, accuracy: 0.001, "The speakers get their volume back")
        XCTAssertEqual(control.volumes[2]!, 0.5, accuracy: 0.001, "The headphones were never touched")
    }

    func testDeviceGoneAtRestoreIsLeftAlone() {
        let ducker = makeDucker()
        ducker.duck()

        control.volumes = [:]
        let callsBefore = control.setCalls.count

        ducker.restore()
        XCTAssertEqual(control.setCalls.count, callsBefore, "No device to restore on")
        XCTAssertNotNil(
            defaults.data(forKey: AudioDucker.pendingRestoreKey),
            "Nil volume read is not terminal; keep the record for retry"
        )
    }

    func testNilVolumeReadKeepsPendingUntilALaterRestoreSucceeds() {
        let ducker = makeDucker()
        ducker.duck()
        XCTAssertEqual(control.volumes[1]!, 0.2, accuracy: 0.001)

        control.volumes = [:]
        ducker.restore()
        XCTAssertNotNil(
            defaults.data(forKey: AudioDucker.pendingRestoreKey),
            "Nil read keeps persistence so restore can retry"
        )

        control.volumes = [1: 0.2]
        ducker.restore()
        XCTAssertEqual(control.volumes[1]!, 0.8, accuracy: 0.001)
        XCTAssertNil(defaults.data(forKey: AudioDucker.pendingRestoreKey))
    }

    func testUnreadablePendingAllowsASecondDuckOnADifferentDevice() {
        let ducker = makeDucker()
        ducker.duck()
        XCTAssertEqual(control.volumes[1]!, 0.2, accuracy: 0.001)

        control.volumes = [:]
        ducker.restore()
        XCTAssertNotNil(
            defaults.data(forKey: AudioDucker.pendingRestoreKey),
            "Nil volume read keeps the original pending restore"
        )

        control.volumes = [2: 0.8]
        control.defaultDeviceID = 2
        ducker.duck()

        XCTAssertEqual(control.volumes[2]!, 0.2, accuracy: 0.001, "The new default output is ducked")
        guard let records = persistedRecords() else {
            XCTFail("Expected pending restores to remain persisted")
            return
        }
        let byDevice = Dictionary(uniqueKeysWithValues: records.map { ($0.deviceID, $0) })
        XCTAssertEqual(records.count, 2, "Ducking B must not discard A's unresolved pending")
        XCTAssertEqual(byDevice[1]!.originalVolume, 0.8, accuracy: 0.001)
        XCTAssertEqual(byDevice[1]!.duckedVolume, 0.2, accuracy: 0.001)
        XCTAssertEqual(byDevice[2]!.originalVolume, 0.8, accuracy: 0.001)
        XCTAssertEqual(byDevice[2]!.duckedVolume, 0.2, accuracy: 0.001)

        control.volumes[1] = 0.2
        ducker.restore()
        XCTAssertEqual(control.volumes[1]!, 0.8, accuracy: 0.001, "A is restored once it is readable again")
        XCTAssertEqual(control.volumes[2]!, 0.8, accuracy: 0.001, "B is restored with A")
        XCTAssertNil(defaults.data(forKey: AudioDucker.pendingRestoreKey))
    }

    func testSecondDuckWhileDuckedIsIgnored() {
        let ducker = makeDucker()
        ducker.duck()
        XCTAssertEqual(control.volumes[1]!, 0.2, accuracy: 0.001)
        XCTAssertEqual(control.setCalls.count, 1, "First duck writes the ducked volume once")
        XCTAssertEqual(control.setCalls[0].volume, 0.2, accuracy: 0.001)

        ducker.duck()
        XCTAssertEqual(
            control.setCalls.count, 1,
            "A second duck must not restore then re-duck while volume is still readable"
        )
        XCTAssertEqual(control.volumes[1]!, 0.2, accuracy: 0.001)
        XCTAssertNotNil(defaults.data(forKey: AudioDucker.pendingRestoreKey))

        ducker.restore()
        XCTAssertEqual(control.volumes[1]!, 0.8, accuracy: 0.001)
        XCTAssertNil(defaults.data(forKey: AudioDucker.pendingRestoreKey))
    }

    func testRestoreWithoutDuckIsANoOp() {
        let ducker = makeDucker()
        ducker.restore()
        XCTAssertTrue(control.setCalls.isEmpty)
    }

    func testSetFailureRecordsNothingToRestore() {
        control.setShouldFail = true
        let ducker = makeDucker()

        ducker.duck()

        XCTAssertNil(defaults.data(forKey: AudioDucker.pendingRestoreKey))
        control.setShouldFail = false
        ducker.restore()
        XCTAssertEqual(control.setCalls.count, 1, "Only the failed duck attempt, no restore")
    }

    // MARK: Surviving a crash

    func testPendingRestoreIsPersistedWhileDucked() {
        let ducker = makeDucker()
        ducker.duck()
        XCTAssertNotNil(defaults.data(forKey: AudioDucker.pendingRestoreKey))

        ducker.restore()
        XCTAssertNil(defaults.data(forKey: AudioDucker.pendingRestoreKey))
    }

    func testNextLaunchRestoresAVolumeTheCrashedRunLeftLow() {
        makeDucker().duck()
        // Process dies here. `control.volumes[1]` is still 0.2.

        let relaunched = makeDucker()
        relaunched.restoreAfterUnexpectedExit()

        XCTAssertEqual(control.volumes[1]!, 0.8, accuracy: 0.001)
        XCTAssertNil(defaults.data(forKey: AudioDucker.pendingRestoreKey))
    }

    func testNextLaunchLeavesAVolumeTheUserAlreadyFixed() {
        makeDucker().duck()
        control.volumes[1] = 0.5  // they turned it back up themselves

        let relaunched = makeDucker()
        relaunched.restoreAfterUnexpectedExit()

        XCTAssertEqual(control.volumes[1]!, 0.5, accuracy: 0.001)
        XCTAssertNil(defaults.data(forKey: AudioDucker.pendingRestoreKey), "Stale record is cleared either way")
    }

    func testNextLaunchWithNothingPendingDoesNothing() {
        makeDucker().restoreAfterUnexpectedExit()
        XCTAssertTrue(control.setCalls.isEmpty)
    }

    func testLegacySinglePendingRestoreStillLoadsOnRelaunch() {
        let legacy = AudioDucker.PendingRestore(deviceID: 1, originalVolume: 0.8, duckedVolume: 0.2)
        guard let data = try? JSONEncoder().encode(legacy) else {
            XCTFail("Failed to encode a legacy single pending restore")
            return
        }
        defaults.set(data, forKey: AudioDucker.pendingRestoreKey)
        control.volumes = [1: 0.2]

        let relaunched = makeDucker()
        relaunched.restoreAfterUnexpectedExit()

        XCTAssertEqual(control.volumes[1]!, 0.8, accuracy: 0.001)
        XCTAssertNil(defaults.data(forKey: AudioDucker.pendingRestoreKey))
    }

    // MARK: Failed restore keeps the record for retry

    func testFailedRestoreKeepsPendingSoARetryCanSucceed() {
        let ducker = makeDucker()
        ducker.duck()
        XCTAssertEqual(control.volumes[1]!, 0.2, accuracy: 0.001)

        control.setShouldFail = true
        ducker.restore()

        XCTAssertEqual(control.volumes[1]!, 0.2, accuracy: 0.001, "Volume stays ducked when the write fails")
        XCTAssertNotNil(defaults.data(forKey: AudioDucker.pendingRestoreKey), "Record stays so restore can retry")

        control.setShouldFail = false
        ducker.restore()
        XCTAssertEqual(control.volumes[1]!, 0.8, accuracy: 0.001)
        XCTAssertNil(defaults.data(forKey: AudioDucker.pendingRestoreKey))
    }

    func testFailedCrashRecoveryKeepsPersistedRecordForRetry() {
        makeDucker().duck()

        control.setShouldFail = true
        let relaunched = makeDucker()
        relaunched.restoreAfterUnexpectedExit()

        XCTAssertEqual(control.volumes[1]!, 0.2, accuracy: 0.001)
        XCTAssertNotNil(defaults.data(forKey: AudioDucker.pendingRestoreKey))

        control.setShouldFail = false
        relaunched.restore()
        XCTAssertEqual(control.volumes[1]!, 0.8, accuracy: 0.001)
        XCTAssertNil(defaults.data(forKey: AudioDucker.pendingRestoreKey))
    }
}
