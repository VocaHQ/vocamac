import XCTest
@testable import VocaMac

@MainActor
final class DictationOutputPipelineTests: XCTestCase {
    private func process(
        _ input: String, cleaner: MockTranscriptCleanup,
        format: WritingStyle = .plain, intent: WritingIntent = .preserve,
        cleanup: WritingCleanupPolicy = .inherit, enabled: Bool = true,
        experimental: Bool = true, snippets: [Snippet] = [], language: String? = "en"
    ) async -> DictationOutputResult {
        await DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander()).process(
            input, profile: WritingProfile(format: format, rules: format.defaultRules, intent: intent, cleanup: cleanup),
            snippetList: snippets, cleanupEnabled: enabled, rewritingEnabled: experimental,
            model: .defaultKind, customPrompt: "Custom cleanup instructions",
            language: language, autoCapitalize: true, trailingSpace: false
        )
    }

    func testRawBypassesEveryTransformation() async {
        let cleaner = MockTranscriptCleanup()
        let text = "  um config dot json.\n"
        let result = await process(text, cleaner: cleaner, format: .code, cleanup: .raw)
        XCTAssertEqual(result.text, text)
        XCTAssertEqual(cleaner.loadCallCount, 0)
        XCTAssertEqual(cleaner.cleanCallCount, 0)
    }

    func testTechnicalFormatsNeverRunModelEvenWithWordingEnabled() async {
        for format in [WritingStyle.code, .terminal] {
            let cleaner = MockTranscriptCleanup()
            let result = await process("open config dot json", cleaner: cleaner, format: format, intent: .professional)
            XCTAssertEqual(result.text, "open config.json")
            XCTAssertEqual(cleaner.cleanCallCount, 0)
        }
    }

    func testLiteralEscapeAtBeginningDoesNotBecomeAFilename() async {
        let result = await process("literally dot json", cleaner: MockTranscriptCleanup(), format: .notes)
        XCTAssertEqual(result.text, "Dot json")
    }

    func testOnePassComposesIntentWithoutCustomPromptConflict() async {
        let cleaner = MockTranscriptCleanup()
        cleaner.cleanHandler = { _ in "Please send the report today." }
        let result = await process("send the report today", cleaner: cleaner, intent: .professional)
        XCTAssertEqual(result.text, "Please send the report today.")
        XCTAssertEqual(cleaner.cleanCallCount, 1)
        XCTAssertTrue(cleaner.lastPrompt?.contains("professional") == true)
        XCTAssertFalse(cleaner.lastPrompt?.contains("Custom cleanup instructions") == true)
    }

    func testExperimentalGateKeepsCleanupOnly() async {
        let cleaner = MockTranscriptCleanup()
        _ = await process("hello there", cleaner: cleaner, intent: .professional, experimental: false)
        XCTAssertTrue(cleaner.lastPrompt?.contains("Custom cleanup instructions") == true)
        XCTAssertFalse(cleaner.lastPrompt?.contains("clear, professional") == true)
    }

    func testCommandsAndLiteralEscapesCannotBeEatenByCleanup() async {
        for (input, format) in [
            ("literally dot json", WritingStyle.notes),
            ("start bold ship this today end bold", .slack),
            ("line one new line line two", .chat)
        ] {
            let cleaner = MockTranscriptCleanup()
            let result = await process(input, cleaner: cleaner, format: format)
            XCTAssertEqual(cleaner.cleanCallCount, 0)
            XCTAssertEqual(result.text, WritingStyleEngine.format(
                input, style: format, globalAutoCapitalize: true, globalTrailingSpace: false
            ))
        }
    }

    func testChangedFactsFallBackToDeterministicOutput() async {
        for (input, output) in [
            ("do not deploy today", "Deploy today."),
            ("the meeting is at 15", "The meeting is at 50."),
            ("we might ship today", "We will ship today."),
            ("this is very very useful", "This is very useful."),
            ("can you send the report?", "I sent the report."),
            ("hey can you send the report today", "Sure, I can do that. Could you please provide the report for today?"),
            ("please let me know when you have a chance to review the proposal", "I'll let you know when I have a chance to review the proposal.")
        ] {
            let cleaner = MockTranscriptCleanup()
            cleaner.cleanHandler = { _ in output }
            let result = await process(input, cleaner: cleaner, intent: .professional)
            XCTAssertTrue(result.summary.contains("rejected"), input)
            XCTAssertEqual(result.text, DictationOutputFormatter.apply(input, autoCapitalize: true, appendTrailingSpace: false))
        }
    }

    func testTechnicalSpansSurviveModelAndFinalCapitalization() async {
        let cleaner = MockTranscriptCleanup()
        cleaner.cleanHandler = { $0 }
        let input = "readme.md belongs to myUser at user@example.com with 15 retries"
        let result = await process(input, cleaner: cleaner)
        XCTAssertEqual(result.text, input)
        XCTAssertFalse(cleaner.lastCleanedText?.contains("readme.md") == true)
        XCTAssertTrue(cleaner.lastCleanedText?.contains("VOCAKEEP") == true)
    }

    func testSnippetTriggerIsMatchedBeforeRewriteAndExpansionIsExact() async {
        let cleaner = MockTranscriptCleanup()
        cleaner.cleanHandler = { $0.replacingOccurrences(of: "um send", with: "Please send") }
        let result = await process(
            "um send my signature", cleaner: cleaner, intent: .professional,
            snippets: [Snippet(trigger: "my signature", expansion: "alice@example.com\nEngineering\n")]
        )
        XCTAssertEqual(result.text, "Please send alice@example.com\nEngineering\n")
        XCTAssertFalse(cleaner.lastCleanedText?.contains("my signature") == true)
        XCTAssertFalse(cleaner.lastCleanedText?.contains("alice@example.com") == true)
    }

    func testFocusChangeHoldsResultAndTemporaryOverrideDoesNotPersist() async {
        let (state, mocks) = AppState.makeTestState()
        let mail = RunningAppSnapshot(displayName: "Mail", bundleIdentifier: "com.apple.mail")
        mocks.frontmostAppResolver.frontmostApp = mail
        mocks.transcriptCleanup.cleanHandler = { text in
            mocks.frontmostAppResolver.frontmostApp = RunningAppSnapshot(
                displayName: "Terminal", bundleIdentifier: "com.apple.Terminal"
            )
            return text
        }
        state.transcriptCleanupEnabled = true
        state.useNextWritingFormat(.chat)
        mocks.audioEngine.stopRecordingResult = Array(repeating: Float(0.1), count: 16_000)
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "send the report", duration: 1, detectedLanguage: "en", audioLengthSeconds: 1, modelUsed: .tiny
        )
        state.isRecording = true
        state.appStatus = .recording
        await state.stopRecordingAndTranscribe()
        XCTAssertNil(mocks.textInjector.lastInjectedText)
        XCTAssertNotNil(state.heldOutput)
        XCTAssertEqual(state.appStatus, .error)
        XCTAssertNil(state.nextWritingProfile)
        XCTAssertTrue(state.writingStyleBindings.isEmpty)
    }

    func testMissingModelAndUnsupportedLanguageUseFallback() async {
        let cleaner = MockTranscriptCleanup()
        cleaner.downloadedKinds = []
        let missing = await process("hello", cleaner: cleaner, intent: .casual)
        XCTAssertTrue(missing.summary.contains("download"))
        let hindi = await process("कल deploy मत करना।", cleaner: cleaner, intent: .professional, language: "hi")
        XCTAssertEqual(hindi.text, "कल deploy मत करना।")
        XCTAssertEqual(cleaner.cleanCallCount, 0)
    }

    func testTokensCannotBeDroppedDuplicatedOrReordered() {
        let protected = RewriteProtectedText("send 15 to user@example.com")
        XCTAssertEqual(protected.restoreValidated(protected.text), "send 15 to user@example.com")
        XCTAssertNil(protected.restoreValidated("send 15"))
        XCTAssertNil(protected.restoreValidated(protected.text + " VOCAKEEP0END"))
        XCTAssertNil(protected.restoreValidated("send VOCAKEEP1END to VOCAKEEP0END"))
        let collision = RewriteProtectedText("VOCAKEEP0END send 15")
        XCTAssertEqual(collision.restoreValidated(collision.text), "VOCAKEEP0END send 15")
    }

    func testLegacyBindingsDecodeWithoutEnablingRewrite() throws {
        let data = Data(#"{"id":"mail","displayName":"Mail","style":"email"}"#.utf8)
        let binding = try JSONDecoder().decode(AppStyleBinding.self, from: data)
        XCTAssertEqual(binding.intent, .preserve)
        XCTAssertEqual(binding.cleanup, .inherit)
        var configured = binding
        configured.intent = .casual
        configured.cleanup = .off
        let roundtrip = try JSONDecoder().decode(AppStyleBinding.self, from: JSONEncoder().encode(configured))
        XCTAssertEqual(roundtrip, configured)
    }

    func testPlainTextDestinationsDoNotPromiseRichTextByPastingMarkdown() {
        XCTAssertEqual(WritingStyle.email.defaultRules.emphasisDialect, .none)
        for id in ["com.apple.Notes", "com.culturedcode.ThingsMac"] {
            let suggestion = WritingStyleCatalog.suggestions.first { $0.bundleIdentifier == id }
            XCTAssertEqual(suggestion?.binding.effectiveRules.emphasisDialect, EmphasisDialect.none)
        }
        XCTAssertEqual(WritingStyle.notes.defaultRules.emphasisDialect, .markdown)
    }

    func testDisabledProfilesRetainGlobalCleanup() async {
        let resolved = WritingStyleResolver.resolve(
            target: nil, bindings: [], defaultStyle: .terminal, isEnabled: false, defaultIntent: .professional
        )
        XCTAssertEqual(resolved.profile.intent, .preserve)
        XCTAssertTrue(resolved.profile.allowsRewrite)
    }

    func testRebindingFormatPreservesWordingAndCleanupPreferences() {
        let (state, mocks) = AppState.makeTestState()
        let mail = RunningAppSnapshot(displayName: "Mail", bundleIdentifier: "com.apple.mail")
        mocks.frontmostAppResolver.frontmostApp = mail
        var binding = AppStyleBinding.from(snapshot: mail, style: .email)
        binding.intent = .professional
        binding.cleanup = .off
        state.writingStyleBindings = [binding]
        state.bindFrontmostApp(to: .chat)
        XCTAssertEqual(state.writingStyleBindings.first?.style, .chat)
        XCTAssertEqual(state.writingStyleBindings.first?.intent, .professional)
        XCTAssertEqual(state.writingStyleBindings.first?.cleanup, .off)
    }

    func testOneOffFormatAndWordingSelectionsComposeInEitherOrder() {
        let (state, _) = AppState.makeTestState()

        state.useNextWritingIntent(.casual)
        state.useNextWritingFormat(.chat)
        XCTAssertEqual(state.nextWritingProfile?.format, .chat)
        XCTAssertEqual(state.nextWritingProfile?.intent, .casual)
        XCTAssertEqual(state.nextWritingProfile?.cleanup, .inherit)

        state.useRawForNextDictation()
        state.useNextWritingFormat(.email)
        state.useNextWritingIntent(.professional)
        XCTAssertEqual(state.nextWritingProfile?.format, .email)
        XCTAssertEqual(state.nextWritingProfile?.intent, .professional)
        XCTAssertEqual(state.nextWritingProfile?.cleanup, .inherit)
    }
}
