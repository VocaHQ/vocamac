// AboutPlatformMarkTests.swift
// VocaMac Tests

import AppKit
import CryptoKit
import XCTest
@testable import VocaMac

final class AboutPlatformMarkTests: XCTestCase {

    func testOfficialPlatformMarksAreBundledAndUnmodified() {
        for mark in AboutPlatformMark.allCases {
            guard let data = mark.svgData() else {
                XCTFail("\(mark.rawValue).svg should load from the resource bundle")
                continue
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            XCTAssertTrue(text.contains("viewBox=\"0 0 24 24\""), mark.rawValue)
            XCTAssertTrue(text.contains("<title>"), mark.rawValue)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("#0F6B57"), mark.rawValue)

            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, mark.expectedSHA256, mark.rawValue)
        }
    }

    func testPlatformTemplateImagesAreVisible() {
        for mark in AboutPlatformMark.allCases {
            XCTAssertNotNil(mark.officialPathData(), mark.rawValue)
            guard let image = mark.templateImage() else {
                XCTFail("\(mark.rawValue) templateImage should be non-nil")
                continue
            }
            XCTAssertGreaterThan(image.size.width, 0, mark.rawValue)
            XCTAssertGreaterThan(image.size.height, 0, mark.rawValue)
            XCTAssertTrue(image.isTemplate, mark.rawValue)
        }
    }

    func testFamilyProductsUseCanonicalDestinations() {
        XCTAssertEqual(AboutFamilyProduct.all.map(\.title), [
            "VocaLinux", "VocaMac", "VocaWin", "VocaPhone", "VocaGateway",
        ])
        XCTAssertEqual(AboutFamilyProduct.all.map(\.url.absoluteString), [
            "https://vocalinux.com",
            "https://vocamac.com",
            "https://vocawin.com",
            "https://vocaphone.vocahq.com",
            "https://vocagateway.vocahq.com",
        ])
        XCTAssertEqual(AboutFamilyProduct.all[3].marks, [.apple, .android])
        XCTAssertEqual(AboutFamilyProduct.all[4].systemImage, "server.rack")
        XCTAssertEqual(AboutLinks.headquarters.absoluteString, "https://vocahq.com")
        XCTAssertEqual(
            AboutLinks.contributors.absoluteString,
            "https://github.com/VocaHQ/vocamac#:~:text=about%20GitHub%20Sponsors-,Contributors,-9"
        )
    }
}
