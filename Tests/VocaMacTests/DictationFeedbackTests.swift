// DictationFeedbackTests.swift
// VocaMac Tests
//
// Error fixes, the menu bar's state and spoken label, VoiceOver
// announcements, the overlay's clickable phases, and the processing stage.

import XCTest
@testable import VocaMac

// MARK: - Error Fixes

final class ErrorFixActionTests: XCTestCase {

    func testMicrophoneMessagesOfferThePrivacyPane() {
        XCTAssertEqual(
            ErrorFixAction.suggested(for: "Microphone permission is required. Please grant access in System Settings."),
            .openMicrophonePrivacy
        )
        XCTAssertEqual(ErrorFixAction.suggested(for: "Microphone access is off."), .openMicrophonePrivacy)
    }

    func testAudioMessagesOpenTheAudioPage() {
        XCTAssertEqual(
            ErrorFixAction.suggested(
                for: "Could not start USB Mic. Pick a different input in Settings → Audio, or reconnect the device."
            ),
            .openSettings(.audio)
        )
        XCTAssertEqual(
            ErrorFixAction.suggested(
                for: "No microphone audio detected. Check that the selected microphone is connected and available in Settings → Audio."
            ),
            .openSettings(.audio)
        )
    }

    func testModelMessagesOpenTheSpeechModelPage() {
        XCTAssertEqual(
            ErrorFixAction.suggested(for: "Could not load the speech model. Open Settings → Speech Model and try again."),
            .openSettings(.speechModel)
        )
        XCTAssertEqual(
            ErrorFixAction.suggested(
                for: "The speech model is still downloading. Dictation will work as soon as it finishes."
            ),
            .openSettings(.speechModel)
        )
    }

    func testAccessibilityMessageOffersAccessibility() {
        XCTAssertEqual(
            ErrorFixAction.suggested(for: TextInjector.accessibilityOffMessage),
            .openAccessibilityPrivacy
        )
    }

    func testMessagesWithNothingToFixOfferNoButton() {
        XCTAssertNil(ErrorFixAction.suggested(for: "Didn't catch that. Nothing was typed."))
        XCTAssertNil(ErrorFixAction.suggested(for: "There's no dictation to paste yet."))
    }

    func testNoticeInfersItsAction() {
        let notice = DictationErrorNotice(message: "Could not load the speech model. Open Settings → Speech Model and try again.")
        XCTAssertEqual(notice.action, .openSettings(.speechModel))
        XCTAssertEqual(notice.action?.title, "Open Speech Model")
    }
}

// MARK: - Menu Bar

final class MenuBarStatusTests: XCTestCase {

    func testReadinessGroupsWhatIsMissing() {
        XCTAssertEqual(MenuBarReadiness(.ready(preparingAnother: true)), .ready)
        XCTAssertEqual(MenuBarReadiness(.preparingModel), .preparing)
        XCTAssertEqual(MenuBarReadiness(.needsMicrophone), .blocked)
        XCTAssertEqual(MenuBarReadiness(.needsInputMonitoring), .blocked)
        XCTAssertEqual(MenuBarReadiness(.needsAccessibility), .blocked)
        XCTAssertEqual(MenuBarReadiness(.needsModel), .blocked)
    }

    func testIdleIconShowsWhenDictationCannotStart() {
        XCTAssertEqual(MenuBarIconStyle.style(for: .idle, readiness: .ready), .systemSymbolTemplate(name: "mic.fill"))
        XCTAssertEqual(MenuBarIconStyle.style(for: .idle, readiness: .preparing), .notReadyTemplate(badged: false))
        XCTAssertEqual(MenuBarIconStyle.style(for: .idle, readiness: .blocked), .notReadyTemplate(badged: true))
    }

    func testReadinessDoesNotHideAnActiveDictation() {
        XCTAssertEqual(MenuBarIconStyle.style(for: .recording, readiness: .blocked), .brandMarkTinted)
        XCTAssertEqual(
            MenuBarIconStyle.style(for: .processing, readiness: .preparing),
            .systemSymbol(name: "ellipsis.circle")
        )
    }

    func testAccessibilityLabelSaysWhatTheAppIsDoing() {
        let ready = DictationReadiness.ready(preparingAnother: false)
        XCTAssertEqual(MenuBarAccessibility.label(status: .idle, readiness: ready), "VocaMac")
        XCTAssertEqual(MenuBarAccessibility.label(status: .recording, readiness: ready), "VocaMac, recording")
        XCTAssertEqual(MenuBarAccessibility.label(status: .processing, readiness: ready), "VocaMac, transcribing")
        XCTAssertEqual(
            MenuBarAccessibility.label(status: .processing, readiness: ready, isCleaningUp: true),
            "VocaMac, cleaning up"
        )
        XCTAssertEqual(
            MenuBarAccessibility.label(status: .recording, readiness: ready, isCommandMode: true),
            "VocaMac, Command Mode listening"
        )
        XCTAssertEqual(MenuBarAccessibility.label(status: .error, readiness: ready), "VocaMac, error")
    }

