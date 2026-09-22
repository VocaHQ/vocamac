// ModelLanguageSupportTests.swift
// VocaMac Tests

import XCTest
@testable import VocaMac

final class ModelLanguageSupportTests: XCTestCase {

    private func info(
        _ size: ModelSize,
        downloaded: Bool = false,
        active: Bool = false,
        supported: Bool = true
    ) -> WhisperModelInfo {
        WhisperModelInfo(
            size: size, filePath: nil, isDownloaded: downloaded,
            isActive: active, isSupported: supported
        )
    }

    // MARK: - Coverage

    func testEveryModelHasCoverageScoresAndSummary() {
        for size in ModelSize.allCases {
            XCTAssertFalse(size.pickerSummary.isEmpty, "\(size)")
            XCTAssertGreaterThan(size.accuracyScore, 0, "\(size)")
            XCTAssertLessThanOrEqual(size.accuracyScore, 1, "\(size)")
            XCTAssertGreaterThan(size.speedScore, 0, "\(size)")
            XCTAssertLessThanOrEqual(size.speedScore, 1, "\(size)")
            if case .only(let codes) = size.languageCoverage {
                XCTAssertFalse(codes.isEmpty, "\(size)")
            }
        }
    }

    /// `accuracyScore` reads `qualityDescription`, so a renamed label would
    /// silently fall back to the default score.
    func testAccuracyScoreRecognisesEveryQualityLabel() {
        let known: Set<String> = ["Good", "Better", "Great", "Excellent", "Best", "Legacy", "Best for Hindi"]
        for size in ModelSize.allCases {
            XCTAssertTrue(known.contains(size.qualityDescription), "\(size): \(size.qualityDescription)")
        }
        XCTAssertLessThan(ModelSize.tiny.accuracyScore, ModelSize.base.accuracyScore)
        XCTAssertLessThan(ModelSize.base.accuracyScore, ModelSize.small.accuracyScore)
        XCTAssertLessThan(ModelSize.small.accuracyScore, ModelSize.parakeetV3.accuracyScore)
        XCTAssertLessThan(ModelSize.parakeetV3.accuracyScore, ModelSize.largeV3Latest.accuracyScore)
    }

    func testSpeedScoreSeparatesSlowModels() {
        XCTAssertEqual(ModelSize.tiny.speedScore, 1, accuracy: 0.001)
        XCTAssertGreaterThan(ModelSize.largeV3LatestCompact.speedScore, ModelSize.largeV3Latest.speedScore)
        XCTAssertGreaterThan(ModelSize.largeV3Latest.speedScore, ModelSize.largeV3.speedScore)
        XCTAssertEqual(ModelSize.largeV3.speedScore, 0.1, accuracy: 0.001)
    }

    func testRatingWordsMatchTheDotsShown() {
        XCTAssertEqual(ModelRating.dots(for: ModelSize.largeV3.speedScore), 0.5)
        XCTAssertEqual(ModelRating.describe(ModelSize.largeV3.speedScore), "0.5 of 5")
        XCTAssertEqual(ModelRating.describe(ModelSize.tiny.speedScore), "5 of 5")
        XCTAssertEqual(ModelRating.describe(0.7), "3.5 of 5")
    }

    func testLargeSlowModelsRankBelowCompactOnes() {
        let models = [info(.largeV3), info(.qwen3Asr06B), info(.largeV3LatestCompact)]
        let forYou = ModelPickerCatalog.models(in: .forYou, from: models, spokenLanguages: ["hi"])
        XCTAssertEqual(forYou, [.largeV3LatestCompact, .qwen3Asr06B, .largeV3])
    }

    func testCoverageMatchesModelLanguages() {
        XCTAssertEqual(ModelSize.small.languageCoverage, .broad)
        XCTAssertEqual(ModelSize.parakeetV2.languageCoverage, .only(["en"]))
        XCTAssertEqual(ModelSize.distilLargeV3Compact.languageCoverage, .only(["en"]))
        XCTAssertEqual(ModelSize.gigaamV3.languageCoverage, .only(["ru"]))
        XCTAssertEqual(ModelSize.canary180mFlash.languageCoverage, .only(["en", "es", "de", "fr"]))
        XCTAssertEqual(ModelSize.appleSpeech.languageCoverage, .system)
        XCTAssertEqual(ModelSize.parakeetV3Languages.count, 25)
        XCTAssertEqual(ModelSize.qwen3AsrLanguages.count, 30)
        XCTAssertTrue(ModelSize.qwen3AsrLanguages.contains("hi"))
    }

    func testParakeetV3LanguagesAreAllSelectable() {
        let selectable = Set(TranscriptionLanguage.selectable.map(\.code))
        XCTAssertTrue(ModelSize.parakeetV3Languages.isSubset(of: selectable))
    }

