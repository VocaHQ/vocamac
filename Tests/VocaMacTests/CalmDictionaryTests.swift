// CalmDictionaryTests.swift
// VocaMac
//
// The v3 Dictionary and Snippets pages' rules: list filtering and search,
// the add / edit checks, and edits that keep an item in place.

import XCTest
@testable import VocaMac

final class CalmDictionaryTests: XCTestCase {

    // MARK: - List

    func testItemsListWordsThenReplacementsNewestFirst() {
        let btw = WordReplacement(heard: "btw", replacement: "by the way")
        let lgtm = WordReplacement(heard: "lgtm", replacement: "looks good to me")
        let items = DictionaryEditing.items(
            terms: ["VocaMac", "Parakeet"], replacements: [btw, lgtm], filter: .all, query: ""
        )
        XCTAssertEqual(items, [.word("Parakeet"), .word("VocaMac"), .replacement(lgtm), .replacement(btw)])
    }

    func testItemsFilterByTab() {
        let btw = WordReplacement(heard: "btw", replacement: "by the way")
        XCTAssertEqual(
            DictionaryEditing.items(terms: ["VocaMac"], replacements: [btw], filter: .words, query: ""),
            [.word("VocaMac")]
        )
        XCTAssertEqual(
            DictionaryEditing.items(terms: ["VocaMac"], replacements: [btw], filter: .replacements, query: ""),
            [.replacement(btw)]
        )
    }

    func testSearchMatchesWordsSpokenFormsAndReplacementsIgnoringCase() {
        let hub = WordReplacement(heard: "get hub", replacement: "GitHub")
        let terms = ["Kubernetes", "Priya Raman"]
        XCTAssertEqual(DictionaryEditing.items(terms: terms, replacements: [hub], filter: .all, query: "kube"),
                       [.word("Kubernetes")])
        XCTAssertEqual(DictionaryEditing.items(terms: terms, replacements: [hub], filter: .all, query: "GET"),
                       [.replacement(hub)])
        XCTAssertEqual(DictionaryEditing.items(terms: terms, replacements: [hub], filter: .all, query: " github "),
                       [.replacement(hub)])
        XCTAssertTrue(DictionaryEditing.items(terms: terms, replacements: [hub], filter: .words, query: "hub").isEmpty)
    }

    func testSearchTargetsOpenTheirTab() {
        XCTAssertEqual(DictionaryListFilter.forSearchTarget("vocabulary"), .words)
        XCTAssertEqual(DictionaryListFilter.forSearchTarget("word-replacements"), .replacements)
        XCTAssertNil(DictionaryListFilter.forSearchTarget("learn-corrections"))
        XCTAssertNil(DictionaryListFilter.forSearchTarget(nil))
    }

    // MARK: - Word checks

    func testWordCheck() {
        let terms = ["Kubernetes"]
        XCTAssertEqual(DictionaryEditing.checkWord("  ", terms: terms), .incomplete)
        XCTAssertEqual(DictionaryEditing.checkWord("WhisperKit", terms: terms), .valid)
        XCTAssertEqual(DictionaryEditing.checkWord(" kubernetes ", terms: terms),
                       .problem("“kubernetes” is already in your dictionary."))
    }

    func testEditingAWordMayKeepOrRecaseIt() {
        let terms = ["Kubernetes", "SwiftUI"]
        XCTAssertEqual(DictionaryEditing.checkWord("Kubernetes", terms: terms, editing: "Kubernetes"), .valid)
        XCTAssertEqual(DictionaryEditing.checkWord("kubernetes", terms: terms, editing: "Kubernetes"), .valid)
        XCTAssertFalse(DictionaryEditing.checkWord("swiftui", terms: terms, editing: "Kubernetes").isValid)
    }

    func testRenamingKeepsPositionAndStaysUnique() {
        XCTAssertEqual(DictionaryEditing.renaming("b", to: " B2 ", in: ["a", "b", "c"]), ["a", "B2", "c"])
        XCTAssertEqual(DictionaryEditing.renaming("b", to: "C", in: ["a", "b", "c"]), ["a", "C"])
        XCTAssertEqual(DictionaryEditing.renaming("x", to: "y", in: ["a"]), ["a"])
        XCTAssertEqual(DictionaryEditing.renaming("a", to: "  ", in: ["a"]), ["a"])
        // Commas separate words: “B, C” is two words in the old one's place,
        // and an existing C is not repeated.
        XCTAssertEqual(DictionaryEditing.renaming("a", to: "B, C", in: ["a", "c", "d"]), ["B", "C", "d"])
        XCTAssertEqual(DictionaryEditing.renaming("a", to: "B\nb", in: ["a"]), ["B"])
    }

    /// Each word of “B, C” is checked, so renaming to it while C exists is
    /// refused rather than creating a second C.
    func testWordCheckSplitsOnCommasAndNewLines() {
        let terms = ["A", "C"]
        XCTAssertEqual(DictionaryEditing.checkWord("B, C", terms: terms, editing: "A"), .problem("“C” is already in your dictionary."))
        XCTAssertEqual(DictionaryEditing.checkWord("B, D", terms: terms, editing: "A"), .valid)
        XCTAssertEqual(DictionaryEditing.checkWord(" , \n", terms: terms), .incomplete)
    }

