import XCTest
@testable import VocaMac

final class CleanupNeedTests: XCTestCase {
    private func reason(
        _ text: String, level: CleanupLevel = .medium, technical: Bool = false, isEnglish: Bool = true
    ) -> String? {
        CleanupNeed.reason(for: text, level: level, technical: technical, isEnglish: isEnglish)
    }

    func testAnAlreadyCleanDictationNeedsNoModel() {
        XCTAssertNil(reason("Sounds good, thanks."))
        XCTAssertNil(reason("The build passed. I will merge it after lunch."))
        XCTAssertNil(reason("Can you send me the report?"))
        XCTAssertNil(reason("We ship on Friday at 3 pm, if the review is done."))
    }

    func testFillerAndFalseStartsStillGoToTheModel() {
        XCTAssertNotNil(reason("It was, like, really late."))
        XCTAssertNotNil(reason("You know, we should ship it."))
        XCTAssertNotNil(reason("So we should ship it."))
        XCTAssertNotNil(reason("The build passed. Okay. I will merge it."))
        XCTAssertNotNil(reason("I think the the build passed."))
        XCTAssertNotNil(reason("We want we want to ship it."))
        XCTAssertNotNil(reason("We can easily sn scan it."))
        XCTAssertNotNil(reason("The wh- the build passed."))
        XCTAssertNotNil(reason("It passed. N"))
        XCTAssertNotNil(reason("It is a very sub substantial benefit.", technical: true))
        XCTAssertNotNil(reason("Show it on my web website.", technical: true))
    }

    func testOrdinaryShortWordsAreNotStutters() {
        XCTAssertNil(reason("We go to today's meeting in an hour."))
        XCTAssertNil(reason("It is in inside the box."))
        XCTAssertNil(reason("We need better view views."))
    }

    func testWhatTheEngineLeftUnpunctuatedGoesToTheModel() {
        XCTAssertNotNil(reason("the build passed and i will merge it"))
        XCTAssertNotNil(reason("The build passed"))
        XCTAssertNotNil(reason("The build passed. then it failed."))
        let runOn = Array(repeating: "word", count: CleanupNeed.longestSentenceWords + 1).joined(separator: " ")
        XCTAssertNotNil(reason("The " + runOn + "."))
    }

    func testDictatedMarksNumbersAndSpellingsGoToTheModel() {
        XCTAssertNotNil(reason("Send it to the team comma then archive it."))
        XCTAssertNotNil(reason("It is four twenty five."))
        XCTAssertNotNil(reason("My name is spelled V O C A."))
        XCTAssertNotNil(reason("Then i went home."))
        // "one" is a pronoun far more often than a number.
        XCTAssertNil(reason("I will take that one."))
    }

    func testLevelsDecideWhatCountsAsWork() {
        // Light only punctuates, so filler is not its business.
        XCTAssertNil(reason("It was, like, really late.", level: .light))
        XCTAssertNotNil(reason("it was late", level: .light))
        // High also resolves corrections; Medium leaves those words alone.
        XCTAssertNil(reason("Send it to John. Sorry, Mary.", level: .medium))
        XCTAssertNotNil(reason("Send it to John. Sorry, Mary.", level: .high))
        // Grammar repairs can't be seen coming.
        XCTAssertNotNil(reason("Sounds good, thanks.", level: .grammar))
    }

    func testCodeAndTerminalOnlyLookForFiller() {
        XCTAssertNil(reason("git status and then run the tests", technical: true))
        XCTAssertNotNil(reason("git status, like, right now", technical: true))
    }

    func testOtherLanguagesAlwaysGoToTheModel() {
        XCTAssertNotNil(reason("Das klingt gut, danke.", isEnglish: false))
    }

    func testPlaceholdersCountAsWordsAndSentenceEnds() {
        // A snippet at the start and an emoji glyph at the end.
        XCTAssertNil(reason("\u{E000} is ready for review \u{E001}"))
    }
}

final class GenerationMonitorTests: XCTestCase {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func raise() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    func testAnAnswerPastItsLimitIsStoppedOnce() {
        let stops = Flag()
        let monitor = GenerationMonitor(characterLimit: 10, stop: { stops.raise() })
        monitor.receive("12345")
        XCTAssertNil(monitor.stopReason)
        monitor.receive("678901")
        XCTAssertEqual(monitor.stopReason, .runaway)
        monitor.receive("more")
        XCTAssertEqual(stops.value, 1)
    }

