// ChangeOfMindResolverTests.swift
// VocaMac

import XCTest
@testable import VocaMac

/// The rules run in every prose app with no model and no setting, so a false
/// positive deletes words the user meant. Every resolved case below has a
/// look-alike that must stay as spoken.
final class ChangeOfMindResolverTests: XCTestCase {

    /// The typed resolver and then the shape resolver, as the pipeline runs them.
    private func resolve(_ text: String, english: Bool = true) -> String {
        ChangeOfMindResolver.resolve(SpokenCorrectionResolver.resolve(text), matchesWordClasses: english)
    }

    private func assertResolves(_ cases: [(String, String)], file: StaticString = #filePath, line: UInt = #line) {
        for (input, expected) in cases {
            XCTAssertEqual(resolve(input), expected, input, file: file, line: line)
        }
    }

    private func assertUnchanged(_ texts: [String], file: StaticString = #filePath, line: UInt = #line) {
        for text in texts {
            XCTAssertEqual(resolve(text), text, text, file: file, line: line)
        }
    }

    // MARK: - Restarts

    func testTheRequestedExampleResolves() {
        assertResolves([
            ("let's meet tomorrow, sorry sorry not actually, let's meet yesterday", "let's meet yesterday"),
            ("Hey, let's meet tomorrow oh sorry sorry not actually let's meet yesterday",
             "Hey, let's meet yesterday"),
            ("Let's meet tomorrow, sorry, no, let's meet yesterday.", "Let's meet yesterday."),
            // Whisper often writes each part as its own sentence.
            ("Let's meet tomorrow. Sorry, sorry, not actually. Let's meet yesterday.", "Let's meet yesterday."),
        ])
    }

    func testRestartsReplaceTheClause() {
        assertResolves([
            ("I'll send the invoice Friday, no wait, I'll send it Monday", "I'll send it Monday"),
            ("deploy to staging, no actually, deploy to prod after the review", "deploy to prod after the review"),
            ("We should order pizza, sorry, no, we should order sushi tonight.", "We should order sushi tonight."),
            ("We should order pizza, oh sorry, we should order sushi tonight.", "We should order sushi tonight."),
            ("I think we should meet at the office, I mean, we should meet at the cafe",
             "I think we should meet at the cafe"),
            ("Book the flight to Paris, no no, book the train to Paris.", "Book the train to Paris."),
            ("Tell Sam the build is green, I mean, tell Sam the build is red.", "Tell Sam the build is red."),
            ("Thanks for the update. Sorry, sorry. Thanks for the fix.", "Thanks for the fix."),
        ])
    }

    func testRestartKeepsWhatCameBeforeTheClause() {
        assertResolves([
            ("Hi team. Please push the fix today, no wait, please push the fix tomorrow.",
             "Hi team. Please push the fix tomorrow."),
            ("So let's meet tomorrow, no, let's meet Friday", "So let's meet Friday"),
        ])
    }

    func testOneSharedWordIsEnoughOnlyForAContentWordAfterAStrongCue() {
        assertResolves([
            ("Send the report to finance, no wait, send it to legal", "Send it to legal"),
        ])
        assertUnchanged([
            "Call John, sorry, call me later",          // one shared word, a single cue
            "Do it, sorry, do it now",               // nothing was replaced
        ])
    }

    func testRestartsInOtherLanguages() {
        assertResolves([
            ("vamos a comer pizza, perdón, no, vamos a comer sushi", "vamos a comer sushi"),
            ("on mange à midi, je veux dire, on mange à treize heures", "on mange à treize heures"),
            ("wir treffen uns im Büro, ich meine, wir treffen uns im Café", "wir treffen uns im Café"),
        ])
    }

    // MARK: - Shared frames

    func testSameFirstWordSwapsThePhrase() {
        assertResolves([
            ("I want the blue one, I mean, the red one", "I want the red one"),
            ("put it on the left shelf, no wait, the top shelf", "put it on the top shelf"),
        ])
    }

    func testSameLastWordSwapsThePhrase() {
        assertResolves([
            ("Wear the blue shirt, no, red shirt today.", "Wear the red shirt today."),
            ("The budget is five thousand, no, six thousand dollars.", "The budget is six thousand dollars."),
        ])
    }

    func testOneNameOrNounForAnother() {
        assertResolves([
            ("Send it to John, no wait, Mary.", "Send it to Mary."),
            ("send it to John, no, Mary", "send it to Mary"),
            ("Call mom, sorry, dad.", "Call dad."),
            ("I'll have the salad, no, soup.", "I'll have the soup."),
            ("Make the banner blue, I mean, green.", "Make the banner green."),
        ])
    }