    func testOnlyTranslationTrainedWhisperModelsTranslate() {
        XCTAssertTrue(ModelSize.tiny.translatesToEnglish)
        XCTAssertTrue(ModelSize.small.translatesToEnglish)
        // Turbo was fine-tuned without translation data; Distil is English-only.
        XCTAssertFalse(ModelSize.largeV3Latest.translatesToEnglish)
        XCTAssertFalse(ModelSize.largeV3LatestTurboCompact.translatesToEnglish)
        XCTAssertFalse(ModelSize.distilLargeV3Compact.translatesToEnglish)
        XCTAssertFalse(ModelSize.vocaHinglish.translatesToEnglish)
        XCTAssertFalse(ModelSize.parakeetV3.translatesToEnglish)
    }

    // MARK: - Fit

    func testFitSplitsCoveredAndMissingInSpokenOrder() {
        let fit = ModelPickerCatalog.fit(of: .parakeetV2, for: ["hi", "en"])
        XCTAssertEqual(fit.covered, ["en"])
        XCTAssertEqual(fit.missing, ["hi"])
        XCTAssertFalse(fit.coversAll)
        XCTAssertTrue(fit.coversAny)
    }

    func testBroadModelCoversEverything() {
        let fit = ModelPickerCatalog.fit(of: .small, for: ["hi", "en", "mt"])
        XCTAssertTrue(fit.coversAll)
    }

    func testNoSpokenLanguagesFitsEveryModel() {
        for size in ModelSize.allCases {
            XCTAssertTrue(ModelPickerCatalog.fit(of: size, for: []).coversAll)
        }
    }

    func testAppleSpeechUsesSystemLanguagesWhenKnown() {
        XCTAssertFalse(ModelPickerCatalog.fit(of: .appleSpeech, for: ["hi"]).coversAll)
        XCTAssertTrue(ModelPickerCatalog.fit(of: .appleSpeech, for: ["hi"], systemLanguages: ["hi"]).coversAll)
    }

    // MARK: - Search

    func testSearchMatchesNameCreatorAndEngine() {
        XCTAssertTrue(ModelPickerCatalog.matches(.parakeetV2, search: "parakeet"))
        XCTAssertTrue(ModelPickerCatalog.matches(.parakeetV2, search: "NVIDIA"))
        XCTAssertTrue(ModelPickerCatalog.matches(.small, search: "whisper"))
        XCTAssertTrue(ModelPickerCatalog.matches(.small, search: "  "))
        XCTAssertFalse(ModelPickerCatalog.matches(.parakeetV2, search: "whisper"))
    }

    func testSearchByLanguageFindsModelsThatSpeakIt() {
        XCTAssertTrue(ModelPickerCatalog.matches(.gigaamV3, search: "russian"))
        XCTAssertTrue(ModelPickerCatalog.matches(.qwen3Asr06B, search: "hindi"))
        XCTAssertTrue(ModelPickerCatalog.matches(.small, search: "hi"))
        XCTAssertFalse(ModelPickerCatalog.matches(.gigaamV3, search: "hindi"))
        XCTAssertFalse(ModelPickerCatalog.matches(.parakeetV2, search: "hi"))
    }

    // MARK: - Scopes

    func testForYouListsOnlyModelsCoveringEveryLanguage() {
        let models = [
            info(.tiny, downloaded: true, active: true),
            info(.parakeetV2),
            info(.qwen3Asr06B),
            info(.small),
            info(.gigaamV3),
        ]
        let forYou = ModelPickerCatalog.models(in: .forYou, from: models, spokenLanguages: ["en", "hi"])
        XCTAssertEqual(Set(forYou), [.tiny, .qwen3Asr06B, .small])
    }

    func testDownloadedModelsKeepTheirRankInForYou() {
        // A downloaded Tiny must not jump ahead of better models it has
        // not earned a place above.
        let models = [
            info(.tiny, downloaded: true, active: true),
            info(.largeV3LatestCompact),
        ]
        let forYou = ModelPickerCatalog.models(in: .forYou, from: models, spokenLanguages: ["hi"])
        XCTAssertEqual(forYou, [.largeV3LatestCompact, .tiny])
    }

    func testDownloadedScopeListsInstalledModelsActiveFirst() {
        var downloading = info(.gigaamV3)
        downloading.downloadProgress = 0.3
        let models = [
            info(.small, downloaded: true),
            info(.parakeetV2, downloaded: true, active: true),
            info(.qwen3Asr06B),
            downloading,
        ]
        let downloaded = ModelPickerCatalog.models(in: .downloaded, from: models, spokenLanguages: ["hi"])
        XCTAssertEqual(downloaded.first, .parakeetV2)
        XCTAssertEqual(Set(downloaded), [.parakeetV2, .small, .gigaamV3])
    }

