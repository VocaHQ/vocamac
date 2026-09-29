// MeetingCaptureSessionTests.swift
// VocaMacTests

import XCTest
@testable import VocaMac

@MainActor
final class MeetingCaptureSessionTests: XCTestCase {
    func testAudioIsPendingUntilItIsTranscribed() {
        let session = MeetingCaptureSession()
        XCTAssertNil(session.pendingAudio, "Nothing captured: the window can close freely")

        session.capturedSamples = [0.2, 0.1]
        session.isTranscribing = true
        XCTAssertEqual(session.pendingAudio, .transcribing)

        session.isTranscribing = false
        XCTAssertEqual(session.pendingAudio, .notTranscribed, "A failed transcription keeps its audio")

        session.capturedSamples = nil
        XCTAssertNil(session.pendingAudio)
    }

    func testDiscardCancelsAnInFlightTranscription() {
        let session = MeetingCaptureSession()
        let task = Task<Void, Never> { try? await Task.sleep(nanoseconds: 10_000_000_000) }
        session.capturedSamples = [0.2]
        session.isTranscribing = true
        session.transcriptionTask = task

        session.discard()

        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(session.transcriptionTask)
        XCTAssertNil(session.pendingAudio)
    }
}
