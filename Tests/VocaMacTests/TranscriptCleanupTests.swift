// TranscriptCleanupTests.swift
// VocaMac
//
// Pure cleanup prompt/sanitizer tests plus AppState injection wiring.

import XCTest
@testable import VocaMac

final class TranscriptCleanupTests: XCTestCase {

    func testSanitizeStripsThinkBlocks() {
        let raw = "<think>planning</think>\nHello there"
        XCTAssertEqual(TranscriptCleanup.sanitize(raw), "Hello there")
    }

    func testSanitizeStripsUserInputTags() {
        let raw = "<USER-INPUT>Hello there</USER-INPUT>"
        XCTAssertEqual(TranscriptCleanup.sanitize(raw), "Hello there")
    }

    func testEmptyAndEllipsisAreRejected() {
        XCTAssertFalse(TranscriptCleanup.isUsable("", original: "hello"))
        XCTAssertFalse(TranscriptCleanup.isUsable("...", original: "hello"))
        XCTAssertFalse(TranscriptCleanup.isUsable("   ", original: "hello"))
    }

    func testChatbotRefusalIsRejected() {
        XCTAssertFalse(TranscriptCleanup.isUsable("How can I help you today?", original: "hello"))
        XCTAssertFalse(TranscriptCleanup.isUsable("As an AI I cannot do that", original: "hello"))
    }

    func testHugeExpansionIsRejected() {
        let original = "hello"
        let inflated = String(repeating: "hello world ", count: 80)
        XCTAssertFalse(TranscriptCleanup.isUsable(inflated, original: original))
    }

    func testNormalRewriteIsAccepted() {
        let original = "so um like the meeting is at 3pm you know"
        let cleaned = "The meeting is at 3pm"
        XCTAssertEqual(TranscriptCleanup.acceptedOutput(cleaned, original: original), cleaned)
    }

    func testFormatInputWrapsUserText() {
        let formatted = TranscriptCleanup.formatInput("hello")
        XCTAssertTrue(formatted.contains("<USER-INPUT>"))
        XCTAssertTrue(formatted.contains("hello"))
        XCTAssertTrue(formatted.contains("</USER-INPUT>"))
    }

    func testDefaultPromptForbidsChatbotBehavior() {
        XCTAssertTrue(TranscriptCleanup.defaultPrompt.contains("NOT a chatbot"))
        XCTAssertTrue(TranscriptCleanup.defaultPrompt.contains("scratch that"))
    }
}

final class CleanupModelTests: XCTestCase {

    func testResolvedUnknownIdFallsBackToDefault() {
        XCTAssertEqual(CleanupModelKind.resolved(stored: nil), .qwen35_0_8b_q4_k_m)
        XCTAssertEqual(CleanupModelKind.resolved(stored: ""), .qwen35_0_8b_q4_k_m)
        XCTAssertEqual(CleanupModelKind.resolved(stored: "nope"), .qwen35_0_8b_q4_k_m)
        XCTAssertEqual(CleanupModelKind.resolved(stored: "qwen3_0_6b_q4_k_m"), .qwen3_0_6b_q4_k_m)
    }

    @MainActor
    func testServiceReportsMissingFilesAsNotDownloaded() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let service = TranscriptCleanupService(modelsDirectory: directory)
        XCTAssertFalse(service.isDownloaded(.qwen35_0_8b_q4_k_m))
        XCTAssertEqual(service.modelState, .idle)
    }

    func testCatalogCoversEveryKind() {
        for kind in CleanupModelKind.allCases {
            let descriptor = kind.descriptor
            XCTAssertEqual(descriptor.kind, kind)
            XCTAssertFalse(descriptor.displayName.isEmpty)
            XCTAssertFalse(descriptor.expectedSHA256.isEmpty)
            XCTAssertGreaterThan(descriptor.expectedByteCount, 0)
            XCTAssertNotNil(descriptor.url.scheme)
        }
        XCTAssertEqual(CleanupModelCatalog.all.count, CleanupModelKind.allCases.count)
    }
}

@MainActor
final class AppStateTranscriptCleanupTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PreferenceKey.transcriptCleanupEnabled)
        UserDefaults.standard.removeObject(forKey: PreferenceKey.transcriptCleanupModel)
        UserDefaults.standard.removeObject(forKey: PreferenceKey.transcriptCleanupPrompt)
        super.tearDown()
    }

    func testCleanupIsOffByDefaultAndDoesNotRun() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.audioEngine.stopRecordingResult = Array(repeating: Float(0.1), count: 16_000)
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "so um hello",
            duration: 1.0,
            detectedLanguage: "en",
            audioLengthSeconds: 1.0,
            modelUsed: .tiny
        )
        mocks.transcriptCleanup.cleanHandler = { _ in "should not run" }
        appState.appendTrailingSpace = false
        appState.autoCapitalize = true
        appState.isRecording = true
        appState.appStatus = .recording

        await appState.stopRecordingAndTranscribe()

        XCTAssertFalse(appState.transcriptCleanupEnabled)
        XCTAssertEqual(mocks.transcriptCleanup.cleanCallCount, 0)
        XCTAssertEqual(mocks.textInjector.lastInjectedText, "So um hello")
    }

    func testEnabledCleanupRewritesBeforePolish() async {
        let (appState, mocks) = AppState.makeTestState()
        mocks.audioEngine.stopRecordingResult = Array(repeating: Float(0.1), count: 16_000)
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "so um hello world",
            duration: 1.0,
            detectedLanguage: "en",
            audioLengthSeconds: 1.0,
            modelUsed: .tiny
        )
        mocks.transcriptCleanup.cleanHandler = { _ in "hello world" }
        appState.transcriptCleanupEnabled = true
        appState.appendTrailingSpace = true
        appState.autoCapitalize = true
        appState.isRecording = true
        appState.appStatus = .recording

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.transcriptCleanup.cleanCallCount, 1)
        XCTAssertEqual(mocks.transcriptCleanup.lastCleanedText, "so um hello world")
        XCTAssertEqual(mocks.textInjector.lastInjectedText, "Hello world ")
    }

    func testCleanupDoesNotRunWhenModelIsMissing() async {
        let cleanup = MockTranscriptCleanup()
        cleanup.downloadedKinds = []
        let (appState, mocks) = AppState.makeTestState(transcriptCleanup: cleanup)
        mocks.audioEngine.stopRecordingResult = Array(repeating: Float(0.1), count: 16_000)
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "hello",
            duration: 1.0,
            detectedLanguage: "en",
            audioLengthSeconds: 1.0,
            modelUsed: .tiny
        )
        cleanup.cleanHandler = { _ in "nope" }
        appState.transcriptCleanupEnabled = true
        appState.appendTrailingSpace = false
        appState.autoCapitalize = true
        appState.isRecording = true
        appState.appStatus = .recording

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(cleanup.cleanCallCount, 0)
        XCTAssertEqual(mocks.textInjector.lastInjectedText, "Hello")
    }

    func testEffectivePromptFallsBackToDefault() {
        let (appState, _) = AppState.makeTestState()
        XCTAssertEqual(appState.effectiveCleanupPrompt, TranscriptCleanup.defaultPrompt)
        appState.transcriptCleanupPrompt = "  custom rules  "
        XCTAssertEqual(appState.effectiveCleanupPrompt, "custom rules")
    }
}
