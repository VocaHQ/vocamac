import XCTest
@testable import VocaMac

final class CalmModelPicksTests: XCTestCase {

    // MARK: - Fixtures

    /// The standard catalog, every model supported and nothing on disk.
    private func catalog(
        supported: Bool = true, downloaded: Set<ModelSize> = [], active: ModelSize? = nil,
        progress: [ModelSize: Double] = [:]
    ) -> [WhisperModelInfo] {
        ModelSize.standardCatalog.map { size in
            WhisperModelInfo(
                size: size, filePath: nil, isDownloaded: downloaded.contains(size) || size.isSystemManaged,
                isActive: size == active, isSupported: supported, downloadProgress: progress[size]
            )
        }
    }

    // MARK: - Speech picks

    func testSpeechPicksAreThreeDistinctModelsInOrder() {
        let picks = CalmModelPicks.speech(languages: ["en", "de"], models: catalog(), systemLanguages: nil, memoryGB: 16)
        XCTAssertEqual(picks.map(\.slot), [.recommended, .lightest, .mostAccurate])
        XCTAssertEqual(Set(picks.map(\.model)).count, 3)
    }

    func testRecommendedIsTheFastestModelThatUnderstandsEveryLanguage() {
        let picks = CalmModelPicks.speech(languages: ["en", "de"], models: catalog(), systemLanguages: nil, memoryGB: 16)
        let recommended = picks[0].model
        let eligible = CalmModelPicks.eligibleSpeechModels(
            languages: ["en", "de"], models: catalog(), systemLanguages: nil, memoryGB: 16
        )
        XCTAssertTrue(ModelPickerCatalog.fit(of: recommended, for: ["en", "de"]).coversAll)
        XCTAssertEqual(recommended.relativeSpeed, eligible.map(\.relativeSpeed).min())
        // Parakeet's English-only models are as fast but miss German.
        XCTAssertFalse([ModelSize.parakeetV2, .parakeetUnified, .parakeetTdtCtc110m].contains(recommended))
        // Ultra is as fast and as “very accurate”, but the bigger download.
        XCTAssertEqual(recommended, .parakeetV3)
    }

    func testTiedModelsPreferTheOneInUseThenOneAlreadyDownloaded() {
        let inUse = CalmModelPicks.speech(
            languages: ["en", "de"], models: catalog(downloaded: [.parakeetUltra], active: .parakeetUltra),
            systemLanguages: nil, memoryGB: 16
        )
        XCTAssertEqual(inUse.first?.model, .parakeetUltra)
        let downloaded = CalmModelPicks.speech(
            languages: ["en", "de"], models: catalog(downloaded: [.parakeetUltra, .tiny], active: .tiny),
            systemLanguages: nil, memoryGB: 16
        )
        XCTAssertEqual(downloaded.first?.model, .parakeetUltra)
    }

    func testEverydayCardsSkipBasicModels() {
        // Whisper Tiny is in use and the lightest English model, but only “basic”.
        let picks = CalmModelPicks.speech(
            languages: ["en"], models: catalog(downloaded: [.tiny], active: .tiny), systemLanguages: nil, memoryGB: 16
        )
        XCTAssertFalse(picks.contains { $0.model == .tiny })
        for pick in picks {
            XCTAssertGreaterThanOrEqual(CalmModelText.accuracyTier(pick.model), 1, "\(pick.slot): \(pick.model)")
        }
    }

    func testLightestIsTheSmallestInMemoryAndMostAccurateTheBest() {
        let picks = CalmModelPicks.speech(languages: ["en"], models: catalog(), systemLanguages: nil, memoryGB: 16)
        let eligible = CalmModelPicks.eligibleSpeechModels(
            languages: ["en"], models: catalog(), systemLanguages: nil, memoryGB: 16
        )
        let lightest = picks.first { $0.slot == .lightest }?.model
        let accurate = picks.first { $0.slot == .mostAccurate }?.model
        // The lightest model that is at least “fair”.
        let localEligible = eligible.filter { !$0.isSystemManaged && CalmModelText.accuracyTier($0) >= 1 }
        XCTAssertEqual(lightest?.ramRequiredGB, localEligible.map(\.ramRequiredGB).min())
        XCTAssertEqual(accurate?.accuracyScore, eligible.map(\.accuracyScore).max())
    }

