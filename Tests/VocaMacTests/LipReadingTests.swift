// LipReadingTests.swift
// VocaMacTests
//
// The lip reader's input and output: face alignment, the mouth crop cut
// the way the model's training data was, windows the Core ML model accepts,
// CTC decoding, and Silent Mode typing what the lips said.

import CoreGraphics
import XCTest
@testable import VocaMac

final class MouthCropTests: XCTestCase {

    func testASimilarityIsRecoveredFromItsPoints() throws {
        let truth = SimilarityTransform(a: 1.7 * cos(0.2), b: 1.7 * sin(0.2), tx: 31, ty: -12)
        let source = [CGPoint(x: 10, y: 20), CGPoint(x: 80, y: 25), CGPoint(x: 45, y: 70), CGPoint(x: 46, y: 95)]
        let estimated = try XCTUnwrap(SimilarityTransform.estimate(from: source, to: source.map(truth.apply)))
        XCTAssertEqual(estimated.a, truth.a, accuracy: 1e-9)
        XCTAssertEqual(estimated.b, truth.b, accuracy: 1e-9)
        XCTAssertEqual(estimated.tx, truth.tx, accuracy: 1e-9)
        XCTAssertEqual(estimated.ty, truth.ty, accuracy: 1e-9)
        let inverse = try XCTUnwrap(estimated.inverse)
        let back = inverse.apply(estimated.apply(CGPoint(x: 5, y: 9)))
        XCTAssertEqual(back.x, 5, accuracy: 1e-9)
        XCTAssertEqual(back.y, 9, accuracy: 1e-9)
    }

    func testDegeneratePointsHaveNoTransform() {
        XCTAssertNil(SimilarityTransform.estimate(from: [CGPoint(x: 1, y: 1)], to: [CGPoint(x: 2, y: 2)]))
        let same = Array(repeating: CGPoint(x: 3, y: 3), count: 4)
        XCTAssertNil(SimilarityTransform.estimate(from: same, to: MouthCropGeometry.reference))
    }

    func testSamplingIsBilinearAndZeroOutside() {
        let pixels: [UInt8] = [0, 100, 200, 0]
        pixels.withUnsafeBufferPointer { buffer in
            XCTAssertEqual(MouthCropGeometry.sample(buffer, width: 2, height: 2, rowBytes: 2, x: 0.5, y: 0), 50)
            XCTAssertEqual(MouthCropGeometry.sample(buffer, width: 2, height: 2, rowBytes: 2, x: 0, y: 0.5), 100)
            XCTAssertEqual(MouthCropGeometry.sample(buffer, width: 2, height: 2, rowBytes: 2, x: 10, y: 0), 0)
        }
    }

    /// A face in a 640×480 picture with a bright spot at the mouth: the crop
    /// puts the spot at its centre, as the model expects the mouth.
    func testTheCropIsCentredOnTheMouth() throws {
        let (patch, _) = try Self.face(shift: CGPoint(x: 0, y: 0))
        var builder = MouthCropBuilder()
        var crops: [MouthCrop] = []
        for index in 0..<10 { crops += builder.ingest(time: Double(index) / 30, patch: patch) }
        XCTAssertEqual(crops.count, 10 - MouthCropBuilder.halfWindow, "Each crop waits for the six frames after it")
        crops += builder.finish()
        XCTAssertEqual(crops.count, 10)
        let crop = try XCTUnwrap(crops.first)
        XCTAssertEqual(crop.pixels.count, 88 * 88)
        let brightest = try XCTUnwrap(crop.pixels.indices.max { crop.pixels[$0] < crop.pixels[$1] })
        XCTAssertEqual(Double(brightest % 88), 44, accuracy: 2)
        XCTAssertEqual(Double(brightest / 88), 44, accuracy: 2)
    }

