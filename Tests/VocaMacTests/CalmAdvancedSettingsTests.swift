// CalmAdvancedSettingsTests.swift
// VocaMac
//
// Tests for Settings › Privacy and History, Advanced, Phone gateway and
// About (v3): the on-device statement, history and permission summaries,
// the apps History can still exclude, memory and update lines.

import XCTest
@testable import VocaMac

// MARK: - On-device statement

@MainActor
final class CalmPrivacyStatementTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PreferenceKey.selectedModelSize)
        super.tearDown()
    }

    func testLocalStatement() {
        let statement = CalmPrivacyStatement(audioLeaves: false, textLeaves: false)
        XCTAssertFalse(statement.isRemote)
        XCTAssertEqual(statement.title, "Everything stays on this Mac")
        XCTAssertEqual(
            statement.message, "Your audio and text never leave it, unless you pick Your own server as your model."
        )
    }

    func testRemoteStatementsSayWhatLeaves() {
        let audio = CalmPrivacyStatement(audioLeaves: true, textLeaves: false)
        XCTAssertTrue(audio.isRemote)
        XCTAssertEqual(audio.title, "Audio leaves this Mac")
        XCTAssertEqual(audio.modelsTab, .speech)

        let text = CalmPrivacyStatement(audioLeaves: false, textLeaves: true)
        XCTAssertEqual(text.title, "Text leaves this Mac")
        XCTAssertTrue(text.message.contains("Your audio stays here"))
        XCTAssertEqual(text.modelsTab, .writing)

        let both = CalmPrivacyStatement(audioLeaves: true, textLeaves: true)
        XCTAssertEqual(both.title, "Audio and text leave this Mac")
        XCTAssertEqual(both.modelsTab, .speech)
    }

    func testAppStateStatementFollowsTheSpeechModel() {
        let (appState, _) = AppState.makeTestState()
        XCTAssertFalse(appState.calmPrivacyStatement.isRemote)

        appState.selectedModelSize = ModelSize.customEndpoint.rawValue
        XCTAssertTrue(appState.calmPrivacyStatement.audioLeaves)
        XCTAssertFalse(appState.calmPrivacyStatement.textLeaves)
    }

    func testAppStateStatementFollowsARemoteCleanupEndpoint() {
        let (appState, _) = AppState.makeTestState()
        var endpoint = appState.cleanupEndpoint
        endpoint.provider = .ollama
        appState.cleanupEndpoint = endpoint

        appState.transcriptCleanupEnabled = false
        appState.commandModeEngine = .local(CommandModeEngine.defaultLocalModel)
        XCTAssertFalse(appState.calmPrivacyStatement.textLeaves, "An endpoint nothing uses sends nothing")

        appState.commandModeEngine = .endpoint
        XCTAssertTrue(appState.calmPrivacyStatement.textLeaves, "Command Mode on the endpoint sends selected text")

        appState.commandModeEngine = .local(CommandModeEngine.defaultLocalModel)

        appState.transcriptCleanupEnabled = true
        XCTAssertTrue(appState.calmPrivacyStatement.textLeaves)
        XCTAssertFalse(appState.calmPrivacyStatement.audioLeaves)
    }

    func testHistoryAudioTotals() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationHistoryStore(directory: directory)
        let (appState, _) = AppState.makeTestState(historyStore: store)

        let kept = await store.begin(audio: [Float](repeating: 0.1, count: 16_000), target: nil, modelID: "tiny", language: "en", audioSeconds: 1)
        store.complete(kept, rawText: "a", finalText: "A", summary: nil, language: "en", transcriptionSeconds: 0.1, keepAudio: true)
        let dropped = await store.begin(audio: [Float](repeating: 0.1, count: 16_000), target: nil, modelID: "tiny", language: "en", audioSeconds: 1)
        store.complete(dropped, rawText: "b", finalText: "B", summary: nil, language: "en", transcriptionSeconds: 0.1, keepAudio: false)

        XCTAssertEqual(appState.calmHistoryAudioCount, 1)
        XCTAssertGreaterThan(appState.calmHistoryAudioBytes, 0)
    }
}

// MARK: - Summaries

final class CalmAdvancedSummaryTests: XCTestCase {

    func testSavedNow() {
        XCTAssertEqual(CalmAdvancedSummary.savedNow(count: 0, audioBytes: 0), "Nothing saved yet")
        XCTAssertEqual(CalmAdvancedSummary.savedNow(count: 1, audioBytes: 0), "1 dictation")
        let withAudio = CalmAdvancedSummary.savedNow(count: 1284, audioBytes: 212_000_000)
        XCTAssertTrue(withAudio.hasPrefix("\(1284.formatted()) dictations · "))
        XCTAssertTrue(withAudio.hasSuffix(" of audio"))
    }

