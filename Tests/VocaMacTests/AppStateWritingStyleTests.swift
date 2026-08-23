// AppStateWritingStyleTests.swift
// VocaMac
//
// Writing styles as wired into the dictation pipeline: which app is resolved,
// which style is applied, and what Test Dictation does instead.

import XCTest
@testable import VocaMac

@MainActor
final class AppStateWritingStyleTests: XCTestCase {

    private let cursor = RunningAppSnapshot(
        displayName: "Cursor",
        bundleIdentifier: "com.todesktop.230313mzl4w4u92",
        processName: "Cursor"
    )

    private func clearPreferences() {
        for key in [
            PreferenceKey.writingStyleEnabled,
            PreferenceKey.writingStyleDefault,
            PreferenceKey.writingStyleBindings,
            PreferenceKey.writingStyleCatalogSeeded,
            PreferenceKey.appendTrailingSpace,
            PreferenceKey.autoCapitalize
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func setUp() {
        super.setUp()
        clearPreferences()
    }

    override func tearDown() {
        clearPreferences()
        super.tearDown()
    }

    /// Drive one full dictation with a fixed transcript.
    private func dictate(
        _ transcript: String,
        on appState: AppState,
        mocks: TestMocks,
        injectResult: Bool = true
    ) async {
        mocks.audioEngine.stopRecordingResult = Array(repeating: Float(0.1), count: 16_000)
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: transcript,
            duration: 1.0,
            detectedLanguage: "en",
            audioLengthSeconds: 1.0,
            modelUsed: .tiny
        )
        appState.isRecording = true
        appState.appStatus = .recording
        await appState.stopRecordingAndTranscribe(injectResult: injectResult)
    }

    // MARK: - Resolution drives injection

    func testBoundAppGetsItsStyle() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.appendTrailingSpace = false
        appState.autoCapitalize = true
        appState.writingStyleEnabled = true
        appState.writingStyleBindings = [
            AppStyleBinding.from(snapshot: cursor, style: .code)
        ]
        mocks.frontmostAppResolver.frontmostApp = cursor

        await dictate("open config dot json", on: appState, mocks: mocks)

        XCTAssertEqual(mocks.textInjector.lastInjectedText, "open config.json")
        XCTAssertEqual(appState.activeWritingStyle.style, .code)
        XCTAssertEqual(appState.activeWritingStyle.matchedAppName, "Cursor")
    }

    func testUnboundAppUsesDefaultStyle() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.appendTrailingSpace = false
        appState.autoCapitalize = true
        appState.writingStyleEnabled = true
        appState.writingStyleDefault = .email
        appState.writingStyleBindings = []
        mocks.frontmostAppResolver.frontmostApp = RunningAppSnapshot(
            displayName: "Unknown",
            bundleIdentifier: "com.unknown.app"
        )

        await dictate("thanks for the update", on: appState, mocks: mocks)

