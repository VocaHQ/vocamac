import XCTest
@testable import VocaMac

final class CodingAgentDetectorTests: XCTestCase {
    private typealias Tab = CodingAgentDetector.Tab

    func testAgentsAreKnownByTheirCommandNotTheirProcessName() {
        // Claude Code's process is named for its version; argv[0] is "claude".
        XCTAssertTrue(CodingAgentDetector.namesAgent(["2.1.311", "claude"]))
        XCTAssertTrue(CodingAgentDetector.namesAgent(["node", "node_modules", "@google", "gemini-cli", "dist", "index"]))
        XCTAssertTrue(CodingAgentDetector.namesAgent(["Codex"]))
        XCTAssertFalse(CodingAgentDetector.namesAgent(["zsh", "-zsh"]))
        XCTAssertFalse(CodingAgentDetector.namesAgent(["vim", "claude-notes"]))
    }

    func testEveryTabRunningAnAgentIsEnough() {
        let agent = Tab(foregroundNames: ["2.1.311", "claude"])
        XCTAssertTrue(CodingAgentDetector.isAgentInFront(tabs: [agent, agent], windowTitle: nil))
        XCTAssertFalse(CodingAgentDetector.isAgentInFront(tabs: [Tab(foregroundNames: ["zsh"])], windowTitle: "✳ Fix it"))
        XCTAssertFalse(CodingAgentDetector.isAgentInFront(tabs: [], windowTitle: "claude"))
    }

    func testWithAShellInAnotherTabTheTitleDecides() {
        let tabs = [Tab(foregroundNames: ["claude"]), Tab(foregroundNames: ["zsh"])]
        // Claude Code titles its tab with a status glyph and its task.
        XCTAssertTrue(CodingAgentDetector.isAgentInFront(tabs: tabs, windowTitle: "◑ VocaMac issue 389 cleanup"))
        XCTAssertTrue(CodingAgentDetector.isAgentInFront(tabs: tabs, windowTitle: "✳ Claude Code"))
        XCTAssertTrue(CodingAgentDetector.isAgentInFront(tabs: tabs, windowTitle: "codex — ~/src/app"))
        XCTAssertFalse(CodingAgentDetector.isAgentInFront(tabs: tabs, windowTitle: "kanishk@mac: ~/src/app"))
        XCTAssertFalse(CodingAgentDetector.isAgentInFront(tabs: tabs, windowTitle: nil))
        XCTAssertFalse(CodingAgentDetector.isAgentInFront(tabs: [Tab(foregroundNames: nil), Tab(foregroundNames: ["zsh"])],
                                                          windowTitle: "✳ task"))
    }
}

final class CodingAgentStyleTests: XCTestCase {
    private func terminal(_ change: (inout ResolvedWritingStyle) -> Void = { _ in }) -> ResolvedWritingStyle {
        var resolved = ResolvedWritingStyle(
            style: .terminal, rules: WritingStyle.terminal.defaultRules, matchedAppName: "Ghostty", intent: .professional
        )
        change(&resolved)
        return resolved
    }

    func testATerminalRunningAnAgentGetsProseCleanup() {
        let prose = WritingStyleResolver.applyingCodingAgent(terminal(), detected: true)
        XCTAssertTrue(prose.codingAgent)
        XCTAssertEqual(prose.style, .terminal, "The menu still shows and binds Terminal")
        XCTAssertEqual(prose.displayName, "Terminal · coding agent")
        XCTAssertEqual(prose.profile.format, .plain)
        XCTAssertTrue(prose.profile.format.supportsWording)
        XCTAssertEqual(prose.profile.intent, .preserve, "An instruction isn't reworded to sound Formal")
        XCTAssertFalse(WritingStyleResolver.applyingCodingAgent(terminal(), detected: false).codingAgent)
    }

    func testARuleTheUserShapedKeepsItsBehaviour() {
        let custom: [ResolvedWritingStyle] = [
            terminal { $0.cleanup = .off },
            terminal { $0.cleanup = .raw },
            terminal { $0.cleanupLevel = .light },
            terminal { $0.cleanupPrompt = "Only remove um" },
            terminal { $0 = ResolvedWritingStyle(style: .terminal, rules: .passthrough, matchedAppName: "Ghostty") },
            ResolvedWritingStyle(style: .code, rules: WritingStyle.code.defaultRules, matchedAppName: "Xcode"),
        ]
        for resolved in custom {
            XCTAssertEqual(WritingStyleResolver.applyingCodingAgent(resolved, detected: true), resolved)
        }
        // An empty prompt is no prompt.
        XCTAssertTrue(WritingStyleResolver.applyingCodingAgent(terminal { $0.cleanupPrompt = "  " }, detected: true).codingAgent)
    }

