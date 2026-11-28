// DirectInputCaptureTests.swift
// VocaMac
//
// A chosen microphone that isn't the system input is recorded through its
// own input unit, so AVAudioEngine never binds (and never switches AirPods
// into their call profile).

import AVFoundation
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

// MARK: - Chunking

final class InputChunkerTests: XCTestCase {
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!

    private func piece(from start: Int, frames: Int) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { buffer.floatChannelData![0][i] = Float(start + i) }
        return buffer
    }

    func testSmallHALBuffersBecomeEngineSizedChunks() throws {
        let chunker = try XCTUnwrap(InputChunker(format: format, maxPieceFrames: 512))
        XCTAssertEqual(chunker.chunkFrames, 4_096, "85 ms at 48 kHz, like the engine tap")

        var chunks: [[Float]] = []
        for n in 0..<20 {  // 20 × 512 = 10,240 frames
            chunker.append(piece(from: n * 512, frames: 512)) { chunk in
                chunks.append(Array(UnsafeBufferPointer(start: chunk.floatChannelData![0], count: Int(chunk.frameLength))))
            }
        }

        XCTAssertEqual(chunks.map(\.count), [4_096, 4_096], "two full chunks; the rest waits")
        XCTAssertEqual(chunks.flatMap { $0 }, (0..<8_192).map(Float.init), "samples in order across seams")
    }

    func testOddSizedBuffersLoseNothing() throws {
        let chunker = try XCTUnwrap(InputChunker(format: format, maxPieceFrames: 1_000))
        var emitted: [Float] = []
        var start = 0
        for size in [1_000, 333, 1_000, 999, 1_000, 1, 1_000] {
            chunker.append(piece(from: start, frames: size)) { chunk in
                emitted += UnsafeBufferPointer(start: chunk.floatChannelData![0], count: Int(chunk.frameLength))
            }
            start += size
        }
        // 1,000 + 333 + 1,000 + 999 + 1,000 = 4,332 passes 4,096: one chunk,
        // and the last 1,001 frames wait for the next.
        XCTAssertEqual(emitted.count, 4_332)
        XCTAssertEqual(emitted, (0..<4_332).map(Float.init), "in order, nothing dropped")
    }

    func testResetDropsAPartialChunk() throws {
        let chunker = try XCTUnwrap(InputChunker(format: format, maxPieceFrames: 512))
        chunker.append(piece(from: 0, frames: 512)) { _ in XCTFail("not full yet") }
        chunker.reset()
        var first: Float?
        for n in 0..<8 {
            chunker.append(piece(from: 1_000 + n * 512, frames: 512)) { first = $0.floatChannelData![0][0] }
        }
        XCTAssertEqual(first, 1_000, "the next recording starts clean")
    }

    func testOtherDeviceRatesKeepTheSameDuration() throws {
        let format16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        XCTAssertEqual(try XCTUnwrap(InputChunker(format: format16k, maxPieceFrames: 256)).chunkFrames, 1_365)
    }
}

final class ConfigurationChangeSourceTests: XCTestCase {
    func testOnlyTheEngineInUseCanStopARecording() {
        let current = ObjectIdentifier(NSObject.self)
        let retired = ObjectIdentifier(NSString.self)
        XCTAssertTrue(AudioEngine.isFromCurrentEngine(source: current, current: current))
        XCTAssertFalse(AudioEngine.isFromCurrentEngine(source: retired, current: current), "retired engine")
        XCTAssertFalse(AudioEngine.isFromCurrentEngine(source: retired, current: nil), "no engine: a direct capture")
        XCTAssertTrue(AudioEngine.isFromCurrentEngine(source: nil, current: current), "unattributed, as before")
    }
}
