import XCTest
import AVFoundation
#if canImport(Speech)
import Speech
#endif
@testable import VocaMac

#if compiler(>=6.2)
final class AppleSpeechAudioTests: XCTestCase {
    @available(macOS 26.0, *)
    private func converted(_ samples: [Float], chunkSize: Int, format: AVAudioFormat) async throws -> [Float] {
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        for offset in stride(from: 0, to: samples.count, by: chunkSize) {
            continuation.yield(Array(samples[offset..<min(samples.count, offset + chunkSize)]))
        }
        continuation.finish()
        let cursor = SpeechInputCursor(chunks: stream, format: format)
        var result: [Float] = []
        while let input = try await cursor.next() {
            let buffer = input.buffer
            let data = try XCTUnwrap(buffer.floatChannelData?[0])
            result.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }
        let count = await cursor.sampleCount
        XCTAssertEqual(count, samples.count)
        return result
    }

    func testChunkBoundariesPreserveResampledWaveformAndTail() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Apple Speech requires macOS 26") }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let samples = (0..<16_003).map { Float(sin(Double($0) * 0.07) * 0.4) }
        let whole = try await converted(samples, chunkSize: samples.count, format: format)
        let chunked = try await converted(samples, chunkSize: 137, format: format)
        XCTAssertEqual(chunked.count, whole.count)
        XCTAssertEqual(chunked.count, samples.count * 3)
        let largestDifference = zip(chunked, whole).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(largestDifference, 0.0001)
    }

    func testMatchingFormatPreservesSamples() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Apple Speech requires macOS 26") }
        let samples: [Float] = [0.1, -0.2, 0.3, -0.4, 0.5]
        let result = try await converted(samples, chunkSize: 2, format: AudioEngine.whisperFormat)
        XCTAssertEqual(result, samples)
    }

    /// Opt-in acceptance uses installed system assets only, never the microphone.
    func testInstalledAppleSpeechBatchAndStreaming() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Apple Speech requires macOS 26") }
        guard ProcessInfo.processInfo.environment["VOCAMAC_TEST_APPLE_SPEECH"] == "1" else {
            throw XCTSkip("Set VOCAMAC_TEST_APPLE_SPEECH=1 to exercise installed system speech assets")
        }
        let installed = await SpeechTranscriber.installedLocales
        guard let english = installed.first(where: { $0.language.languageCode?.identifier == "en" }) else {
            throw XCTSkip("English Apple Speech assets are not installed")
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/short-yes.wav")
        let samples = try AudioFileLoader().loadAudio(at: url).samples
        let service = AppleSpeechService()
        try await service.loadModel(language: english.identifier)
        do {
            let batch = try await service.transcribe(audioData: samples, language: english.identifier)
            let session = RecordingTranscription(language: english.identifier) { chunks in
                try await service.transcribe(chunks: chunks, language: english.identifier)
            }
            for offset in stride(from: 0, to: samples.count, by: 1024) {
                session.append(Array(samples[offset..<min(samples.count, offset + 1024)]), at: offset)
            }
            let live = try await session.finish(expectedSampleCount: samples.count)
            XCTAssertFalse(batch.text.isEmpty)
            XCTAssertEqual(live.text.lowercased(), batch.text.lowercased())
            XCTAssertEqual(live.audioLengthSeconds, Double(samples.count) / 16_000)
            await service.unloadModel()
        } catch {
            await service.unloadModel()
            throw error
        }
    }
}
#endif
