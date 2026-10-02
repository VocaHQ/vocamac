import XCTest
@testable import VocaMac

final class SpeechModelRecommendationTests: XCTestCase {
    private func models(_ sizes: [ModelSize]) -> [WhisperModelInfo] {
        sizes.map { WhisperModelInfo(size: $0, filePath: nil, isDownloaded: false, isActive: false, isSupported: true) }
    }

    func testOnboardingAndCatalogUseTheSameLanguageGuidance() {
        let available = models([.tiny, .small, .parakeetTdtCtc110m])
        let onboarding = OnboardingModelGuidance.recommendation(for: "en", availableModels: available)
        let catalog = OnboardingModelGuidance.recommendation(for: ["en"], availableModels: available)
        XCTAssertEqual(onboarding, catalog)
    }

    func testBilingualChoiceMustCoverEveryLanguage() {
        let available = models([.tiny, .small, .parakeetTdtCtc110m])
        let result = OnboardingModelGuidance.recommendation(for: ["en", "hi"], availableModels: available)
        XCTAssertEqual(result?.model, .small)
    }

    func testDownloadPriorityAvoidsSystemAssetsWithUnknownSize() {
        let available = models([.tiny, .small, .appleSpeech, .parakeetTdtCtc110m])
        let result = OnboardingModelGuidance.recommendation(for: ["en"], availableModels: available, priority: .smallestDownload)
        XCTAssertEqual(result?.model, .tiny)
    }

    func testAccuracyPriorityDoesNotFallBackToTheBundledStarter() {
        let available = models([.tiny, .small])
        let result = OnboardingModelGuidance.recommendation(for: ["en"], availableModels: available, priority: .accuracy)
        XCTAssertEqual(result?.model, .small)
    }

    func testRemoteOrUnsupportedModelsAreNeverSuggested() {
        var available = models([.customEndpoint, .small, .tiny])
        available[1].isSupported = false
        let result = OnboardingModelGuidance.recommendation(for: ["en"], availableModels: available, priority: .accuracy)
        XCTAssertEqual(result?.model, .tiny)
        XCTAssertNil(OnboardingModelGuidance.recommendation(for: ["ru"], availableModels: models([.parakeetTdtCtc110m])))
    }
}