    func testSmoothingFollowsTheFaceAcrossFrames() throws {
        var builder = MouthCropBuilder()
        var crops: [MouthCrop] = []
        // The face drifts right; every crop still has the mouth near its centre.
        for index in 0..<20 {
            let (patch, _) = try Self.face(shift: CGPoint(x: Double(index) * 2, y: 0))
            crops += builder.ingest(time: Double(index) / 30, patch: patch)
        }
        crops += builder.finish()
        for crop in crops {
            let brightest = try XCTUnwrap(crop.pixels.indices.max { crop.pixels[$0] < crop.pixels[$1] })
            XCTAssertEqual(Double(brightest % 88), 44, accuracy: 8)
        }
    }

    /// A grayscale picture with a 7×7 bright spot at the mouth, and its patch.
    static func face(shift: CGPoint) throws -> (MouthPatch, MouthKeypoints) {
        let width = 640, height = 480
        let keypoints = MouthKeypoints(
            rightEye: CGPoint(x: 280 + shift.x, y: 200 + shift.y), leftEye: CGPoint(x: 360 + shift.x, y: 199 + shift.y),
            nose: CGPoint(x: 320 + shift.x, y: 262 + shift.y), mouth: CGPoint(x: 320 + shift.x, y: 294 + shift.y)
        )
        var image = [UInt8](repeating: 40, count: width * height)
        let mx = Int(keypoints.mouth.x), my = Int(keypoints.mouth.y)
        for y in (my - 3)...(my + 3) { for x in (mx - 3)...(mx + 3) { image[y * width + x] = 250 } }
        let transform = try XCTUnwrap(SimilarityTransform.estimate(from: keypoints.points, to: MouthCropGeometry.reference))
        let pixels = try XCTUnwrap(image.withUnsafeBufferPointer {
            MouthCropGeometry.patch(from: $0, width: width, height: height, rowBytes: width, toReference: transform)
        })
        return (MouthPatch(keypoints: keypoints, transform: transform, pixels: pixels), keypoints)
    }
}

final class LipReadingWindowTests: XCTestCase {

    func testLengthsRoundUpToTheModelsLengths() {
        XCTAssertEqual(LipReadingWindow.modelLength(for: 1), 8)
        XCTAssertEqual(LipReadingWindow.modelLength(for: 8), 8)
        XCTAssertEqual(LipReadingWindow.modelLength(for: 41), 42)
        XCTAssertEqual(LipReadingWindow.modelLength(for: 61), 64)
        XCTAssertEqual(LipReadingWindow.modelLength(for: 401), 410)
        XCTAssertEqual(LipReadingWindow.modelLength(for: 2_000), 750)
        XCTAssertLessThanOrEqual(LipReadingWindow.lengths.count, 128, "Core ML's limit on enumerated shapes")
        XCTAssertEqual(LipReadingWindow.lengths, LipReadingWindow.lengths.sorted())
    }

    func testAModelsOwnLengthsWin() {
        XCTAssertEqual(LipReadingWindow.modelLength(for: 41, lengths: [10, 50, 100]), 50)
    }

    func testShortStretchesJoinAndLongOnesSplit() {
        let joined = LipReadingWindow.chunks([0...2, 3...5, 6...8])
        XCTAssertEqual(joined, [0...8])
        let long = LipReadingWindow.chunks([0...70])
        XCTAssertEqual(long.count, 3)
        XCTAssertTrue(long.allSatisfy { $0.upperBound - $0.lowerBound <= 30 })
        XCTAssertEqual(long.last?.upperBound, 70)
    }

    func testAWindowIsAModelLengthAndStaysOnRecordedFrames() {
        let times = LipReadingWindow.frameTimes(for: 1.0...2.0, available: 0.9...10)
        XCTAssertEqual(times.count, 26, "25 frames rounded up to the next length")
        XCTAssertGreaterThanOrEqual(times.first ?? 0, 0.9)
        XCTAssertEqual((times[1] - times[0]), 1 / 25, accuracy: 1e-9)
        // Near the start, the window slides into recorded frames.
        let early = LipReadingWindow.frameTimes(for: 0.0...0.05, available: 0...5)
        XCTAssertEqual(early.first ?? -1, 0, accuracy: 1e-9)
    }

