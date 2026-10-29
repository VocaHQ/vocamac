// MicrophoneCheckTests.swift
// VocaMac
//
// The microphone fixes: a device whose format the input node misreports
// (#379), named start failures, and the overlay's "No sound" warning.

import AudioToolbox
import XCTest
@testable import VocaMac

final class InputFormatAlignmentTests: XCTestCase {

    func testA16kMonoDeviceReportedAs48kStereoIsStale() {
        // The Poly Sync 10 from #379.
        XCTAssertTrue(AudioEngine.isInputFormatStale(
            reportedSampleRate: 48_000, reportedChannels: 2, deviceSampleRate: 16_000, deviceChannels: 1
        ))
    }

    func testAMatchingFormatIsLeftAlone() {
        XCTAssertFalse(AudioEngine.isInputFormatStale(
            reportedSampleRate: 48_000, reportedChannels: 1, deviceSampleRate: 48_000, deviceChannels: 1
        ))
        XCTAssertFalse(AudioEngine.isInputFormatStale(
            reportedSampleRate: 44_100, reportedChannels: 2, deviceSampleRate: 44_100.4, deviceChannels: 2
        ), "Rounding in the nominal rate isn't a mismatch")
    }

    func testFewerChannelsThanTheDeviceIsFine() {
        XCTAssertFalse(AudioEngine.isInputFormatStale(
            reportedSampleRate: 48_000, reportedChannels: 1, deviceSampleRate: 48_000, deviceChannels: 4
        ))
        XCTAssertTrue(AudioEngine.isInputFormatStale(
            reportedSampleRate: 48_000, reportedChannels: 2, deviceSampleRate: 48_000, deviceChannels: 1
        ))
    }

    func testUnknownDeviceValuesNeverCountAsAMismatch() {
        XCTAssertFalse(AudioEngine.isInputFormatStale(
            reportedSampleRate: 48_000, reportedChannels: 2, deviceSampleRate: 0, deviceChannels: 1
        ))
        XCTAssertFalse(AudioEngine.isInputFormatStale(
            reportedSampleRate: 48_000, reportedChannels: 2, deviceSampleRate: 16_000, deviceChannels: 0
        ))
    }

    func testFormatNotSupportedIsRetriedOnceOnAFreshEngine() {
        let error = NSError(domain: "com.apple.coreaudio.avfaudio", code: Int(kAudioUnitErr_FormatNotSupported))
        XCTAssertTrue(AudioEngine.isFormatNotSupported(error))
        XCTAssertTrue(AudioEngine.shouldRetryStart(after: error, attempt: 1))
        XCTAssertFalse(AudioEngine.shouldRetryStart(after: error, attempt: 2))
        let other = NSError(domain: NSOSStatusErrorDomain, code: -50)
        XCTAssertFalse(AudioEngine.isFormatNotSupported(other))
        XCTAssertFalse(AudioEngine.shouldRetryStart(after: other, attempt: 1))
    }
}

final class AudioStartFailureTests: XCTestCase {

    func testMessagesNameTheDeviceAndTheFormat() {
        let unsupported = AudioStartFailure.unsupportedFormat(device: "Poly Sync 10", sampleRate: 16_000, channels: 1)
        XCTAssertEqual(unsupported.overlayMessage, "Couldn’t open Poly Sync 10.")
        XCTAssertTrue(unsupported.message.contains("Poly Sync 10 (16 kHz, mono)"), unsupported.message)
        let stereo = AudioStartFailure.unsupportedFormat(device: "Mixer", sampleRate: 44_100, channels: 2)
        XCTAssertTrue(stereo.message.contains("(44.1 kHz, 2 channels)"), stereo.message)

        let silent = AudioStartFailure.noAudio(device: "AirPods")
        XCTAssertEqual(silent.overlayMessage, "No sound from AirPods.")
        XCTAssertTrue(silent.message.hasPrefix("No sound came from AirPods."))
    }

