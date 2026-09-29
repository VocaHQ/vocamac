// SettingsPolishStateTests.swift
// VocaMac
//
// Tests for AppState behavior behind the Settings polish: restoring a removed
// vocabulary term, the "model is missing" test, and ending the overlay preview
// when a dictation starts.

import XCTest
@testable import VocaMac

@MainActor
final class SettingsPolishStateTests: XCTestCase {

    private var appState: AppState!
    private var mocks: TestMocks!

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: PreferenceKey.selectedModelSize)
        let (state, testMocks) = AppState.makeTestState()
        appState = state
        mocks = testMocks
        appState.setVocabularyTerms([])
    }

    override func tearDown() async throws {
        appState.setVocabularyTerms([])
        UserDefaults.standard.removeObject(forKey: PreferenceKey.selectedModelSize)
        appState = nil
        mocks = nil
    }

    // MARK: - Vocabulary undo

    func testRestoredVocabularyTermReturnsToItsPosition() {
        appState.setVocabularyTerms(["alpha", "beta", "gamma"])
        appState.removeVocabularyTerm("alpha")

        appState.restoreVocabularyTerm("alpha", at: 0)

        XCTAssertEqual(appState.vocabularyTerms, ["alpha", "beta", "gamma"])
    }

    func testRestoreClampsAnOutOfRangeIndex() {
        appState.setVocabularyTerms(["alpha"])

        appState.restoreVocabularyTerm("omega", at: 40)

        XCTAssertEqual(appState.vocabularyTerms, ["alpha", "omega"])
    }

    func testRestoreSkipsATermAddedAgainMeanwhile() {
        appState.setVocabularyTerms(["alpha", "beta"])
        appState.removeVocabularyTerm("alpha")
        appState.addVocabularyTerm("Alpha")

        appState.restoreVocabularyTerm("alpha", at: 0)

        XCTAssertEqual(appState.vocabularyTerms, ["beta", "Alpha"])
    }

    // MARK: - needsSpeechModel

    private func model(_ size: ModelSize, downloaded: Bool, loading: Bool = false, progress: Double? = nil)
        -> WhisperModelInfo {
        WhisperModelInfo(
            size: size, filePath: nil, isDownloaded: downloaded, isActive: false,
            isSupported: true, downloadProgress: progress, isLoading: loading
        )
    }

    func testNoModelNeededWhenTheModelListIsNotPopulatedYet() {
        mocks.whisperService.isModelLoaded = false
        appState.availableModels = []
        XCTAssertFalse(appState.needsSpeechModel)
    }

    func testModelNeededWhenTheSelectedOneIsNotDownloaded() {
        mocks.whisperService.isModelLoaded = false
        appState.selectedModelSize = ModelSize.tiny.rawValue
        appState.availableModels = [model(.tiny, downloaded: false)]
        XCTAssertTrue(appState.needsSpeechModel)
    }

    func testIdleUnloadOfADownloadedModelIsNotMissing() {
        mocks.whisperService.isModelLoaded = false
        appState.selectedModelSize = ModelSize.tiny.rawValue
        appState.availableModels = [model(.tiny, downloaded: true)]
        XCTAssertFalse(appState.needsSpeechModel)
    }

    func testNoModelNeededWhileOneIsDownloadingOrLoading() {
        mocks.whisperService.isModelLoaded = false
        appState.selectedModelSize = ModelSize.tiny.rawValue
        appState.availableModels = [model(.tiny, downloaded: false, progress: 0.4)]
        XCTAssertFalse(appState.needsSpeechModel)
        appState.availableModels = [model(.tiny, downloaded: false, loading: true)]
        XCTAssertFalse(appState.needsSpeechModel)
    }

    func testNoModelNeededWhenOneIsLoaded() {
        mocks.whisperService.isModelLoaded = true
        appState.availableModels = [model(.tiny, downloaded: false)]
        XCTAssertFalse(appState.needsSpeechModel)
    }

    // MARK: - Overlay preview vs dictation

    func testStartingADictationEndsARunningPreviewBeforeAnythingElse() async {
        appState.overlayPreview.start(style: .live, position: .top)
        XCTAssertTrue(appState.overlayPreview.isRunning)
        let hidesBefore = mocks.cursorOverlay.hideCallCount

        await appState.startRecording()

        XCTAssertFalse(appState.overlayPreview.isRunning)
        XCTAssertGreaterThan(mocks.cursorOverlay.hideCallCount, hidesBefore)
    }
}