    /// Canary and Cohere decode everything in the language they load with,
    /// so they are never suggested to someone who speaks two.
    func testSingleLanguageModelsAreOnlySuggestedForOneLanguage() {
        let both = CalmModelPicks.eligibleSpeechModels(
            languages: ["en", "fr"], models: catalog(), systemLanguages: nil, memoryGB: 16
        )
        XCTAssertFalse(both.contains(.cohereTranscribe))
        XCTAssertFalse(both.contains(.canary180mFlash))
        let picks = CalmModelPicks.speech(languages: ["en", "fr"], models: catalog(), systemLanguages: nil, memoryGB: 16)
        XCTAssertFalse(picks.contains { $0.model.needsOneLanguage })

        let french = CalmModelPicks.eligibleSpeechModels(
            languages: ["fr"], models: catalog(), systemLanguages: nil, memoryGB: 16
        )
        XCTAssertTrue(french.contains(.cohereTranscribe))
    }

    func testPicksNeverOfferTheServerOrUnsupportedModels() {
        let models = catalog().map { info -> WhisperModelInfo in
            var info = info
            if info.size == .parakeetUltra { info.isSupported = false }
            return info
        }
        let picks = CalmModelPicks.speech(languages: [], models: models, systemLanguages: nil, memoryGB: 32)
        XCTAssertFalse(picks.contains { $0.model == .customEndpoint })
        XCTAssertFalse(picks.contains { $0.model == .parakeetUltra })
    }

    func testPicksFollowTheLanguages() {
        let russian = CalmModelPicks.speech(languages: ["ru", "en"], models: catalog(), systemLanguages: nil, memoryGB: 16)
        for pick in russian {
            XCTAssertTrue(ModelPickerCatalog.fit(of: pick.model, for: ["ru", "en"]).coversAll, "\(pick.model)")
        }
        let hindi = CalmModelPicks.speech(languages: ["hi"], models: catalog(), systemLanguages: nil, memoryGB: 16)
        XCTAssertFalse(hindi.contains { $0.model.engine == .parakeet })
    }

    func testSmallMemoryKeepsPicksWithinTheMemoryShare() {
        let picks = CalmModelPicks.speech(languages: ["en"], models: catalog(), systemLanguages: nil, memoryGB: 8)
        for pick in picks {
            XCTAssertLessThanOrEqual(pick.model.firstLoadRAMRequiredGB, 8 * OnboardingModelGuidance.memoryShare, "\(pick.model)")
        }
    }

    /// Tiny still shows when nothing better understands the languages.
    func testOnlyOneEligibleModelGivesOneCard() {
        let models = catalog().filter { $0.size == .tiny || $0.size == .customEndpoint }
        let picks = CalmModelPicks.speech(languages: ["en"], models: models, systemLanguages: nil, memoryGB: 16)
        XCTAssertEqual(picks.map(\.model), [.tiny])
    }

    // MARK: - Writing picks

    func testWritingPicksFollowTheBoardFromSixteenGigabytes() {
        let picks = CalmModelPicks.writing(memoryGB: 16)
        XCTAssertEqual(picks.map(\.slot), [.recommended, .lightest, .bestQuality])
        XCTAssertEqual(picks.map(\.model), [.ministral3_3b_q4_k_m, .qwen25_0_5b_q4_k_m, .qwen3_4b_instruct_2507_q4_k_m])
        XCTAssertFalse(picks.contains { $0.isRunnerUp })
    }

    func testWritingLightestMovesOverWhenRecommendedTakesIt() {
        // Below 16 GB the suggestion is the 0.5B model, so Lightest shows the next one.
        let picks = CalmModelPicks.writing(memoryGB: 8)
        XCTAssertEqual(picks.map(\.model).prefix(2), [.qwen25_0_5b_q4_k_m, .qwen3_0_6b_q4_k_m])
        XCTAssertEqual(picks[1].isRunnerUp, true)
    }

