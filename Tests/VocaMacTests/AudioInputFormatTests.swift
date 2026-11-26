// AudioInputFormatTests.swift
// VocaMac
//
// The tap format must follow the device's sample rate after a device switch,
// or engine.start() fails with -10868 (format not supported).

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
}
