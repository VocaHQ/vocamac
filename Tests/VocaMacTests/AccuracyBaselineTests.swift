// AccuracyBaselineTests.swift
// VocaMac

import XCTest
@testable import VocaMac

final class AccuracyBaselineTests: XCTestCase {
    private let baseline = AccuracyBaseline(
        note: nil, corpus: "v1", tolerance: 0.01,
        models: [
            "tiny": .init(corpusWER: 0.20, corpusCER: nil, finalCorpusWER: 0.18, edgeDropRate: 0.05),
            "parakeet-unified-en-0.6b": .init(corpusWER: 0.07, corpusCER: nil, finalCorpusWER: nil, edgeDropRate: nil),
        ]
    )

    func testWithinToleranceIsNotARegression() {
        let measured: [String: AccuracyBaseline.Entry] = [
            "tiny": .init(corpusWER: 0.205, corpusCER: nil, finalCorpusWER: 0.17, edgeDropRate: 0.06),
            "parakeet-unified-en-0.6b": .init(corpusWER: 0.08, corpusCER: nil, finalCorpusWER: nil, edgeDropRate: nil),
        ]
        XCTAssertEqual(baseline.regressions(in: measured), [])
    }

    func testWorseThanToleranceFails() {
        let measured: [String: AccuracyBaseline.Entry] = [
            "tiny": .init(corpusWER: 0.25, corpusCER: nil, finalCorpusWER: 0.18, edgeDropRate: 0.10),
        ]
        let regressions = baseline.regressions(in: measured)
        XCTAssertEqual(regressions.map(\.metric), ["corpus WER", "edge drop rate"])
        XCTAssertEqual(regressions.first?.model, "tiny")
        // An explicit tolerance overrides the stored one.
        XCTAssertEqual(baseline.regressions(in: measured, tolerance: 0.1), [])
    }

    func testModelsMissingFromEitherSideAreNotCompared() {
        let measured: [String: AccuracyBaseline.Entry] = [
            "new-model": .init(corpusWER: 0.9, corpusCER: nil, finalCorpusWER: nil, edgeDropRate: nil),
            "parakeet-unified-en-0.6b": .init(corpusWER: nil, corpusCER: 0.5, finalCorpusWER: nil, edgeDropRate: nil),
        ]
        XCTAssertEqual(baseline.regressions(in: measured), [])
    }

    func testRoundTripsThroughJSON() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("baseline-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try baseline.write(to: url)
        XCTAssertEqual(try AccuracyBaseline.load(from: url), baseline)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"corpus_wer\""), text)
    }

    func testCheckedInPlaceholderDecodes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".github/accuracy/baseline.json")
        let placeholder = try AccuracyBaseline.load(from: url)
        XCTAssertNotNil(placeholder.note)
    }

    func testBenchmarkSummarizesFilesForTheBaseline() {
        let entry = SpeechAccuracyBenchmarkTests.CorpusEntry(
            name: "a", audio: URL(fileURLWithPath: "/dev/null"), reference: "so we ship on Friday", terms: ["Friday"]
        )
        let cjk = SpeechAccuracyBenchmarkTests.CorpusEntry(
            name: "b", audio: URL(fileURLWithPath: "/dev/null"), reference: "今日は良い天気です"
        )
        let files = [
            SpeechAccuracyBenchmarkTests.scored(
                entry: entry, hypothesis: "we ship on friday", terms: ["Friday"], audioSeconds: 2, decodeSeconds: 1
            ),
            SpeechAccuracyBenchmarkTests.scored(
                entry: cjk, hypothesis: "今日は良い電気です", terms: [], audioSeconds: 2, decodeSeconds: 1
            ),
        ]
        let result = SpeechAccuracyBenchmarkTests.summarized(model: "tiny", files: files, loadSeconds: 0)
        XCTAssertEqual(result.corpus, WordErrorRate(substitutions: 0, deletions: 1, insertions: 0, referenceWords: 5))
        XCTAssertEqual(result.characterCorpus?.substitutions, 1)
        XCTAssertEqual(result.firstWordDrops, 1)
        XCTAssertEqual(result.wordScoredFiles, 1)
        XCTAssertEqual(result.edgeDropRate, 1)
        XCTAssertEqual(result.terms, TranscriptScoring.TermRecall(expected: 1, recalled: 0, falseInsertions: 0))
        XCTAssertEqual(result.baselineEntry.corpusWER ?? 0, 0.2, accuracy: 1e-9)
    }

    func testPairedVocabularyComparesTheSameFiles() {
        let hinted = SpeechAccuracyBenchmarkTests.CorpusEntry(
            name: "a", audio: URL(fileURLWithPath: "/dev/null"), reference: "push it to GitHub", terms: ["GitHub"]
        )
        let plain = SpeechAccuracyBenchmarkTests.CorpusEntry(
            name: "b", audio: URL(fileURLWithPath: "/dev/null"), reference: "one two three four"
        )
        var withHints = SpeechAccuracyBenchmarkTests.scored(
            entry: hinted, hypothesis: "push it to GitHub", terms: ["GitHub"], audioSeconds: 1, decodeSeconds: 1
        )
        withHints.withoutVocabulary = SpeechAccuracyBenchmarkTests.Unhinted(
            hypothesis: "push it to get hub",
            wer: WordErrorRate.measure(reference: hinted.reference, hypothesis: "push it to get hub"),
            terms: TranscriptScoring.termRecall(terms: ["GitHub"], reference: hinted.reference, hypothesis: "push it to get hub")
        )
        let noHints = SpeechAccuracyBenchmarkTests.scored(
            entry: plain, hypothesis: "one two", terms: [], audioSeconds: 1, decodeSeconds: 1
        )
        let result = SpeechAccuracyBenchmarkTests.summarized(model: "m", files: [withHints, noHints], loadSeconds: 0)
        // Only the file with hints is in the pair; the other one's errors stay out of it.
        XCTAssertEqual(result.hintedCorpus?.errors, 0)
        XCTAssertEqual(result.hintedCorpus?.referenceWords, 4)
        XCTAssertEqual(result.unhintedCorpus?.errors, 2)
        XCTAssertEqual(result.unhintedTerms, TranscriptScoring.TermRecall(expected: 1, recalled: 0, falseInsertions: 0))
        XCTAssertEqual(result.corpus.referenceWords, 8)
    }

    func testVocabularyMergesFileTerms() {
        XCTAssertEqual(
            SpeechAccuracyBenchmarkTests.vocabulary("GitHub, Kubernetes", adding: ["github", "Namrata"]),
            "GitHub, Kubernetes, Namrata"
        )
        XCTAssertEqual(SpeechAccuracyBenchmarkTests.vocabulary("", adding: []), "")
    }
}
