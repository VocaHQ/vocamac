// AboutSocialMarkTests.swift
// VocaMac Tests

import CryptoKit
import XCTest
@testable import VocaMac

final class AboutSocialMarkTests: XCTestCase {

    func testOfficialMarksMatchVocaDesignBytes() {
        for mark in AboutSocialMark.allCases {
            guard let data = mark.svgData() else {
                XCTFail("\(mark.rawValue).svg should load from the resource bundle")
                continue
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            XCTAssertTrue(text.contains("viewBox=\"0 0 24 24\""), mark.rawValue)
            XCTAssertTrue(text.contains("fill=\"currentColor\""), mark.rawValue)
            XCTAssertFalse(
                text.localizedCaseInsensitiveContains("#0F6B57"),
                "\(mark.rawValue).svg must keep currentColor; do not bake Settings teal into the file"
            )
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, mark.expectedSHA256, mark.rawValue)
        }
    }

    func testTalkToUsLabelsAndURLs() {
        XCTAssertEqual(AboutSocialMark.github.visibleLabel, "Report a bug or idea")
        XCTAssertEqual(AboutSocialMark.discord.visibleLabel, "Discord")
        XCTAssertEqual(AboutSocialMark.x.visibleLabel, "X")
        XCTAssertEqual(AboutSocialMark.mail.visibleLabel, "Email")
        XCTAssertFalse(AboutSocialMark.x.visibleLabel.lowercased().contains("twitter"))

        XCTAssertEqual(
            AboutSocialMark.github.url.absoluteString,
            "https://github.com/VocaHQ/vocamac/issues"
        )
        XCTAssertEqual(
            AboutSocialMark.discord.url.absoluteString,
            "https://discord.gg/UMJduhcqn"
        )
        XCTAssertEqual(AboutSocialMark.x.url.absoluteString, "https://x.com/vocahq")
        XCTAssertEqual(AboutSocialMark.mail.url.absoluteString, "mailto:hello@vocahq.com")
        XCTAssertEqual(AboutSocialMark.talkRowMarks, [.discord, .x, .mail])
        XCTAssertFalse(AboutSocialMark.talkRowMarks.contains(.github))
    }
}
