import AVFoundation
import XCTest
@testable import VocaMac

final class AudioPCMBufferCacheTests: XCTestCase {
    func testReuseAndReplacementAtFormatOrCapacityBoundary() throws {
        let cache = AudioPCMBufferCache()
        let first = try XCTUnwrap(cache.buffer(format: AudioEngine.whisperFormat, capacity: 32))
        first.frameLength = 32
        let reused = try XCTUnwrap(cache.buffer(format: AudioEngine.whisperFormat, capacity: 16))
        XCTAssertTrue(first === reused)
        XCTAssertEqual(reused.frameLength, 0)
        let larger = try XCTUnwrap(cache.buffer(format: AudioEngine.whisperFormat, capacity: 64))
        XCTAssertFalse(first === larger)
        let stereo = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let changed = try XCTUnwrap(cache.buffer(format: stereo, capacity: 64))
        XCTAssertEqual(changed.format, stereo)
        XCTAssertEqual(cache.creationCount, 3)
    }

    func testReusedMonoBufferDoesNotContainPreviousChannelSamples() throws {
        let cache = AudioPCMBufferCache()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        input.frameLength = 8
        for i in 0..<8 { input.floatChannelData?[0][i] = 1; input.floatChannelData?[1][i] = -1 }
        _ = AudioEngine.monoBuffer(from: input, selecting: 0, cache: cache)
        input.frameLength = 3
        let second = try XCTUnwrap(AudioEngine.monoBuffer(from: input, selecting: 1, cache: cache))
        XCTAssertEqual(second.frameLength, 3)
        for i in 0..<3 { XCTAssertEqual(second.floatChannelData?[0][i], -1) }
        XCTAssertEqual(cache.creationCount, 1)
    }
}
