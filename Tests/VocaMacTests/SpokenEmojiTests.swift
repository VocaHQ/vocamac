// SpokenEmojiTests.swift
// VocaMac Tests
//
// Ported from VocaPhone's SpokenEmojiTests, so the clients stay in step. The
// rules that stop "emoji" being eaten out of ordinary sentences.

import XCTest
@testable import VocaMac

final class SpokenEmojiTests: XCTestCase {
    private func glyphs(_ text: String, language: String = "auto") -> String {
        SpokenEmoji.glyphs(in: text, language: language)
    }

    func testADescriptorAndTheTriggerBecomeTheGlyph() {
        XCTAssertEqual(glyphs("crying emoji"), "😭")
        XCTAssertEqual(glyphs("happy emoji"), "😊")
        XCTAssertEqual(glyphs("smiling emoji"), "😊")
    }

    func testRepeatedTriggersEachConvert() {
        XCTAssertEqual(glyphs("crying emoji crying emoji"), "😭 😭")
    }

    func testMultiWordDescriptorsResolve() {
        XCTAssertEqual(glyphs("thumbs up emoji"), "👍")
        XCTAssertEqual(glyphs("shrug emoji"), "🤷")
    }

    /// Speech models rarely put a comma where the speaker paused, so the
    /// longest key before the trigger converts and the prose before it stays.
    func testProseBeforeADescriptorStaysProse() {
        XCTAssertEqual(glyphs("I'm so sad crying emoji"), "I'm so sad 😭")
        XCTAssertEqual(glyphs("nice work thumbs up emoji"), "nice work 👍")
        XCTAssertEqual(glyphs("I'm so sad, crying emoji"), "I'm so sad, 😭")
    }

    /// ...but only at the end of a clause: mid-sentence, "emoji" is a noun.
    func testATriggerMidClauseIsANoun() {
        XCTAssertEqual(glyphs("can you check emoji support"), "can you check emoji support")
        XCTAssertEqual(glyphs("can you check emoji support in Safari?"), "can you check emoji support in Safari?")
        XCTAssertEqual(glyphs("check emoji support"), "✅ support")
    }

    /// A determiner or a subject right before the descriptor means the
    /// speaker is talking about the emoji.
    func testTalkingAboutAnEmojiKeepsTheWords() {
        for phrase in ["send a fire emoji", "I love the fire emoji", "what's the crying emoji", "I love you emoji"] {
            XCTAssertEqual(glyphs(phrase), phrase)
        }
    }

    func testSpokenPhrasingsResolve() {
        XCTAssertEqual(glyphs("heart eyes emoji"), "😍")
        XCTAssertEqual(glyphs("praying hands emoji"), "🙏")
        XCTAssertEqual(glyphs("tears of joy emoji"), "😂")
        XCTAssertEqual(glyphs("check mark emoji"), "✅")
    }

    func testTheFullMultiWordNameConverts() {
        XCTAssertEqual(glyphs("loudly crying emoji"), "😭")
    }

    func testPunctuationBetweenTwoGlyphsCollapses() {
        XCTAssertEqual(glyphs("Crying emoji, crying emoji, crying emoji."), "😭 😭 😭")
        XCTAssertEqual(glyphs("Crying emoji. Fire emoji."), "😭 🔥")
        XCTAssertEqual(glyphs("crying emoji crying emoji"), "😭 😭")
    }

    func testPunctuationOutsideTheRunIsUntouched() {
        XCTAssertEqual(glyphs("fire emoji, then home"), "🔥, then home")
        XCTAssertEqual(
            glyphs("I'm sad, crying emoji, but fire emoji, then home"),
            "I'm sad, 😭, but 🔥, then home"
        )
        XCTAssertEqual(
            glyphs("I'm sad, crying emoji. Fire emoji, then home"),
            "I'm sad, 😭 🔥, then home"
        )
        XCTAssertEqual(glyphs("crying emoji and fire emoji"), "😭 and 🔥")
    }