    func testARefusalIsStoppedAtItsFirstWords() {
        let stops = Flag()
        let monitor = GenerationMonitor(
            characterLimit: 1_000, refusalPrefixes: TranscriptCleanup.cleanupRefusalPrefixes, stop: { stops.raise() }
        )
        monitor.receive("  Sure, ")
        XCTAssertNil(monitor.stopReason)
        monitor.receive("here’s the cleaned text:")
        XCTAssertEqual(monitor.stopReason, .refusal)
        XCTAssertEqual(stops.value, 1)
    }

    func testAnOrdinaryAnswerIsLeftAlone() {
        let stops = Flag()
        let monitor = GenerationMonitor(
            characterLimit: 1_000, refusalPrefixes: TranscriptCleanup.cleanupRefusalPrefixes, stop: { stops.raise() }
        )
        monitor.receive("The meeting is at 3 pm on Tuesday. ")
        monitor.receive("I cannot make it.")
        monitor.receive(nil)
        XCTAssertNil(monitor.stopReason)
        XCTAssertEqual(stops.value, 0)
    }

    func testReadingAheadStopsAtTheFirstText() {
        let stops = Flag()
        let monitor = GenerationMonitor(characterLimit: 0, stop: { stops.raise() })
        monitor.receive("O")
        XCTAssertEqual(monitor.stopReason, .primed)
        XCTAssertEqual(stops.value, 1)
    }

    func testReasoningBeforeTheAnswerDoesNotCountAsLength() {
        let monitor = GenerationMonitor(characterLimit: 20, stop: {})
        monitor.receive("<think>This is a long chain of reasoning that goes past the limit")
        XCTAssertNil(monitor.stopReason)
    }

    @MainActor
    func testThePreviewCarriesTheTextSoFar() async {
        let received = expectation(description: "preview")
        let monitor = GenerationMonitor(
            characterLimit: 1_000,
            onPartial: { text in
                XCTAssertEqual(text, "Hello")
                received.fulfill()
            },
            stop: {}
        )
        monitor.receive("Hello")
        await fulfillment(of: [received], timeout: 2)
    }

    func testTheWatchRoutesTextToTheCurrentMonitorOnly() {
        let watch = GenerationWatch()
        let first = GenerationMonitor(characterLimit: 3, stop: {})
        let second = GenerationMonitor(characterLimit: 3, stop: {})
        watch.follow(first)
        watch.receive("abcd")
        watch.follow(second)
        XCTAssertEqual(first.stopReason, .runaway)
        XCTAssertNil(second.stopReason)
        watch.follow(nil)
        watch.receive("abcd")
        XCTAssertNil(second.stopReason)
    }
}

final class CleanupBoundsTests: XCTestCase {
    func testAPassIsStoppedBeforeTheLengthThatWouldBeRejected() {
        for length in [0, 10, 80, 400, 4_000] {
            let original = String(repeating: "a", count: length)
            XCTAssertLessThanOrEqual(
                TranscriptCleanup.maximumCleanupLength(original: original),
                TranscriptCleanup.maximumAcceptedCleanupLength(original: original)
            )
            XCTAssertGreaterThan(TranscriptCleanup.maximumCleanupLength(original: original), length)
        }
    }

    func testTheAcceptanceGateStillUsesItsOwnBound() {
        let original = String(repeating: "word ", count: 40)
        let tooLong = String(repeating: "word ", count: 200)
        XCTAssertFalse(TranscriptCleanup.isUsable(tooLong, original: original))
        XCTAssertTrue(TranscriptCleanup.isUsable(original + "More.", original: original))
    }

    func testARequestedReplyMayBeginWithICant() {
        XCTAssertEqual(
            TranscriptCleanup.acceptedTransformOutput("I can't make it on Friday, sorry.", original: "Are you free on Friday?"),
            "I can't make it on Friday, sorry."
        )
        XCTAssertNil(TranscriptCleanup.acceptedTransformOutput("I can’t assist with that request.", original: "text"))
        XCTAssertNil(TranscriptCleanup.acceptedTransformOutput("As an AI, I do not edit text.", original: "text"))
    }