    func testSingleWordSwapsNeedTheSameKindOfWord() {
        assertUnchanged([
            "I'll do it, no, really",               // adverb for pronoun
            "Thank you, no, really.",
            "Let's go home, no, seriously.",
            "I want pizza, no, really.",
            "Yes, no, maybe.",
            "Send it to John, no, Mary will do it.", // the replacement runs on
            "Send it to the old team lead, no wait, Mary.", // "lead" ends a longer phrase
            "Ping John Smith, no, Mary.",
            "Coffee beans, no, tea.",
        ])
    }

    func testWordClassSwapsAreEnglishOnly() {
        XCTAssertEqual(resolve("I'll have the salad, no, soup.", english: false), "I'll have the salad, no, soup.")
        // Names are names in any language.
        XCTAssertEqual(resolve("Send it to John, no wait, Mary.", english: false), "Send it to Mary.")
    }

    // MARK: - Cancellation

    func testScratchThatDropsTheSentenceItEnds() {
        assertResolves([
            ("Send it to Alice, scratch that, send it to Jordan.", "Send it to Jordan."),
            ("Hey Alice I have an email. Scratch that, this email is for Jordan.", "This email is for Jordan."),
            ("Hi Bob. The meeting is at noon, no, scratch that.", "Hi Bob."),
            ("Hi Bob. Let me start over. Hi Robert, welcome.", "Hi Robert, welcome."),
        ])
    }

    func testScratchThatAsOrdinaryWordsStays() {
        assertUnchanged([
            "I need to scratch that itch",
            "Scratch that off the list.",           // nothing before it to cancel
            "Strike that pose for the camera",
            "Take a photo. Strike that pose.",       // runs on into ordinary words
            "Scratch that itch. Then sleep.",
        ])
    }

    func testCancellationNeverCrossesALineBreak() {
        assertUnchanged(["Groceries\nScratch that, pick up milk"])
    }

    // MARK: - Look-alikes

    func testOrdinarySpeechStaysAsSpoken() {
        assertUnchanged([
            "Sorry, I missed your call. Actually, I think Monday works.",
            "I was actually thrilled with the result",
            "No, I don't think so.",
            "Sorry I'm late, I was stuck in traffic.",
            "Wait, what did you say?",
            "I mean it, this is the best one.",
            "That's great, I mean, that's really great.",
            "No no no, that's fine.",
            "Oh no, the build broke again.",
            "We could go to Paris, actually, we could go to Rome too.",
            "I love it, actually, I love all of them too.",
            "Let's go, sorry, let's go",            // nothing was replaced
            "Thanks for the update. Sorry, sorry. Thanks for the quick update.",
            "Rather than wait, let's ship it.",
            "I'd rather stay home tonight.",
        ])
    }

    func testAnswersAndNegationsStay() {
        assertUnchanged([
            "Should we meet tomorrow? No, let's meet Friday.",
            "Are you coming tomorrow? No, Wednesday.",
            "I can't do Monday, no, I can do Tuesday",
            "I don't like the red one, no wait, I like the blue one",
        ])
    }

    func testANegationTheSpeakerRepeatsStillResolves() {
        assertResolves([
            ("I don't want the red one, no wait, I don't want the blue one",
             "I don't want the blue one"),
        ])
    }

    func testCorrectionsNeverCrossALineOrASentence() {
        assertUnchanged([
            "let's meet tomorrow\nsorry, let's meet yesterday",
            "We need 2. Sorry, 3 of us can't make it.",
        ])
    }

