// SpeechActivityTrimmerTests.swift
// VocaMac
//
// Silence trimming before the speech model runs.

import XCTest
@testable import VocaMac

final class SpeechActivityTrimmerTests: XCTestCase {

    private let second = SpeechActivityTrimmer.sampleRate
    private var pause: Int { Int(SpeechActivityTrimmer.maximumPause * Double(second)) }

    // MARK: Decisions

    func testNoSpeechWhenTheDetectorHeardNothing() {
        XCTAssertEqual(SpeechActivityTrimmer.decide(speech: [], peakProbability: 0.05, totalSamples: 3 * second),
                       .noSpeech)
    }

    func testUnsureDetectorKeepsTheRecording() {
        // Some speech-like frames, but no segment: whispered speech the model
        // should still get a chance at.
        XCTAssertEqual(SpeechActivityTrimmer.decide(speech: [], peakProbability: 0.4, totalSamples: 3 * second),
                       .keep)
    }

    func testMostlySpeechIsNotWorthTrimming() {
        let speech = [(second / 20)..<(3 * second - second / 20)]
        XCTAssertEqual(SpeechActivityTrimmer.decide(speech: speech, peakProbability: 0.9, totalSamples: 3 * second),
                       .keep)
    }

    func testLongSilenceIsTrimmed() {
        let speech = [(2 * second)..<(3 * second)]
        XCTAssertEqual(SpeechActivityTrimmer.decide(speech: speech, peakProbability: 0.9, totalSamples: 6 * second),
                       .trim(speech))
    }

    func testRangesAreClampedToTheRecording() {
        let decision = SpeechActivityTrimmer.decide(
            speech: [(-100)..<second, (4 * second)..<(9 * second)], peakProbability: 0.9, totalSamples: 6 * second
        )
        XCTAssertEqual(decision, .trim([0..<second, (4 * second)..<(6 * second)]))
    }

    func testEmptyRecordingHasNoSpeech() {
        XCTAssertEqual(SpeechActivityTrimmer.decide(speech: [], peakProbability: 1, totalSamples: 0), .noSpeech)
    }

    // MARK: Assembly

    func testShortPausesAreKeptWhole() {
        let samples = (0..<(4 * second)).map(Float.init)
        let ranges = [0..<second, (second + pause / 2)..<(2 * second)]
        let output = SpeechActivityTrimmer.apply(ranges, to: samples)
        XCTAssertEqual(output, Array(samples[0..<(2 * second)]))
    }

    func testLongPausesKeepOnlyTheirEdges() {
        let samples = (0..<(6 * second)).map(Float.init)
        let ranges = [0..<second, (4 * second)..<(5 * second)]
        let output = SpeechActivityTrimmer.apply(ranges, to: samples)
        XCTAssertEqual(output.count, 2 * second + pause)
        XCTAssertEqual(output.count, SpeechActivityTrimmer.assembledLength(ranges))
        // Speech is intact on both sides of the shortened pause.
        XCTAssertEqual(Array(output[0..<second]), Array(samples[0..<second]))
        XCTAssertEqual(Array(output.suffix(second)), Array(samples[(4 * second)..<(5 * second)]))
        XCTAssertEqual(output[second], samples[second])
        XCTAssertEqual(output[second + pause - 1], samples[4 * second - 1])
    }

    func testOverlappingRangesAreNotDuplicated() {
        let samples = (0..<(3 * second)).map(Float.init)
        let output = SpeechActivityTrimmer.apply([0..<(2 * second), second..<(3 * second)], to: samples)
        XCTAssertEqual(output, samples)
    }

    // MARK: Real detector

    /// Runs Silero on "Yes" padded with three seconds of silence on each side.
    /// Skipped unless the VAD model is already cached, so tests never download.
    func testSileroTrimsSilenceAroundSpeech() async throws {
        guard CoreMLModelCache.isComplete(VoiceActivityDetector.modelDirectory) else {
            throw XCTSkip("Silero VAD is not cached on this machine")
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/short-yes.wav")
        let speech = try AudioFileLoader().loadAudio(at: url).samples
        let silence = [Float](repeating: 0, count: 3 * second)
        let recording = silence + speech + silence

        let detector = VoiceActivityDetector()
        await detector.prepare()
        var decision = SpeechActivityTrimmer.Decision.keep
        for _ in 0..<50 {
            decision = await detector.decision(for: recording)
            if decision != .keep { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard case .trim(let ranges) = decision else {
            return XCTFail("Expected trimming, got \(decision)")
        }
        let trimmed = SpeechActivityTrimmer.apply(ranges, to: recording)
        XCTAssertLessThan(trimmed.count, recording.count / 2)
        XCTAssertGreaterThanOrEqual(trimmed.count, speech.count / 2)

        let silent = await detector.decision(for: silence + silence)
        XCTAssertEqual(silent, .noSpeech)
    }
}

final class CoreMLModelCacheTests: XCTestCase {

    private func makeBundle(in directory: URL, files: [String]) throws {
        let bundle = directory.appendingPathComponent("model.mlmodelc")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for file in files { FileManager.default.createFile(atPath: bundle.appendingPathComponent(file).path, contents: Data()) }
    }

    func testBundleWithoutProgramIsIncompleteAndRemoved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeBundle(in: directory, files: ["coremldata.bin", "metadata.json"])
        XCTAssertFalse(CoreMLModelCache.isComplete(directory))
        CoreMLModelCache.removeIfIncomplete(directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testCompleteBundleIsKept() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeBundle(in: directory, files: ["coremldata.bin", "model.mil"])
        XCTAssertTrue(CoreMLModelCache.isComplete(directory))
        CoreMLModelCache.removeIfIncomplete(directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testMissingDirectoryIsIncompleteButLeftAlone() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertFalse(CoreMLModelCache.isComplete(directory))
        CoreMLModelCache.removeIfIncomplete(directory)
    }
}
