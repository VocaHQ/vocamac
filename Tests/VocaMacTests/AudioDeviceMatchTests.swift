// AudioDeviceMatchTests.swift
// VocaMac
//
// A saved microphone must keep working when its Core Audio UID changes
// (a USB mic without a serial number moved to another port).

import XCTest
@testable import VocaMac

final class AudioDeviceMatchTests: XCTestCase {
    private let usbOnPortA = "AppleUSBAudioEngine:Unknown Manufacturer:USB PnP Audio Device:2100000:1"
    private let usbOnPortB = "AppleUSBAudioEngine:Unknown Manufacturer:USB PnP Audio Device:100000:1"

    private func device(_ id: String, _ name: String, builtIn: Bool = false) -> AudioDevice {
        AudioDevice(id: id, name: name, isDefault: false, sampleRate: 48_000, channelCount: 1, isBuiltIn: builtIn)
    }

    private var builtIn: AudioDevice { device("BuiltInMicrophoneDevice", "MacBook Pro Microphone", builtIn: true) }

    func testPortIndependentKeyDropsTheLocationPart() {
        XCTAssertEqual(AudioDeviceMatch.portIndependentKey(forUID: usbOnPortA),
                       AudioDeviceMatch.portIndependentKey(forUID: usbOnPortB))
        XCTAssertEqual(AudioDeviceMatch.portIndependentKey(forUID: usbOnPortB),
                       "AppleUSBAudioEngine:Unknown Manufacturer:USB PnP Audio Device:1")
    }

    func testPortIndependentKeyIsNilForOtherDevices() {
        XCTAssertNil(AudioDeviceMatch.portIndependentKey(forUID: "BuiltInMicrophoneDevice"))
        XCTAssertNil(AudioDeviceMatch.portIndependentKey(forUID: "80-99-E7-F8-AC-6D:input"))
        XCTAssertNil(AudioDeviceMatch.portIndependentKey(forUID: "AppleUSBAudioEngine:short:1"))
    }

    func testExactUIDWins() {
        let exact = device(usbOnPortA, "USB PnP Audio Device")
        let match = AudioDeviceMatch.device(
            forSavedID: usbOnPortA, savedName: "USB PnP Audio Device",
            among: [builtIn, device(usbOnPortB, "USB PnP Audio Device"), exact]
        )
        XCTAssertEqual(match?.id, usbOnPortA)
    }

    func testUSBMicMovedToAnotherPortIsFound() {
        let match = AudioDeviceMatch.device(
            forSavedID: usbOnPortA, savedName: "",
            among: [builtIn, device(usbOnPortB, "USB PnP Audio Device")]
        )
        XCTAssertEqual(match?.id, usbOnPortB)
    }

    func testTwoIdenticalUSBMicsAreNotGuessedBetween() {
        let match = AudioDeviceMatch.device(
            forSavedID: usbOnPortA, savedName: "USB PnP Audio Device",
            among: [
                device(usbOnPortB, "USB PnP Audio Device"),
                device("AppleUSBAudioEngine:Unknown Manufacturer:USB PnP Audio Device:3100000:1", "USB PnP Audio Device"),
            ]
        )
        XCTAssertNil(match)
    }

    func testUSBMicFromAnotherMakerWithTheSameNameIsNotUsed() {
        let match = AudioDeviceMatch.device(
            forSavedID: usbOnPortA, savedName: "USB PnP Audio Device",
            among: [builtIn, device("AppleUSBAudioEngine:C-Media:USB PnP Audio Device:1100000:1", "USB PnP Audio Device")]
        )
        XCTAssertNil(match)
    }

    func testUnpluggedHeadphoneMicDoesNotMatchAnything() {
        let match = AudioDeviceMatch.device(
            forSavedID: "BuiltInHeadphoneInputDevice", savedName: "External Microphone",
            among: [builtIn, device(usbOnPortB, "USB PnP Audio Device")]
        )
        XCTAssertNil(match)
    }

    func testUniqueNameIsTheLastResort() {
        let match = AudioDeviceMatch.device(
            forSavedID: "old-virtual-uid", savedName: "Studio Mic",
            among: [builtIn, device("new-virtual-uid", "Studio Mic")]
        )
        XCTAssertEqual(match?.id, "new-virtual-uid")
    }

    func testMissingDeviceStaysMissing() {
        XCTAssertNil(AudioDeviceMatch.device(forSavedID: usbOnPortA, savedName: "USB PnP Audio Device", among: [builtIn]))
        XCTAssertNil(AudioDeviceMatch.device(forSavedID: "", savedName: "MacBook Pro Microphone", among: [builtIn]))
    }
}

// MARK: - AppState

@MainActor
final class AppStateMicrophoneReconnectTests: XCTestCase {
    private let oldUID = "AppleUSBAudioEngine:Unknown Manufacturer:USB PnP Audio Device:2100000:1"
    private let newUID = "AppleUSBAudioEngine:Unknown Manufacturer:USB PnP Audio Device:100000:1"

    func testRecordingFollowsAUSBMicMovedToAnotherPort() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.selectedAudioDeviceID = oldUID
        appState.selectedAudioDeviceName = "USB PnP Audio Device"
        appState.selectedAudioChannelDeviceID = oldUID
        appState.availableInputDevices = { [self] in
            [
                AudioDevice(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", isDefault: true,
                            sampleRate: 48_000, channelCount: 1, isBuiltIn: true),
                AudioDevice(id: newUID, name: "USB PnP Audio Device", isDefault: false,
                            sampleRate: 48_000, channelCount: 1),
            ]
        }

        await appState.startRecording()

        XCTAssertEqual(mocks.audioEngine.lastPreferredInputDeviceID, newUID)
        XCTAssertEqual(mocks.audioEngine.lastPreferredInputChannelDeviceID, newUID)
        XCTAssertEqual(appState.selectedAudioDeviceID, newUID, "The saved choice follows the mic")
        await appState.cancelRecording()
    }

    func testUnpluggedMicKeepsTheSavedChoice() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.selectedAudioDeviceID = oldUID
        appState.selectedAudioDeviceName = "USB PnP Audio Device"
        appState.availableInputDevices = {
            [AudioDevice(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", isDefault: true,
                         sampleRate: 48_000, channelCount: 1, isBuiltIn: true)]
        }

        await appState.startRecording()

        XCTAssertEqual(mocks.audioEngine.lastPreferredInputDeviceID, oldUID,
                       "AudioEngine reports the fallback; the choice comes back when the mic does")
        XCTAssertEqual(appState.selectedAudioDeviceID, oldUID)
        await appState.cancelRecording()
    }
}
