// DirectInputCaptureTests.swift
// VocaMac
//
// A chosen microphone that isn't the system input is recorded through its
// own input unit, so AVAudioEngine never binds (and never switches AirPods
// into their call profile).

import CoreAudio
import XCTest
@testable import VocaMac

final class DirectInputCaptureTests: XCTestCase {
    private let usb: AudioDeviceID = 86
    private let builtIn: AudioDeviceID = 81
    private let airPods: AudioDeviceID = 98

    private func device(_ uid: String?, systemInput: AudioDeviceID? = 98) -> AudioDeviceID? {
        let connected = ["usb": usb, "built-in": builtIn, "airpods": airPods]
        return AudioEngine.directCaptureDevice(
            forPreferredUID: uid,
            deviceForUID: { connected[$0] },
            systemInput: { systemInput },
            isBluetooth: { $0 == self.airPods }
        )
    }

    func testAChosenWiredMicIsRecordedDirectly() {
        XCTAssertEqual(device("usb"), usb, "USB mic while AirPods are the system input")
        XCTAssertEqual(device("built-in"), builtIn)
        XCTAssertEqual(device(" usb "), usb)
    }

    func testTheEngineIsUsedOtherwise() {
        XCTAssertNil(device(nil), "System Default")
        XCTAssertNil(device(""), "blank choice")
        XCTAssertNil(device("not-connected"), "a chosen mic that is gone falls back to the system input")
        XCTAssertNil(device("usb", systemInput: 86), "the chosen mic is the system input")
        XCTAssertNil(device("airpods", systemInput: 81), "Bluetooth keeps the engine, which settles its call profile")
    }

    func testAnUnknownDeviceIsRefused() {
        XCTAssertNil(DirectInputCapture(deviceID: AudioDeviceID(kAudioObjectUnknown)) { _, _ in })
    }
}
