// DictionaryTransferTests.swift
// VocaMac Tests
//
// Dictionary import and export: CSV, JSON and plain word lists, the
// duplicate rules, and what the Dictionary page offers to add.

import XCTest
@testable import VocaMac

final class DictionaryTransferTests: XCTestCase {

    private let sample = DictionaryTransferContents(
        words: ["Kubernetes", "Priya Raman"],
        replacements: [
            DictionaryTransferReplacement(heard: "get hub, git hub", replacement: "GitHub"),
            DictionaryTransferReplacement(heard: "btw", replacement: "by the way, \"really\""),
        ]
    )

    // MARK: Round trips

    func testCSVRoundTripKeepsWordsAndReplacements() throws {
        let csv = DictionaryTransfer.csv(sample)
        XCTAssertTrue(csv.hasPrefix("type,heard,text\n"))
        XCTAssertEqual(try DictionaryTransfer.parse(csv, format: .csv), sample)
    }

    func testJSONRoundTripKeepsWordsAndReplacements() throws {
        let json = DictionaryTransfer.json(sample)
        XCTAssertEqual(try DictionaryTransfer.parse(json, format: .json), sample)
    }

    // MARK: CSV from other apps

    func testTwoColumnCSVWithHeaderIsReadAsReplacements() throws {
        let contents = try DictionaryTransfer.parse("from,to\nget hub,GitHub\ncube or netties,Kubernetes\n", format: .csv)
        XCTAssertEqual(contents.words, [])
        XCTAssertEqual(contents.replacements, [
            DictionaryTransferReplacement(heard: "get hub", replacement: "GitHub"),
            DictionaryTransferReplacement(heard: "cube or netties", replacement: "Kubernetes"),
        ])
    }

    func testOneColumnCSVIsReadAsWords() throws {
        let contents = try DictionaryTransfer.parse("word\nKubernetes\nVocaMac\r\n", format: .csv)
        XCTAssertEqual(contents.words, ["Kubernetes", "VocaMac"])
    }

    func testCSVWithoutHeaderKeepsTheFirstRow() throws {
        let contents = try DictionaryTransfer.parse("Kubernetes\nVocaMac", format: .csv)
        XCTAssertEqual(contents.words, ["Kubernetes", "VocaMac"])
    }

    func testQuotedCSVFieldsKeepCommasQuotesAndLineBreaks() {
        let rows = DictionaryTransfer.csvRows("a,\"b, c\",\"say \"\"hi\"\"\"\n\"two\nlines\",x\n")
        XCTAssertEqual(rows, [["a", "b, c", "say \"hi\""], ["two\nlines", "x"]])
    }

    func testTabSeparatedFileIsRead() throws {
        let contents = try DictionaryTransfer.parse("heard\treplacement\nget hub\tGitHub\n", format: .csv)
        XCTAssertEqual(contents.replacements, [DictionaryTransferReplacement(heard: "get hub", replacement: "GitHub")])
    }

    // MARK: JSON shapes

