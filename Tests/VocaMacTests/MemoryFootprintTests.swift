// MemoryFootprintTests.swift
// VocaMac
//
// Memory pressure unloads, and the smaller starting context of cleanup models.

import XCTest
@testable import VocaMac

@MainActor
final class MemoryFootprintTests: XCTestCase {

    private let speech = [Float](repeating: 0.1, count: 16_000)

    // MARK: - Memory pressure

    func testPressureLevelsMapFromDispatchEvents() {
        XCTAssertEqual(MemoryPressureMonitor.level(for: .warning), .warning)
        XCTAssertEqual(MemoryPressureMonitor.level(for: .critical), .critical)
        XCTAssertEqual(MemoryPressureMonitor.level(for: [.warning, .critical]), .critical)
        XCTAssertNil(MemoryPressureMonitor.level(for: .normal), "A return to normal frees nothing")
    }

    func testPressureWhileIdleUnloadsTheSpeechAndCleanupModels() async {
        let cleanup = MockTranscriptCleanup()
        cleanup.isLoaded = true
        let (appState, mocks) = AppState.makeTestState(transcriptCleanup: cleanup)
        XCTAssertTrue(mocks.transcriber.isModelLoaded)

        await appState.handleMemoryPressure(.warning)

        XCTAssertEqual(mocks.transcriber.unloadCallCount, 1)
        XCTAssertGreaterThanOrEqual(cleanup.unloadCallCount, 1)
        XCTAssertEqual(appState.lastModelUnloadReason, .memoryPressure)
    }

    func testPressureAlsoEmptiesTheCommandModeSlot() async {
        let slot = MockTranscriptCleanup()
        slot.isLoaded = true
        let (appState, _) = AppState.makeTestState(commandModelSlot: slot)

        await appState.handleMemoryPressure(.warning)

        XCTAssertEqual(slot.unloadCallCount, 1)
    }

    func testPressureDuringADictationKeepsTheModel() async {
        let (appState, mocks) = AppState.makeTestState()

        await appState.startRecording()
        await appState.handleMemoryPressure(.critical)

        XCTAssertEqual(mocks.transcriber.unloadCallCount, 0, "Unloading under a recording fails it at stop")
        XCTAssertTrue(mocks.transcriber.isModelLoaded)
        await appState.cancelRecording()
    }

    func testPressureWhileAutoPausedLeavesStateAlone() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.isAutoPaused = true

        await appState.handleMemoryPressure(.warning)

        XCTAssertEqual(mocks.transcriber.unloadCallCount, 0)
    }

    func testMemoryPressureUnloadExplainsItself() async {
        let (appState, _) = AppState.makeTestState()

        await appState.handleMemoryPressure(.warning)

        XCTAssertEqual(
            appState.modelUnloadStatusMessage,
            "Model unloaded because the Mac was low on memory. Next dictation reloads it."
        )
    }

    // MARK: - Cleanup context

    func testCleanupModelsStartAtNoMoreThan4096Tokens() {
        for kind in CleanupModelKind.allCases {
            let descriptor = kind.descriptor
            XCTAssertLessThanOrEqual(descriptor.startingTokenCount, 4096, descriptor.displayName)
            XCTAssertLessThanOrEqual(descriptor.startingTokenCount, descriptor.maxTokenCount, descriptor.displayName)
        }
    }

    func testInputThatFitsInOnePassKeepsTheSmallerContext() {
        XCTAssertFalse(TranscriptCleanupService.needsLargerContext(chunkCount: 1, loadedTokens: 4096, fullTokens: 8192))
    }

    func testInputThatWouldBeSplitGrowsTheContext() {
        XCTAssertTrue(TranscriptCleanupService.needsLargerContext(chunkCount: 2, loadedTokens: 4096, fullTokens: 8192))
    }

    func testInputThatDoesNotFitAtAllGrowsTheContext() {
        XCTAssertTrue(TranscriptCleanupService.needsLargerContext(chunkCount: nil, loadedTokens: 4096, fullTokens: 8192))
    }

    func testAModelAlreadyAtFullContextNeverGrows() {
        XCTAssertFalse(TranscriptCleanupService.needsLargerContext(chunkCount: 3, loadedTokens: 8192, fullTokens: 8192))
        XCTAssertFalse(TranscriptCleanupService.needsLargerContext(chunkCount: nil, loadedTokens: 4096, fullTokens: 4096))
    }
}
