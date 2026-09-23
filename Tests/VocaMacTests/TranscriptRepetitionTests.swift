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

    // MARK: - Letter loops

    /// An 11.5 second Voca Hinglish dictation that ran into the token limit
    /// on one Cyrillic letter, with no space between copies.
    private let letterLoop = "By the way have you been to Turkey? Like it's 1 of the best pantries if you love cats. "
        + "It is just amazing. в к" + String(repeating: "т", count: 170)

    func testFindsALoopOfOneLetterInsideAWord() throws {
        XCTAssertNil(TranscriptRepetition.loop(in: letterLoop, audioSeconds: 11.5))
        let loop = try XCTUnwrap(TranscriptRepetition.characterLoop(in: letterLoop))
        XCTAssertEqual(loop.unitLength, 1)
        XCTAssertEqual(loop.copies, 170)
        XCTAssertTrue(TranscriptRepetition.containsLoop(letterLoop, audioSeconds: 11.5))
    }

    func testFindsLoopsOfSeveralLettersAndInScriptsWithoutSpaces() {
        XCTAssertTrue(TranscriptRepetition.containsLoop("Okay " + String(repeating: "кт", count: 40) + "к"))
        XCTAssertTrue(TranscriptRepetition.containsLoop(String(repeating: "谢", count: 30)))
        XCTAssertTrue(TranscriptRepetition.containsLoop("Hi" + String(repeating: "abcd", count: 20)))
    }

    func testLaughterThatFitsTheAudioIsKept() {
        let laugh = String(repeating: "ha", count: 8)
        XCTAssertNil(TranscriptRepetition.characterLoop(in: laugh))
        XCTAssertNil(TranscriptRepetition.characterLoop(in: laugh, audioSeconds: 3))
        XCTAssertEqual(TranscriptRepetition.collapsingLoops(in: laugh, audioSeconds: 3), laugh)
    }

    func testLetterRunTooLongForItsAudioNeedsFewerCopies() {
        let run = String(repeating: "ha", count: 10)
        // Ten copies: short of a loop on count alone, but no one laughs ten
        // syllables in half a second.
        XCTAssertNil(TranscriptRepetition.characterLoop(in: run))
        XCTAssertNil(TranscriptRepetition.characterLoop(in: run, audioSeconds: 3))
        XCTAssertNotNil(TranscriptRepetition.characterLoop(in: run, audioSeconds: 0.5))
        XCTAssertEqual(TranscriptRepetition.collapsingLoops(in: run, audioSeconds: 0.5), "ha")
    }

    func testStretchedWordsAndNumbersAreNotLetterLoops() {
        for text in [
            "Sooooo good.",
            "Hmmmmmm, let me think.",
            "Hahahahaha that's funny.",
            "Hahahahahahahaha!",
            "Nooooooooooooooo!",
            "Aaaaaaah!",
            "Mississippi",
            "It costs 1000000000000 dollars.",
            "Zzzzzz",
            "हाहाहाहा",
        ] {
            XCTAssertNil(TranscriptRepetition.characterLoop(in: text), text)
            XCTAssertFalse(TranscriptRepetition.containsLoop(text), text)
        }
    }

    func testCollapseCutsALetterLoopToOneCopy() {
        XCTAssertEqual(
            TranscriptRepetition.collapsingLoops(in: letterLoop, audioSeconds: 11.5),
            "By the way have you been to Turkey? Like it's 1 of the best pantries if you love cats. It is just amazing. в кт"
        )
        XCTAssertEqual(
            TranscriptRepetition.collapsingLoops(in: "Okay " + String(repeating: "кт", count: 40) + "к then."),
            "Okay кт then."
        )
    }

    func testCollapseHandlesLetterLoopsBeforeWordLoops() {
        let word = "Hi" + String(repeating: "i", count: 30)
        let text = Array(repeating: word, count: 20).joined(separator: " ")
        XCTAssertEqual(TranscriptRepetition.collapsingLoops(in: text), "Hi")
    }

    // MARK: - Retry

    func testOnlyARetryWithTextReplacesTheFirstTranscription() {
        XCTAssertTrue(WhisperService.isUsableRetry("Nahin main puchh raha hoon."))
        XCTAssertFalse(WhisperService.isUsableRetry(""))
        XCTAssertFalse(WhisperService.isUsableRetry("  \n "))
    }

    func testOnlyALoopFreeRetryReplacesALoopedTranscription() {
        XCTAssertTrue(WhisperService.isLoopFreeRetry("It is just amazing.", audioSeconds: 11.5))
        XCTAssertFalse(WhisperService.isLoopFreeRetry(letterLoop, audioSeconds: 11.5))
        XCTAssertFalse(WhisperService.isLoopFreeRetry(hinglishLoop, audioSeconds: 1.8))
        XCTAssertFalse(WhisperService.isLoopFreeRetry(" ", audioSeconds: 11.5))
    }
}