    @MainActor
    func testProseToAnAgentKeepsItsPeriod() async {
        let cleaner = MockTranscriptCleanup()
        func type(_ resolved: ResolvedWritingStyle) async -> String {
            await DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander()).process(
                "can you fix the failing test in auth service.", profile: resolved.profile, snippetList: [],
                cleanupEnabled: false, rewritingEnabled: false, model: .defaultKind, customPrompt: "",
                language: "en", autoCapitalize: true, trailingSpace: false
            ).text
        }
        let shell = await type(terminal())
        let agent = await type(WritingStyleResolver.applyingCodingAgent(terminal(), detected: true))
        XCTAssertFalse(shell.hasSuffix("."), shell)
        XCTAssertEqual(agent, "Can you fix the failing test in auth service.")
    }

    @MainActor
    func testRecordingWarmsTheProsePromptForAnAgent() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.transcriptCleanupEnabled = true
        let ghostty = RunningAppSnapshot(displayName: "Ghostty", bundleIdentifier: "com.mitchellh.ghostty", processName: "ghostty")
        appState.writingStyleBindings = [AppStyleBinding.from(snapshot: ghostty, style: .terminal)]
        await appState.warmCleanupModel(for: ghostty)
        await appState.warmCleanupModel(for: ghostty, codingAgentTerminal: ghostty)
        XCTAssertEqual(mocks.transcriptCleanup.primedPrompts.first, RewriteValidation.technicalPrompt)
        XCTAssertNotEqual(mocks.transcriptCleanup.primedPrompts.last, RewriteValidation.technicalPrompt,
                          "An agent's terminal cleans up prose, so that prompt is the one read ahead")
    }

    @MainActor
    func testTheAgentMustRunInTheAppTheTextGoesTo() {
        let (appState, _) = AppState.makeTestState()
        appState.codingAgentsAsProse = true
        defer { appState.codingAgentsAsProse = true }
        let ghostty = RunningAppSnapshot(displayName: "Ghostty", bundleIdentifier: "com.mitchellh.ghostty", processName: "ghostty")
        let iterm = RunningAppSnapshot(displayName: "iTerm2", bundleIdentifier: "com.googlecode.iterm2")
        appState.writingStyleBindings = [
            AppStyleBinding.from(snapshot: ghostty, style: .terminal), AppStyleBinding.from(snapshot: iterm, style: .terminal),
        ]
        XCTAssertTrue(appState.resolveWritingStyle(for: ghostty, codingAgentTerminal: ghostty).codingAgent)
        XCTAssertFalse(appState.resolveWritingStyle(for: iterm, codingAgentTerminal: ghostty).codingAgent)
        XCTAssertFalse(appState.resolveWritingStyle(for: ghostty).codingAgent)
        appState.codingAgentsAsProse = false
        XCTAssertFalse(appState.resolveWritingStyle(for: ghostty, codingAgentTerminal: ghostty).codingAgent)
    }
}

final class TermSuggestionFinderTests: XCTestCase {
    func testScreenTermsThatReplacedWhatWasHeard() {
        let found = TermSuggestionFinder.screenRespellings(
            raw: "did you join the django nots call and fix the user id bug",
            final: "Did you join the Djangonauts call and fix the userId bug?",
            terms: ["Djangonauts", "userId", "GitHub"]
        )
        XCTAssertEqual(found.map(\.heard), ["django nots", "user id"])
        XCTAssertEqual(found.map(\.term), ["Djangonauts", "userId"])
        // A term that was heard right, or a change that isn't a term, isn't one.
        XCTAssertTrue(TermSuggestionFinder.screenRespellings(
            raw: "push it to GitHub", final: "Push it to GitHub.", terms: ["GitHub"]
        ).isEmpty)
        // Only the casing changed, with no spacing change.
        let cased = TermSuggestionFinder.screenRespellings(
            raw: "fix the userid bug", final: "Fix the userId bug.", terms: ["userId"]
        )
        XCTAssertEqual(cased.map(\.heard), ["userid"])
        XCTAssertEqual(cased.map(\.term), ["userId"])
        XCTAssertTrue(TermSuggestionFinder.screenRespellings(
            raw: "send it today", final: "Send it tomorrow.", terms: ["GitHub"]
        ).isEmpty)
    }

