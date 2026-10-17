// AIModelRoleTests.swift
// VocaMac Tests
//
// Choosing on-device models for Smart Cleanup and Command Mode.

import XCTest
@testable import VocaMac

@MainActor
final class AIModelRoleTests: XCTestCase {

    private func makeState() -> (AppState, MockTranscriptCleanup) {
        let cleanup = MockTranscriptCleanup()
        let (state, _) = AppState.makeTestState(transcriptCleanup: cleanup)
        state.aiModelsKeptSeparate = false
        // Other suites leave a remote endpoint in UserDefaults.
        state.cleanupEndpoint = CleanupEndpointConfiguration()
        state.transcriptCleanupEnabled = false
        state.transcriptCleanupModel = CleanupModelKind.defaultKind.rawValue
        // Pinned so the result doesn't depend on Apple Intelligence on the host.
        state.selectCommandModeEngine(.local(.qwen25_1_5b_q4_k_m))
        return (state, cleanup)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PreferenceKey.aiModelsKeptSeparate)
        UserDefaults.standard.removeObject(forKey: PreferenceKey.commandModeEngine)
        super.tearDown()
    }

    func testUsingAModelForBothSetsCleanupAndCommandMode() async {
        let (state, _) = makeState()
        state.transcriptCleanupEnabled = true
        await state.useAIModel(.ministral3_3b_q4_k_m, for: .both)
        XCTAssertEqual(state.selectedCleanupModelKind, .ministral3_3b_q4_k_m)
        XCTAssertEqual(state.commandModeEngine, .local(.ministral3_3b_q4_k_m))
        XCTAssertTrue(state.sharesAIModel)
    }

    func testSharingIsSuggestedUntilChosenOrDeclined() async {
        let (state, _) = makeState()
        XCTAssertFalse(state.suggestsSharingAIModel, "nothing to share while cleanup is off")

        state.transcriptCleanupEnabled = true
        XCTAssertTrue(state.suggestsSharingAIModel)
        // The cleanup-only default can't edit, so the Command Mode model is offered.
        XCTAssertEqual(state.sharedAIModelCandidate, .qwen25_1_5b_q4_k_m)

        await state.setSharesAIModel(false)
        XCTAssertFalse(state.suggestsSharingAIModel, "declining hides the suggestion")

        await state.setSharesAIModel(true)
        XCTAssertTrue(state.sharesAIModel)
        XCTAssertFalse(state.suggestsSharingAIModel)
    }

    func testWhileSharingEitherChoiceMovesBoth() async {
        let (state, _) = makeState()
        await state.setSharesAIModel(true)
        XCTAssertEqual(state.selectedCleanupModelKind, .qwen25_1_5b_q4_k_m)

        await state.useAIModel(.qwen3_4b_instruct_2507_q4_k_m, for: .cleanup)
        XCTAssertEqual(state.commandModeEngine, .local(.qwen3_4b_instruct_2507_q4_k_m))

        await state.useAIModel(.qwen25_7b_q4_k_m, for: .commandMode)
        XCTAssertEqual(state.selectedCleanupModelKind, .qwen25_7b_q4_k_m)
    }

    func testCleanupOnlyModelEndsSharingAndKeepsCommandModel() async {
        let (state, _) = makeState()
        await state.setSharesAIModel(true)
        await state.useAIModel(.qwen25_0_5b_q4_k_m, for: .cleanup)
        XCTAssertFalse(state.sharesAIModel)
        XCTAssertEqual(state.selectedCleanupModelKind, .qwen25_0_5b_q4_k_m)
        XCTAssertEqual(state.commandModeEngine, .local(.qwen25_1_5b_q4_k_m))
    }

    func testCleanupOnlyModelIsNeverUsedForCommandMode() async {
        let (state, _) = makeState()
        await state.useAIModel(.qwen25_0_5b_q4_k_m, for: .commandMode)
        XCTAssertEqual(state.commandModeEngine, .local(.qwen25_1_5b_q4_k_m))
    }

    func testChoosingAppleIntelligenceEndsSharing() async {
        let (state, _) = makeState()
        await state.useAIModel(.ministral3_3b_q4_k_m, for: .both)
        state.selectCommandModeEngine(.appleIntelligence)
        XCTAssertFalse(state.sharesAIModel)
        XCTAssertEqual(state.selectedCleanupModelKind, .ministral3_3b_q4_k_m)
    }

    func testTurningSharingOnAdoptsAModelThatCanEdit() async {
        let (state, _) = makeState()
        state.selectCommandModeEngine(.appleIntelligence)
        await state.setSharesAIModel(true)
        XCTAssertTrue(state.selectedCleanupModelKind.supportsCommandMode)
        XCTAssertEqual(state.commandModeEngine, .local(state.selectedCleanupModelKind))
        XCTAssertTrue(state.sharesAIModel)
    }

    func testTurningSharingOffIsRemembered() async {
        let (state, _) = makeState()
        await state.useAIModel(.ministral3_3b_q4_k_m, for: .both)
        await state.setSharesAIModel(false)
        XCTAssertFalse(state.sharesAIModel)
        await state.useAIModel(.qwen3_4b_instruct_2507_q4_k_m, for: .cleanup)
        XCTAssertEqual(state.commandModeEngine, .local(.ministral3_3b_q4_k_m))
    }

    func testChoosingOneModelForBothSharesAgain() async {
        let (state, _) = makeState()
        await state.setSharesAIModel(false)
        await state.useAIModel(.qwen3_4b_instruct_2507_q4_k_m, for: .both)
        XCTAssertFalse(state.aiModelsKeptSeparate)
        XCTAssertTrue(state.sharesAIModel)
    }

    func testRefusedCleanupLoadForBothChangesNothing() async {
        let (state, cleanup) = makeState()
        state.transcriptCleanupEnabled = true
        await state.setSharesAIModel(false)
        cleanup.loadSucceeds = false
        await state.useAIModel(.qwen25_7b_q4_k_m, for: .both)
        XCTAssertEqual(state.selectedCleanupModelKind, .defaultKind)
        XCTAssertEqual(state.commandModeEngine, .local(.qwen25_1_5b_q4_k_m))
        XCTAssertTrue(state.aiModelsKeptSeparate)
    }

    func testTurningSharingOffDuringItsLoadWins() async {
        let (state, cleanup) = makeState()
        state.transcriptCleanupEnabled = true
        state.selectCommandModeEngine(.appleIntelligence)
        var release: CheckedContinuation<Void, Never>?
        cleanup.onLoad = { await withCheckedContinuation { release = $0 } }

        let older = Task { await state.setSharesAIModel(true) }
        while release == nil { await Task.yield() }
        cleanup.onLoad = nil
        await state.setSharesAIModel(false)
        release?.resume()
        await older.value

        XCTAssertTrue(state.aiModelsKeptSeparate)
        XCTAssertEqual(state.commandModeEngine, .appleIntelligence)
        XCTAssertEqual(state.selectedCleanupModelKind, .defaultKind)
    }

    func testNewerModelChoiceWinsOverAnOlderLoad() async {
        let (state, cleanup) = makeState()
        state.transcriptCleanupEnabled = true
        var release: CheckedContinuation<Void, Never>?
        cleanup.onLoad = { await withCheckedContinuation { release = $0 } }

        let older = Task { await state.useAIModel(.qwen25_7b_q4_k_m, for: .both) }
        while release == nil { await Task.yield() }
        cleanup.onLoad = nil
        await state.useAIModel(.qwen3_4b_instruct_2507_q4_k_m, for: .both)
        release?.resume()
        await older.value

        XCTAssertEqual(state.selectedCleanupModelKind, .qwen3_4b_instruct_2507_q4_k_m)
        XCTAssertEqual(state.commandModeEngine, .local(.qwen3_4b_instruct_2507_q4_k_m))
    }

    func testFailedDownloadChangesNothing() async {
        let (state, cleanup) = makeState()
        cleanup.downloadedKinds = []
        cleanup.downloadSucceeds = false
        await state.useAIModel(.ministral3_3b_q4_k_m, for: .both)
        XCTAssertEqual(state.selectedCleanupModelKind, .defaultKind)
        XCTAssertEqual(state.commandModeEngine, .local(.qwen25_1_5b_q4_k_m))
    }

    // MARK: Back from a server

    private func onServer(_ state: AppState) {
        var endpoint = state.cleanupEndpoint
        endpoint.provider = .ollama
        state.cleanupEndpoint = endpoint
        state.commandModeEngine = .endpoint
        state.transcriptCleanupEnabled = true
    }

    /// The server keeps cleaning while the model downloads and loads; only
    /// then does cleanup (and Command Mode on the server) move to this Mac.
    func testMovingCleanupToThisMacWaitsForTheModel() async {
        let (state, cleanup) = makeState()
        onServer(state)
        cleanup.downloadedKinds.remove(.ministral3_3b_q4_k_m)
        var wasOnServerWhileDownloading = false
        cleanup.onDownload = { wasOnServerWhileDownloading = !state.cleanupEndpoint.isLocal }
        var wasOnServerWhileLoading: Bool?
        cleanup.onLoad = { if wasOnServerWhileLoading == nil { wasOnServerWhileLoading = !state.cleanupEndpoint.isLocal } }

        let moved = await state.calmMoveCleanupToThisMac(.ministral3_3b_q4_k_m, for: .cleanup)

        XCTAssertTrue(moved)
        XCTAssertTrue(wasOnServerWhileDownloading)
        XCTAssertEqual(wasOnServerWhileLoading, true)
        XCTAssertTrue(state.cleanupEndpoint.isLocal)
        XCTAssertEqual(state.selectedCleanupModelKind, .ministral3_3b_q4_k_m)
        XCTAssertEqual(state.commandModeEngine, .local(.ministral3_3b_q4_k_m), "Command Mode leaves the server too")
    }

    func testFailedOrSupersededMoveKeepsTheServer() async {
        let (state, cleanup) = makeState()
        onServer(state)
        cleanup.downloadedKinds.remove(.ministral3_3b_q4_k_m)
        cleanup.downloadSucceeds = false
        let failed = await state.calmMoveCleanupToThisMac(.ministral3_3b_q4_k_m, for: .cleanup)
        XCTAssertFalse(failed)
        XCTAssertEqual(state.cleanupEndpoint.provider, .ollama)
        XCTAssertEqual(state.commandModeEngine, .endpoint)
        XCTAssertEqual(state.selectedCleanupModelKind, .defaultKind)

        cleanup.downloadSucceeds = true
        let superseded = await state.calmMoveCleanupToThisMac(.ministral3_3b_q4_k_m, for: .cleanup) { false }
        XCTAssertFalse(superseded)
        XCTAssertEqual(state.cleanupEndpoint.provider, .ollama)
    }

    /// While the two share a model, only a plain cleanup pick moves both:
    /// “Use for Command Mode only” leaves the cleanup model alone.
    func testCommandModeOnlyPickLeavesCleanupWhileSharing() async {
        let (state, _) = makeState()
        state.transcriptCleanupEnabled = true
        await state.useAIModel(.ministral3_3b_q4_k_m, for: .both)
        XCTAssertTrue(state.sharesAIModel)
        let picker = CalmModelPicker()

        picker.startWriting(.qwen25_7b_q4_k_m, role: .commandMode, cancelling: nil, appState: state)
        for _ in 0..<200 where picker.pendingCommandMode != nil { await Task.yield() }

        XCTAssertNil(picker.pendingCommandMode)
        XCTAssertEqual(state.commandModeEngine, .local(.qwen25_7b_q4_k_m))
        XCTAssertEqual(state.selectedCleanupModelKind, .ministral3_3b_q4_k_m)
        XCTAssertFalse(state.sharesAIModel)
    }

    func testChoosingWhileCleanupIsOffDoesNotLoadAModel() async {
        let (state, cleanup) = makeState()
        await state.useAIModel(.qwen25_1_5b_q4_k_m, for: .cleanup)
        XCTAssertEqual(state.selectedCleanupModelKind, .qwen25_1_5b_q4_k_m)
        XCTAssertEqual(cleanup.loadCallCount, 0)
    }

    func testLoadedModelShowsItsDisplayNameNotItsIdentifier() {
        let (state, mocks) = AppState.makeTestState()
        state.currentModel = nil
        mocks.whisperService.loadedModelName = "openai_whisper-tiny"
        XCTAssertEqual(state.loadedModelDisplayName, CalmModelText.name(.tiny))

        mocks.whisperService.loadedModelName = ModelSize.allCases.last?.rawValue
        XCTAssertEqual(state.loadedModelDisplayName, ModelSize.allCases.last.map(CalmModelText.name))

        mocks.whisperService.loadedModelName = nil
        XCTAssertNil(state.loadedModelDisplayName)
    }

    func testChoosingATranslatingModelOpensSpeechModelFiltered() {
        let (state, _) = AppState.makeTestState()
        state.showModelsThatTranslate()
        XCTAssertEqual(state.requestedSettingsPage, .speechModel)
        XCTAssertEqual(state.requestedSpeechModelSearch, "translate")
        XCTAssertTrue(ModelSize.allCases.contains { $0.translatesToEnglish })
    }

    func testCommandModeProblemsPointToTheCommandModePage() {
        let (state, cleanup) = makeState()
        cleanup.downloadedKinds = []
        let problem = state.commandModeProblem(for: .local(.qwen3_4b_instruct_2507_q4_k_m))
        XCTAssertEqual(problem?.contains("Settings → Command Mode"), true)
        XCTAssertEqual(problem?.contains("Cleanup"), false)
    }
}