    /// No card offers a model that needs more than its share of memory:
    /// on 8 GB the 4B and 7B models (and Ministral 3B) are left out.
    func testWritingPicksFitTheMacsMemory() {
        let small = CalmModelPicks.writing(memoryGB: 8)
        XCTAssertEqual(small.map(\.model), [.qwen25_0_5b_q4_k_m, .qwen3_0_6b_q4_k_m, .qwen25_1_5b_q4_k_m])
        XCTAssertEqual(small.last?.slot, .bestQuality)
        for memory in [8, 16, 24, 64] {
            for pick in CalmModelPicks.writing(memoryGB: memory) {
                XCTAssertLessThanOrEqual(
                    pick.model.descriptor.ramRequiredGB, Double(memory) * CalmModelPicks.writingMemoryShare, "\(memory) GB: \(pick.model)"
                )
            }
        }
        // 24 GB has room for the 7B model, but Qwen 3 4B is still the best pick.
        XCTAssertEqual(CalmModelPicks.writing(memoryGB: 24).last?.model, .qwen3_4b_instruct_2507_q4_k_m)
    }

    /// Qwen 3 4B turned German and French dictation into English, so it is
    /// never offered to someone who speaks another language; Ministral 3B
    /// (which keeps them) is Best quality instead.
    func testWritingPicksAvoidAModelThatTranslatesOtherLanguages() {
        for languages in [["en", "de"], ["fr"], ["es", "en"], ["ja"]] {
            let picks = CalmModelPicks.writing(memoryGB: 32, languages: languages)
            XCTAssertFalse(picks.contains { $0.model == .qwen3_4b_instruct_2507_q4_k_m }, "\(languages)")
            XCTAssertTrue(picks.contains { $0.model == .ministral3_3b_q4_k_m }, "\(languages)")
        }
        let english = CalmModelPicks.writing(memoryGB: 32, languages: ["en"])
        XCTAssertEqual(english.first { $0.slot == .bestQuality }?.model, .qwen3_4b_instruct_2507_q4_k_m)
        // Below 16 GB, Ministral is the Best quality card for German.
        let german = CalmModelPicks.writing(memoryGB: 12, languages: ["de"])
        XCTAssertEqual(german.first { $0.slot == .bestQuality }?.model, .ministral3_3b_q4_k_m)
        XCTAssertFalse(german.first { $0.slot == .bestQuality }?.isRunnerUp ?? true)
    }

    // MARK: - Pick steps

    func testPickingTheModelInUseDoesNothing() {
        let models = catalog(downloaded: [.small], active: .small)
        XCTAssertEqual(CalmModelPicks.speechStep(for: .small, models: models), .nothing)
    }

    func testPickingTheServerOpensItsDialog() {
        XCTAssertEqual(CalmModelPicks.speechStep(for: .customEndpoint, models: catalog()), .setUpServer)
    }

    func testPickingAnUnverifiedModelAsksFirst() {
        let models = catalog(supported: false)
        XCTAssertEqual(CalmModelPicks.speechStep(for: .base, models: models), .confirmExperimental)
        XCTAssertEqual(
            CalmModelPicks.speechStep(for: .base, models: models, confirmedExperimental: true),
            .start(cancelling: nil)
        )
    }

    func testPickingWhileAnotherDownloadsStopsItOrAsksPastHalfWay() {
        let early = catalog(progress: [.small: 0.3])
        XCTAssertEqual(CalmModelPicks.speechStep(for: .base, models: early), .start(cancelling: .small))
        let late = catalog(progress: [.small: 0.7])
        XCTAssertEqual(CalmModelPicks.speechStep(for: .base, models: late), .confirmStopDownload(.small, progress: 0.7))
        XCTAssertEqual(
            CalmModelPicks.speechStep(for: .base, models: late, confirmedStop: true),
            .start(cancelling: .small)
        )
        XCTAssertEqual(CalmModelPicks.speechStep(for: .small, models: late), .nothing)
    }

    func testWritingStepFollowsTheOneDownloadRule() {
        let busy = CleanupModelState.downloading(kind: .qwen3_4b_instruct_2507_q4_k_m, progress: 0.8)
        XCTAssertEqual(
            CalmModelPicks.writingStep(for: .qwen25_0_5b_q4_k_m, state: busy, isInUse: false),
            .confirmStopDownload(.qwen3_4b_instruct_2507_q4_k_m, progress: 0.8)
        )
        XCTAssertEqual(
            CalmModelPicks.writingStep(for: .qwen25_0_5b_q4_k_m, state: .ready, isInUse: true),
            .nothing
        )
        XCTAssertEqual(
            CalmModelPicks.writingStep(for: .qwen25_0_5b_q4_k_m, state: .idle, isInUse: false),
            .start(cancelling: nil)
        )
    }

    // MARK: - Text

