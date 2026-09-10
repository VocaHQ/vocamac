// DictionaryCorrectorTests.swift
// VocaMac

import XCTest
@testable import VocaMac

final class DictionaryCorrectorTests: XCTestCase {

    private func correct(
        _ text: String,
        vocabulary: [String] = [],
        replacements: [WordReplacement] = [],
        context: [String] = [],
        identifierJoins: Bool = false
    ) -> DictionaryCorrection {
        DictionaryCorrector.correct(
            text,
            context: DictionaryContext(
                vocabulary: vocabulary,
                replacements: replacements,
                contextTerms: context,
                isKnownWord: { TestWords.common.contains($0.lowercased()) }
            ),
            allowIdentifierJoins: identifierJoins
        )
    }

    // MARK: Replacements

    func testReplacementIgnoresCaseAndUsesUserSpelling() {
        let result = correct("Push it to get hub please", replacements: [
            WordReplacement(heard: "get hub", replacement: "GitHub"),
        ])
        XCTAssertEqual(result.text, "Push it to GitHub please")
        XCTAssertEqual(result.protectedTerms, ["GitHub"])
        XCTAssertEqual(result.changes, [.init(from: "get hub", to: "GitHub")])
    }

    func testReplacementMatchesWholeWordsOnly() {
        let result = correct("the cattle and the cat", replacements: [
            WordReplacement(heard: "cat", replacement: "Kat"),
        ])
        XCTAssertEqual(result.text, "the cattle and the Kat")
    }

    func testReplacementAcceptsSeveralSpokenForms() {
        let replacement = WordReplacement(heard: "cube cuttle, cube control", replacement: "kubectl")
        XCTAssertEqual(correct("run cube cuttle then Cube Control", replacements: [replacement]).text,
                       "run kubectl then kubectl")
    }

    func testLongerSpokenFormWins() {
        let result = correct("open ai studio", replacements: [
            WordReplacement(heard: "open ai", replacement: "OpenAI"),
            WordReplacement(heard: "open ai studio", replacement: "AI Studio"),
        ])
        XCTAssertEqual(result.text, "AI Studio")
    }

    // MARK: Vocabulary

    func testVocabularyFixesCasingAndJoinsWords() {
        XCTAssertEqual(correct("I love voca mac and github", vocabulary: ["VocaMac", "GitHub"]).text,
                       "I love VocaMac and GitHub")
    }

    func testVocabularyDoesNotJoinAcrossPunctuation() {
        XCTAssertEqual(correct("try voca. mac", vocabulary: ["VocaMac"]).text, "try voca. mac")
    }

    func testFuzzyFixesAnUnknownNearMiss() {
        XCTAssertEqual(correct("ask Namratha about it", vocabulary: ["Namrata"]).text,
                       "ask Namrata about it")
    }

    func testFuzzyNeverChangesAnOrdinaryWord() {
        XCTAssertEqual(correct("the cloud is down", vocabulary: ["Claude"]).text, "the cloud is down")
    }

    func testFuzzyIgnoresShortTerms() {
        XCTAssertEqual(correct("open jiro today", vocabulary: ["Jira"]).text, "open jiro today")
    }

    func testFuzzyJoinsSeveralWordsForLongTerms() {
        XCTAssertEqual(correct("the post gress database", vocabulary: ["PostgreSQL"]).text,
                       "the PostgreSQL database")
    }

    func testFuzzyRequiresSameFirstSound() {
        XCTAssertEqual(correct("ask Tamrata about it", vocabulary: ["Namrata"]).text, "ask Tamrata about it")
    }

    // MARK: Screen context

    func testScreenIdentifiersJoinOnlyInCodeApps() {
        XCTAssertEqual(correct("set the user id value", context: ["userId"]).text, "set the user id value")
        XCTAssertEqual(correct("set the user id value", context: ["userId"], identifierJoins: true).text,
                       "set the userId value")
    }

    func testScreenNamesApplyEverywhere() {
        XCTAssertEqual(correct("send it to open ai", context: ["OpenAI"]).text, "send it to OpenAI")
    }

    func testScreenTermsAreNeverFuzzy() {
        XCTAssertEqual(correct("ask Namratha", context: ["Namrata"]).text, "ask Namratha")
    }

    func testUserVocabularyWinsOverScreenSpelling() {
        XCTAssertEqual(correct("use voca mac", vocabulary: ["VocaMac"], context: ["Vocamac"]).text,
                       "use VocaMac")
    }

    // MARK: Protection

    func testProtectionRules() {
        XCTAssertTrue(DictionaryCorrector.needsProtection("iPhone"))
        XCTAssertTrue(DictionaryCorrector.needsProtection("kubectl"))
        XCTAssertTrue(DictionaryCorrector.needsProtection("GitHub"))
        XCTAssertTrue(DictionaryCorrector.needsProtection("C++"))
        XCTAssertFalse(DictionaryCorrector.needsProtection("Namrata"))
        XCTAssertFalse(DictionaryCorrector.needsProtection("New York"))
    }

    func testUnchangedTextHasNoChanges() {
        let result = correct("nothing to see here", vocabulary: ["VocaMac"])
        XCTAssertEqual(result.text, "nothing to see here")
        XCTAssertTrue(result.changes.isEmpty)
    }

    func testLevenshtein() {
        XCTAssertEqual(DictionaryCorrector.levenshtein("kitten", "sitting"), 3)
        XCTAssertEqual(DictionaryCorrector.levenshtein("", "abc"), 3)
        XCTAssertEqual(DictionaryCorrector.levenshtein("same", "same"), 0)
    }
}

// MARK: - Pipeline

@MainActor
final class DictionaryPipelineTests: XCTestCase {

    private func run(_ text: String, format: WritingStyle = .plain, cleanup: WritingCleanupPolicy = .inherit,
                     dictionary: DictionaryContext) async -> String {
        let pipeline = DictationOutputPipeline(cleaner: MockTranscriptCleanup(), snippets: SnippetExpander())
        let profile = WritingProfile(format: format, rules: format.defaultRules, cleanup: cleanup)
        return await pipeline.process(
            text, profile: profile, snippetList: [], cleanupEnabled: false, rewritingEnabled: false,
            model: .defaultKind, customPrompt: "", language: "en", autoCapitalize: true,
            trailingSpace: false, dictionary: dictionary
        ).text
    }

    private func dictionary(vocabulary: [String] = [], replacements: [WordReplacement] = []) -> DictionaryContext {
        DictionaryContext(vocabulary: vocabulary, replacements: replacements, contextTerms: [],
                          isKnownWord: { TestWords.common.contains($0.lowercased()) })
    }

    func testTermAtSentenceStartKeepsItsCasing() async {
        let output = await run("iphone is great", dictionary: dictionary(vocabulary: ["iPhone"]))
        XCTAssertTrue(output.hasPrefix("iPhone"), output)
    }

    func testRawDictationSkipsTheDictionary() async {
        let output = await run("get hub", cleanup: .raw,
                               dictionary: dictionary(replacements: [WordReplacement(heard: "get hub", replacement: "GitHub")]))
        XCTAssertEqual(output, "get hub")
    }
}
