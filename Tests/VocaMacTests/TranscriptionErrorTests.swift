// TranscriptionErrorTests.swift
// VocaMac Tests
//
// The shared engine error: wording each engine had before the merge, and
// which failures count toward reloading the model.

import XCTest
@testable import VocaMac

final class TranscriptionErrorTests: XCTestCase {
    func testSharedFailuresKeepEachEnginesWording() {
        XCTAssertEqual(
            TranscriptionError.modelNotLoaded(.whisperKit).localizedDescription,
            "No whisper model is loaded. Please load a model first."
        )
        XCTAssertEqual(
            TranscriptionError.modelNotLoaded(.parakeet).localizedDescription,
            "No Parakeet model is loaded. Please load a model first."
        )
        XCTAssertEqual(
            TranscriptionError.modelNotLoaded(.sherpaOnnx).localizedDescription,
            "No ONNX model is loaded. Please load a model first."
        )
        XCTAssertEqual(
            TranscriptionError.modelNotLoaded(.appleSpeech).localizedDescription,
            "Apple Speech is not prepared. Please load the model first."
        )
        XCTAssertEqual(
            TranscriptionError.modelNotLoaded(.customEndpoint).localizedDescription,
            "The custom endpoint is not loaded."
        )
        XCTAssertEqual(
            TranscriptionError.initializationFailed(.whisperKit, reason: "x").localizedDescription,
            "Failed to initialize WhisperKit: x"
        )
        XCTAssertEqual(
            TranscriptionError.initializationFailed(.parakeet, reason: "x").localizedDescription,
            "Failed to initialize Parakeet: x"
        )
        XCTAssertEqual(
            TranscriptionError.initializationFailed(.sherpaOnnx, reason: "x").localizedDescription,
            "Failed to initialize the ONNX model: x"
        )
        XCTAssertEqual(TranscriptionError.emptyAudio(.parakeet).localizedDescription, "No audio data to transcribe.")
        XCTAssertEqual(TranscriptionError.emptyAudio(.customEndpoint).localizedDescription, "Nothing was recorded.")
        XCTAssertEqual(
            TranscriptionError.transcriptionFailed(reason: "boom").localizedDescription,
            "Transcription failed: boom"
        )
    }

    func testOnlyRealDecodeFaultsCountTowardAReload() {
        XCTAssertTrue(TranscriptionError.transcriptionFailed(reason: "MPS error").indicatesModelFault)
        XCTAssertTrue(
            TranscriptionError.transcriptionFailed(
                reason: "fault", underlying: NSError(domain: "CoreML", code: 1)
            ).indicatesModelFault
        )
        XCTAssertFalse(
            TranscriptionError.transcriptionFailed(reason: "cancelled", underlying: CancellationError())
                .indicatesModelFault
        )
        XCTAssertFalse(
            TranscriptionError.transcriptionFailed(reason: "offline", underlying: URLError(.notConnectedToInternet))
                .indicatesModelFault
        )
        for engine in TranscriptionEngine.allCases {
            XCTAssertFalse(TranscriptionError.modelNotLoaded(engine).indicatesModelFault, "\(engine)")
            XCTAssertFalse(TranscriptionError.emptyAudio(engine).indicatesModelFault, "\(engine)")
            XCTAssertFalse(TranscriptionRouter.isModelFailure(TranscriptionError.emptyAudio(engine)), "\(engine)")
        }
    }
}