    func testNamesDropTheCatalogParentheses() {
        XCTAssertEqual(CalmModelText.name(.parakeetV3), "Parakeet v3")
        XCTAssertEqual(CalmModelText.variant(.parakeetV3), "Multilingual")
        XCTAssertEqual(CalmModelText.name(.largeV3LatestCompact), "Whisper Large v3 Latest")
        XCTAssertEqual(CalmModelText.variant(.tiny), "Built in")
        XCTAssertNil(CalmModelText.variant(.tiny, isBundled: false))
        XCTAssertEqual(CalmModelText.variant(.parakeetV3, isBundled: false), "Multilingual")
        for size in ModelSize.allCases {
            XCTAssertFalse(CalmModelText.name(size).contains("("), "\(size)")
        }
    }

    func testSizesReadLikeTheDesign() {
        XCTAssertEqual(CalmModelText.size(bytes: 483_257_242), "483 MB")
        XCTAssertEqual(CalmModelText.size(bytes: 2_147_023_008), "2.15 GB")
        XCTAssertEqual(CalmModelText.size(bytes: 1_000_089_677), "1 GB")
        XCTAssertEqual(CalmModelText.memory(gb: 1.0), "About 1 GB")
        XCTAssertEqual(CalmModelText.memory(gb: 0.9), "About 0.9 GB")
    }

    func testMetaLineMatchesTheBoard() {
        XCTAssertEqual(CalmModelText.meta(.parakeetV3, systemLanguages: nil), "25 European languages · Fastest · very accurate")
        XCTAssertEqual(CalmModelText.meta(.tiny, systemLanguages: nil), "99 languages · Fastest · basic")
        XCTAssertEqual(CalmModelText.meta(.base, systemLanguages: nil), "99 languages · Very fast · fair")
        XCTAssertEqual(CalmModelText.meta(.small, systemLanguages: nil), "99 languages · Fast · accurate")
        XCTAssertEqual(CalmModelText.meta(.largeV3LatestCompact, systemLanguages: nil), "99 languages · Medium speed · most accurate")
        XCTAssertEqual(CalmModelText.meta(.customEndpoint, systemLanguages: nil), "Whisper-compatible · Depends on your server")
    }

    func testMisfitNamesTheMissingLanguage() {
        XCTAssertEqual(CalmModelText.misfit(.parakeetTdtCtc110m, spoken: ["en", "de"], systemLanguages: nil), "Doesn’t understand German")
        XCTAssertNil(CalmModelText.misfit(.parakeetV3, spoken: ["en", "de"], systemLanguages: nil))
    }

    func testFamiliesGroupInBoardOrder() {
        let groups = CalmSpeechFamily.groups([.customEndpoint, .tiny, .parakeetV3, .canary180mFlash])
        XCTAssertEqual(groups.map(\.family), [.parakeet, .whisper, .specialized, .ownServer])
    }

    // MARK: - Command Mode choice

    func testCommandModeChoicesOnThisMac() {
        let options = CalmCommandModeChoice.options(
            cleanupIsLocal: true, appleIntelligenceAvailable: false, endpointIsValid: false,
            engine: .local(.ministral3_3b_q4_k_m)
        )
        XCTAssertEqual(options, [.same, .own])
        let withApple = CalmCommandModeChoice.options(
            cleanupIsLocal: true, appleIntelligenceAvailable: true, endpointIsValid: false,
            engine: .local(.ministral3_3b_q4_k_m)
        )
        XCTAssertEqual(withApple, [.same, .own, .appleIntelligence])
    }

    func testCommandModeChoicesWithCleanupOnAServer() {
        let options = CalmCommandModeChoice.options(
            cleanupIsLocal: false, appleIntelligenceAvailable: false, endpointIsValid: true, engine: .endpoint
        )
        XCTAssertEqual(options, [.server, .onThisMac])
        let unset = CalmCommandModeChoice.options(
            cleanupIsLocal: false, appleIntelligenceAvailable: false, endpointIsValid: false,
            engine: .local(.qwen25_1_5b_q4_k_m)
        )
        XCTAssertEqual(unset, [.onThisMac])
    }