    func testAccessibilityLabelSaysWhatIsMissing() {
        XCTAssertEqual(MenuBarAccessibility.label(status: .idle, readiness: .needsMicrophone), "VocaMac, needs permission")
        XCTAssertEqual(MenuBarAccessibility.label(status: .idle, readiness: .needsAccessibility), "VocaMac, needs permission")
        XCTAssertEqual(MenuBarAccessibility.label(status: .idle, readiness: .needsModel), "VocaMac, needs a speech model")
        XCTAssertEqual(
            MenuBarAccessibility.label(status: .idle, readiness: .preparingModel),
            "VocaMac, preparing speech model"
        )
        XCTAssertEqual(
            MenuBarAccessibility.label(status: .idle, readiness: .ready(preparingAnother: false), isAutoPaused: true),
            "VocaMac, paused"
        )
    }
}

// MARK: - Announcements

final class DictationAnnouncementTests: XCTestCase {

    func testStartIsAnnouncedOnlyOnceTheMicrophoneIsLive() {
        // The status turns to `.recording` while a Bluetooth input may still
        // be connecting, so that change says nothing.
        XCTAssertNil(DictationAnnouncement.message(from: .idle, to: .recording, isCommandMode: false))
        XCTAssertNil(DictationAnnouncement.message(from: .error, to: .recording, isCommandMode: false))
        XCTAssertEqual(DictationAnnouncement.recordingStarted(isCommandMode: false), "Recording")
        XCTAssertEqual(DictationAnnouncement.recordingStarted(isCommandMode: true), "Command Mode listening")
    }

    func testStopIsAnnounced() {
        XCTAssertEqual(
            DictationAnnouncement.message(from: .recording, to: .processing, isCommandMode: false),
            "Recording stopped, transcribing"
        )
        XCTAssertEqual(DictationAnnouncement.message(from: .recording, to: .idle, isCommandMode: false), "Recording stopped")
    }

    func testDeliveryAndUnchangedStatusesStayQuiet() {
        XCTAssertNil(DictationAnnouncement.message(from: .processing, to: .idle, isCommandMode: false))
        XCTAssertNil(DictationAnnouncement.message(from: .recording, to: .recording, isCommandMode: false))
        // Errors are announced with their own message.
        XCTAssertNil(DictationAnnouncement.message(from: .processing, to: .error, isCommandMode: false))
    }
}

// MARK: - Overlay

final class OverlayInteractionTests: XCTestCase {

    func testOnlyAnActiveDictationTakesClicks() {
        XCTAssertTrue(OverlayInteraction.acceptsClicks(in: .connecting))
        XCTAssertTrue(OverlayInteraction.acceptsClicks(in: .recording))
        XCTAssertTrue(OverlayInteraction.acceptsClicks(in: .processing))
        XCTAssertFalse(OverlayInteraction.acceptsClicks(in: .failure))
        XCTAssertFalse(OverlayInteraction.acceptsClicks(in: .idle))
    }

    func testFailuresStayLongEnoughToRead() {
        XCTAssertEqual(OverlayInteraction.failureDisplayDuration(for: "Didn't catch that."), 4)
        let long = String(repeating: "word ", count: 40)
        XCTAssertEqual(OverlayInteraction.failureDisplayDuration(for: long), 8)
        let medium = "The app changed. Your text is saved in the menu bar."
        XCTAssertGreaterThan(OverlayInteraction.failureDisplayDuration(for: medium), 4)
    }
}

// MARK: - Cleanup Levels

final class CleanupLevelDisplayTests: XCTestCase {

    func testGrammarSitsBetweenMediumAndHigh() {
        XCTAssertEqual(CleanupLevel.displayOrder, [.none, .light, .medium, .grammar, .high])
        XCTAssertEqual(Set(CleanupLevel.displayOrder), Set(CleanupLevel.allCases))
        XCTAssertEqual(CleanupLevel.displayOrder.count, CleanupLevel.allCases.count)
        // Stored values are unchanged.
        XCTAssertEqual(CleanupLevel.grammar.rawValue, "grammar")
    }

    func testOffExplanationMatchesWhatTheRulesStillDo() {
        XCTAssertTrue(CleanupLevel.medium.withoutSmartCleanup.contains("“Um”"))
        XCTAssertTrue(CleanupLevel.high.withoutSmartCleanup.contains("“Um”"))
        XCTAssertFalse(CleanupLevel.light.withoutSmartCleanup.contains("“Um”"))
        XCTAssertFalse(CleanupLevel.none.withoutSmartCleanup.contains("“Um”"))
        for level in CleanupLevel.allCases {
            // Formatting lives on the Styles page in v3.
            XCTAssertTrue(level.withoutSmartCleanup.contains("Styles"))
            XCTAssertFalse(level.withoutSmartCleanup.contains("Formatting"))
        }
    }
}