    func testLongerPhrasesDoNotStrandTheirLeadingWords() {
        XCTAssertEqual(glyphs("one hundred emoji"), "💯")
        XCTAssertEqual(glyphs("face with tears of joy emoji"), "😂")
        XCTAssertEqual(glyphs("rolling on the floor laughing emoji"), "🤣")
        XCTAssertEqual(glyphs("crying face emoji"), "😢")
        XCTAssertEqual(glyphs("thumbs up sign emoji"), "👍")
    }

    func testCLDRNamesConvertFullyOrNotAtAll() {
        XCTAssertEqual(glyphs("smiling face with heart eyes emoji"), "😍")
        XCTAssertEqual(glyphs("pile of poo emoji"), "💩")
        XCTAssertEqual(glyphs("face with rolling eyes emoji"), "🙄")
        XCTAssertEqual(glyphs("smiling face with sunglasses emoji"), "😎")
        XCTAssertEqual(glyphs("heart on fire emoji"), "❤️‍🔥")
        XCTAssertEqual(glyphs("couple with heart emoji"), "💑")

        for phrase in ["I love you emoji", "face with heart eyes emoji", "person running emoji"] {
            XCTAssertEqual(glyphs(phrase), phrase)
        }
    }

    /// Every key in the table, spoken as itself before "emoji", converts with
    /// no leftover prefix.
    func testTableKeysConvertWithNoLeftoverPrefix() {
        var failures: [String] = []
        for (key, glyph) in EmojiTable.triggers where key.count >= EmojiTable.minimumLength && key != "korea" {
            let output = glyphs("\(key) emoji")
            if output != glyph { failures.append("\(key) → \(output)") }
        }
        XCTAssertEqual(failures, [])

        let spaced: [(String, String)] = [
            ("heart eyes", "😍"),
            ("loudly crying", "😭"),
            ("one hundred", "💯"),
            ("thumbs up", "👍"),
            ("face with tears of joy", "😂"),
            ("rolling on the floor laughing", "🤣"),
        ]
        for (phrase, glyph) in spaced {
            XCTAssertEqual(glyphs("\(phrase) emoji"), glyph, phrase)
        }
    }

    func testKoreaAloneDoesNotBecomeTheDPRKFlag() {
        XCTAssertEqual(glyphs("korea emoji"), "korea emoji")
        XCTAssertEqual(glyphs("southkorea emoji"), "🇰🇷")
        XCTAssertEqual(glyphs("northkorea emoji"), "🇰🇵")
        XCTAssertEqual(EmojiTable.triggers["korea"], "🇰🇵")
    }

    func testDigitsCanBeDescriptors() {
        XCTAssertEqual(glyphs("100 emoji"), "💯")
        XCTAssertEqual(glyphs("a hundred emoji"), "💯")
        XCTAssertEqual(glyphs("one hundred emoji"), "💯")
        XCTAssertEqual(glyphs("I need 20 emoji"), "I need 20 emoji")
        XCTAssertEqual(glyphs("3 crying emoji"), "3 crying emoji")
        XCTAssertEqual(glyphs("3, crying emoji"), "3, 😭")
    }

    func testMaskedSpansAreNotDescriptors() {
        XCTAssertEqual(glyphs("it cost 3.50 crying emoji"), "it cost 3.50 😭")
        XCTAssertEqual(glyphs("meet at 10:30 crying emoji"), "meet at 10:30 😭")
        XCTAssertEqual(glyphs("the 1st crying emoji"), "the 1st 😭")
        XCTAssertEqual(glyphs("read https://example.com/a fire emoji"), "read https://example.com/a 🔥")
    }

    func testOnlyTheDescriptorHasToBeEnglish() {
        XCTAssertEqual(glyphs("मैं बहुत उदास हूँ crying emoji", language: "hi"), "मैं बहुत उदास हूँ 😭")
        XCTAssertEqual(glyphs("とても悲しい crying emoji", language: "ja"), "とても悲しい 😭")
        XCTAssertEqual(
            glyphs("estoy muy triste llorando emoji", language: "es"),
            "estoy muy triste llorando emoji"
        )
    }