    func testCurrentCommandModeChoice() {
        XCTAssertEqual(CalmCommandModeChoice.current(engine: .local(.qwen25_1_5b_q4_k_m), cleanupIsLocal: true, sharesModel: true), .same)
        XCTAssertEqual(CalmCommandModeChoice.current(engine: .local(.qwen25_1_5b_q4_k_m), cleanupIsLocal: true, sharesModel: false), .own)
        XCTAssertEqual(CalmCommandModeChoice.current(engine: .local(.qwen25_1_5b_q4_k_m), cleanupIsLocal: false, sharesModel: false), .onThisMac)
        XCTAssertEqual(CalmCommandModeChoice.current(engine: .appleIntelligence, cleanupIsLocal: true, sharesModel: false), .appleIntelligence)
    }

    @MainActor
    func testChoosingSameModelSharesIt() async {
        let cleanup = MockTranscriptCleanup()
        cleanup.downloadedKinds = [.ministral3_3b_q4_k_m, .qwen25_1_5b_q4_k_m]
        let (appState, _) = AppState.makeTestState(transcriptCleanup: cleanup)
        appState.selectedCleanupModelKind = .ministral3_3b_q4_k_m
        appState.commandModeEngine = .local(.qwen25_1_5b_q4_k_m)
        XCTAssertEqual(appState.calmCommandModeChoice, .own)

        await appState.selectCalmCommandModeChoice(.same)
        XCTAssertTrue(appState.sharesAIModel)
        XCTAssertEqual(appState.calmCommandModeChoice, .same)

        await appState.selectCalmCommandModeChoice(.own)
        XCTAssertFalse(appState.sharesAIModel)
        XCTAssertEqual(appState.calmCommandModeChoice, .own)
    }

    /// With separate models, the Command Mode model configured but not on
    /// this Mac is not "in use": picking it again must download it.
    @MainActor
    func testAMissingCommandModeModelIsNotInUse() {
        let cleanup = MockTranscriptCleanup()
        cleanup.downloadedKinds = [.ministral3_3b_q4_k_m]
        let (appState, _) = AppState.makeTestState(transcriptCleanup: cleanup)
        appState.selectedCleanupModelKind = .ministral3_3b_q4_k_m
        appState.commandModeEngine = .local(.qwen25_1_5b_q4_k_m)
        XCTAssertFalse(appState.sharesAIModel)

        let missing = CleanupModelKind.qwen25_1_5b_q4_k_m
        XCTAssertFalse(CalmWritingPickFlow.isInUse(missing, role: .commandMode, appState: appState))
        XCTAssertEqual(
            CalmModelPicks.writingStep(
                for: missing, state: .idle,
                isInUse: CalmWritingPickFlow.isInUse(missing, role: .commandMode, appState: appState)
            ),
            .start(cancelling: nil)
        )

        cleanup.downloadedKinds.insert(missing)
        XCTAssertTrue(CalmWritingPickFlow.isInUse(missing, role: .commandMode, appState: appState))
        XCTAssertTrue(CalmWritingPickFlow.isInUse(.ministral3_3b_q4_k_m, role: .cleanup, appState: appState))

        cleanup.downloadedKinds.remove(.ministral3_3b_q4_k_m)
        XCTAssertFalse(CalmWritingPickFlow.isInUse(.ministral3_3b_q4_k_m, role: .cleanup, appState: appState))
        XCTAssertFalse(CalmWritingPickFlow.isInUse(.ministral3_3b_q4_k_m, role: .cleanupOnly, appState: appState))
    }

    @MainActor
    func testRunningCleanupOnThisMacAgain() {
        let (appState, _) = AppState.makeTestState()
        var endpoint = appState.cleanupEndpoint
        endpoint.provider = .ollama
        appState.cleanupEndpoint = endpoint
        appState.calmRunCleanupOnThisMac()
        XCTAssertTrue(appState.cleanupEndpoint.isLocal)
    }

    // MARK: - Smart Cleanup copy

    func testEveryLevelHasAnExample() {
        for level in CleanupLevel.displayOrder {
            let example = CalmCleanupExample.example(for: level)
            XCTAssertFalse(example.summary.isEmpty)
            XCTAssertFalse(example.types.isEmpty)
        }
        XCTAssertEqual(CalmCleanupExample.example(for: .none).types, CalmCleanupExample.example(for: .none).said)
    }

    func testNoneIsOfferedOnlyWhileItIsTheLevel() {
        XCTAssertEqual(CalmCleanupExample.levels(current: .medium), [.light, .medium, .grammar, .high])
        XCTAssertEqual(CalmCleanupExample.levels(current: .none), CleanupLevel.displayOrder)
    }
}
