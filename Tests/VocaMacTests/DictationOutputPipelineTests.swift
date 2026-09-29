import XCTest
@testable import VocaMac

@MainActor
final class DictationOutputPipelineTests: XCTestCase {
    func testGrammarModeRepairsAgreementAndArticlesThroughThePipeline() async {
        let cleaner = MockTranscriptCleanup()
        cleaner.cleanHandler = { _ in "She goes to the office every day." }
        let result = await process("she go to office every day", cleaner: cleaner, level: .grammar)
        XCTAssertEqual(result.text, "She goes to the office every day.")
    }

    func testGermanPrepositionSurvivesTheModelsFillerDeletion() async {
        let cleaner = MockTranscriptCleanup()
        cleaner.cleanHandler = { $0.replacingOccurrences(of: "um ", with: "") }
        let result = await process("wir treffen uns um 5 Uhr", cleaner: cleaner, language: "de")
        XCTAssertTrue(result.text.contains("um 5 Uhr"), result.text)
    }

    private func process(
        _ input: String, cleaner: MockTranscriptCleanup,
        format: WritingStyle = .plain, intent: WritingIntent = .preserve,
        cleanup: WritingCleanupPolicy = .inherit, enabled: Bool = true,
        experimental: Bool = true, snippets: [Snippet] = [], language: String? = "en",
        level: CleanupLevel = .medium, cleanupPrompt: String? = nil
    ) async -> DictationOutputResult {
        await DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander()).process(
            input,
            profile: WritingProfile(
                format: format, rules: format.defaultRules, intent: intent,
                cleanup: cleanup, cleanupPrompt: cleanupPrompt
            ),
            snippetList: snippets, cleanupEnabled: enabled, rewritingEnabled: experimental,
            model: .defaultKind, customPrompt: "Custom cleanup instructions",
            cleanupLevel: level,
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

    func testNoneLevelSkipsTheCleanupModel() async {
        let cleaner = MockTranscriptCleanup()
        let result = await process("um hello", cleaner: cleaner, level: .none)
        XCTAssertEqual(cleaner.cleanCallCount, 0)
        XCTAssertEqual(result.text, "Um hello", "None keeps every spoken sound")
        XCTAssertEqual(result.summary, "Cleanup level None — formatting only")
    }

    func testHesitationsGoWithoutTheModelInTerminalAndWithCleanupOff() async {
        let terminal = MockTranscriptCleanup()
        let inTerminal = await process("git status um um", cleaner: terminal, format: .terminal)
        XCTAssertEqual(inTerminal.text, "git status")
        XCTAssertEqual(terminal.cleanCallCount, 0, "Terminal still never reaches the model")
        XCTAssertTrue(inTerminal.summary.contains("Terminal style"))
        XCTAssertTrue(inTerminal.summary.contains("removed"))

        let off = await process("hello, um, how are you?", cleaner: MockTranscriptCleanup(), enabled: false)
        XCTAssertEqual(off.text, "Hello, how are you?")
        XCTAssertTrue(off.summary.contains("Smart Cleanup is off"))
    }

    func testHesitationsSurviveWhenARewriteIsRejected() async {
        let cleaner = MockTranscriptCleanup()
        cleaner.cleanHandler = { _ in "Something completely different." }
        let result = await process("Hi, um, I hope you're good", cleaner: cleaner)
        XCTAssertEqual(result.text, "Hi, I hope you're good")
        XCTAssertTrue(result.summary.hasPrefix("Kept your wording"), result.summary)
    }

    func testLightLevelAndFormattingOnlyKeepHesitations() async {
        let light = await process("um hello", cleaner: MockTranscriptCleanup(), level: .light)
        XCTAssertTrue(light.text.lowercased().contains("um"))
        let formattingOnly = await process("um hello there", cleaner: MockTranscriptCleanup(), cleanup: .off)
        XCTAssertTrue(formattingOnly.text.lowercased().hasPrefix("um"))
    }

    func testUnlabelledTextIsJudgedWithoutItsHesitations() {
        XCTAssertTrue(RewriteValidation.likelyEnglish("hello world um um"))
        XCTAssertTrue(RewriteValidation.likelyEnglish("so um hello"))
        XCTAssertTrue(RewriteValidation.likelyEnglish("Uh"))
        XCTAssertFalse(RewriteValidation.likelyEnglish("wir treffen uns um 5 Uhr"))
    }

    func testEnginesThatReportAutoStillGetHesitationRemoval() async {
        // Parakeet reports "auto" when no language is chosen.
        let result = await process("hello world um um", cleaner: MockTranscriptCleanup(), enabled: false, language: "auto")
        XCTAssertEqual(result.text, "Hello world")
        XCTAssertNil(DictationOutputPipeline.knownLanguage("auto"))
        XCTAssertEqual(DictationOutputPipeline.knownLanguage("en-US"), "en-us")
    }

    func testSpokenCorrectionsResolveWithoutTheModel() async {
        let cleaner = MockTranscriptCleanup()
        let result = await process("let's do it tomorrow, oh, no, Wednesday", cleaner: cleaner, enabled: false)
        XCTAssertEqual(result.text, "Let's do it Wednesday")
        XCTAssertTrue(result.summary.contains("spoken correction applied"), result.summary)
        // Code and Terminal text is only trimmed of filler, never corrected.
        let terminal = await process("deploy Monday, no, Tuesday tonight", cleaner: MockTranscriptCleanup(),
                                     format: .terminal, enabled: false)
        XCTAssertEqual(terminal.text, "deploy Monday, no, Tuesday tonight")
        // Light keeps every word, corrections included.
        let light = await process("let's do it tomorrow, no, Wednesday", cleaner: MockTranscriptCleanup(), enabled: false, level: .light)
        XCTAssertTrue(light.text.contains("tomorrow"))
    }

    func testCutOffWordsGoWithoutTheModel() async {
        let result = await process(
            "Can you tell me with our current changes we supp are supporting streaming in whisper models and if yes how?",
            cleaner: MockTranscriptCleanup(), enabled: false
        )
        XCTAssertEqual(result.text,
                       "Can you tell me with our current changes we are supporting streaming in whisper models and if yes how?")
        XCTAssertTrue(result.summary.contains("cut-off word removed"), result.summary)
        // Terminal keeps its casing and punctuation, but loses the fragment.
        let terminal = await process("can you tell me if we supp are supporting streaming",
                                     cleaner: MockTranscriptCleanup(), format: .terminal, enabled: false)
        XCTAssertEqual(terminal.text, "can you tell me if we are supporting streaming")
        // Light and per-app Formatting only keep every word.
        let light = await process("what we can im improve", cleaner: MockTranscriptCleanup(), enabled: false, level: .light)
        XCTAssertTrue(light.text.contains("im improve"), light.text)
        let off = await process("what we can im improve", cleaner: MockTranscriptCleanup(), cleanup: .off)
        XCTAssertTrue(off.text.contains("im improve"), off.text)
        // A snippet trigger or dictionary term is never a fragment.
        let snippet = await process("my addr address is here", cleaner: MockTranscriptCleanup(), enabled: false,
                                    snippets: [Snippet(trigger: "addr", expansion: "1 Main St")])
        XCTAssertTrue(snippet.text.contains("1 Main St"), snippet.text)
        let unguarded = await process("my addre address is here", cleaner: MockTranscriptCleanup(), enabled: false)
        XCTAssertEqual(unguarded.text, "My address is here")
    }

    func testCutOffWordRules() {
        let known: Set<String> = [
            "please", "improve", "sorry", "supporting", "are", "diff", "different", "them", "theme",
            "we", "the", "done", "can", "it", "is", "what", "didn't", "typescript", "use",
            "install", "package", "javascript", "file", "set", "here", "address",
        ]
        let isKnownWord = { known.contains($0) }
        let cases: [(String, String)] = [
            ("can you ple please install", "can you please install"),
            ("what we can im improve", "what we can improve"),
            ("Oh not sor, sorry tomorrow", "Oh not sorry tomorrow"),
            ("we supp are supporting it", "we are supporting it"),
            ("we supp supp are supporting it", "we are supporting it"),
            ("we su supp are supporting it", "we are supporting it"),
            ("it didn didn't work", "it didn't work"),
            // Capitals may be names, even opening a sentence.
            ("Wh what is it? Wh what", "Wh what is it? Wh what"),
            // Vowel-less abbreviations are meant.
            ("install the pkg package", "install the pkg package"),
            ("the js javascript file", "the js javascript file"),
            // A word also used on its own is the speaker's.
            ("set addr here, the addr address", "set addr here, the addr address"),
            ("the addre address", "the address"),
            // Both halves are real words: only the model may judge.
            ("its indicator is diff different", "its indicator is diff different"),
            ("make them theme", "make them theme"),
            // Two letters need the word right after; a sentence end breaks the link.
            ("im the improve", "im the improve"),
            ("we supp. Supporting it", "we supp. Supporting it"),
            // Names, flags, and paths are not fragments.
            ("ask Ple please", "ask Ple please"),
            ("run --supp supporting", "run --supp supporting"),
            // The completion must be a real word.
            ("voca vocamac is done", "voca vocamac is done"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(WritingStyleEngine.removeCutOffWords(input, isKnownWord: isKnownWord).text, expected, input)
        }
        // Mid-sentence capitals are names; in a command, case is data.
        XCTAssertEqual(WritingStyleEngine.removeCutOffWords("it is Supp supporting", isKnownWord: isKnownWord).text,
                       "it is Supp supporting")
        XCTAssertEqual(WritingStyleEngine.removeCutOffWords("Wh what", prose: false, isKnownWord: isKnownWord).text,
                       "Wh what")
        // Terminal text loses the fragment too, keeping its own case.
        XCTAssertEqual(WritingStyleEngine.removeCutOffWords("we supp are supporting it", prose: false, isKnownWord: isKnownWord).text,
                       "we are supporting it")
        XCTAssertEqual(WritingStyleEngine.removeCutOffWords("use tsx use typescript", prose: false, isKnownWord: isKnownWord).text,
                       "use tsx use typescript")
    }

    func testHesitationRemovalIsEnglishOnly() async {
        let german = await process("wir treffen uns um 5 Uhr", cleaner: MockTranscriptCleanup(), enabled: false, language: "de")
        XCTAssertTrue(german.text.contains(" um 5 Uhr"))
    }

    func testALoneHesitationTypesNothing() async {
        let result = await process("Uh", cleaner: MockTranscriptCleanup())
        XCTAssertEqual(result.text, "")
    }

    func testHesitationCleanupRepairsPunctuationAndCase() {
        let cases: [(String, String)] = [
            ("Hello, um, how are you?", "Hello, how are you?"),
            ("How are you? Um I hope you're good.", "How are you? I hope you're good."),
            ("Um, so we ship Friday", "So we ship Friday"),
            ("hello world, um.", "hello world."),
            ("uh uh okay", "okay"),
            ("Umm, uhh, hmm, erm, uhm", ""),
            ("the summary says 5 mm and humming", "the summary says 5 mm and humming"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(WritingStyleEngine.removeHesitations(input).text, expected, input)
        }
        XCTAssertFalse(WritingStyleEngine.removeHesitations("nothing to remove").removed)
    }

    func testOtherLanguagesLoseOnlyUniversalHesitations() {
        let cases: [(String, String?, String)] = [
            // "um" is German for "at", "em" Portuguese for "in", "am" German for "on the".
            ("Wir treffen uns um 5 Uhr, ähm, am Bahnhof", "de", "Wir treffen uns um 5 Uhr, am Bahnhof"),
            ("Eu moro em Lisboa, hmm, perto do rio", "pt", "Eu moro em Lisboa, perto do rio"),
            ("Alors euh on commence", "fr", "Alors on commence"),
            // The French filler is a word elsewhere, so it needs the language.
            ("Alors euh on commence", nil, "Alors euh on commence"),
            ("Uhm, ja", nil, "Ja"),
        ]
        for (input, language, expected) in cases {
            XCTAssertEqual(
                WritingStyleEngine.removeOtherLanguageHesitations(input, language: language).text,
                expected, input
            )
        }
    }

    func testStuttersCollapseButDeliberateRepeatsStay() {
        let known: (String) -> Bool = { ["no", "very", "where", "i", "think"].contains($0) }
        let cases: [(String, String)] = [
            ("I I I think so", "I think so"),
            ("wh wh wh where is it", "wh where is it"),
            ("no no no, not that", "no no no, not that"),
            ("it is very very very good", "it is very very very good"),
            ("I I think", "I I think"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(WritingStyleEngine.collapseStutters(input, isKnownWord: known).text, expected, input)
        }
    }

    func testPipelineRemovesUniversalHesitationsInGerman() async {
        let result = await process("Wir treffen uns um 5 Uhr, ähm, am Bahnhof", cleaner: MockTranscriptCleanup(), enabled: false, language: "de")
        XCTAssertEqual(result.text, "Wir treffen uns um 5 Uhr, am Bahnhof")
    }

    func testHesitationRemovalLeavesOtherWhitespaceAlone() {
        // Indentation, double spaces, and line breaks are content in code.
        XCTAssertEqual(
            WritingStyleEngine.removeHesitations("    let x = 1  // um").text,
            "    let x = 1  //"
        )
        XCTAssertEqual(
            WritingStyleEngine.removeHesitations("first  line\num second line\n\tindented").text,
            "first  line\nsecond line\n\tindented"
        )
        XCTAssertEqual(
            WritingStyleEngine.removeHesitations("a  b uh c").text,
            "a  b c"
        )
    }

    func testNamesStayReadableForTheModelAndMustSurvive() {
        let protected = RewriteProtectedText("Hi Sergey, how are you?")
        XCTAssertTrue(protected.text.contains("Sergey"), "Names are not hidden behind tokens")
        XCTAssertEqual(protected.restoreValidated("Hi Sergey, how are you?"), "Hi Sergey, how are you?")
        XCTAssertNil(protected.restoreValidated("How are you?"), "Dropping the name rejects the rewrite")
        XCTAssertNil(protected.restoreValidated("Hi Sergei, how are you?"), "So does respelling it")
    }

    func testNumericCorrectionsResolveWithOrWithoutTheModel() async {
        let cleaner = MockTranscriptCleanup()
        cleaner.cleanHandler = { $0 }
        let corrected = await process("meet at 2 actually 3", cleaner: cleaner, level: .high)
        XCTAssertEqual(corrected.text, "Meet at 3")

        let disabled = await process(
            "meet at 2 actually 3", cleaner: MockTranscriptCleanup(), enabled: false, level: .high
        )
        // Rule-based, so Smart Cleanup being off doesn't matter.
        XCTAssertEqual(disabled.text, "Meet at 3")
    }

    func testProfileCleanupPromptOverridesTheGlobalPrompt() async {
        let cleaner = MockTranscriptCleanup()
        _ = await process(
            "hello there", cleaner: cleaner,
            cleanupPrompt: "Keep the app-specific terminology"
        )
        XCTAssertTrue(cleaner.lastPrompt?.contains("Keep the app-specific terminology") == true)
        XCTAssertFalse(cleaner.lastPrompt?.contains("Custom cleanup instructions") == true)
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

    func testChangedFactsAreNeverTakenFromTheModel() async {
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
            // Every word the user said survives exactly; at most the model's
            // punctuation is taken. Nothing is "rejected" whole.
            let words = { (text: String) in RewriteValidation.substrings(#"[\p{L}\p{N}']+"#, in: text.lowercased()) }
            XCTAssertEqual(words(result.text), words(input), input)
            XCTAssertFalse(result.summary.contains("rejected"), input)
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
        // "um" is removed before the model; the model sees "send …".
        cleaner.cleanHandler = { $0.hasPrefix("send") ? "Please " + $0 : $0 }
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

// MARK: - Romanized Hindi

extension DictationOutputPipelineTests {
    func testRomanizedHindiSkipsTheCleanupModel() async {
        let cleaner = MockTranscriptCleanup()
        // What the model did to a real Voca Hinglish dictation.
        cleaner.cleanHandler = { _ in "Aur, batao, kya aajkal pankha *kahan* hai? Kitne mukadme *hoge* us par?" }
        let spoken = "Aur batao, pankha kahaan hai aajkal? Kitne mukdame ho gae us par?"

        let result = await process(spoken, cleaner: cleaner, language: "hi-Latn", level: .high)

        XCTAssertEqual(result.text, spoken)
        XCTAssertEqual(cleaner.cleanCallCount, 0)
        XCTAssertTrue(result.summary.contains("Romanized text kept as written"), result.summary)
    }

    func testRomanizedHindiStillLosesUniversalHesitations() async {
        let result = await process("Umm haan thik hai.", cleaner: MockTranscriptCleanup(), language: "hi-Latn")
        XCTAssertEqual(result.text, "Haan thik hai.")
    }
}

// MARK: - Pieces

extension DictationOutputPipelineTests {
    private func pieces(_ texts: [String]) -> [TranscribedPiece] {
        texts.enumerated().map { index, text in
            TranscribedPiece(range: (index * 16_000)..<((index + 1) * 16_000), text: text, language: "en")
        }
    }

    private func options(format: WritingStyle = .plain, intent: WritingIntent = .preserve) -> DictationOutputOptions {
        DictationOutputOptions(
            profile: WritingProfile(format: format, rules: format.defaultRules, intent: intent),
            snippetList: [], cleanupEnabled: true, rewritingEnabled: true,
            model: .defaultKind, customPrompt: "Custom cleanup instructions",
            language: "en", autoCapitalize: true, trailingSpace: true
        )
    }

    func testPiecesGiveTheSameTextAsTheWholeWhenTheModelChangesNothing() async {
        let cases: [[String]] = [
            ["so um I was thinking we could ship it on friday.", "then maybe after the review we talk."],
            ["meet me at readme.md on the 15th, okay?", "email alice@example.com about it.", "um thanks"],
            ["first part without punctuation", "second part also without it"],
        ]
        for texts in cases {
            let wholeCleaner = MockTranscriptCleanup()
            wholeCleaner.cleanHandler = { $0 }
            let pieceCleaner = MockTranscriptCleanup()
            pieceCleaner.cleanHandler = { $0 }
            let joined = TranscribedPiece.join(texts)
            let whole = await DictationOutputPipeline(cleaner: wholeCleaner, snippets: SnippetExpander())
                .process(joined, options: options())
            let split = await DictationOutputPipeline(cleaner: pieceCleaner, snippets: SnippetExpander())
                .process(joined, options: options(), pieces: pieces(texts))
            XCTAssertEqual(split.text, whole.text, "\(texts)")
            XCTAssertEqual(split.summary, whole.summary, "\(texts)")
            XCTAssertEqual(pieceCleaner.cleanCallCount, texts.count, "\(texts)")
        }
    }

    func testRejectedPieceKeepsItsWordsAndTheOthersAreStillCleaned() async {
        let cleaner = MockTranscriptCleanup()
        cleaner.cleanHandler = { text in
            text.contains("ship") ? "Something else entirely." : text.replacingOccurrences(of: "if if", with: "if")
        }
        let texts = ["we will ship it on friday.", "tell me if if the review comes after that."]
        let output = await DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
            .process(TranscribedPiece.join(texts), options: options(), pieces: pieces(texts))
        XCTAssertEqual(output.text, "We will ship it on friday. Tell me if the review comes after that. ")
        XCTAssertTrue(output.summary.hasPrefix("Cleaned up"), output.summary)
        XCTAssertTrue(output.summary.contains("1 of 2 parts kept as spoken"), output.summary)
    }

    func testEveryPieceKeptGivesTheExactFormattingFallback() async {
        let cleaner = MockTranscriptCleanup()
        cleaner.cleanHandler = { _ in "Something else entirely." }
        let texts = ["we will ship it on friday.", "the review comes after that."]
        let joined = TranscribedPiece.join(texts)
        let whole = await DictationOutputPipeline(cleaner: MockTranscriptCleanup(), snippets: SnippetExpander())
            .process(joined, options: DictationOutputOptions(
                profile: options().profile, snippetList: [], cleanupEnabled: false, rewritingEnabled: true,
                model: .defaultKind, customPrompt: "", language: "en", autoCapitalize: true, trailingSpace: true
            ))
        let output = await DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
            .process(joined, options: options(), pieces: pieces(texts))
        XCTAssertEqual(output.text, whole.text)
        XCTAssertTrue(output.summary.hasPrefix("Kept your wording"), output.summary)
    }

    func testTechnicalPiecesOnlyLoseFiller() async {
        let cleaner = MockTranscriptCleanup()
        cleaner.cleanHandler = { $0.replacingOccurrences(of: "with with", with: "with") }
        let texts = ["git commit with with the message fix the build", "then push it to the main branch"]
        let output = await DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
            .process(TranscribedPiece.join(texts), options: options(format: .terminal), pieces: pieces(texts))
        XCTAssertFalse(output.text.contains("with with"), output.text)
        XCTAssertTrue(output.text.contains("then push it to the main branch"), output.text)
        XCTAssertEqual(cleaner.previewCallCount, 2, "Code and Terminal never count toward the give-up limit")
    }

    func testSlicesFollowThePiecesInThePreparedText() {
        let texts = ["Hello there.", "How are you?", "Fine."]
        let slices = DictationOutputPipeline.slices(
            of: "Hello there. How are you? Fine.", pieces: pieces(texts), prepare: { $0 }
        )
        XCTAssertEqual(slices.map(\.text), texts)
        XCTAssertEqual(slices.map(\.separatorBefore), ["", " ", " "])
    }

    func testPieceThatVanishedHasNoSlice() {
        let prepare: (String) -> String = {
            $0.replacingOccurrences(of: "um ", with: "").replacingOccurrences(of: "um", with: "")
        }
        let slices = DictationOutputPipeline.slices(
            of: "One two. Three four.", pieces: pieces(["One two.", "um", "Three four."]), prepare: prepare
        )
        XCTAssertEqual(slices.map(\.text), ["One two.", "Three four."])
    }

    func testStageThatWorksAcrossABoundaryJoinsThosePieces() {
        // A correction in the third piece reaches back into the second.
        let prepare: (String) -> String = { text in
            text.replacingOccurrences(of: "at 2. No, 3.", with: "at 3.")
        }
        let texts = ["First sentence here.", "Let's meet at 2.", "No, 3.", "See you."]
        let whole = prepare(TranscribedPiece.join(texts))
        let slices = DictationOutputPipeline.slices(of: whole, pieces: pieces(texts), prepare: prepare)
        XCTAssertEqual(slices.map(\.text), ["First sentence here.", "Let's meet at 3.", "See you."])
    }

    func testPlaceholdersNumberedPerPieceStillMatch() {
        let whole = "Mail \u{E000} now. Call \u{E001} later."
        let prepare: (String) -> String = { $0.replacingOccurrences(of: "X", with: "\u{E000}") }
        let slices = DictationOutputPipeline.slices(
            of: whole, pieces: pieces(["Mail X now.", "Call X later."]), prepare: prepare
        )
        XCTAssertEqual(slices.map(\.text), ["Mail \u{E000} now.", "Call \u{E001} later."])
    }

    func testUnmatchedTextStaysOneSlice() {
        let slices = DictationOutputPipeline.slices(
            of: "Completely different", pieces: pieces(["One.", "Two."]), prepare: { $0 }
        )
        XCTAssertEqual(slices, [DictationOutputPipeline.wholeSlice(of: "Completely different")])
    }

    func testConcatenatedMasksAreRenumbered() throws {
        let base = TextPlaceholder.identifierBase
        let first = try XCTUnwrap(TextPlaceholder.character(at: 0, base: base))
        let second = try XCTUnwrap(TextPlaceholder.character(at: 1, base: base))
        let parts = [
            MaskedText(text: "a \(first)", replacements: ["x.md"], base: base),
            MaskedText(text: "b \(first)", replacements: ["y.md"], base: base),
        ]
        let combined = try XCTUnwrap(DictationOutputPipeline.concatenate(parts, separators: [" "]))
        XCTAssertEqual(combined.text, "a \(first) b \(second)")
        XCTAssertEqual(combined.restore(in: combined.text), "a x.md b y.md")
    }
}