    func testAPlainAddressDressedAsAMarkdownLinkIsUnwrapped() {
        let original = "Check https://status.example.com/migration if anything looks off."
        XCTAssertEqual(
            TranscriptCleanup.acceptedTransformOutput(
                "Check [https://status.example.com/migration](https://status.example.com/migration) for issues.",
                original: original
            ),
            "Check https://status.example.com/migration for issues."
        )
        XCTAssertEqual(
            TranscriptCleanup.unwrappingInventedLinks(
                in: "See [status.example.com/migration](https://status.example.com/migration).", original: original
            ),
            "See https://status.example.com/migration."
        )
        // A link with real text, or one the original wrote itself, stays.
        let named = "See [the status page](https://status.example.com/migration)."
        XCTAssertEqual(TranscriptCleanup.unwrappingInventedLinks(in: named, original: original), named)
        let own = "See [https://a.example](https://a.example)."
        XCTAssertEqual(TranscriptCleanup.unwrappingInventedLinks(in: own, original: own), own)
    }

    func testRefusalOpeningsAreComparedWithoutCaseOrCurlyQuotes() {
        XCTAssertEqual(TranscriptCleanup.normalizedForRefusal("  \nI’m sorry, I cannot"), "i'm sorry, i cannot")
    }
}

@MainActor
final class CleanupPipelineSpeedTests: XCTestCase {
    private func options(
        _ cleaner: MockTranscriptCleanup, profile: WritingProfile = WritingProfile(format: .plain, rules: .passthrough),
        model: CleanupModelKind = .qwen25_0_5b_q4_k_m, level: CleanupLevel = .medium, skip: Bool = true
    ) -> DictationOutputOptions {
        DictationOutputOptions(
            profile: profile, snippetList: [], cleanupEnabled: true, rewritingEnabled: false,
            model: model, customPrompt: "", cleanupLevel: level, language: "en",
            autoCapitalize: true, trailingSpace: false, skipWhenClean: skip
        )
    }

    func testACleanDictationIsPastedWithoutTheModel() async {
        let cleaner = MockTranscriptCleanup()
        cleaner.cleanHandler = { _ in "Changed." }
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())

        let result = await pipeline.process("The build passed, and I will merge it.", options: options(cleaner))