    func testCropsAreTheNearestFrames() {
        let crops = [0.0, 0.033, 0.067, 0.1].map { MouthCrop(time: $0, pixels: [UInt8($0 * 1000)]) }
        let picked = LipReadingWindow.crops(at: [0, 0.04, 0.08, 0.5], from: crops)
        XCTAssertEqual(picked.map { $0.pixels[0] }, [0, 33, 67, 100])
        XCTAssertEqual(picked.map(\.time), [0, 0.04, 0.08, 0.5])
    }
}

final class CTCGreedyDecoderTests: XCTestCase {
    private let tokens = ["<blank>", "▁HELLO", "▁HOW", "▁ARE", "▁YOU", "S", "<eos>"]

    func testRepeatsCollapseAndBlanksDrop() {
        let ids = [0, 1, 1, 0, 2, 2, 2, 0, 3, 4, 0, 6]
        XCTAssertEqual(CTCGreedyDecoder.decode(bestTokens: ids, tokens: tokens), "hello how are you")
    }

    func testABlankSeparatesARepeatedToken() {
        XCTAssertEqual(CTCGreedyDecoder.decode(bestTokens: [1, 0, 1], tokens: tokens), "hello hello")
    }

    func testPiecesWithoutAWordMarkJoinTheWord() {
        XCTAssertEqual(CTCGreedyDecoder.decode(bestTokens: [4, 5], tokens: tokens), "yous")
        XCTAssertEqual(CTCGreedyDecoder.decode(bestTokens: [0, 0], tokens: tokens), "")
        XCTAssertEqual(CTCGreedyDecoder.decode(bestTokens: [99], tokens: tokens), "")
    }
}