    func testRetentionTitles() {
        XCTAssertEqual(CalmAdvancedSummary.retentionTitle(.month), "30 days")
        XCTAssertEqual(CalmAdvancedSummary.retentionTitle(.forever), "Never delete")
    }

    func testExcludedApps() {
        XCTAssertEqual(CalmAdvancedSummary.excludedApps([]), "None yet. Add password managers or banking apps.")
        XCTAssertEqual(CalmAdvancedSummary.excludedApps(["1Password"]), "1Password")
        XCTAssertEqual(CalmAdvancedSummary.excludedApps(["1Password", "Bank"]), "1Password and Bank")
        XCTAssertEqual(CalmAdvancedSummary.excludedApps(["1Password", "Bank", "Health", "Notes"]), "1Password, Bank and 2 more")
    }

    func testConfirmationsNameTheCount() {
        XCTAssertTrue(CalmAdvancedSummary.clearHistoryMessage(count: 1).hasPrefix("This deletes 1 dictation and"))
        XCTAssertTrue(CalmAdvancedSummary.clearHistoryMessage(count: 3).contains("Your totals in Insights are kept"))
        XCTAssertTrue(CalmAdvancedSummary.deleteAudioMessage(count: 2).contains("recordings of 2 dictations"))
    }

    func testPermissionRows() {
        XCTAssertEqual(CalmAdvancedSummary.permissionDescription(purpose: "To hear you", status: .granted), "To hear you")
        XCTAssertEqual(CalmAdvancedSummary.permissionDescription(purpose: "To hear you", status: .notDetermined), "To hear you")
        XCTAssertEqual(
            CalmAdvancedSummary.permissionDescription(purpose: "To hear you", status: .denied),
            "To hear you. Turn it on in System Settings › Privacy & Security."
        )
        XCTAssertNil(CalmAdvancedSummary.permissionAction(.granted))
        XCTAssertEqual(CalmAdvancedSummary.permissionAction(.notDetermined), "Grant access")
        XCTAssertEqual(CalmAdvancedSummary.permissionAction(.denied), "Open Settings")
        XCTAssertTrue(CalmAdvancedSummary.recheckDescription(mayNeedRelaunch: true).contains("Restart VocaMac"))
    }

    func testLogsAndMemory() {
        XCTAssertEqual(CalmAdvancedSummary.logs(entryCount: 1), "1 entry · helpful when reporting a problem")
        XCTAssertEqual(CalmAdvancedSummary.logs(entryCount: 0), "0 entries · helpful when reporting a problem")
        XCTAssertEqual(CalmAdvancedSummary.memory(512), "512 MB")
        XCTAssertEqual(CalmAdvancedSummary.memory(1536), "1.5 GB")
        XCTAssertEqual(CalmAdvancedSummary.cpu(3.14), "3.1%")
    }

    func testModelStatus() {
        XCTAssertEqual(
            CalmAdvancedSummary.modelStatus(isLoaded: true, unloadMessage: "ignored", freedMB: 100),
            "Loaded and ready, so dictation starts right away"
        )
        XCTAssertEqual(
            CalmAdvancedSummary.modelStatus(isLoaded: false, unloadMessage: "Unloaded after 5 minutes.", freedMB: 420),
            "Unloaded after 5 minutes. About 420 MB was freed."
        )
        XCTAssertEqual(CalmAdvancedSummary.modelStatus(isLoaded: false, unloadMessage: nil, freedMB: nil), "It loads when you next dictate")
    }

