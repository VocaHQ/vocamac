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

    /// Parakeet Unified had the fewest errors of the Parakeet models on
    /// English; 110M is next when Unified isn't available.
    func testEnglishPrefersParakeetUnifiedThenCompact() {
        XCTAssertEqual(
            OnboardingModelGuidance.recommendation(
                for: "en", availableModels: models([.tiny, .small, .parakeetTdtCtc110m, .parakeetUnified, .parakeetUltra])
            )?.model,
            .parakeetUnified
        )
        XCTAssertEqual(
            OnboardingModelGuidance.recommendation(
                for: ["en"], availableModels: models([.tiny, .small, .parakeetTdtCtc110m, .parakeetUnified]),
                memoryGB: 16
            )?.model,
            .parakeetUnified
        )
    }

    func testOtherParakeetLanguagesUseParakeetV3BeforeWhisper() {
        let available = models([.tiny, .small, .parakeetV3, .parakeetUltra])
        for language in ["it", "nl", "pl", "sv", "uk"] {
            XCTAssertEqual(
                OnboardingModelGuidance.recommendation(for: language, availableModels: available)?.model,
                .parakeetV3, language
            )
        }
        // A language Parakeet doesn't know still gets Whisper.
        XCTAssertEqual(OnboardingModelGuidance.recommendation(for: "hi", availableModels: available)?.model, .small)
        // Specialists keep their languages.
        XCTAssertEqual(
            OnboardingModelGuidance.recommendation(
                for: "fr", availableModels: models([.small, .parakeetV3, .canary180mFlash])
            )?.model,
            .canary180mFlash
        )
    }

    /// Cohere Transcribe can't detect the language, so it is only suggested
    /// to someone who speaks exactly one of its languages.
    func testModelsWithoutLanguageDetectionNeedExactlyOneLanguage() {
        let available = models([.tiny, .small, .largeV3LatestCompact, .cohereTranscribe])
        XCTAssertEqual(
            OnboardingModelGuidance.recommendation(
                for: ["en"], availableModels: available, priority: .accuracy, memoryGB: 16
            )?.model,
            .cohereTranscribe
        )
        for languages in [["en", "fr"], []] {
            XCTAssertNotEqual(
                OnboardingModelGuidance.recommendation(
                    for: languages, availableModels: available, priority: .accuracy, memoryGB: 16
                )?.model,
                .cohereTranscribe, "\(languages)"
            )
        }
        // 4.5 GB doesn't fit half of an 8 GB Mac.
        XCTAssertNotEqual(
            OnboardingModelGuidance.recommendation(
                for: ["en"], availableModels: available, priority: .accuracy, memoryGB: 8
            )?.model,
            .cohereTranscribe
        )
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
