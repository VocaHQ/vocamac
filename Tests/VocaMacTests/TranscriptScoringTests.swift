// TranscriptScoringTests.swift
// VocaMac

import XCTest
@testable import VocaMac

final class TranscriptScoringTests: XCTestCase {

    // MARK: - Alignment

    func testAlignmentCountsMatchWordErrorRate() {
        let cases = [
            ("a b c d", "a c d e"), ("a b c d e", "a x c e f"), ("", "x y"), ("x y", ""),
            ("please send the report to Namrata by Friday", "Please send the report to Namrata."),
        ]
        for (reference, hypothesis) in cases {
            let words = (WordErrorRate.normalizedWords(reference), WordErrorRate.normalizedWords(hypothesis))
            let steps = TranscriptScoring.alignment(reference: words.0, hypothesis: words.1)
            var counted = WordErrorRate(substitutions: 0, deletions: 0, insertions: 0, referenceWords: words.0.count)
            for step in steps {
                switch step {
                case .match: break
                case .substitution: counted.substitutions += 1
                case .deletion: counted.deletions += 1
                case .insertion: counted.insertions += 1
                }
            }
            XCTAssertEqual(counted, WordErrorRate.measure(reference: reference, hypothesis: hypothesis), reference)
        }
    }

    // MARK: - Edge words

    func testEdgeWordsDropped() {
        let clippedStart = TranscriptScoring.edgeWords(reference: "so we ship on Friday", hypothesis: "we ship on Friday")
        XCTAssertEqual(clippedStart, TranscriptScoring.EdgeWords(leadingDropped: 1, trailingDropped: 0))
        XCTAssertTrue(clippedStart.firstWordDropped)

        let clippedEnd = TranscriptScoring.edgeWords(
            reference: "please send the report to Namrata by Friday", hypothesis: "Please send the report to Namrata."
        )
        XCTAssertEqual(clippedEnd, TranscriptScoring.EdgeWords(leadingDropped: 0, trailingDropped: 2))

        // A misheard first word is not a dropped one; an extra word is skipped over.
        let misheard = TranscriptScoring.edgeWords(reference: "so we ship", hypothesis: "uh oh we ship")
        XCTAssertFalse(misheard.firstWordDropped)
        XCTAssertFalse(misheard.lastWordDropped)

        // Nothing came through: an empty transcript, not a clipped edge.
        XCTAssertEqual(TranscriptScoring.edgeWords(reference: "hello there", hypothesis: ""),
                       TranscriptScoring.EdgeWords(leadingDropped: 0, trailingDropped: 0))
    }

    // MARK: - Formatting

    func testFormattingScoresSharedWordsOnly() {
        let formatting = TranscriptScoring.formatting(
            reference: "Send it to Priya. Thanks!",
            hypothesis: "send it to Priya, thanks."
        )
        // Reference marks: "Priya." and "Thanks!"; hypothesis: "Priya," and "thanks.".
        XCTAssertEqual(formatting.punctuation, TranscriptScoring.MarkAgreement(
            referenceMarks: 2, hypothesisMarks: 2, agreements: 0
        ))
        // Capitals: reference Send, Priya, Thanks; hypothesis Priya.
        XCTAssertEqual(formatting.capitalization, TranscriptScoring.MarkAgreement(
            referenceMarks: 3, hypothesisMarks: 1, agreements: 1
        ))
        // Marks on both sides that never agree are a score of 0, not "n/a".
        XCTAssertEqual(formatting.punctuation.f1, 0)
        XCTAssertEqual(TranscriptScoring.MarkAgreement(referenceMarks: 2).f1, 0)
        XCTAssertEqual(TranscriptScoring.MarkAgreement(hypothesisMarks: 1).f1, 0)
        XCTAssertNil(TranscriptScoring.MarkAgreement().f1)
        XCTAssertEqual(formatting.capitalization.precision, 1)
        XCTAssertEqual(formatting.capitalization.recall ?? 0, 1.0 / 3.0, accuracy: 1e-9)

        let perfect = TranscriptScoring.formatting(reference: "Yes, today.", hypothesis: "Yes, today.")
        XCTAssertEqual(perfect.punctuation.f1, 1)
        XCTAssertEqual(perfect.capitalization.f1, 1)

        // A misheard word carries no formatting score.
        let misheard = TranscriptScoring.formatting(reference: "Call Jatin.", hypothesis: "Call Jathin.")
        XCTAssertEqual(misheard.punctuation.referenceMarks, 0)
    }

    // MARK: - Terms

    func testTermRecallNeedsTheExactSpelling() {
        let recall = TranscriptScoring.termRecall(
            terms: ["GitHub", "Kubernetes", "VocaMac"],
            reference: "Push it to GitHub and deploy on Kubernetes",
            hypothesis: "Push it to github and deploy on Kubernetes"
        )
        XCTAssertEqual(recall, TranscriptScoring.TermRecall(expected: 2, recalled: 1, falseInsertions: 0))
        XCTAssertEqual(recall.recall, 0.5)
    }

    func testTermInsertedWhereNotSaid() {
        let recall = TranscriptScoring.termRecall(
            terms: ["Claude"], reference: "it is cloudy today", hypothesis: "it is Claude today"
        )
        XCTAssertEqual(recall, TranscriptScoring.TermRecall(expected: 0, recalled: 0, falseInsertions: 1))
        XCTAssertNil(recall.recall)
    }

    func testMultiWordTermsAndRepeats() {
        let recall = TranscriptScoring.termRecall(
            terms: ["Visual Studio Code", "visual studio code"],
            reference: "open Visual Studio Code then Visual Studio Code again",
            hypothesis: "open Visual Studio Code then visual studio code again"
        )
        XCTAssertEqual(recall, TranscriptScoring.TermRecall(expected: 2, recalled: 1, falseInsertions: 0))
    }

    func testTermsKeepTheirSymbols() {
        // "C" is not "C++", and "C#" is a different term again.
        let wrong = TranscriptScoring.termRecall(
            terms: ["C++", "C#"], reference: "I write C++ and C# daily.", hypothesis: "I write C and C daily."
        )
        XCTAssertEqual(wrong, TranscriptScoring.TermRecall(expected: 2, recalled: 0, falseInsertions: 0))

        // Sentence punctuation, quotes and brackets around a term still match.
        let right = TranscriptScoring.termRecall(
            terms: ["C++", ".NET", "Node.js"],
            reference: "Use C++, then (.NET) and Node.js.",
            hypothesis: "Use \"C++\" then .NET, and Node.js!"
        )
        XCTAssertEqual(right, TranscriptScoring.TermRecall(expected: 3, recalled: 3, falseInsertions: 0))

        // Separators the term does not use split tokens, whatever the spacing.
        let slashed = TranscriptScoring.termRecall(
            terms: ["Node.js", "TCP/IP"],
            reference: "Use Node.js/TypeScript over TCP/IP",
            hypothesis: "Use Node.js / TypeScript over TCP/IP"
        )
        XCTAssertEqual(slashed, TranscriptScoring.TermRecall(expected: 2, recalled: 2, falseInsertions: 0))

        let lowered = TranscriptScoring.termRecall(
            terms: ["Node.js"], reference: "run Node.js", hypothesis: "run node.js"
        )
        XCTAssertEqual(lowered, TranscriptScoring.TermRecall(expected: 1, recalled: 0, falseInsertions: 0))
    }
}