        XCTAssertEqual(mocks.textInjector.lastInjectedText, "Thanks for the update.")
        XCTAssertEqual(appState.activeWritingStyle.style, .email)
    }

    func testDisabledFeatureLeavesTodaysBehavior() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.appendTrailingSpace = false
        appState.autoCapitalize = true
        appState.writingStyleEnabled = false
        appState.writingStyleBindings = [
            AppStyleBinding.from(snapshot: cursor, style: .code)
        ]
        mocks.frontmostAppResolver.frontmostApp = cursor

        await dictate("open config dot json", on: appState, mocks: mocks)

        XCTAssertEqual(mocks.textInjector.lastInjectedText, "Open config dot json")
    }

    func testNoFrontmostAppFallsBackToDefaultStyle() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.appendTrailingSpace = false
        appState.autoCapitalize = false
        appState.writingStyleEnabled = true
        appState.writingStyleDefault = .terminal
        mocks.frontmostAppResolver.frontmostApp = nil

        await dictate("git status.", on: appState, mocks: mocks)

        XCTAssertEqual(mocks.textInjector.lastInjectedText, "git status")
    }

    func testFrontmostAppIsResolvedAtInjectionTime() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.appendTrailingSpace = false
        appState.autoCapitalize = false
        appState.writingStyleEnabled = true
        appState.writingStyleBindings = [
            AppStyleBinding.from(snapshot: cursor, style: .code)
        ]
        mocks.frontmostAppResolver.frontmostApp = cursor

        await dictate("run the tests.", on: appState, mocks: mocks)

        XCTAssertGreaterThan(
            mocks.frontmostAppResolver.callCount, 0,
            "the target app must be read when the text is injected"
        )
        XCTAssertEqual(mocks.textInjector.lastInjectedText, "run the tests")
    }

    /// Writing styles live between the router and the injector, so the engine
    /// that produced a transcript must not change how it is formatted. Pinned
    /// because "styles only work on Whisper" is an easy conclusion to draw:
    /// Whisper normalizes spoken symbols itself, so it has less left to do.
    func testFormattingIsIndependentOfTheEngineThatProducedTheText() async {
        let transcript = "open config dot json"
        var injected: [String] = []

        for engine in [ModelSize.tiny, .parakeetV3, .appleSpeech] {
            let (appState, mocks) = AppState.makeTestState()
            appState.appendTrailingSpace = false
            appState.autoCapitalize = true
            appState.writingStyleEnabled = true
            appState.writingStyleBindings = [AppStyleBinding.from(snapshot: cursor, style: .code)]
            mocks.frontmostAppResolver.frontmostApp = cursor

            mocks.audioEngine.stopRecordingResult = Array(repeating: Float(0.1), count: 16_000)
            mocks.whisperService.mockTranscriptionResult = VocaTranscription(
                text: transcript,
                duration: 1.0,
                detectedLanguage: "en",
                audioLengthSeconds: 1.0,
                modelUsed: engine
            )
            appState.isRecording = true
            appState.appStatus = .recording
            await appState.stopRecordingAndTranscribe()

            injected.append(mocks.textInjector.lastInjectedText ?? "")
        }

        XCTAssertEqual(injected, Array(repeating: "open config.json", count: 3))
    }

    // MARK: - Test Dictation

    func testTestDictationUsesThePreviewStyleAndDoesNotInject() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.appendTrailingSpace = false
        appState.autoCapitalize = true
        appState.writingStyleEnabled = true
        appState.settingsPreviewStyle = .email
        mocks.frontmostAppResolver.frontmostApp = cursor

        await dictate("thanks for the update", on: appState, mocks: mocks, injectResult: false)

        XCTAssertEqual(mocks.textInjector.injectCallCount, 0)
        XCTAssertEqual(appState.settingsTestResultText, "Thanks for the update.")
    }

    // MARK: - Binding management

    func testBindFrontmostAppReplacesAnExistingRule() {
        let (appState, mocks) = AppState.makeTestState()
        mocks.frontmostAppResolver.frontmostApp = cursor
        appState.writingStyleBindings = [AppStyleBinding.from(snapshot: cursor, style: .chat)]

        let name = appState.bindFrontmostApp(to: .code)

        XCTAssertEqual(name, "Cursor")
        XCTAssertEqual(appState.writingStyleBindings.count, 1)
        XCTAssertEqual(appState.writingStyleBindings.first?.style, .code)
    }

    func testBindFrontmostAppWithNoFrontmostAppIsANoOp() {
        let (appState, mocks) = AppState.makeTestState()
        mocks.frontmostAppResolver.frontmostApp = nil

        XCTAssertNil(appState.bindFrontmostApp(to: .code))
        XCTAssertTrue(appState.writingStyleBindings.isEmpty)
    }

    func testBindingsSurviveAnEncodeDecodeCycleThroughDefaults() {
        let (appState, _) = AppState.makeTestState()
        appState.writingStyleBindings = [
            AppStyleBinding.from(snapshot: cursor, style: .code)
        ]

        XCTAssertEqual(appState.writingStyleBindings.count, 1)
        XCTAssertEqual(appState.writingStyleBindings.first?.displayName, "Cursor")
        XCTAssertEqual(appState.writingStyleBindings.first?.style, .code)
    }

    func testCorruptBindingsDecodeToEmptyRatherThanFailing() {
        let (appState, _) = AppState.makeTestState()
        appState.writingStyleBindingsJSON = "{ this is not json"

        XCTAssertTrue(appState.writingStyleBindings.isEmpty)
    }

    func testAddSuggestedStylesDoesNotDuplicate() {
        let (appState, _) = AppState.makeTestState()
        let first = appState.addSuggestedWritingStyles()
        let second = appState.addSuggestedWritingStyles()

        XCTAssertGreaterThanOrEqual(first, 0)
        XCTAssertEqual(second, 0, "re-running suggestions must not add duplicates")
    }

    func testApplyWritingStyleSeedMergesWithoutClobbering() {
        let (appState, _) = AppState.makeTestState()
        appState.writingStyleBindings = [
            AppStyleBinding(id: "com.apple.Terminal", displayName: "Terminal", bundleIdentifier: "com.apple.Terminal", style: .chat)
        ]

        appState.applyWritingStyleSeed(WritingStyleCatalog.terminals)

        XCTAssertEqual(
            appState.writingStyleBindings.first { $0.id == "com.apple.Terminal" }?.style,
            .chat,
            "an existing user rule must not be overwritten by the seed"
        )
        XCTAssertTrue(appState.writingStyleBindings.contains { $0.displayName == "Ghostty" })
    }

    func testApplyWritingStyleSeedWithNoSuggestionsIsANoOp() {
        let (appState, _) = AppState.makeTestState()
        appState.applyWritingStyleSeed([])
        XCTAssertTrue(appState.writingStyleBindings.isEmpty)
    }

    // MARK: - Preview

    func testPreviewUsesTheSameEngineAsThePipeline() {
        let (appState, _) = AppState.makeTestState()
        appState.autoCapitalize = true
        appState.appendTrailingSpace = false

        XCTAssertEqual(appState.writingStylePreview("open config dot json", style: .code), "open config.json")
        XCTAssertEqual(appState.writingStylePreview("thanks", style: .email), "Thanks.")
    }

    func testRefreshActiveWritingStyleReadsTheFrontmostApp() {
        let (appState, mocks) = AppState.makeTestState()
        appState.writingStyleEnabled = true
        appState.writingStyleBindings = [AppStyleBinding.from(snapshot: cursor, style: .code)]
        mocks.frontmostAppResolver.frontmostApp = cursor

        appState.refreshActiveWritingStyle()

        XCTAssertEqual(appState.activeWritingStyle.style, .code)
        XCTAssertEqual(appState.activeWritingStyle.matchedAppName, "Cursor")
    }
}
