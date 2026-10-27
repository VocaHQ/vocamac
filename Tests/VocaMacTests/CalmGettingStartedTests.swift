// CalmGettingStartedTests.swift
// VocaMac Tests

import XCTest
@testable import VocaMac

@MainActor
final class CalmGettingStartedTests: XCTestCase {
    func testFreshInstallHasNothingDone() {
        let (state, _) = AppState.makeTestState()
        state.selectedModelSize = ModelSize.tiny.rawValue
        state.transcriptCleanupEnabled = false
        state.setVocabularyTerms([])
        state.wordReplacements = []

        XCTAssertFalse(state.calmGettingStartedDone.contains(.pickModel))
        XCTAssertFalse(state.calmGettingStartedDone.contains(.addWord))
        XCTAssertFalse(state.calmGettingStartedDone.contains(.smartCleanup))
    }

    func testStepsTickOffFromSettings() {
        let (state, _) = AppState.makeTestState()
        state.selectedModelSize = ModelSize.parakeetV3.rawValue
        state.transcriptCleanupEnabled = true
        state.setVocabularyTerms(["Priya Raman"])

        let done = state.calmGettingStartedDone
        XCTAssertTrue(done.contains(.pickModel))
        XCTAssertTrue(done.contains(.addWord))
        XCTAssertTrue(done.contains(.smartCleanup))
    }

    func testATranscribedFileIsNotADictation() {
        let (state, mocks) = AppState.makeTestState()
        // What recordTranscription(_:isDictation: false) leaves: counts, no speaking time.
        mocks.statsManager.stats = UserStats(totalWords: 120, totalTranscriptions: 1, dailyWordCounts: ["2026-10-21": 120])

        XCTAssertTrue(state.hasStatistics)
        XCTAssertFalse(state.calmGettingStartedDone.contains(.dictate))
        XCTAssertEqual(state.calmHomeTitle, "Welcome")
    }

    func testADictationTicksDictateAndWelcomesBack() {
        let (state, mocks) = AppState.makeTestState()
        mocks.statsManager.stats = UserStats(totalWords: 12, totalTranscriptions: 1, dailyAudioSeconds: ["2026-10-21": 4], longestDictationSeconds: 4)

        XCTAssertTrue(state.calmGettingStartedDone.contains(.dictate))
        XCTAssertEqual(state.calmHomeTitle, "Welcome back")
    }
}