    func testKilohertz() {
        XCTAssertEqual(AudioStartFailure.kilohertz(16_000), "16")
        XCTAssertEqual(AudioStartFailure.kilohertz(44_100), "44.1")
        XCTAssertEqual(AudioStartFailure.kilohertz(8_000), "8")
    }

    @MainActor
    func testAFailedStartSaysWhy() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.audioEngine.startRecordingResult = false
        mocks.audioEngine.lastStartFailure = .noAudio(device: "Poly Sync 10")

        await appState.startRecording()

        XCTAssertFalse(appState.isRecording)
        XCTAssertEqual(appState.errorMessage, AudioStartFailure.noAudio(device: "Poly Sync 10").message)
    }

    @MainActor
    func testAFailedStartWithoutAReasonKeepsTheGeneralMessage() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.audioEngine.startRecordingResult = false

        await appState.startRecording()

        XCTAssertTrue(appState.errorMessage?.hasPrefix("Could not start the system default microphone") == true,
                      appState.errorMessage ?? "")
    }
}

final class SilentInputMonitorTests: XCTestCase {

    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    func testWarnsAfterTheWindowOfSilence() {
        var monitor = SilentInputMonitor()
        XCTAssertFalse(monitor.observe(level: 0, at: start))
        XCTAssertFalse(monitor.observe(level: 0, at: start.addingTimeInterval(1)))
        XCTAssertTrue(monitor.observe(level: 0, at: start.addingTimeInterval(SilentInputMonitor.window)))
        XCTAssertTrue(monitor.isWarning)
    }

    func testSoundClearsTheWarningForGood() {
        var monitor = SilentInputMonitor()
        _ = monitor.observe(level: 0, at: start)
        XCTAssertTrue(monitor.observe(level: 0, at: start.addingTimeInterval(3)))
        XCTAssertFalse(monitor.observe(level: 0.05, at: start.addingTimeInterval(3.1)))
        XCTAssertFalse(monitor.isWarning)
        XCTAssertFalse(monitor.observe(level: 0, at: start.addingTimeInterval(10)), "One sound proves the microphone works")
    }

    func testAQuietRoomIsNotSilence() {
        var monitor = SilentInputMonitor()
        // About -70 dBFS of room noise: RMS 0.0003, normalised by 0.3.
        let roomNoise: Float = 0.0003 / 0.3
        for second in 0..<5 {
            XCTAssertFalse(monitor.observe(level: roomNoise, at: start.addingTimeInterval(Double(second))))
        }
    }

    @MainActor
    func testTheOverlayIsToldOnceEachWay() async {
        let (appState, mocks) = AppState.makeTestState()
        await appState.startRecording()
        XCTAssertEqual(mocks.cursorOverlay.inputSilentChanges, [false], "A new recording starts without the warning")

        // Levels arrive about 15 times a second; fake two and a half seconds.
        appState.silentInputMonitor = SilentInputMonitor()
        appState.observeInputLevel(0)
        appState.silentInputMonitor = monitorPastTheWindow()
        appState.observeInputLevel(0)
        XCTAssertTrue(mocks.cursorOverlay.isInputSilent)

        appState.observeInputLevel(0.2)
        XCTAssertFalse(mocks.cursorOverlay.isInputSilent)
        XCTAssertEqual(mocks.cursorOverlay.inputSilentChanges, [false, true, false])
        await appState.cancelRecording()
    }

    /// A monitor whose first level arrived longer ago than the window.
    private func monitorPastTheWindow() -> SilentInputMonitor {
        var past = SilentInputMonitor()
        _ = past.observe(level: 0, at: Date().addingTimeInterval(-(SilentInputMonitor.window + 0.5)))
        return past
    }
}

@MainActor
final class OverlayModeAndSilenceTests: XCTestCase {

    func testListeningHintNamesTheModeAndSilence() {
        let model = MicIndicatorViewModel()
        model.phase = .recording
        model.showsEscapeHint = false
        model.modeName = "Code"
        XCTAssertEqual(OverlayCopy.listeningHint(model), "Code mode")
        model.isInputSilent = true
        XCTAssertEqual(OverlayCopy.listeningHint(model), "No sound from the microphone · Code mode")
    }
}