    @MainActor
    func testStoredWordsNeverRepeatAfterAnEditWithACommaInIt() {
        let (state, _) = AppState.makeTestState()
        let saved = state.customVocabulary
        defer { state.customVocabulary = saved }
        state.setVocabularyTerms(["A", "C"])
        state.renameVocabularyTerm("A", to: "B, C")
        XCTAssertEqual(state.vocabularyTerms, ["B", "C"])
        state.setVocabularyTerms(["X, Y", "y", "Z"])
        XCTAssertEqual(state.vocabularyTerms, ["X", "Y", "Z"])
        let ids = DictionaryEditing.items(terms: state.vocabularyTerms, replacements: [], filter: .all, query: "").map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    // MARK: - Replacement checks

    func testReplacementCheck() {
        let btw = WordReplacement(heard: "btw, b t w", replacement: "by the way")
        XCTAssertEqual(DictionaryEditing.checkReplacement(heard: "", replacement: "x", existing: [btw]), .incomplete)
        XCTAssertEqual(DictionaryEditing.checkReplacement(heard: "lgtm", replacement: " ", existing: [btw]), .incomplete)
        XCTAssertEqual(DictionaryEditing.checkReplacement(heard: "lgtm", replacement: "looks good", existing: [btw]), .valid)
        XCTAssertEqual(DictionaryEditing.checkReplacement(heard: "B T W", replacement: "bye", existing: [btw]),
                       .problem("“B T W” already becomes “by the way”."))
    }

    func testNewSpokenFormForExistingTextIsValid() {
        let btw = WordReplacement(heard: "btw", replacement: "by the way")
        XCTAssertEqual(DictionaryEditing.checkReplacement(heard: "by tea way", replacement: "by the way", existing: [btw]),
                       .valid)
    }

    func testEditingAReplacementIgnoresItself() {
        let btw = WordReplacement(heard: "btw", replacement: "by the way")
        XCTAssertEqual(
            DictionaryEditing.checkReplacement(heard: "btw", replacement: "by the way!", existing: [btw], editing: btw.id),
            .valid
        )
    }

    // MARK: - Snippet checks

    func testSnippetCheck() {
        let standup = Snippet(trigger: "standup", expansion: "Yesterday: …")
        XCTAssertEqual(DictionaryEditing.checkSnippet(trigger: " ", expansion: "x", existing: []), .incomplete)
        XCTAssertEqual(DictionaryEditing.checkSnippet(trigger: "intro", expansion: "\n ", existing: []), .incomplete)
        XCTAssertEqual(DictionaryEditing.checkSnippet(trigger: "intro", expansion: "Hi", existing: [standup]), .valid)
        XCTAssertEqual(DictionaryEditing.checkSnippet(trigger: " Standup ", expansion: "x", existing: [standup]),
                       .problem("You already have a snippet called “Standup”."))
        XCTAssertEqual(
            DictionaryEditing.checkSnippet(trigger: "standup", expansion: "new", existing: [standup], editing: standup.id),
            .valid
        )
    }

    func testOneLineJoinsLines() {
        XCTAssertEqual(DictionaryEditing.oneLine("Yesterday: …\n  Today: …\n\nBlockers: none."),
                       "Yesterday: … Today: … Blockers: none.")
    }

    // MARK: - AppState

    @MainActor
    func testAppStateEditsKeepPlace() {
        let (state, _) = AppState.makeTestState()
        defer {
            state.setVocabularyTerms([])
            state.wordReplacements = []
            state.snippets = []
        }
        state.setVocabularyTerms(["VocaMac", "Parakeet", "SwiftUI"])
        state.renameVocabularyTerm("Parakeet", to: "Parakeet TDT")
        XCTAssertEqual(state.vocabularyTerms, ["VocaMac", "Parakeet TDT", "SwiftUI"])

        let first = WordReplacement(heard: "btw", replacement: "by the way")
        let second = WordReplacement(heard: "lgtm", replacement: "looks good to me")
        state.wordReplacements = [first, second]
        state.updateWordReplacement(id: first.id, heard: " btw ,  b t w ", replacement: " by the way ")
        XCTAssertEqual(state.wordReplacements.map(\.heard), ["btw, b t w", "lgtm"])
        XCTAssertEqual(state.wordReplacements.first?.replacement, "by the way")
        state.updateWordReplacement(id: first.id, heard: " ", replacement: "x")
        XCTAssertEqual(state.wordReplacements.first?.heard, "btw, b t w", "an empty edit changes nothing")

        state.snippets = []
        state.saveSnippet(id: nil, trigger: "  sig ", expansion: "  Best,\nK  ")
        XCTAssertEqual(state.snippets.map(\.trigger), ["sig"])
        XCTAssertEqual(state.snippets.first?.expansion, "  Best,\nK  ", "the text is kept as typed")
        let id = state.snippets[0].id
        state.saveSnippet(id: id, trigger: "signature", expansion: "Thanks")
        XCTAssertEqual(state.snippets.count, 1)
        XCTAssertEqual(state.snippets.first?.trigger, "signature")
        state.saveSnippet(id: nil, trigger: " ", expansion: "x")
        XCTAssertEqual(state.snippets.count, 1)
    }

    @MainActor
    func testItemsAndChecksReadAppState() {
        let (state, _) = AppState.makeTestState()
        defer {
            state.setVocabularyTerms([])
            state.wordReplacements = []
        }
        state.setVocabularyTerms(["Kubernetes"])
        state.wordReplacements = [WordReplacement(heard: "btw", replacement: "by the way")]
        XCTAssertEqual(state.dictionaryItems(filter: .all, query: "").count, 2)
        XCTAssertFalse(state.checkVocabularyTerm("kubernetes").isValid)
        XCTAssertFalse(state.checkWordReplacement(heard: "BTW", replacement: "x").isValid)
    }
}
