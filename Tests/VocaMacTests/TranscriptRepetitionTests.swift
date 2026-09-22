// TranscriptRepetitionTests.swift
// VocaMac Tests

import XCTest
@testable import VocaMac

final class TranscriptRepetitionTests: XCTestCase {

    /// A 2 second "Nahin main puchh raha hoon" from Voca Hinglish, cut off by
    /// the token limit mid-word.
    private let hinglishLoop = String(repeating: "Nahin main puchh raha hoon.", count: 15) + "Nahin main puch"

    // MARK: - Detection

    func testFindsTheHinglishLoopIncludingTheCutOffCopy() throws {
        let loop = try XCTUnwrap(TranscriptRepetition.loop(in: hinglishLoop))
        XCTAssertEqual(loop.start, 0)
        XCTAssertEqual(loop.unitLength, 5)
        XCTAssertEqual(loop.copies, 15)
        XCTAssertEqual(loop.trailingPartial, 3)
    }

    func testFindsSingleWordAndSpacedLoops() {
        XCTAssertTrue(TranscriptRepetition.containsLoop(String(repeating: "Chalo. ", count: 20)))
        XCTAssertTrue(TranscriptRepetition.containsLoop("Nahin nahin." + String(repeating: "Nahin.", count: 18)))
        XCTAssertTrue(TranscriptRepetition.containsLoop(String(repeating: "Haan thik hai.", count: 30)))
    }

    func testRepetitionPeopleSayOnPurposeIsNotALoop() {
        for text in [
            "No no no, that's not what I meant.",
            "Thank you, thank you, thank you!",
            "It was very very very good.",
            "Nahin nahin.",
            "Bye bye bye bye.",
            "Go team go team go team!",
            "We need to test, test, and test again.",
            "",
            "Hello",
        ] {
            XCTAssertNil(TranscriptRepetition.loop(in: text), text)
        }
    }

    func testDeliberateRepetitionThatFitsTheAudioIsKept() {
        let text = String(repeating: "Please leave now. ", count: 4)
        // 12 words in 4 seconds is ordinary speech.
        XCTAssertNil(TranscriptRepetition.loop(in: text, audioSeconds: 4))
        XCTAssertNil(TranscriptRepetition.loop(in: text))
        XCTAssertEqual(TranscriptRepetition.collapsingLoops(in: text, audioSeconds: 4), text)
    }

    func testTextTooLongForItsAudioNeedsFewerCopies() {
        let text = String(repeating: "Chalo. ", count: 9)
        // Nine copies: short of a loop on count alone, but no one says nine
        // words in half a second.
        XCTAssertNil(TranscriptRepetition.loop(in: text))
        XCTAssertNil(TranscriptRepetition.loop(in: text, audioSeconds: 3))
        XCTAssertNotNil(TranscriptRepetition.loop(in: text, audioSeconds: 0.5))
        XCTAssertEqual(TranscriptRepetition.collapsingLoops(in: text, audioSeconds: 0.5), "Chalo.")

        let phrase = String(repeating: "Please leave now. ", count: 4)
        XCTAssertNotNil(TranscriptRepetition.loop(in: phrase, audioSeconds: 1))
    }

    func testTheRealLoopIsCaughtAtItsRecordingLength() {
        XCTAssertNotNil(TranscriptRepetition.loop(in: hinglishLoop, audioSeconds: 1.8))
    }

    func testOrdinaryDictationIsNotALoop() {
        let text = "Aisa hai paaji bhai tumhaara. Batao bhai? Apna nahin dekh raha hai. Doosron ka itna dekh raha hai ki kya bataen?"
        XCTAssertNil(TranscriptRepetition.loop(in: text))
    }

    // MARK: - Collapsing

    func testCollapseKeepsOneCopyWithItsPunctuation() {
        XCTAssertEqual(TranscriptRepetition.collapsingLoops(in: hinglishLoop), "Nahin main puchh raha hoon.")
        XCTAssertEqual(
            TranscriptRepetition.collapsingLoops(in: String(repeating: "Chalo. ", count: 20)),
            "Chalo."
        )
    }

    func testCollapseKeepsWhatWasSaidBeforeAndAfter() {
        let text = "Suno. " + String(repeating: "Haan thik hai. ", count: 10) + "Kal milte hain."
        XCTAssertEqual(TranscriptRepetition.collapsingLoops(in: text), "Suno. Haan thik hai. Kal milte hain.")
    }

    func testCollapseLeavesTextWithoutALoopAlone() {
        let text = "No no no, that's not what I meant."
        XCTAssertEqual(TranscriptRepetition.collapsingLoops(in: text), text)
    }

    func testCollapseHandlesDevanagari() {
        let text = String(repeating: "मैं पूछ रहा हूँ। ", count: 12)
        XCTAssertEqual(TranscriptRepetition.collapsingLoops(in: text), "मैं पूछ रहा हूँ।")
    }

    // MARK: - Retry

    func testOnlyARetryWithTextReplacesTheFirstTranscription() {
        XCTAssertTrue(WhisperService.isUsableRetry("Nahin main puchh raha hoon."))
        XCTAssertFalse(WhisperService.isUsableRetry(""))
        XCTAssertFalse(WhisperService.isUsableRetry("  \n "))
    }
}