    func testAllScopeOrdersByFitThenRank() {
        let models = [info(.gigaamV3), info(.parakeetV2), info(.small)]
        let all = ModelPickerCatalog.models(in: .all, from: models, spokenLanguages: ["en", "hi"])
        // Full coverage, then partial (English only), then none.
        XCTAssertEqual(all, [.small, .parakeetV2, .gigaamV3])
    }

    func testEmptySpokenLanguagesPutsEveryModelInForYou() {
        let models = [info(.parakeetV2), info(.gigaamV3), info(.small)]
        let forYou = ModelPickerCatalog.models(in: .forYou, from: models, spokenLanguages: [])
        XCTAssertEqual(Set(forYou), [.parakeetV2, .gigaamV3, .small])
    }

    func testRecommendedModelLeadsAndExperimentalTrails() {
        let models = [
            info(.parakeetV2, supported: false),
            info(.tiny),
            info(.parakeetTdtCtc110m),
        ]
        let forYou = ModelPickerCatalog.models(
            in: .forYou, from: models, spokenLanguages: ["en"], recommended: .tiny
        )
        XCTAssertEqual(forYou, [.tiny, .parakeetTdtCtc110m, .parakeetV2])
    }

    func testSearchNarrowsEveryScope() {
        let models = [
            info(.small, downloaded: true),
            info(.parakeetV3, downloaded: true),
            info(.tiny),
            info(.largeV3Latest),
        ]
        XCTAssertEqual(
            ModelPickerCatalog.models(in: .downloaded, from: models, spokenLanguages: ["en"], search: "parakeet"),
            [.parakeetV3]
        )
        XCTAssertEqual(
            Set(ModelPickerCatalog.models(in: .all, from: models, spokenLanguages: ["en"], search: "translate")),
            [.small, .tiny]
        )
    }

    func testLanguageLabels() {
        XCTAssertEqual(ModelLanguageBadge.label(for: .small, systemLanguages: nil), "99 languages")
        XCTAssertEqual(ModelLanguageBadge.label(for: .parakeetV2, systemLanguages: nil), "English only")
        XCTAssertEqual(ModelLanguageBadge.label(for: .parakeetV3, systemLanguages: nil), "25 languages")
        XCTAssertEqual(ModelLanguageBadge.label(for: .appleSpeech, systemLanguages: ["en", "fr"]), "2 languages")
    }

    // MARK: - Spoken Languages

    func testDecodeDropsBlanksDuplicatesAndUnknownCodes() {
        XCTAssertEqual(SpokenLanguages.decode("en, hi,,EN,xx,auto"), ["en", "hi"])
        XCTAssertEqual(SpokenLanguages.decode(""), [])
    }

    func testEncodeRoundTrips() {
        let codes = ["hi", "en", "fr"]
        XCTAssertEqual(SpokenLanguages.decode(SpokenLanguages.encode(codes)), codes)
    }

    func testResolveKeepsAnExplicitlyClearedList() {
        XCTAssertEqual(
            SpokenLanguages.resolve(stored: "", selectedLanguage: "de", preferredLanguages: ["en-US"]),
            []
        )
    }

    func testGuessStartsWithPinnedLanguageThenSystemLanguages() {
        XCTAssertEqual(
            SpokenLanguages.resolve(stored: nil, selectedLanguage: "de", preferredLanguages: ["en-IN", "hi-IN"]),
            ["de", "en", "hi"]
        )
        XCTAssertEqual(
            SpokenLanguages.guess(selectedLanguage: "auto", preferredLanguages: ["en-IN", "hi-IN", "en-GB"]),
            ["en", "hi"]
        )
    }

    func testGuessMapsSystemAliasesAndCapsTheList() {
        XCTAssertEqual(
            SpokenLanguages.guess(selectedLanguage: "auto", preferredLanguages: ["nb-NO"]),
            ["no"]
        )
        XCTAssertEqual(
            SpokenLanguages.guess(
                selectedLanguage: "auto",
                preferredLanguages: ["en", "fr", "de", "es", "it"]
            ).count,
            SpokenLanguages.maximumGuessed
        )
    }

    func testListJoinsNames() {
        XCTAssertEqual(SpokenLanguages.list([]), "")
        XCTAssertEqual(SpokenLanguages.list(["en"]), "English")
        XCTAssertEqual(SpokenLanguages.list(["en", "hi"]), "English and Hindi")
        XCTAssertEqual(SpokenLanguages.list(["en", "hi", "fr"]), "English, Hindi, and French")
    }

    func testDisplayNameFallsBackToSystemNames() {
        XCTAssertEqual(SpokenLanguages.displayName(for: "hi"), "Hindi")
        XCTAssertEqual(SpokenLanguages.displayName(for: "yue"), "Cantonese")
    }
}