    func testVersionAndThisMac() {
        XCTAssertEqual(CalmAdvancedSummary.versionLine(version: "1.0.0"), "Version 1.0.0 · Stable")
        XCTAssertEqual(CalmAdvancedSummary.channel(version: "1.1.0-nightly.3"), "Nightly")
        XCTAssertEqual(
            CalmAdvancedSummary.thisMac(
                processor: "Apple M1 Pro", memoryGB: 16,
                osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
            ),
            "Apple M1 Pro · 16 GB · macOS 26.1"
        )
        XCTAssertEqual(
            CalmAdvancedSummary.thisMac(
                processor: nil, memoryGB: nil,
                osVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 2, patchVersion: 1)
            ),
            "macOS 15.2.1"
        )
        XCTAssertEqual(CalmAdvancedSummary.thisMacDetail(isAppleSilicon: true, hasNeuralEngine: true), "Apple Silicon · Neural Engine")
    }

    private func release(_ version: String = "v1.1.0", notes: String = "") -> UpdateInfo {
        UpdateInfo(
            version: version, tagName: version, releaseNotes: notes,
            releasePageURL: URL(fileURLWithPath: "/"), dmgURL: URL(fileURLWithPath: "/"), dmgSize: 1, sha256: nil
        )
    }

    func testUpdateStatus() {
        XCTAssertNil(CalmAdvancedSummary.updateStatus(.idle))
        XCTAssertEqual(CalmAdvancedSummary.updateStatus(.upToDate)?.text, "Up to date")
        XCTAssertEqual(CalmAdvancedSummary.updateStatus(.upToDate)?.tone, .good)
        XCTAssertEqual(CalmAdvancedSummary.updateStatus(.updateAvailable(release()))?.text, "VocaMac 1.1.0 is available")
        XCTAssertEqual(CalmAdvancedSummary.updateStatus(.error("Offline"))?.tone, .problem)
        XCTAssertEqual(CalmAdvancedSummary.updateProblem(.error("Offline")), "Offline")
        XCTAssertNil(CalmAdvancedSummary.updateProblem(.upToDate))
        XCTAssertEqual(
            CalmAdvancedSummary.updateStatus(.downloading(progress: 0.42, bytesDownloaded: 1, totalBytes: 2, estimatedSecondsRemaining: 1))?.text,
            "Downloading 42%"
        )
    }

    func testReleaseNoteLines() {
        XCTAssertEqual(
            CalmAdvancedSummary.releaseNoteLines("- Faster start-up\n- Fixes for Mail"),
            ["• Faster start-up", "• Fixes for Mail"]
        )
        XCTAssertEqual(CalmAdvancedSummary.releaseNoteLines(""), [])
    }

    @MainActor
    func testUpdateDialogOpensForTheRightStates() {
        let info = release()
        XCTAssertEqual(CalmAboutSettings.availableInfo(.updateAvailable(info)), info)
        XCTAssertNil(CalmAboutSettings.availableInfo(.upToDate))
        XCTAssertEqual(CalmAboutSettings.pendingInfo(.verifying, last: info), info)
        XCTAssertNil(CalmAboutSettings.pendingInfo(.upToDate, last: info))
        XCTAssertNil(CalmAboutSettings.pendingInfo(.checking, last: info))
        XCTAssertEqual(CalmUpdateDialog.remaining(130), "2m 10s left")
        XCTAssertEqual(CalmUpdateDialog.remaining(40), "40s left")
    }

    func testGatewayLines() {
        XCTAssertEqual(CalmAdvancedSummary.gatewayRow(status: .stopped, isReady: false), "Dictate on your phone and type on this Mac")
        XCTAssertEqual(CalmAdvancedSummary.gatewayRow(status: .ready, isReady: true), "Running · ready to pair")
        XCTAssertEqual(
            CalmAdvancedSummary.gatewayStatusDetail(status: .error("Port busy"), isLive: false, isReady: false), "Port busy"
        )
        XCTAssertEqual(
            CalmAdvancedSummary.gatewayStatusDetail(status: .pairable, isLive: true, isReady: false),
            "Running · model may still be downloading"
        )
        XCTAssertEqual(CalmAdvancedSummary.gatewayTag(.ready).text, "Ready")
        XCTAssertEqual(CalmAdvancedSummary.gatewayTag(.error("x")).tone, .warning)
    }
}

// MARK: - Never save from these apps

@MainActor
final class CalmExcludedAppsTests: XCTestCase {

    func testCandidatesSkipListedAppsAndFilterBySearch() {
        let running = [
            RunningAppSnapshot(displayName: "1Password", bundleIdentifier: "com.1password.1password"),
            RunningAppSnapshot(displayName: "Notion", bundleIdentifier: "notion.id"),
            RunningAppSnapshot(displayName: "Notes", bundleIdentifier: "com.apple.Notes"),
        ]
        let excluded = [AutoPauseAppEntry.from(snapshot: running[0])]

        XCTAssertEqual(
            CalmExcludedAppsDialog.candidates(running: running, excluded: excluded, search: "").map(\.displayName),
            ["Notion", "Notes"]
        )
        XCTAssertEqual(
            CalmExcludedAppsDialog.candidates(running: running, excluded: excluded, search: " noti ").map(\.displayName),
            ["Notion"]
        )
        XCTAssertTrue(CalmExcludedAppsDialog.candidates(running: running, excluded: excluded, search: "pass").isEmpty)
    }
}