    /// What Parakeet and Apple Speech actually wrote for spoken corrections
    /// (synthesized speech with pauses): the pause before a cue becomes a
    /// full stop.
    func testEngineOutputWithAFullStopBeforeTheCue() {
        assertResolves([
            ("Let's meet tomorrow. Oh sorry sorry, not actually. Let's meet yesterday.", "Let's meet yesterday."),
            ("Let's meet tomorrow. Oh, sorry, sorry. Not actually. Let's meet yesterday.", "Let's meet yesterday."),
            ("I'll send the invoice Friday. No wait, I'll send it Monday.", "I'll send it Monday."),
            ("I'll send the invoice Friday. No, wait. I'll send it Monday.", "I'll send it Monday."),
            ("Send it to John. No, wait, Mary", "Send it to Mary"),
            ("Send it to John. No wait, Mary.", "Send it to Mary."),
            ("I want the blue one. I mean, the red one.", "I want the red one."),
            ("Hey Alice, I have an email. Scratch that. This email is for Jordan", "This email is for Jordan"),
            ("Let's meet tomorrow. Sorry, actually yesterday.", "Let's meet yesterday."),
            ("Let's meet tomorrow. No. Let's meet Friday.", "Let's meet Friday."),
            ("Meet me at 2. Actually 3.", "Meet me at 3."),
        ])
        assertUnchanged([
            "Sorry, I missed your call. Actually, I think Monday works.",
            "I met John. No, Mary was there too.",
            "We need 2. Sorry, 3 of us can't make it.",
            "Thanks for the help. Actually, thanks for everything.",
            "Deploy to staging. Actually, deploy to prod after the review",   // a lone "actually"
            "Let's meet tomorrow. Sorry. Let's meet Friday.",
            "I'll be late today. Sorry, I'll be there by ten.",               // an apology
            "I'll be late, sorry, I'll be there at ten.",
            "I love you. No. I love you more.",
            "It works on my machine. Sorry, it works on staging too.",
            "Is it John? No, Mary.",
            "We meet Monday, not actually Tuesday.", // a lone "not actually" denies
            "I want the blue one, I mean, the red one too.",
            "Send it to [John], no wait, Mary.",      // never splits a bracket
            "He said \"stop\", no wait, \"go\".",
        ])
    }

    func testAQuoteOrBracketTheEditDoesNotCrossStays() {
        assertResolves([
            ("Send it to [the team], no wait, Mary.", "Send it to [the team], no wait, Mary."),
            ("Tag it (draft), sorry, no, tag it final.", "Tag it (draft), sorry, no, tag it final."),
            ("Send it to John, no wait, [Mary].", "Send it to John, no wait, [Mary]."),
        ])
    }

    func testSettingsExampleResolves() {
        assertResolves([("let's meet tomorrow, sorry, no, let's meet Friday", "let's meet Friday")])
    }

    func testSeveralCorrectionsInOneDictation() {
        assertResolves([
            ("Send it to John, no, Mary. Let's meet at the office, sorry, no, let's meet at the cafe.",
             "Send it to Mary. Let's meet at the cafe."),
        ])
    }

    // MARK: - Typed values with cue chains

    func testTypedValuesAcceptChainsOfCues() {
        assertResolves([
            ("let's meet tomorrow, sorry, actually yesterday", "let's meet yesterday"),
            ("call me at 5, sorry sorry not actually, 6 pm", "call me at 6 pm"),
            ("see you Monday, oh sorry, no, Tuesday", "see you Tuesday"),
        ])
        // "not actually" alone denies; it doesn't correct.
        XCTAssertEqual(SpokenCorrectionResolver.resolve("It's Monday not actually Tuesday"),
                       "It's Monday not actually Tuesday")
    }

    // MARK: - Pipeline

    @MainActor
    private func run(_ text: String, format: WritingStyle = .plain, level: CleanupLevel = .medium) async -> DictationOutputResult {
        let cleaner = MockTranscriptCleanup()
        cleaner.cleanHandler = { _ in XCTFail("the rules need no model"); return "" }
        return await DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander()).process(
            text,
            options: DictationOutputOptions(
                profile: WritingProfile(format: format, rules: .passthrough), snippetList: [],
                cleanupEnabled: false, rewritingEnabled: false, model: .defaultKind, customPrompt: "",
                cleanupLevel: level, language: "en", autoCapitalize: false, trailingSpace: false
            )
        )
    }

    @MainActor
    func testPipelineResolvesAtMediumWithoutAModel() async {
        let result = await run("let's meet tomorrow, sorry sorry not actually, let's meet yesterday")
        XCTAssertEqual(result.text, "let's meet yesterday")
        XCTAssertTrue(result.summary.contains("spoken correction applied"), result.summary)
    }

    @MainActor
    func testPipelineLeavesLightCodeAndTerminalAlone() async {
        let text = "let's meet tomorrow, sorry, let's meet yesterday"
        let light = await run(text, level: .light)
        XCTAssertEqual(light.text, text)
        for format in [WritingStyle.code, .terminal] {
            let result = await run(text, format: format)
            XCTAssertTrue(result.text.contains("tomorrow"), "\(format): \(result.text)")
        }
    }
}
