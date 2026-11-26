// ChosenSpeechModelTests.swift
// VocaMac
//
// The model the user dictates with must survive an idle unload (it can't be
// removed) and a failed re-download at launch (a stand-in isn't saved over it).

import XCTest
@testable import VocaMac

@MainActor
final class ChosenSpeechModelTests: XCTestCase {
    func testChosenModelCantBeDeletedAfterAnIdleUnload() async {
        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.small, .medium]
        let (appState, _) = AppState.makeTestState(modelManager: modelManager)
        await appState.loadModel(.small)
        await appState.unloadActiveModel(reason: .idleKeepAlive)
        XCTAssertEqual(appState.availableModels.first { $0.size == .small }?.isActive, false)

        await appState.deleteModel(.small)

        XCTAssertTrue(modelManager.deletedModels.isEmpty)
        XCTAssertTrue(appState.errorMessage?.contains("dictate with") == true)
    }

    func testRemoveIsNotOfferedForTheChosenModel() {
        let info = WhisperModelInfo(size: .small, filePath: nil, isDownloaded: true, isActive: false, isSupported: true)
        XCTAssertFalse(CalmSpeechPickFlow.canRemove(info, selectedModelSize: ModelSize.small.rawValue))
        XCTAssertTrue(CalmSpeechPickFlow.canRemove(info, selectedModelSize: ModelSize.medium.rawValue))
    }

    func testStandInLoadKeepsTheChoice() async {
        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.tiny]
        let (appState, mocks) = AppState.makeTestState(modelManager: modelManager)
        appState.selectedModelSize = ModelSize.medium.rawValue

        await appState.loadModel(.tiny, persistsSelection: false)

        XCTAssertEqual(mocks.transcriber.loadedModelName, modelManager.modelIdentifier(for: .tiny))
        XCTAssertEqual(appState.selectedModelSize, ModelSize.medium.rawValue)
    }

    func testReloadAfterIdleUnloadUsesTheStandInUntilTheChosenModelIsDownloaded() async {
        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.tiny]
        let (appState, mocks) = AppState.makeTestState(modelManager: modelManager)
        appState.selectedModelSize = ModelSize.medium.rawValue
        appState.startupModelStandIn = .tiny
        await appState.loadModel(.tiny, persistsSelection: false)
        await appState.unloadActiveModel(reason: .idleKeepAlive)

        await appState.ensureModelLoaded()

        XCTAssertEqual(mocks.transcriber.loadedModelName, modelManager.modelIdentifier(for: .tiny))
        XCTAssertEqual(appState.selectedModelSize, ModelSize.medium.rawValue)

        // Once the chosen model is on disk, the next reload uses it.
        modelManager.downloadedModels.insert(.medium)
        await appState.unloadActiveModel(reason: .idleKeepAlive)
        await appState.ensureModelLoaded()
        XCTAssertEqual(mocks.transcriber.loadedModelName, modelManager.modelIdentifier(for: .medium))
        XCTAssertNil(appState.startupModelStandIn)
    }

    func testRecordingFollowsTheStandInNotTheSavedChoice() async {
        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.tiny]
        let (appState, _) = AppState.makeTestState(modelManager: modelManager)
        appState.selectedModelSize = ModelSize.parakeetV3.rawValue
        appState.startupModelStandIn = .tiny
        await appState.loadModel(.tiny, persistsSelection: false)
        XCTAssertEqual(appState.dictationModelSize, .tiny)

        // After an idle unload, the reload target decides.
        await appState.unloadActiveModel(reason: .idleKeepAlive)
        XCTAssertEqual(appState.dictationModelSize, .tiny)
    }

    func testChosenModelMissingFromTheListCantBeDeleted() async {
        // A settings import can choose an older download the picker no longer lists.
        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.tiny, .medium]
        let (appState, _) = AppState.makeTestState(modelManager: modelManager)
        appState.availableModels.removeAll { $0.size == .medium }
        appState.selectedModelSize = ModelSize.medium.rawValue

        await appState.deleteModel(.medium)

        XCTAssertTrue(modelManager.deletedModels.isEmpty)
    }

    func testStandInCoveringForAMissingChoiceDoesntAskToSetUp() async {
        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.tiny]
        let (appState, _) = AppState.makeTestState(modelManager: modelManager)
        appState.selectedModelSize = ModelSize.medium.rawValue
        appState.startupModelStandIn = .tiny
        await appState.loadModel(.tiny, persistsSelection: false)
        await appState.unloadActiveModel(reason: .idleKeepAlive)
        appState.refreshModelStatuses()

        XCTAssertFalse(appState.needsSpeechModel, "Tiny reloads offline; nothing to set up")

        appState.startupModelStandIn = nil
        XCTAssertTrue(appState.needsSpeechModel, "Without a stand-in the missing choice must be set up")
    }
}
