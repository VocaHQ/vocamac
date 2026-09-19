// OnboardingModelGuidanceTests.swift
// VocaMacTests

import XCTest
@testable import VocaMac

final class OnboardingModelGuidanceTests: XCTestCase {
    func testEnglishPrefersCompactEnglishSpecialist() {
        let recommendation = OnboardingModelGuidance.recommendation(
            for: "en",
            availableModels: models([.tiny, .small, .parakeetTdtCtc110m])
        )

        XCTAssertEqual(recommendation?.model, .parakeetTdtCtc110m)
    }

    func testLanguageSpecialistsFollowExplicitCoverage() {
        let available = models([.small, .senseVoiceSmall, .gigaamV3, .canary180mFlash])

        XCTAssertEqual(
            OnboardingModelGuidance.recommendation(for: "ru", availableModels: available)?.model,
            .gigaamV3
        )
        XCTAssertEqual(
            OnboardingModelGuidance.recommendation(for: "ja", availableModels: available)?.model,
            .senseVoiceSmall
        )
        XCTAssertEqual(
            OnboardingModelGuidance.recommendation(for: "fr", availableModels: available)?.model,
            .canary180mFlash
        )
    }

    func testAutomaticAndOtherLanguagesUseMultilingualWhisper() {
        let available = models([.tiny, .small, .parakeetTdtCtc110m])

        XCTAssertEqual(
            OnboardingModelGuidance.recommendation(for: "auto", availableModels: available)?.model,
            .small
        )
        XCTAssertEqual(
            OnboardingModelGuidance.recommendation(for: "hi", availableModels: available)?.model,
            .small
        )
    }

    func testUnsupportedSpecialistFallsBackToSupportedGeneralModel() {
        let available = [
            model(.canary180mFlash, isSupported: false),
            model(.small, isSupported: true),
            model(.tiny, isSupported: true),
        ]

        XCTAssertEqual(
            OnboardingModelGuidance.recommendation(for: "de", availableModels: available)?.model,
            .small
        )
    }

    func testBundledTinyIsLastResort() {
        XCTAssertEqual(
            OnboardingModelGuidance.recommendation(
                for: "en",
                availableModels: models([.tiny])
            )?.model,
            .tiny
        )
    }

    private func models(_ sizes: [ModelSize]) -> [WhisperModelInfo] {
        sizes.map { model($0, isSupported: true) }
    }

    private func model(_ size: ModelSize, isSupported: Bool) -> WhisperModelInfo {
        WhisperModelInfo(
            size: size,
            filePath: nil,
            isDownloaded: size == .tiny,
            isActive: false,
            isSupported: isSupported
        )
    }
}
