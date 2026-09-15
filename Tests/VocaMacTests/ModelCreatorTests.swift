// ModelCreatorTests.swift
// VocaMac Tests

import CryptoKit
import XCTest
@testable import VocaMac

final class ModelCreatorTests: XCTestCase {

    func testBundledMarksMatchLobeIconsBytes() {
        for creator in ModelCreator.allCases where creator.markName != nil {
            guard let data = creator.svgData() else {
                XCTFail("\(creator.rawValue) mark should load from the resource bundle")
                continue
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            XCTAssertTrue(text.contains("viewBox=\"0 0 24 24\""), creator.rawValue)
            XCTAssertTrue(text.contains("fill=\"currentColor\""), creator.rawValue)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, creator.expectedSHA256, creator.rawValue)
        }
    }

    func testMarksDrawVisibleTemplates() {
        for creator in ModelCreator.allCases where creator.markName != nil {
            guard let image = creator.templateImage() else {
                XCTFail("\(creator.rawValue) templateImage should be non-nil")
                continue
            }
            XCTAssertTrue(image.isTemplate, creator.rawValue)
            XCTAssertGreaterThan(image.size.width, 0, creator.rawValue)
        }
    }

    func testMonogramCreatorsHaveNoMark() {
        XCTAssertNil(ModelCreator.usefulSensors.templateImage())
        XCTAssertNil(ModelCreator.sber.expectedSHA256)
        XCTAssertFalse(ModelCreator.sber.monogram.isEmpty)
    }

    func testCreditLinksUseHTTPS() {
        for creator in ModelCreator.allCases {
            XCTAssertEqual(creator.url.scheme, "https", creator.rawValue)
            XCTAssertFalse(creator.creditedModels.isEmpty, creator.rawValue)
        }
    }

    func testModelsCreditTheRightTeams() {
        XCTAssertEqual(ModelSize.tiny.creator, .openAI)
        XCTAssertEqual(ModelSize.distilLargeV3Compact.creator, .huggingFace)
        XCTAssertEqual(ModelSize.parakeetV3.creator, .nvidia)
        XCTAssertEqual(ModelSize.canary180mFlash.creator, .nvidia)
        XCTAssertEqual(ModelSize.appleSpeech.creator, .apple)
        XCTAssertEqual(ModelSize.senseVoiceSmall.creator, .alibaba)
        XCTAssertEqual(CleanupModelKind.ministral3_3b_q4_k_m.creator, .mistral)
        XCTAssertEqual(CleanupModelKind.qwen25_0_5b_q4_k_m.creator, .qwen)
    }
}