        XCTAssertEqual(result.text, "The build passed, and I will merge it.")
        XCTAssertEqual(result.summary, DictationOutputPipeline.alreadyCleanSummary)
        XCTAssertEqual(cleaner.cleanCallCount, 0)
        XCTAssertEqual(cleaner.loadCallCount, 0)
    }

    func testTheModelStillRunsWhenThereIsSomethingToClean() async {
        let cleaner = MockTranscriptCleanup()
        cleaner.cleanHandler = { _ in "It was really late." }
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())

        let result = await pipeline.process("It was like really late.", options: options(cleaner))

        XCTAssertEqual(cleaner.cleanCallCount, 1)
        XCTAssertNotEqual(result.summary, DictationOutputPipeline.alreadyCleanSummary)
    }

    func testSkippingCanBeTurnedOff() async {
        let cleaner = MockTranscriptCleanup()
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())

        _ = await pipeline.process("The build passed, and I will merge it.", options: options(cleaner, skip: false))

        XCTAssertEqual(cleaner.cleanCallCount, 1)
    }

    func testAPromptTheUserWroteIsAlwaysGivenTheText() async {
        // Only the user knows what their prompt asks for; text that looks
        // clean to VocaMac may be exactly what it is meant to change.
        let global = MockTranscriptCleanup()
        let pipeline = DictationOutputPipeline(cleaner: global, snippets: SnippetExpander())
        var custom = options(global)
        custom.customPrompt = "Rewrite every sentence in British spelling."
        _ = await pipeline.process("The build passed, and I will merge it.", options: custom)
        XCTAssertEqual(global.cleanCallCount, 1)

        let perApp = MockTranscriptCleanup()
        let perAppPipeline = DictationOutputPipeline(cleaner: perApp, snippets: SnippetExpander())
        let profile = WritingProfile(format: .plain, rules: .passthrough, cleanupPrompt: "Expand every acronym.")
        _ = await perAppPipeline.process("The build passed, and I will merge it.", options: options(perApp, profile: profile))
        XCTAssertEqual(perApp.cleanCallCount, 1)
    }

    func testTheBuiltInPromptCountsHoweverItIsStored() {
        let cleaner = MockTranscriptCleanup()
        var stored = options(cleaner)
        XCTAssertTrue(DictationOutputPipeline.usesBuiltInCleanupPrompt(stored))
        stored.customPrompt = TranscriptCleanup.defaultPrompt + "\n"
        XCTAssertTrue(DictationOutputPipeline.usesBuiltInCleanupPrompt(stored))
        stored.profile.cleanupPrompt = "   "
        XCTAssertTrue(DictationOutputPipeline.usesBuiltInCleanupPrompt(stored))
        stored.profile.cleanupPrompt = "Mine."
        XCTAssertFalse(DictationOutputPipeline.usesBuiltInCleanupPrompt(stored))
    }

    func testCodeAndTerminalSkipWhateverTheUsersPromptSays() async {
        // They always use their own fixed prompt, so a custom one changes
        // nothing about what the model would be asked there.
        let cleaner = MockTranscriptCleanup()
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
        var terminal = options(cleaner, profile: WritingProfile(format: .terminal, rules: .passthrough))
        terminal.customPrompt = "Rewrite every sentence in British spelling."

        _ = await pipeline.process("git status and then run the tests", options: terminal)

        XCTAssertEqual(cleaner.cleanCallCount, 0)
    }

    func testOneCleanPieceStillGoesToAPromptTheUserWrote() async {
        let cleaner = MockTranscriptCleanup()
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
        var custom = options(cleaner)
        custom.customPrompt = "Rewrite every sentence in British spelling."
        let pieces = [
            TranscribedPiece(range: 0..<16_000, text: "The build passed.", language: "en"),
            TranscribedPiece(range: 16_000..<32_000, text: "It was, like, really late.", language: "en"),
        ]

        _ = await pipeline.process(TranscribedPiece.join(pieces.map(\.text)), options: custom, pieces: pieces)

        XCTAssertEqual(cleaner.cleanCallCount, 2)
    }

    func testRewordingStylesAlwaysAskTheModel() async {
        let cleaner = MockTranscriptCleanup()
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
        var formal = options(cleaner, profile: WritingProfile(format: .email, rules: .passthrough, intent: .professional))
        formal.rewritingEnabled = true

        _ = await pipeline.process("The build passed, and I will merge it.", options: formal)

        XCTAssertEqual(cleaner.cleanCallCount, 1)
    }

    func testACleanPieceIsNotRequestedAheadOfTime() async {
        let cleaner = MockTranscriptCleanup()
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())

        let clean = await pipeline.cleanupRequest(for: "The build passed.", options: options(cleaner))
        let dirty = await pipeline.cleanupRequest(for: "the build like passed", options: options(cleaner))

        XCTAssertNil(clean)
        XCTAssertNotNil(dirty)
    }

    func testOnlyTheUncleanPartsOfALongDictationReachTheModel() async {
        let cleaner = MockTranscriptCleanup()
        cleaner.cleanHandler = { $0.replacingOccurrences(of: "like, ", with: "") }
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
        let pieces = [
            TranscribedPiece(range: 0..<16_000, text: "The build passed.", language: "en"),
            TranscribedPiece(range: 16_000..<32_000, text: "It was, like, really late.", language: "en"),
        ]
        let original = TranscribedPiece.join(pieces.map(\.text))

        let result = await pipeline.process(original, options: options(cleaner), pieces: pieces)

        XCTAssertEqual(cleaner.cleanCallCount, 1)
        XCTAssertEqual(cleaner.lastCleanedText, "It was, like, really late.")
        XCTAssertTrue(result.text.hasPrefix("The build passed."))
    }

    func testTheExpectedPromptIsTheOneADictationSends() async {
        let cleaner = MockTranscriptCleanup()
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
        let prose = options(cleaner)
        let terminal = options(cleaner, profile: WritingProfile(format: .terminal, rules: .passthrough))

        _ = await pipeline.process("it was like really late", options: prose)
        XCTAssertEqual(pipeline.expectedPrompt(options: prose), cleaner.lastPrompt)
        XCTAssertEqual(pipeline.expectedPrompt(options: terminal), RewriteValidation.technicalPrompt)
    }

    func testNoPromptIsExpectedWhenTheModelWillNotBeAsked() {
        let cleaner = MockTranscriptCleanup()
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
        var off = options(cleaner)
        off.cleanupEnabled = false
        XCTAssertNil(pipeline.expectedPrompt(options: off))
        XCTAssertNil(pipeline.expectedPrompt(options: options(cleaner, level: .none)))
        XCTAssertNil(pipeline.expectedPrompt(options: options(
            cleaner, profile: WritingProfile(format: .plain, rules: .passthrough, cleanup: .raw)
        )))
        cleaner.downloadedKinds = []
        XCTAssertNil(pipeline.expectedPrompt(options: options(cleaner)))
    }

    func testWarmingUpLoadsTheModelAndReadsItsPrompt() async {
        let cleaner = MockTranscriptCleanup()
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
        let prose = options(cleaner)

        await pipeline.warmUp(options: prose)

        XCTAssertEqual(cleaner.loadedKind, .qwen25_0_5b_q4_k_m)
        XCTAssertEqual(cleaner.primedPrompts, [pipeline.expectedPrompt(options: prose)])
    }

    func testWarmingUpDoesNothingWhenCleanupIsOff() async {
        let cleaner = MockTranscriptCleanup()
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
        var off = options(cleaner)
        off.cleanupEnabled = false

        await pipeline.warmUp(options: off)

        XCTAssertEqual(cleaner.loadCallCount, 0)
        XCTAssertTrue(cleaner.primedPrompts.isEmpty)
    }

    func testASmallerModelStandsInWhenTheSelectedOneDoesNotFit() async {
        let cleaner = MockTranscriptCleanup()
        cleaner.memoryRefusedKinds = [.ministral3_3b_q4_k_m]
        cleaner.memoryFallbackKind = .qwen25_1_5b_q4_k_m
        cleaner.cleanHandler = { _ in "It was really late." }
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())

        let result = await pipeline.process(
            "it was really late", options: options(cleaner, model: .ministral3_3b_q4_k_m)
        )

        XCTAssertEqual(cleaner.loadRequests, [.ministral3_3b_q4_k_m, .qwen25_1_5b_q4_k_m])
        XCTAssertEqual(cleaner.loadedKind, .qwen25_1_5b_q4_k_m)
        XCTAssertEqual(cleaner.cleanCallCount, 1)
        XCTAssertEqual(result.text, "It was really late.")
        XCTAssertTrue(result.summary.contains("Qwen 2.5 1.5B stood in"))
        XCTAssertTrue(result.summary.contains("Ministral 3 3B Instruct"))
    }

    func testCleanupIsSkippedWhenNothingSmallerFits() async {
        let cleaner = MockTranscriptCleanup()
        cleaner.memoryRefusedKinds = [.ministral3_3b_q4_k_m]
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())

        let result = await pipeline.process(
            "It was like really late.", options: options(cleaner, model: .ministral3_3b_q4_k_m)
        )

        XCTAssertEqual(cleaner.cleanCallCount, 0)
        XCTAssertTrue(result.summary.contains("model could not load"))
    }
}

