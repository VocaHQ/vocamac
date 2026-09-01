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

    // MARK: - Nothing is configured without being asked

    /// Writing styles ship inert: default style Plain, no app rules, so an
    /// upgrade cannot change the shape of an existing user's dictation.
    ///
    /// Startup here runs with `skipSystemIntegration`, so this cannot catch a
    /// seed call reintroduced *inside* that guard — the guarantee that no such
    /// call site exists is enforced by the doc comment on
    /// `seedWritingStyleCatalogIfNeeded()`. What it does catch is a seed that
    /// ignores the guard, and the defaults being anything but inert.
    func testStartupLeavesTheFeatureInert() async {
        let (appState, _) = AppState.makeTestState()
        XCTAssertEqual(appState.writingStyleDefault, .plain)
        XCTAssertTrue(appState.writingStyleBindings.isEmpty)

        await appState.performStartup()

        XCTAssertTrue(
            appState.writingStyleBindings.isEmpty,
            "launch must not create app rules; seeding is an explicit action in Settings"
        )
        XCTAssertFalse(
            UserDefaults.standard.bool(forKey: PreferenceKey.writingStyleCatalogSeeded),
            "no seed lifecycle should have run at launch"
        )
    }

    /// The seed still works — it just has to be asked for.
    func testSuggestionsAreAddedOnRequest() {
        let (appState, _) = AppState.makeTestState()
        appState.applyWritingStyleSeed(WritingStyleCatalog.terminals)
        XCTAssertFalse(appState.writingStyleBindings.isEmpty)
    }

    // MARK: - The master toggle really reverts everything

    /// With the feature off, output must match the pre-writing-styles pipeline
    /// byte for byte — including its capitalization, which the style-aware
    /// pass would otherwise quietly improve.
    func testDisabledStylesReproduceTheOldPipeline() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.writingStyleEnabled = false
        appState.autoCapitalize = true
        appState.appendTrailingSpace = false
        mocks.frontmostAppResolver.frontmostApp = cursor

        let transcript = "readme.md was updated"
        await dictate(transcript, on: appState, mocks: mocks)

        XCTAssertEqual(
            mocks.textInjector.lastInjectedText,
            DictationOutputFormatter.apply(
                transcript,
                autoCapitalize: true,
                appendTrailingSpace: false
            )
        )
        XCTAssertEqual(mocks.textInjector.lastInjectedText, "Readme.md was updated")
    }

    /// Plain makes the same promise as the master toggle and must keep it.
    func testPlainStyleReproducesTheOldPipeline() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.writingStyleEnabled = true
        appState.writingStyleDefault = .plain
        appState.autoCapitalize = true
        appState.appendTrailingSpace = false
        mocks.frontmostAppResolver.frontmostApp = cursor

        await dictate("readme.md was updated", on: appState, mocks: mocks)

        XCTAssertEqual(mocks.textInjector.lastInjectedText, "Readme.md was updated")
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
        let fixtures: [(model: ModelSize, transcript: String)] = [
            (.tiny, "open config.json"),
            (.parakeetV3, "open config dot json"),
            (.appleSpeech, "open config dotjson"),
            (.moonshineTiny, "open config dot json")
        ]
        var injected: [String] = []

        for fixture in fixtures {
            let (appState, mocks) = AppState.makeTestState()
            appState.appendTrailingSpace = false
            appState.autoCapitalize = true
            appState.writingStyleEnabled = true
            appState.writingStyleBindings = [AppStyleBinding.from(snapshot: cursor, style: .code)]
            mocks.frontmostAppResolver.frontmostApp = cursor

            mocks.audioEngine.stopRecordingResult = Array(repeating: Float(0.1), count: 16_000)
            mocks.whisperService.mockTranscriptionResult = VocaTranscription(
                text: fixture.transcript,
                duration: 1.0,
                detectedLanguage: "en",
                audioLengthSeconds: 1.0,
                modelUsed: fixture.model
            )
            appState.isRecording = true
            appState.appStatus = .recording
            await appState.stopRecordingAndTranscribe()

            injected.append(mocks.textInjector.lastInjectedText ?? "")
        }

        XCTAssertEqual(injected, Array(repeating: "open config.json", count: fixtures.count))
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

    func testCompletingWritingStyleSeedMarksCatalogAfterMerging() {
        let (appState, _) = AppState.makeTestState()
        let revision = appState.writingStyleBindingsRevision
        let json = appState.writingStyleBindingsJSON

        appState.completeWritingStyleCatalogSeed(
            [WritingStyleCatalog.terminals[0]],
            bindingsRevisionAtStart: revision,
            bindingsJSONAtStart: json
        )

        XCTAssertEqual(appState.writingStyleBindings.count, 1)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: PreferenceKey.writingStyleCatalogSeeded))
    }

    func testBeginningWritingStyleSeedDoesNotPersistCompletionEarly() {
        let (appState, _) = AppState.makeTestState()

        let context = appState.beginWritingStyleCatalogSeedIfNeeded()

        XCTAssertNotNil(context)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: PreferenceKey.writingStyleCatalogSeeded))
        XCTAssertNil(appState.beginWritingStyleCatalogSeedIfNeeded(), "an in-flight lookup must not start twice")
    }

    func testDelayedWritingStyleSeedDoesNotUndoRemoveAll() {
        let (appState, _) = AppState.makeTestState()
        appState.writingStyleBindings = [
            AppStyleBinding.from(snapshot: cursor, style: .code)
        ]
        let revision = appState.writingStyleBindingsRevision
        let json = appState.writingStyleBindingsJSON

        appState.removeAllWritingStyleBindings()
        appState.completeWritingStyleCatalogSeed(
            WritingStyleCatalog.terminals,
            bindingsRevisionAtStart: revision,
            bindingsJSONAtStart: json
        )

        XCTAssertTrue(appState.writingStyleBindings.isEmpty)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: PreferenceKey.writingStyleCatalogSeeded))
    }

    // MARK: - Preview

    func testPreviewUsesTheSameEngineAsThePipeline() {
        let (appState, _) = AppState.makeTestState()
        appState.autoCapitalize = true
        appState.appendTrailingSpace = false

        XCTAssertEqual(appState.writingStylePreview("open config dot json", style: .code), "open config.json")
        XCTAssertEqual(appState.writingStylePreview("thanks", style: .email), "Thanks.")
    }

    // MARK: - VocaMac's own window has focus

    func testStyleFallsBackToTheLastActiveAppWhenVocaMacIsInFront() {
        // Opening the menu bar popover activates VocaMac, so the frontmost app
        // is VocaMac and `currentFrontmostApp()` returns nil. The style row is
        // asking about the app the user came from.
        let (appState, mocks) = AppState.makeTestState()
        appState.writingStyleEnabled = true
        appState.writingStyleBindings = [AppStyleBinding.from(snapshot: cursor, style: .code)]
        mocks.frontmostAppResolver.frontmostApp = nil
        mocks.frontmostAppResolver.previousApp = cursor

        appState.refreshActiveWritingStyle()

        XCTAssertEqual(appState.activeWritingStyle.style, .code)
        XCTAssertEqual(appState.activeWritingStyle.matchedAppName, "Cursor")
    }

    func testBindFrontmostAppUsesTheLastActiveAppWhenVocaMacIsInFront() {
        let (appState, mocks) = AppState.makeTestState()
        mocks.frontmostAppResolver.frontmostApp = nil
        mocks.frontmostAppResolver.previousApp = cursor

        XCTAssertEqual(appState.bindFrontmostApp(to: .code), "Cursor")
        XCTAssertEqual(appState.writingStyleBindings.first?.style, .code)
    }

    func testInjectionFallsBackToTheLastActiveApp() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.appendTrailingSpace = false
        appState.writingStyleEnabled = true
        appState.writingStyleBindings = [AppStyleBinding.from(snapshot: cursor, style: .code)]
        mocks.frontmostAppResolver.frontmostApp = nil
        mocks.frontmostAppResolver.previousApp = cursor

        await dictate("open config dot json", on: appState, mocks: mocks)

        XCTAssertEqual(mocks.textInjector.lastInjectedText, "open config.json")
    }

    // MARK: - Clearing a rule

    func testUnbindFrontmostAppRemovesTheRule() {
        let (appState, mocks) = AppState.makeTestState()
        mocks.frontmostAppResolver.frontmostApp = cursor
        appState.writingStyleBindings = [AppStyleBinding.from(snapshot: cursor, style: .code)]

        XCTAssertEqual(appState.unbindFrontmostApp(), "Cursor")
        XCTAssertTrue(appState.writingStyleBindings.isEmpty)
    }

    func testUnbindWithNoRuleIsHarmless() {
        let (appState, mocks) = AppState.makeTestState()
        mocks.frontmostAppResolver.frontmostApp = cursor

        XCTAssertEqual(appState.unbindFrontmostApp(), "Cursor")
        XCTAssertTrue(appState.writingStyleBindings.isEmpty)
    }

    func testRemoveAllBindings() {
        let (appState, _) = AppState.makeTestState()
        appState.writingStyleBindings = [
            AppStyleBinding.from(snapshot: cursor, style: .code),
            AppStyleBinding(id: "com.apple.Terminal", displayName: "Terminal", bundleIdentifier: "com.apple.Terminal", style: .terminal)
        ]

        appState.removeAllWritingStyleBindings()

        XCTAssertTrue(appState.writingStyleBindings.isEmpty)
    }

    // MARK: - Preview honors per-app overrides

    func testPreviewCanTargetASavedRuleWithOverrides() {
        let (appState, _) = AppState.makeTestState()
        appState.autoCapitalize = true
        appState.appendTrailingSpace = false

        var overrides = WritingStyle.code.defaultRules
        overrides.capitalization = .sentences
        var binding = AppStyleBinding.from(snapshot: cursor, style: .code)
        binding.ruleOverrides = overrides
        appState.writingStyleBindings = [binding]
        appState.settingsPreviewBindingID = binding.id

        XCTAssertEqual(
            appState.writingStylePreview("open config dot json", rules: appState.settingsPreviewRules),
            "Open config.json",
            "the preview must use the rule's overrides, not the bare preset"
        )
    }

    func testPreviewFallsBackToThePresetWhenTheRuleIsGone() {
        let (appState, _) = AppState.makeTestState()
        appState.settingsPreviewStyle = .email
        appState.settingsPreviewBindingID = "com.deleted.app"

        XCTAssertEqual(appState.settingsPreviewRules, WritingStyle.email.defaultRules)
    }

    func testTestDictationUsesTheSelectedRuleOverrides() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.appendTrailingSpace = false
        appState.autoCapitalize = true

        var overrides = WritingStyle.code.defaultRules
        overrides.capitalization = .sentences
        var binding = AppStyleBinding.from(snapshot: cursor, style: .code)
        binding.ruleOverrides = overrides
        appState.writingStyleBindings = [binding]
        appState.settingsPreviewBindingID = binding.id

        await dictate("open config dot json", on: appState, mocks: mocks, injectResult: false)

        XCTAssertEqual(appState.settingsTestResultText, "Open config.json")
    }

    // MARK: - Binding cache

    func testBindingsAreRereadWhenTheStoredJSONChangesUnderneath() {
        let (appState, _) = AppState.makeTestState()
        appState.writingStyleBindings = [AppStyleBinding.from(snapshot: cursor, style: .code)]
        XCTAssertEqual(appState.writingStyleBindings.count, 1)

        appState.writingStyleBindingsJSON = WritingStyleBindingStore(bindings: []).encodedJSON()

        XCTAssertTrue(appState.writingStyleBindings.isEmpty, "the cache must key off the stored JSON")
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
