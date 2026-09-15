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

    func testFailedDownloadChangesNothing() async {
        let (state, cleanup) = makeState()
        cleanup.downloadedKinds = []
        cleanup.downloadSucceeds = false
        await state.useAIModel(.ministral3_3b_q4_k_m, for: .both)
        XCTAssertEqual(state.selectedCleanupModelKind, .defaultKind)
        XCTAssertEqual(state.commandModeEngine, .local(.qwen25_1_5b_q4_k_m))
    }

    func testChoosingWhileCleanupIsOffDoesNotLoadAModel() async {
        let (state, cleanup) = makeState()
        await state.useAIModel(.qwen25_1_5b_q4_k_m, for: .cleanup)
        XCTAssertEqual(state.selectedCleanupModelKind, .qwen25_1_5b_q4_k_m)
        XCTAssertEqual(cleanup.loadCallCount, 0)
    }
}
