import XCTest
@testable import VocaMac

@MainActor
final class CleanupReadinessTests: XCTestCase {
    func testOptionalCleanupFailureDoesNotChangeDictationStatus() {
        let cleanup = MockTranscriptCleanup()
        let (state, _) = AppState.makeTestState(transcriptCleanup: cleanup)
        cleanup.modelState = .error("Not enough memory")
        state.transcriptCleanupEnabled = false
        XCTAssertNil(state.cleanupReadinessLabel)
        state.transcriptCleanupEnabled = true
        XCTAssertEqual(state.cleanupReadinessLabel, "Cleanup unavailable")
        XCTAssertEqual(state.appStatus, .idle)
        cleanup.modelState = .ready
        XCTAssertNil(state.cleanupReadinessLabel)
    }

    func testRecoveryOnlyOffersSmallerDownloadedModels() {
        let cleanup = MockTranscriptCleanup()
        let (state, _) = AppState.makeTestState(transcriptCleanup: cleanup)
        state.transcriptCleanupModel = CleanupModelKind.qwen3_4b_instruct_2507_q4_k_m.rawValue
        cleanup.downloadedKinds = [.qwen25_0_5b_q4_k_m, .qwen25_1_5b_q4_k_m, .qwen25_7b_q4_k_m]
        XCTAssertEqual(state.smallerDownloadedCleanupModel, .qwen25_0_5b_q4_k_m)
        cleanup.downloadedKinds = [.qwen3_4b_instruct_2507_q4_k_m, .qwen25_7b_q4_k_m]
        XCTAssertNil(state.smallerDownloadedCleanupModel)
        cleanup.downloadedKinds = []
        XCTAssertNil(state.smallerDownloadedCleanupModel)
    }

    func testLoadingAndDownloadingAreNotReportedAsReady() {
        XCTAssertEqual(CleanupModelState.loading(kind: .qwen25_0_5b_q4_k_m).readinessLabel, "Cleanup loading")
        XCTAssertEqual(CleanupModelState.downloading(kind: .qwen25_0_5b_q4_k_m, progress: 0.5).readinessLabel,
                       "Cleanup downloading")
        XCTAssertEqual(CleanupModelState.idle.readinessLabel, "Cleanup not loaded")
    }

    func testRemoteCleanupDoesNotInheritLocalModelFailure() {
        let cleanup = MockTranscriptCleanup()
        let (state, _) = AppState.makeTestState(transcriptCleanup: cleanup)
        cleanup.modelState = .error("Local model failed")
        state.transcriptCleanupEnabled = true
        state.cleanupEndpoint = CleanupEndpointConfiguration(provider: .ollama, model: "qwen3")
        XCTAssertNil(state.cleanupReadinessLabel)
        state.cleanupEndpoint = CleanupEndpointConfiguration(provider: .ollama, baseURL: "invalid url", model: "qwen3")
        XCTAssertEqual(state.cleanupReadinessLabel, "Cleanup needs setup")
    }
}
