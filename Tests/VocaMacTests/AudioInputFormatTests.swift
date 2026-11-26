// AudioInputFormatTests.swift
// VocaMac
//
// The tap format must follow the device's sample rate after a device switch,
// or engine.start() fails with -10868 (format not supported).

import AudioToolbox
import XCTest
@testable import VocaMac

final class AudioInputFormatTests: XCTestCase {
    func testChosenMicAtADifferentRateThanTheHeadsetIsAligned() {
        // Bluetooth headset in a call profile was the system input; a 48 kHz USB mic is chosen.
        XCTAssertTrue(AudioEngine.needsClientRateAlignment(hardwareRate: 48_000, clientRate: 24_000))
        XCTAssertTrue(AudioEngine.needsClientRateAlignment(hardwareRate: 16_000, clientRate: 44_100))
    }

    func testMatchingRatesAreLeftAlone() {
        XCTAssertFalse(AudioEngine.needsClientRateAlignment(hardwareRate: 48_000, clientRate: 48_000))
    }

    func testUnknownHardwareRateIsLeftAlone() {
        XCTAssertFalse(AudioEngine.needsClientRateAlignment(hardwareRate: 0, clientRate: 48_000))
        XCTAssertFalse(AudioEngine.needsClientRateAlignment(hardwareRate: .nan, clientRate: 48_000))
    }

    // MARK: - The format write

    /// Records property calls against a fake input unit.
    private final class FakeUnit {
        var format = AudioStreamBasicDescription(
            mSampleRate: 24_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        var reads: [(AudioUnitScope, AudioUnitElement)] = []
        var writes: [(AudioStreamBasicDescription, AudioUnitScope, AudioUnitElement)] = []
        var writeStatus: OSStatus = noErr

        var access: AudioUnitStreamFormatAccess {
            AudioUnitStreamFormatAccess(
                read: { scope, element in
                    self.reads.append((scope, element))
                    return self.format
                },
                write: { format, scope, element in
                    self.writes.append((format, scope, element))
                    if self.writeStatus == noErr { self.format = format }
                    return self.writeStatus
                }
            )
        }
    }

    func testMismatchWritesTheHardwareRateToTheInputSideOutputScope() throws {
        let unit = FakeUnit()
        let before = unit.format

        XCTAssertTrue(AudioEngine.alignInputClientRate(hardwareRate: 48_000, clientRate: 24_000, access: unit.access))

        let write = try XCTUnwrap(unit.writes.first)
        XCTAssertEqual(unit.writes.count, 1)
        XCTAssertEqual(write.1, kAudioUnitScope_Output, "The tap side is the output scope")
        XCTAssertEqual(write.2, 1, "Element 1 is the input side of an I/O unit")
        XCTAssertEqual(unit.reads.first?.0, kAudioUnitScope_Output)
        XCTAssertEqual(unit.reads.first?.1, 1)

        let written = write.0
        XCTAssertEqual(written.mSampleRate, 48_000)
        XCTAssertEqual(written.mFormatID, before.mFormatID)
        XCTAssertEqual(written.mFormatFlags, before.mFormatFlags)
        XCTAssertEqual(written.mBytesPerPacket, before.mBytesPerPacket)
        XCTAssertEqual(written.mFramesPerPacket, before.mFramesPerPacket)
        XCTAssertEqual(written.mBytesPerFrame, before.mBytesPerFrame)
        XCTAssertEqual(written.mChannelsPerFrame, before.mChannelsPerFrame)
        XCTAssertEqual(written.mBitsPerChannel, before.mBitsPerChannel)
    }

    func testMatchingRatesTouchNothing() {
        let unit = FakeUnit()
        XCTAssertFalse(AudioEngine.alignInputClientRate(hardwareRate: 24_000, clientRate: 24_000, access: unit.access))
        XCTAssertTrue(unit.reads.isEmpty)
        XCTAssertTrue(unit.writes.isEmpty)
    }

    func testARefusedWriteIsReported() {
        let unit = FakeUnit()
        unit.writeStatus = kAudioUnitErr_FormatNotSupported
        XCTAssertFalse(AudioEngine.alignInputClientRate(hardwareRate: 48_000, clientRate: 24_000, access: unit.access))
        XCTAssertEqual(unit.format.mSampleRate, 24_000)
    }

    // MARK: - Input-only unit for a chosen microphone

    /// A standalone HAL I/O unit, like the one AVAudioEngine's input node uses.
    private func makeHALUnit() throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        )
        let component = try XCTUnwrap(AudioComponentFindNext(nil, &description))
        var unit: AudioUnit?
        XCTAssertEqual(AudioComponentInstanceNew(component, &unit), noErr)
        return try XCTUnwrap(unit)
    }

    private func outputEnabled(_ unit: AudioUnit) -> UInt32 {
        var enabled: UInt32 = 99
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioUnitGetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabled, &size)
        return enabled
    }

    func testAChosenMicrophoneTurnsTheUnitsOutputOff() throws {
        // A shared input/output unit can't take another microphone while it
        // drives the system output (a Bluetooth headset's aggregate): -10851.
        let unit = try makeHALUnit()
        defer { AudioComponentInstanceDispose(unit) }
        XCTAssertEqual(outputEnabled(unit), 1, "a HAL unit starts with output on")

        XCTAssertTrue(AudioEngine.makeInputOnly(unit))
        XCTAssertEqual(outputEnabled(unit), 0)
        XCTAssertTrue(AudioEngine.makeInputOnly(unit), "already input-only is fine")
    }

    func testNoChosenMicrophoneFollowsTheSystemInput() {
        XCTAssertTrue(AudioEngine.followsSystemInput(preferredInputDeviceUID: nil))
        XCTAssertTrue(AudioEngine.followsSystemInput(preferredInputDeviceUID: "  "))
        XCTAssertTrue(
            AudioEngine.followsSystemInput(preferredInputDeviceUID: "no-such-microphone"),
            "a chosen microphone that isn't connected falls back to the system input"
        )
    }
}
