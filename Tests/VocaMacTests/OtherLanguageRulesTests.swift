// OtherLanguageRulesTests.swift
// VocaMac

import XCTest
@testable import VocaMac

/// Repeated phrases and cut-off words outside English: only the parts that
/// need no English word list.
final class OtherLanguageRulesTests: XCTestCase {

    // MARK: - Repeated phrases

    func testAPhraseSaidTwiceGoesInAnyLanguage() {
        let cases: [(String, String)] = [
            ("vamos a vamos a comer mañana", "vamos a comer mañana"),
            ("on peut on peut le faire demain", "on peut le faire demain"),
            ("ich glaube ich glaube das stimmt", "ich glaube das stimmt"),
            ("eu acho que eu acho que sim", "eu acho que sim"),
            ("mujhe lagta hai mujhe lagta hai ki", "mujhe lagta hai ki"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(WritingStyleEngine.removeRepeatedPhrases(input, minimumLength: 2).text, expected, input)
        }
    }

    func testOneWordSaidTwiceStaysOutsideEnglish() {
        for text in [
            "es muy muy importante",
            "c'est très très bien",
            "das ist sehr sehr gut",
            "bahut bahut shukriya",
            "si si, claro",
        ] {
            XCTAssertEqual(WritingStyleEngine.removeRepeatedPhrases(text, minimumLength: 2).text, text, text)
        }
    }

    func testCountingAndNumbersStay() {
        for text in ["probando 1 2 1 2", "probando uno dos uno dos", "un deux un deux", "eins zwei eins zwei"] {
            XCTAssertEqual(WritingStyleEngine.removeRepeatedPhrases(text, minimumLength: 2).text, text, text)
        }
    }

    /// English's list of meant repeats ("no no") isn't consulted: Portuguese
    /// "no" means "in the".
    func testEnglishMeantRepeatsDontApplyElsewhere() {
        XCTAssertEqual(
            WritingStyleEngine.removeRepeatedPhrases("fica no meio no meio de tudo", minimumLength: 2).text,
            "fica no meio de tudo"
        )
    }

    // MARK: - Cut-off words

    private let spanish: Set<String> = ["por", "favor", "envía", "el", "informe", "mañana", "fa", "la", "factura"]

    func testAFragmentBeforeTheWordItStartsGoes() {
        let result = WritingStyleEngine.removeCutOffWords(
            "por fav favor envía el informe", fragmentsOnly: true, isKnownWord: { self.spanish.contains($0) }
        )
        XCTAssertEqual(result.text, "por favor envía el informe")
    }

    func testRealWordsAndShortPiecesStay() {
        // "fa" is a word (a note), and two letters are too short to judge.
        for text in ["la fa factura", "el in informe"] {
            let result = WritingStyleEngine.removeCutOffWords(
                text, fragmentsOnly: true, isKnownWord: { self.spanish.contains($0) }
            )
            XCTAssertEqual(result.text, text, text)
        }
    }

    func testAFragmentInAnotherScriptGoes() {
        let russian: Set<String> = ["пожалуйста", "отправь", "отчёт"]
        let result = WritingStyleEngine.removeCutOffWords(
            "пож пожалуйста отправь отчёт", fragmentsOnly: true, isKnownWord: { russian.contains($0) }
        )
        XCTAssertEqual(result.text, "пожалуйста отправь отчёт")
    }

    func testOnlyTheFragmentRuleRunsOutsideEnglish() {
        // English's "less clutter less cluttery" rule leans on English lists.
        let text = "más claro más clarito"
        let result = WritingStyleEngine.removeCutOffWords(text, fragmentsOnly: true, isKnownWord: { _ in true })
        XCTAssertEqual(result.text, text)
    }

    // MARK: - Pipeline

    @MainActor
    func testPipelineAppliesBothInAKnownLanguage() async {
        let cleaner = MockTranscriptCleanup()
        let known: Set<String> = ["vamos", "a", "comer", "por", "favor", "mañana"]
        let result = await DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander()).process(
            "vamos a vamos a comer mañana por fav favor",
            options: DictationOutputOptions(
                profile: WritingProfile(format: .plain, rules: .passthrough), snippetList: [],
                cleanupEnabled: false, rewritingEnabled: false, model: .defaultKind, customPrompt: "",
                cleanupLevel: .medium, language: "es", autoCapitalize: false, trailingSpace: false,
                dictionary: DictionaryContext(vocabulary: [], replacements: [], contextTerms: [],
                                              isKnownWord: { known.contains($0) })
            )
        )
        XCTAssertEqual(result.text, "vamos a comer mañana por favor")
    }

    @MainActor
    func testUnknownLanguageSkipsCutOffWords() async {
        let cleaner = MockTranscriptCleanup()
        let result = await DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander()).process(
            "por fav favor",
            options: DictationOutputOptions(
                profile: WritingProfile(format: .plain, rules: .passthrough), snippetList: [],
                cleanupEnabled: false, rewritingEnabled: false, model: .defaultKind, customPrompt: "",
                cleanupLevel: .medium, language: nil, autoCapitalize: false, trailingSpace: false
            )
        )
        XCTAssertEqual(result.text, "por fav favor", "Without a language there's no checker to trust")
    }
}