// MARK: - Pipeline Stage

@MainActor
final class CleanupStageTests: XCTestCase {

    private func options(cleanupEnabled: Bool) -> DictationOutputOptions {
        DictationOutputOptions(
            profile: WritingProfile(format: .plain, rules: .passthrough), snippetList: [],
            cleanupEnabled: cleanupEnabled, rewritingEnabled: false,
            model: .qwen25_0_5b_q4_k_m, customPrompt: "", cleanupLevel: .medium, language: "en",
            autoCapitalize: true, trailingSpace: false, skipWhenClean: true
        )
    }

    func testThePipelineSaysWhenTheModelIsAsked() async {
        let cleaner = MockTranscriptCleanup()
        cleaner.cleanHandler = { _ in "It was really late." }
        var calls = 0
        let pipeline = DictationOutputPipeline(
            cleaner: cleaner, snippets: SnippetExpander(), onModelCleanup: { calls += 1 }
        )

        _ = await pipeline.process("It was like really late.", options: options(cleanupEnabled: true))

        XCTAssertEqual(calls, 1)
    }

    func testNoCleanupStageWithoutTheModel() async {
        let cleaner = MockTranscriptCleanup()
        var calls = 0
        let pipeline = DictationOutputPipeline(
            cleaner: cleaner, snippets: SnippetExpander(), onModelCleanup: { calls += 1 }
        )

        _ = await pipeline.process("It was like really late.", options: options(cleanupEnabled: false))
        // Already clean: skipped, so there is no cleanup to show.
        _ = await pipeline.process("The build passed, and I will merge it.", options: options(cleanupEnabled: true))

        XCTAssertEqual(calls, 0)
    }
}

// MARK: - AppState

@MainActor
final class AppStateDictationFeedbackTests: XCTestCase {

    func testAFailedStartKeepsItsFixInTheMenu() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.permissionManager.micPermission = .denied

        await appState.startRecording()

        XCTAssertEqual(appState.appStatus, .error)
        XCTAssertEqual(appState.errorNotice?.action, .openMicrophonePrivacy)
        XCTAssertEqual(mocks.cursorOverlay.failureMessages, ["Microphone access is off."])

        // The status clears itself; the notice stays until dismissed.
        appState.appStatus = .idle
        appState.errorMessage = nil
        XCTAssertNotNil(appState.errorNotice)

        appState.dismissErrorNotice()
        XCTAssertNil(appState.errorNotice)
    }

    func testDismissClearsAnErrorStatus() {
        let (appState, _) = AppState.makeTestState()
        appState.errorMessage = "Something broke."
        appState.appStatus = .error
        XCTAssertEqual(appState.errorNotice?.message, "Something broke.")

        appState.dismissErrorNotice()

        XCTAssertEqual(appState.appStatus, .idle)
        XCTAssertNil(appState.errorMessage)
        XCTAssertNil(appState.errorNotice)
    }

    func testTheNextDictationClearsTheNotice() async {
        let (appState, _) = AppState.makeTestState()
        appState.errorMessage = "Something broke."
        appState.appStatus = .error
        XCTAssertNotNil(appState.errorNotice)

        await appState.startRecording()

        XCTAssertEqual(appState.appStatus, .recording)
        XCTAssertNil(appState.errorNotice)
        await appState.cancelRecording()
    }

    func testAFixActionClosesTheNotice() {
        let (appState, _) = AppState.makeTestState()
        appState.errorMessage = "Could not load the speech model. Open Settings → Speech Model and try again."
        appState.appStatus = .error
        var opened: SettingsPage?

        appState.performErrorFix(.openSettings(.speechModel)) { opened = $0 }

        XCTAssertEqual(opened, .speechModel)
        XCTAssertNil(appState.errorNotice)
        XCTAssertEqual(appState.appStatus, .idle)
    }

    func testCleanupStageOnlyFollowsADictationBeingProcessed() {
        let (appState, mocks) = AppState.makeTestState()

        appState.dictationReachedCleanup()
        XCTAssertFalse(appState.isCleaningUp, "A Settings preview isn't a dictation")

        appState.appStatus = .processing
        appState.dictationReachedCleanup()
        XCTAssertTrue(appState.isCleaningUp)
        XCTAssertEqual(appState.processingStatusText, "Cleaning up…")
        XCTAssertEqual(mocks.cursorOverlay.cleaningUpCallCount, 1)

        appState.appStatus = .idle
        XCTAssertFalse(appState.isCleaningUp)
        XCTAssertEqual(appState.processingStatusText, "Transcribing…")
    }

    func testASettingsCleanupRunLeavesTheDictationStageAlone() async {
        // A cleanup try or preview can run while a dictation is still
        // transcribing; it must not move that dictation to "Cleaning up…".
        let cleanup = MockTranscriptCleanup()
        cleanup.cleanHandler = { _ in "Hello." }
        let (appState, mocks) = AppState.makeTestState(transcriptCleanup: cleanup)
        appState.transcriptCleanupEnabled = true
        appState.appStatus = .processing

        _ = await appState.tryCleanup("so um hello", prompt: TranscriptCleanup.defaultPrompt)
        _ = await appState.previewWritingProfile("so um hello")

        XCTAssertEqual(cleanup.previewCallCount, 2, "Both runs reached the model")
        XCTAssertFalse(appState.isCleaningUp)
        XCTAssertEqual(appState.processingStatusText, "Transcribing…")
        XCTAssertEqual(mocks.cursorOverlay.cleaningUpCallCount, 0)
    }

    func testTheOverlayCancelButtonCancelsTheRecording() async throws {
        let (appState, mocks) = AppState.makeTestState()
        await appState.startRecording()
        XCTAssertTrue(appState.isRecording)
        XCTAssertTrue(appState.canCancelDictation)
        let cancel = try XCTUnwrap(mocks.cursorOverlay.cancelAction)

        cancel()
        for _ in 0..<200 where appState.isRecording {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertFalse(appState.isRecording)
        XCTAssertEqual(appState.appStatus, .idle)
        XCTAssertFalse(appState.canCancelDictation)
    }

    func testTheOverlayLearnsWhetherEscapeCancels() async {
        let (appState, mocks) = AppState.makeTestState()
        let original = appState.escapeCancelsDictation
        defer { appState.escapeCancelsDictation = original }
        appState.escapeCancelsDictation = false

        await appState.startRecording()

        XCTAssertEqual(mocks.cursorOverlay.escapeHintVisible, false)
        await appState.cancelRecording()
    }
}