    func testJSONArrayOfWordsIsRead() throws {
        let contents = try DictionaryTransfer.parse(#"["Kubernetes", "VocaMac"]"#, format: .json)
        XCTAssertEqual(contents.words, ["Kubernetes", "VocaMac"])
    }

    func testJSONArrayOfFromToObjectsIsRead() throws {
        let json = #"[{"from": "get hub", "to": "GitHub"}, {"word": "Priya"}]"#
        let contents = try DictionaryTransfer.parse(json, format: .json)
        XCTAssertEqual(contents.replacements, [DictionaryTransferReplacement(heard: "get hub", replacement: "GitHub")])
        XCTAssertEqual(contents.words, ["Priya"])
    }

    func testMalformedJSONIsUnreadable() {
        XCTAssertThrowsError(try DictionaryTransfer.parse("{not json", format: .json)) {
            XCTAssertEqual($0 as? DictionaryTransferError, .unreadable)
        }
    }

    // MARK: Plain text

    func testPlainTextIsOneWordPerLineWithArrowsForReplacements() throws {
        let text = """
        # my words
        Kubernetes
        get hub -> GitHub
        btw → by the way

        VocaMac
        """
        let contents = try DictionaryTransfer.parse(text, format: .plainText)
        XCTAssertEqual(contents.words, ["Kubernetes", "VocaMac"])
        XCTAssertEqual(contents.replacements, [
            DictionaryTransferReplacement(heard: "get hub", replacement: "GitHub"),
            DictionaryTransferReplacement(heard: "btw", replacement: "by the way"),
        ])
    }

    func testFormatFollowsTheFileExtension() {
        XCTAssertEqual(DictionaryTransferFormat.forFile(URL(fileURLWithPath: "/a/words.CSV")), .csv)
        XCTAssertEqual(DictionaryTransferFormat.forFile(URL(fileURLWithPath: "/a/words.json")), .json)
        XCTAssertEqual(DictionaryTransferFormat.forFile(URL(fileURLWithPath: "/a/words.txt")), .plainText)
        XCTAssertEqual(DictionaryTransferFormat.forFile(URL(fileURLWithPath: "/a/words")), .plainText)
    }

    // MARK: Cleanup

    func testEmptyFileFindsNothing() {
        XCTAssertThrowsError(try DictionaryTransfer.parse("\n  \n# only a comment\n", format: .plainText)) {
            XCTAssertEqual($0 as? DictionaryTransferError, .nothingFound)
        }
    }

    func testDuplicatesInsideTheFileAndOverlongEntriesAreDropped() throws {
        let long = String(repeating: "x", count: DictionaryTransfer.maxEntryLength + 1)
        let contents = try DictionaryTransfer.parse("Kubernetes\nkubernetes\n\(long)\nVocaMac", format: .plainText)
        XCTAssertEqual(contents.words, ["Kubernetes", "VocaMac"])
    }

    // MARK: Plan

    func testPlanSkipsWordsAlreadyListedIgnoringCase() {
        let plan = DictionaryTransfer.plan(
            importing: DictionaryTransferContents(words: ["kubernetes", "VocaMac"]),
            existingWords: ["Kubernetes"], existingReplacements: []
        )
        XCTAssertEqual(plan.newWords, ["VocaMac"])
        XCTAssertEqual(plan.duplicateCount, 1)
    }

    func testPlanKeepsOnlySpokenFormsNotAlreadyClaimed() {
        let existing = [WordReplacement(heard: "get hub", replacement: "GitHub")]
        let plan = DictionaryTransfer.plan(
            importing: DictionaryTransferContents(replacements: [
                DictionaryTransferReplacement(heard: "get hub", replacement: "GitHub"),
                DictionaryTransferReplacement(heard: "Get Hub, git hub", replacement: "Github Inc"),
                DictionaryTransferReplacement(heard: "btw", replacement: "by the way"),
            ]),
            existingWords: [], existingReplacements: existing
        )
        XCTAssertEqual(plan.newReplacements, [
            DictionaryTransferReplacement(heard: "git hub", replacement: "Github Inc"),
            DictionaryTransferReplacement(heard: "btw", replacement: "by the way"),
        ])
        XCTAssertEqual(plan.duplicateCount, 1)
    }

    func testEverythingDuplicateIsAnEmptyPlan() {
        let plan = DictionaryTransfer.plan(
            importing: DictionaryTransferContents(words: ["Kubernetes"]),
            existingWords: ["Kubernetes"], existingReplacements: []
        )
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(CalmDictionaryPendingImport(plan: plan).summary,
                       "Everything in that file is already in your dictionary (1 entry).")
    }

    func testImportSummaryCountsNewAndExisting() {
        let plan = DictionaryImportPlan(
            newWords: ["A", "B"], newReplacements: [DictionaryTransferReplacement(heard: "x", replacement: "y")],
            duplicateCount: 3
        )
        let pending = CalmDictionaryPendingImport(plan: plan)
        XCTAssertEqual(pending.summary, "2 new words and 1 new replacement. 3 already in your dictionary will be left as they are.")
        XCTAssertEqual(pending.doneMessage, "Imported 2 words and 1 replacement.")
    }

    // MARK: AppState

    @MainActor
    func testApplyingAnImportAddsWordsAndReplacementsWithoutChangingExistingOnes() {
        let (appState, _) = AppState.makeTestState()
        let savedVocabulary = appState.customVocabulary
        let savedReplacements = appState.wordReplacements
        defer {
            appState.customVocabulary = savedVocabulary
            appState.wordReplacements = savedReplacements
        }
        appState.setVocabularyTerms(["Kubernetes"])
        appState.wordReplacements = [WordReplacement(heard: "get hub", replacement: "GitHub")]

        let contents = DictionaryTransferContents(
            words: ["kubernetes", "VocaMac"],
            replacements: [
                DictionaryTransferReplacement(heard: "get hub", replacement: "Gitlab"),
                DictionaryTransferReplacement(heard: "btw", replacement: "by the way"),
            ]
        )
        appState.applyDictionaryImport(appState.dictionaryImportPlan(for: contents))

        XCTAssertEqual(appState.vocabularyTerms, ["Kubernetes", "VocaMac"])
        XCTAssertEqual(appState.wordReplacements.map(\.replacement), ["GitHub", "by the way"])
        XCTAssertEqual(appState.dictionaryTransferContents.words, ["Kubernetes", "VocaMac"])
    }
}