@MainActor
final class SilentLipReadingTests: XCTestCase {
    private let silentKeys = HotKeyCombo(keyCode: 1, modifiers: [.control, .option, .command])

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    private func silentState(installed: Bool) -> (AppState, TestMocks) {
        let (state, mocks) = AppState.makeTestState()
        state.setShortcut(silentKeys, for: .silentMode)
        state.silentModeHoldThreshold = 0
        mocks.lipReader.isInstalled = installed
        // A mouthed recording: almost no sound.
        mocks.audioEngine.stopRecordingResult = [Float](repeating: 0.001, count: 48_000)
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "from the whisper", duration: 0.1, detectedLanguage: "en", audioLengthSeconds: 3, modelUsed: .tiny
        )
        return (state, mocks)
    }

    /// Three seconds of frames ending now: still, mouthing, still, each with a mouth patch.
    private func feedMouthing(_ state: AppState) throws {
        let (patch, _) = try MouthCropTests.face(shift: .zero)
        let start = ProcessInfo.processInfo.systemUptime - 3
        let frames = LipFrameFactory.still(from: start, seconds: 1)
            + LipFrameFactory.speaking(from: start + 1, seconds: 1)
            + LipFrameFactory.still(from: start + 2, seconds: 1)
        for var frame in frames {
            frame.mouth = patch
            state.silentMode.ingest(frame)
        }
    }

    private func record(_ state: AppState, _ mocks: TestMocks, frames: () throws -> Void) async rethrows {
        await state.handleShortcut(.silentMode)
        await waitUntil { state.silentMode.isCameraRequested && mocks.lipTracker.startCount > 0 }
        try frames()
        await state.handleShortcutReleased(.silentMode)
        await waitUntil { mocks.textInjector.injectCallCount == 1 }
    }

    func testMouthedWordsAreReadFromTheLips() async throws {
        let (state, mocks) = silentState(installed: true)
        try await record(state, mocks) { try feedMouthing(state) }

        XCTAssertTrue(mocks.lipTracker.capturesMouth == false, "Mouth capture stops with the recording")
        XCTAssertEqual(mocks.lipReader.readLengths.count, 1)
        let length = try XCTUnwrap(mocks.lipReader.readLengths.first)
        XCTAssertTrue(LipReadingWindow.lengths.contains(length), "One of the model's lengths")
        XCTAssertGreaterThan(length, 25)
        XCTAssertEqual(mocks.textInjector.lastInjectedText?.lowercased().contains("hello how are you"), true)
        XCTAssertNil(mocks.whisperService.lastTranscribedAudioData, "The audio isn't decoded")
    }

    func testWithoutTheModelAWhisperIsDecodedInEnglish() async throws {
        let (state, mocks) = silentState(installed: false)
        state.selectedLanguage = "de"
        try await record(state, mocks) { try feedMouthing(state) }

        XCTAssertTrue(mocks.lipReader.readLengths.isEmpty)
        XCTAssertNotNil(mocks.whisperService.lastTranscribedAudioData)
        XCTAssertEqual(mocks.whisperService.lastLanguage, "en", "Silent Mode is English only")
        XCTAssertEqual(mocks.textInjector.lastInjectedText?.lowercased().contains("from the whisper"), true)
    }

    func testWhisperModeDecodesTheAudio() async throws {
        let (state, mocks) = silentState(installed: true)
        state.silentModeReadsLips = false
        try await record(state, mocks) { try feedMouthing(state) }

        XCTAssertTrue(mocks.lipReader.readLengths.isEmpty)
        XCTAssertEqual(mocks.whisperService.lastLanguage, "en")
    }

    func testNothingReadTypesNothing() async throws {
        let (state, mocks) = silentState(installed: true)
        mocks.lipReader.text = ""
        await state.handleShortcut(.silentMode)
        await waitUntil { state.silentMode.isCameraRequested && mocks.lipTracker.startCount > 0 }
        try feedMouthing(state)
        await state.handleShortcutReleased(.silentMode)
        await waitUntil { !mocks.cursorOverlay.failureMessages.isEmpty }

        XCTAssertEqual(mocks.lipReader.readLengths.count, 1)
        XCTAssertNil(mocks.whisperService.lastTranscribedAudioData, "Near-silent audio isn't decoded instead")
        XCTAssertEqual(mocks.textInjector.injectCallCount, 0)
        XCTAssertEqual(mocks.cursorOverlay.failureMessages.last, "Didn't catch that.")
    }

    func testSubtleMouthingIsStillRead() async throws {
        let (state, mocks) = silentState(installed: true)
        let (patch, _) = try MouthCropTests.face(shift: .zero)
        await state.handleShortcut(.silentMode)
        await waitUntil { state.silentMode.isCameraRequested && mocks.lipTracker.startCount > 0 }
        // Lips the movement check calls still, but in view.
        let start = ProcessInfo.processInfo.systemUptime - 3
        for var frame in LipFrameFactory.still(from: start, seconds: 3) {
            frame.mouth = patch
            state.silentMode.ingest(frame)
        }
        await state.handleShortcutReleased(.silentMode)
        await waitUntil { mocks.textInjector.injectCallCount == 1 }

        XCTAssertEqual(mocks.lipReader.readLengths.count, 1)
        XCTAssertEqual(mocks.textInjector.lastInjectedText?.lowercased().contains("hello how are you"), true)
    }

    func testALoneWordFromStillLipsIsDropped() async throws {
        let (state, mocks) = silentState(installed: true)
        mocks.lipReader.text = "people"
        let (patch, _) = try MouthCropTests.face(shift: .zero)
        await state.handleShortcut(.silentMode)
        await waitUntil { state.silentMode.isCameraRequested && mocks.lipTracker.startCount > 0 }
        let start = ProcessInfo.processInfo.systemUptime - 3
        for var frame in LipFrameFactory.still(from: start, seconds: 3) {
            frame.mouth = patch
            state.silentMode.ingest(frame)
        }
        await state.handleShortcutReleased(.silentMode)
        await waitUntil { !mocks.cursorOverlay.failureMessages.isEmpty }
        XCTAssertEqual(mocks.textInjector.injectCallCount, 0)
    }

    func testTheModelLoadsWhenASilentRecordingStarts() async {
        let (state, mocks) = silentState(installed: true)
        await state.handleShortcut(.silentMode)
        await waitUntil { mocks.lipReader.prepareCount > 0 }
        XCTAssertEqual(mocks.lipReader.prepareCount, 1)
        XCTAssertTrue(mocks.lipTracker.capturesMouth)
        await state.cancelRecording()
        XCTAssertFalse(mocks.lipTracker.capturesMouth)
    }
}