@MainActor
final class CleanupServiceFallbackTests: XCTestCase {
    private func service(downloaded: [CleanupModelKind]) throws -> TranscriptCleanupService {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocaMac-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        // Sparse files of the catalog's size pass the "is it downloaded" check
        // without holding a model; nothing here gets as far as loading one.
        for kind in downloaded {
            let url = directory.appendingPathComponent(kind.descriptor.fileName)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(kind.descriptor.expectedByteCount))
            try handle.close()
        }
        return TranscriptCleanupService(modelsDirectory: directory)
    }

    func testTheLargestSmallerModelThatFitsStandsIn() async throws {
        let service = try service(downloaded: [.ministral3_3b_q4_k_m, .qwen25_1_5b_q4_k_m, .qwen25_0_5b_q4_k_m])
        service.modelFitsInMemory = { descriptor, _ in descriptor.kind != .ministral3_3b_q4_k_m }

        XCTAssertNil(service.memoryFallback(for: .ministral3_3b_q4_k_m), "nothing has been refused yet")
        await service.load(.ministral3_3b_q4_k_m)

        XCTAssertEqual(service.memoryFallback(for: .ministral3_3b_q4_k_m), .qwen25_1_5b_q4_k_m)
        // Only the model that was refused gets a stand-in.
        XCTAssertNil(service.memoryFallback(for: .qwen25_1_5b_q4_k_m))
    }

    func testNoStandInWhenNothingSmallerIsDownloadedOrFits() async throws {
        let alone = try service(downloaded: [.ministral3_3b_q4_k_m])
        alone.modelFitsInMemory = { _, _ in false }
        await alone.load(.ministral3_3b_q4_k_m)
        XCTAssertNil(alone.memoryFallback(for: .ministral3_3b_q4_k_m))

        let tight = try service(downloaded: [.ministral3_3b_q4_k_m, .qwen25_0_5b_q4_k_m])
        tight.modelFitsInMemory = { _, _ in false }
        await tight.load(.ministral3_3b_q4_k_m)
        XCTAssertNil(tight.memoryFallback(for: .ministral3_3b_q4_k_m))
    }

    func testReadingAheadWithoutAModelDoesNothing() async throws {
        let service = try service(downloaded: [])
        await service.prime(prompt: "anything")
        XCTAssertFalse(service.isLoaded)
    }
}
