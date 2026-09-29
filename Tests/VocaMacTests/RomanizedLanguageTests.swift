// RomanizedLanguageTests.swift
// VocaMac Tests

import XCTest
@testable import VocaMac

final class RomanizedLanguageTests: XCTestCase {

    func testVocaHinglishReportsRomanizedHindi() {
        for text in [
            "Aur batao, pankha kahaan hai aajkal? Kitne mukdame ho gae us par?",
            "Nahin main puchh raha hoon.",
            "Bhai pata hai paaji kya bol raha tha aaj.",
            "Haan thik hai.",
        ] {
            XCTAssertEqual(
                WhisperService.reportedLanguage(for: text, model: .vocaHinglish, decoded: "en"), "hi-Latn", text
            )
        }
    }

    func testVocaHinglishReportsEnglishForEnglish() {
        for text in [
            "Hello, this is a quick test of the model.",
            "Please send me the report by tomorrow.",
            "Ok, I found a bug in the English model that, for example, I say main puchh raha hoon like this small word.",
        ] {
            XCTAssertEqual(WhisperService.reportedLanguage(for: text, model: .vocaHinglish, decoded: "en"), "en", text)
        }
    }

    func testOtherModelsReportWhatTheyDecoded() {
        XCTAssertEqual(WhisperService.reportedLanguage(for: "Haan thik hai.", model: .small, decoded: "hi"), "hi")
        XCTAssertEqual(WhisperService.reportedLanguage(for: "Hello there.", model: .tiny, decoded: "en"), "en")
    }

    // MARK: - Unexpected scripts

    func testVocaHinglishDropsWordsInOtherScripts() {
        XCTAssertEqual(
            WhisperService.removingUnexpectedScripts(
                from: "Cats are everywhere. It is just amazing. в кт", model: .vocaHinglish
            ),
            "Cats are everywhere. It is just amazing."
        )
        XCTAssertEqual(
            WhisperService.removingUnexpectedScripts(from: "Haan 谢谢 thik hai, مرحبا bhai.", model: .vocaHinglish),
            "Haan thik hai, bhai."
        )
    }

    func testVocaHinglishKeepsTheLatinPartOfAWordWithGarbageAttached() {
        XCTAssertEqual(
            WhisperService.removingUnexpectedScripts(from: "It is just amazing.в кт", model: .vocaHinglish),
            "It is just amazing."
        )
        XCTAssertEqual(
            WhisperService.removingUnexpectedScripts(from: "Приветbhai, kaise ho? «в»", model: .vocaHinglish),
            "bhai, kaise ho?"
        )
        XCTAssertEqual(
            WhisperService.removingUnexpectedScripts(from: "Room 404в mein", model: .vocaHinglish),
            "Room 404 mein"
        )
    }

    func testVocaHinglishKeepsLatinAndDevanagari() {
        for text in [
            "Aap pandrah log hain.",
            "हाँ ठीक है, kal milte hain.",
            "Café mein naïve sa sawaal, 1,500 rupaye!",
            "Deadline 5:30 pm hai 🙂",
            "",
        ] {
            XCTAssertEqual(WhisperService.removingUnexpectedScripts(from: text, model: .vocaHinglish), text, text)
        }
    }

    func testOtherModelsKeepEveryScript() {
        let text = "Привет, 谢谢 and hello."
        XCTAssertEqual(WhisperService.removingUnexpectedScripts(from: text, model: .largeV3Turbo), text)
        XCTAssertEqual(WhisperService.removingUnexpectedScripts(from: text, model: .small), text)
    }

    func testRomanizedTags() {
        XCTAssertTrue(DictationOutputPipeline.isRomanized("hi-Latn"))
        XCTAssertTrue(DictationOutputPipeline.isRomanized("hi-latn"))
        XCTAssertFalse(DictationOutputPipeline.isRomanized("hi"))
        XCTAssertFalse(DictationOutputPipeline.isRomanized("en"))
        XCTAssertFalse(DictationOutputPipeline.isRomanized(nil))
        XCTAssertFalse(DictationOutputPipeline.isRomanized("zh-Hans"))
    }

    func testRomanizedHindiEndsSentencesWithAFullStop() {
        XCTAssertEqual(SpokenEmoji.sentenceTerminator(language: "hi-Latn", text: "Haan thik hai"), ".")
        XCTAssertEqual(SpokenEmoji.sentenceTerminator(language: "hi", text: "हाँ ठीक है"), "।")
    }
}