    func testAnUnmatchedTriggerIsLeftAlone() {
        XCTAssertEqual(glyphs("Send me the emoji."), "Send me the emoji.")
        XCTAssertEqual(glyphs("emoji"), "emoji")
        XCTAssertEqual(glyphs("emoji emoji"), "emoji emoji")
    }

    func testTheTriggerMayBePluralized() {
        XCTAssertEqual(glyphs("fire emojis"), "🔥")
    }

    func testPunctuationAroundTheTriggerSurvives() {
        XCTAssertEqual(glyphs("party emoji!"), "🎉!")
        XCTAssertEqual(glyphs("Crying emoji. That was rough."), "😭. That was rough.")
    }

    func testATrailingFullStopAfterAGlyphGoes() {
        XCTAssertEqual(glyphs("I'm so sad, crying emoji."), "I'm so sad, 😭")
        XCTAssertEqual(glyphs("Hundred emoji."), "💯")
        XCTAssertEqual(glyphs("Crying emoji is how I feel."), "😭 is how I feel.")
    }

    func testMeaningfulTerminatorsAfterAGlyphStay() {
        XCTAssertEqual(glyphs("Crying emoji!"), "😭!")
        XCTAssertEqual(glyphs("Crying emoji?"), "😭?")
    }

    func testPunctuationInsideThePhraseEndsIt() {
        XCTAssertEqual(glyphs("I was crying, emoji"), "I was crying, emoji")
    }

    func testAddressesAreNotEaten() {
        XCTAssertEqual(glyphs("see crying emoji.com"), "see crying emoji.com")
        XCTAssertEqual(glyphs("mail fire emoji@example.com"), "mail fire emoji@example.com")
    }

    func testOtherLanguagesPassThrough() {
        XCTAssertEqual(glyphs("मैं बहुत खुश हूँ।"), "मैं बहुत खुश हूँ।")
    }

    func testTextWithNoTriggerIsReturnedUnchanged() {
        XCTAssertEqual(glyphs("just an ordinary sentence"), "just an ordinary sentence")
        XCTAssertEqual(glyphs(""), "")
    }

    func testTheTableShipsInTheBundle() {
        XCTAssertGreaterThan(EmojiTable.triggers.count, 3_000)
        XCTAssertGreaterThan(EmojiTable.widestKeyLength, 0)
        XCTAssertEqual(EmojiTable.triggers["loudlycrying"], "😭")
        XCTAssertNil(EmojiTable.triggers["emoji"])
    }

    func testTheFastPathChangesNothing() {
        let untouched = "no trigger anywhere in this sentence at all"
        XCTAssertEqual(glyphs(untouched), untouched)
        XCTAssertEqual(glyphs("just a jar of jam"), "just a jar of jam")
        XCTAssertEqual(glyphs("fire emojify"), "fire emojify")
        XCTAssertEqual(glyphs("Fire EMOJI now"), "🔥 now")
    }

    /// The pipeline masks each glyph; the insert closure decides what is
    /// written, and snippet placeholders already in the text are not words.
    func testInsertWritesWhatTheCallerChoosesAndPlaceholdersEndAPhrase() {
        var inserted: [String] = []
        let text = SpokenEmoji.glyphs(in: "great, fire emoji") { glyph in
            inserted.append(glyph)
            return "<\(inserted.count - 1)>"
        }
        XCTAssertEqual(text, "great, <0>")
        XCTAssertEqual(inserted, ["🔥"])
        XCTAssertEqual(glyphs("\u{E000} fire emoji"), "\u{E000} 🔥")
        XCTAssertEqual(glyphs("heart\u{E000} eyes emoji"), "heart\u{E000} 👀")
    }
}