// MARK: - Overlay Stop Hint

@MainActor
final class OverlayStopHintStateTests: XCTestCase {

    func testHintFollowsTheActivationModeAndKey() {
        let (state, _) = AppState.makeTestState()
        let savedMode = state.activationMode
        let savedKey = state.hotKeyCode
        let savedModifiers = state.hotKeyModifiers
        defer {
            state.activationMode = savedMode
            state.hotKeyCode = savedKey
            state.hotKeyModifiers = savedModifiers
        }
        state.hotKeyCode = 61
        state.hotKeyModifiers = []
        state.dictationTrigger = .dictationKey
        defer { state.dictationTrigger = .other }

        state.activationMode = .pushToTalk
        XCTAssertEqual(state.overlayStopHint, .hold(key: "Right ⌥"))

        state.activationMode = .doubleTapToggle
        XCTAssertEqual(state.overlayStopHint, .doubleTap(key: "Right ⌥"))
        XCTAssertTrue(state.overlayStopHint.isHandsFree)
    }

    /// A deep link in push to talk has no key to let go of: pressing the
    /// dictation key types it. The mouse button is named as itself.
    func testHintFollowsHowTheDictationStarted() async {
        let (state, mocks) = AppState.makeTestState()
        let saved = (state.activationMode, state.hotKeyCode, state.hotKeyModifiers, state.showCursorIndicator, state.overlayStyle)
        defer {
            state.activationMode = saved.0
            state.hotKeyCode = saved.1
            state.hotKeyModifiers = saved.2
            state.showCursorIndicator = saved.3
            state.overlayStyle = saved.4
        }
        state.activationMode = .pushToTalk
        state.hotKeyCode = 61
        state.hotKeyModifiers = []
        state.showCursorIndicator = true
        state.overlayStyle = .minimal

        await state.handleDeepLink(.startDictation)
        XCTAssertTrue(state.isRecording)
        XCTAssertEqual(mocks.cursorOverlay.stopHint, .press(key: "Right ⌥"))
        XCTAssertEqual(mocks.cursorOverlay.stopHint?.instruction, "Press Right ⌥ to type")
        XCTAssertEqual(mocks.cursorOverlay.stopHint?.isHandsFree, true)
        await state.cancelRecording()

        mocks.hotKeyManager.lastStartWasMouseButton = true
        await state.startRecordingFromActivationShortcut()
        XCTAssertEqual(mocks.cursorOverlay.stopHint, .hold(key: "the mouse button"))
        XCTAssertEqual(state.dictationTrigger, .other, "the trigger only lasts for its start")
        await state.cancelRecording()

        mocks.hotKeyManager.lastStartWasMouseButton = false
        await state.startRecordingFromActivationShortcut()
        XCTAssertEqual(mocks.cursorOverlay.stopHint, .hold(key: "Right ⌥"))
        await state.cancelRecording()
    }
}
