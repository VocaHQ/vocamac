// HallucinationGuardTests.swift
// VocaMac

import XCTest
@testable import VocaMac

final class HallucinationGuardTests: XCTestCase {

    func testStockPhrasesOverUnconfirmedSpeechAreDropped() {
        for text in ["Thank you.", " thank you ", "Thanks for watching!", "You", "Bye-bye.", "[Music]"] {
            XCTAssertEqual(HallucinationGuard.filter(text, speechUnconfirmed: true), "", text)
        }
    }

    func testRealSpeechIsNeverTouched() {
        // The detector found speech: short replies stay, stock phrase or not.
        for text in ["Thank you.", "Bye.", "Yes.", "Thanks!", "Okay.", "You"] {
            XCTAssertEqual(HallucinationGuard.filter(text, speechUnconfirmed: false), text, text)
        }
    }

    func testOnlyAWholeStockPhraseCounts() {
        // Unsure audio, but more was said than a stock phrase.
        for text in ["Yes.", "Okay.", "Thanks!", "Thank you, Priya.", "Thank you for the notes, see you Monday."] {
            XCTAssertEqual(HallucinationGuard.filter(text, speechUnconfirmed: true), text, text)
        }
    }

    func testUnsureDetectionIsNotTreatedAsNoSpeech() {
        // Whispered speech still gets decoded; only the output is checked.
        XCTAssertEqual(SpeechActivityTrimmer.decide(speech: [], peakProbability: 0.3, totalSamples: 16_000), .unsure)
    }
}