    func testOnlyTheMostRecentDictationsAreScanned() {
        // Newest first, as History keeps them: a name only in the newest
        // dictations is found even past the limit.
        let recent = Array(repeating: "Ask Djangonaut Priyanka about it", count: 3)
        let old = Array(repeating: "Ask Oldname about it", count: TermSuggestionFinder.maximumDictations)
        let candidates = TermSuggestionFinder.capitalizedCandidates(in: recent + old).map(\.term)
        XCTAssertTrue(candidates.contains("Priyanka"))
        XCTAssertTrue(candidates.contains("Oldname"), "Still within the most recent \(TermSuggestionFinder.maximumDictations)")
        let pastLimit = TermSuggestionFinder.capitalizedCandidates(
            in: recent + old + Array(repeating: "Ask Ancient about it", count: 5)
        ).map(\.term)
        XCTAssertFalse(pastLimit.contains("Ancient"))
    }

    func testNamesSaidInSeveralDictations() {
        let texts = [
            "Ask Greptile to review it", "Greptile found two bugs", "Thanks Sergey, Greptile is happy",
            "Hey Sergey", "Voca Mac is out", "Try Voca Mac", "Voca Mac nightly", "Hey there",
        ]
        let candidates = TermSuggestionFinder.capitalizedCandidates(in: texts)
        let known: Set<String> = ["ask", "hey", "thanks", "try", "mac", "there"]
        let names = TermSuggestionFinder.unknownNames(candidates, vocabulary: ["sergey"]) { known.contains($0) }
        // Hey: a word. Sergey: listed. Voca Mac: Mac is a word, but Voca isn't.
        XCTAssertEqual(names, ["Greptile", "Voca"])
        let pairs = TermSuggestionFinder.unknownNames(
            TermSuggestionFinder.capitalizedCandidates(in: ["Voca Phone a", "Voca Phone b", "Voca Phone c"]),
            vocabulary: []
        ) { _ in false }
        XCTAssertEqual(pairs, ["Voca Phone"], "The pair covers its words")
        XCTAssertTrue(TermSuggestionFinder.capitalizedCandidates(in: ["Greptile", "Greptile"]).isEmpty, "Two is too few")
    }
}

@MainActor
final class SuggestedTermsAppStateTests: XCTestCase {
    func testAScreenRespellingIsSuggestedTheSecondTime() {
        let (appState, _) = AppState.makeTestState()
        appState.learnCorrectionsMode = .suggest
        TestDefaults.store.removeObject(forKey: PreferenceKey.screenRespellingCounts)
        defer { TestDefaults.store.removeObject(forKey: PreferenceKey.screenRespellingCounts) }
        func dictate() {
            appState.noteScreenRespellings(raw: "the django nots call", final: "The Djangonauts call.",
                                           screenTerms: ["Djangonauts"], language: "en")
        }
        dictate()
        XCTAssertTrue(appState.dictionarySuggestions.isEmpty)
        dictate()
        XCTAssertEqual(appState.dictionarySuggestions.first?.corrected, "Djangonauts")
        XCTAssertEqual(appState.dictionarySuggestions.first?.source, .screen)

        appState.learnCorrectionsMode = .off
        appState.noteScreenRespellings(raw: "voca mac", final: "VocaMac", screenTerms: ["VocaMac"], language: "en")
        appState.noteScreenRespellings(raw: "voca mac", final: "VocaMac", screenTerms: ["VocaMac"], language: "en")
        XCTAssertEqual(appState.dictionarySuggestions.count, 1)
    }

    func testAcceptingANameSaidOftenAddsTheTermOnly() throws {
        let (appState, _) = AppState.makeTestState()
        appState.learnCorrectionsMode = .suggest
        appState._receiveCorrectionsForTesting([.init(heard: "Greptile", corrected: "Greptile", language: "en", source: .frequent)])
        let suggestion = try XCTUnwrap(appState.dictionarySuggestions.first)
        XCTAssertEqual(suggestion.source, .frequent)
        appState.acceptDictionarySuggestion(suggestion)
        XCTAssertEqual(appState.vocabularyTerms, ["Greptile"])
        XCTAssertTrue(appState.wordReplacements.isEmpty)
    }

    func testOldSuggestionsStillDecode() throws {
        let json = #"[{"heard":"github","corrected":"GitHub","occurrences":2,"lastSeen":0}]"#
        let decoded = try JSONDecoder().decode([CorrectionSuggestion].self, from: Data(json.utf8))
        XCTAssertNil(decoded.first?.source)
    }
}
