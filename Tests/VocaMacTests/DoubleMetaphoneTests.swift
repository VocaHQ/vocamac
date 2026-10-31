// DoubleMetaphoneTests.swift
// VocaMac

import XCTest
@testable import VocaMac

final class DoubleMetaphoneTests: XCTestCase {

    private func key(_ word: String) -> DoubleMetaphone.Key? {
        DoubleMetaphone.encode(word)
    }

    // Reference values from the Apache Commons Codec implementation.
    func testKnownKeys() {
        XCTAssertEqual(key("Smith"), .init(primary: "SM0", alternate: "XMT"))
        XCTAssertEqual(key("Schmidt"), .init(primary: "XMT", alternate: "SMT"))
        XCTAssertEqual(key("Thomas")?.primary, "TMS")
        XCTAssertEqual(key("knight")?.primary, "NT")
        XCTAssertEqual(key("Xavier")?.primary, "SF")
        XCTAssertEqual(key("Caesar")?.primary, "SSR")
        XCTAssertEqual(key("Philip")?.primary, "FLP")
        XCTAssertEqual(key("Jose")?.primary, "HS")
        XCTAssertEqual(key("laugh")?.primary, "LF")
    }

    func testSoundAlikeSpellingsShareAKey() {
        let pairs = [
            ("kubernetes", "coopernetties"),
            ("kaiser", "kayzer"),
            ("pachauri", "pachori"),
            ("stephen", "steven"),
            ("catherine", "kathryn"),
            ("philip", "fillip"),
        ]
        for (a, b) in pairs {
            guard let left = key(a), let right = key(b) else { return XCTFail("no key for \(a) or \(b)") }
            XCTAssertTrue(left.matches(right), "\(a) \(left) vs \(b) \(right)")
        }
    }

    func testDifferentWordsDoNotShareAKey() {
        let pairs = [("kubernetes", "cucumbers"), ("namrata", "tamrata"), ("kaiser", "kolmar")]
        for (a, b) in pairs {
            guard let left = key(a), let right = key(b) else { return XCTFail("no key for \(a) or \(b)") }
            XCTAssertFalse(left.matches(right), "\(a) \(left) vs \(b) \(right)")
        }
    }

    func testOnlyEnglishLettersAreKeyed() {
        XCTAssertNil(key("müller"))
        XCTAssertNil(key("gpt4"))
        XCTAssertNil(key(""))
        // Vowels alone still key on the leading vowel.
        XCTAssertEqual(key("aeiou")?.primary, "A")
    }

    func testKeysAreCapped() {
        XCTAssertEqual(DoubleMetaphone.encode("Schwarzenegger", maxLength: 4)?.primary.count, 4)
    }
}
