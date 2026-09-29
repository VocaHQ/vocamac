import XCTest
@testable import VocaMac

@MainActor
final class CleanupSpeculatorTests: XCTestCase {
    private func options(customPrompt: String = "Custom cleanup instructions") -> DictationOutputOptions {
        DictationOutputOptions(
            profile: WritingProfile(format: .plain, rules: WritingStyle.plain.defaultRules),
            snippetList: [], cleanupEnabled: true, rewritingEnabled: false,
            model: .defaultKind, customPrompt: customPrompt,
            language: "en", autoCapitalize: true, trailingSpace: false
        )
    }

    private func pieces(_ texts: [String]) -> [TranscribedPiece] {
        var start = 0
        return texts.map { text in
            defer { start += 16_000 }
            return TranscribedPiece(range: start..<(start + 16_000), text: text, language: "en")
        }
    }

    /// Poll the main actor until `condition` holds; speculation hops through
    /// a few tasks before it reaches the cleaner.
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    private let firstSentence = "so we could could ship it on friday."
    private let secondSentence = "then we talk about the review."

    func testMatchingPieceReusesTheAnswerAndOnlyTheTailIsCleanedAtStop() async {
        let cleaner = MockTranscriptCleanup()
        cleaner.cleanHandler = { $0.replacingOccurrences(of: "could could", with: "could") }
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
        let speculator = CleanupSpeculator(pipeline: pipeline) { _ in self.options() }
        let parts = pieces([firstSentence, secondSentence])

        speculator.submit(parts[0], index: 0)
        await waitUntil { cleaner.speculateCallCount == 1 }
        let output = await pipeline.process(
            TranscribedPiece.join(parts), options: options(), pieces: parts, speculator: speculator
        )

        XCTAssertEqual(output.text, "So we could ship it on friday. Then we talk about the review.")
        XCTAssertEqual(cleaner.speculateCallCount, 1)
        XCTAssertEqual(cleaner.cleanCallCount, 1, "only the tail is cleaned at stop")
        XCTAssertEqual(speculator.hitCount, 1)
        XCTAssertEqual(speculator.missCount, 1)
        XCTAssertEqual(cleaner.recordedOutcomes.count, 1, "a used answer counts like a normal cleanup")
        XCTAssertLessThanOrEqual(cleaner.maxConcurrentModelCalls, 1)
    }

    func testChangedRequestIsCleanedAgain() async {
        let cleaner = MockTranscriptCleanup()
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
        // The style changed after the piece was cleaned: a different prompt.
        let speculator = CleanupSpeculator(pipeline: pipeline) { _ in self.options(customPrompt: "Older instructions") }
        let parts = pieces([firstSentence, secondSentence])

        speculator.submit(parts[0], index: 0)
        await waitUntil { cleaner.speculateCallCount == 1 }
        _ = await pipeline.process(
            TranscribedPiece.join(parts), options: options(), pieces: parts, speculator: speculator
        )

        XCTAssertEqual(speculator.hitCount, 0)
        XCTAssertEqual(cleaner.cleanCallCount, 2, "both pieces are cleaned at stop")
        XCTAssertLessThanOrEqual(cleaner.maxConcurrentModelCalls, 1)
    }

    func testFinalPassWaitsForAMatchingRunningJob() async {
        let cleaner = MockTranscriptCleanup()
        var release: CheckedContinuation<Void, Never>?
        cleaner.onSpeculate = { await withCheckedContinuation { release = $0 } }
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
        let speculator = CleanupSpeculator(pipeline: pipeline) { _ in self.options() }
        let parts = pieces([firstSentence, secondSentence])

        speculator.submit(parts[0], index: 0)
        await waitUntil { release != nil }
        let final = Task { @MainActor in
            await pipeline.process(TranscribedPiece.join(parts), options: self.options(), pieces: parts, speculator: speculator)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(cleaner.cleanCallCount, 0, "nothing else runs while the model is busy")
        release?.resume()
        _ = await final.value

        XCTAssertEqual(speculator.hitCount, 1)
        XCTAssertEqual(cleaner.cleanCallCount, 1)
        XCTAssertEqual(cleaner.cancelCleanupCallCount, 0, "a job the final pass needs is not stopped")
        XCTAssertLessThanOrEqual(cleaner.maxConcurrentModelCalls, 1)
    }

    func testUnneededRunningJobIsStoppedBeforeTheFinalPass() async {
        let cleaner = MockTranscriptCleanup()
        var release: CheckedContinuation<Void, Never>?
        cleaner.onSpeculate = { await withCheckedContinuation { release = $0 } }
        cleaner.onCancelCleanup = { release?.resume(); release = nil }
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
        let speculator = CleanupSpeculator(pipeline: pipeline) { _ in self.options() }

        speculator.submit(TranscribedPiece(range: 0..<16_000, text: "something I said and then took back.", language: "en"), index: 0)
        await waitUntil { release != nil }
        let output = await pipeline.process("hello there", options: options(), speculator: speculator)

        XCTAssertEqual(output.text, "Hello there")
        XCTAssertEqual(cleaner.cancelCleanupCallCount, 1)
        XCTAssertEqual(speculator.cancelledCount, 1)
        XCTAssertEqual(cleaner.cleanCallCount, 1)
        XCTAssertLessThanOrEqual(cleaner.maxConcurrentModelCalls, 1)
    }

    func testCancelAllStopsTheJobAndNothingStartsAfterwards() async {
        let cleaner = MockTranscriptCleanup()
        var release: CheckedContinuation<Void, Never>?
        cleaner.onSpeculate = { await withCheckedContinuation { release = $0 } }
        cleaner.onCancelCleanup = { release?.resume(); release = nil }
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
        let speculator = CleanupSpeculator(pipeline: pipeline) { _ in self.options() }
        let parts = pieces([firstSentence, secondSentence])

        speculator.submit(parts[0], index: 0)
        await waitUntil { release != nil }
        speculator.cancelAll()
        await speculator.finish()
        speculator.submit(parts[1], index: 1)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(cleaner.cancelCleanupCallCount, 1)
        XCTAssertEqual(cleaner.speculateCallCount, 1, "a cancelled speculator never starts another job")
        let claimed = await speculator.claim(CleanupRequestKey(model: .defaultKind, prompt: "", input: ""))
        XCTAssertNil(claimed)
    }

    func testOnlyTheNewestWaitingPiecesAreKept() async {
        let cleaner = MockTranscriptCleanup()
        var releases: [CheckedContinuation<Void, Never>] = []
        cleaner.onSpeculate = { await withCheckedContinuation { releases.append($0) } }
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
        let speculator = CleanupSpeculator(pipeline: pipeline) { _ in self.options() }
        let parts = pieces([
            "the first sentence is here.", "a second one follows it.",
            "and then a third one arrives.", "a fourth one closes it.",
        ])

        speculator.submit(parts[0], index: 0)
        await waitUntil { releases.count == 1 }
        speculator.submit(parts[1], index: 1)
        speculator.submit(parts[2], index: 2)
        speculator.submit(parts[3], index: 3)
        try? await Task.sleep(nanoseconds: 50_000_000)
        for _ in 0..<3 {
            await waitUntil { releases.count == 1 }
            releases.removeFirst().resume()
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(cleaner.speculatedTexts, [parts[0].text, parts[2].text, parts[3].text],
                       "the oldest waiting piece is left for the final pass")
    }

    func testACorrectedPieceWaitsAlongsideTheNextOne() async {
        let cleaner = MockTranscriptCleanup()
        var releases: [CheckedContinuation<Void, Never>] = []
        cleaner.onSpeculate = { await withCheckedContinuation { releases.append($0) } }
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
        let speculator = CleanupSpeculator(pipeline: pipeline) { _ in self.options() }
        let parts = pieces(["we ran out of flower.", "for the bread tonight."])
        let corrected = TranscribedPiece(range: parts[0].range, text: "we ran out of flour", language: "en")

        speculator.submit(parts[0], index: 0)
        await waitUntil { releases.count == 1 }
        speculator.submit(corrected, index: 0)
        speculator.submit(parts[1], index: 1)
        try? await Task.sleep(nanoseconds: 50_000_000)
        for _ in 0..<3 {
            await waitUntil { releases.count == 1 }
            releases.removeFirst().resume()
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(cleaner.speculatedTexts, [parts[0].text, corrected.text, parts[1].text])
    }
}

extension CleanupSpeculatorTests {
    func testEscapeDuringTheFinalPassStopsTheRemainingPieces() async {
        let cleaner = MockTranscriptCleanup()
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
        let speculator = CleanupSpeculator(pipeline: pipeline) { _ in self.options() }
        cleaner.onClean = { speculator.cancelAll() }
        let parts = pieces(["the first sentence is here.", "a second one follows it.", "and then a third one arrives."])

        let output = await pipeline.process(
            TranscribedPiece.join(parts), options: options(), pieces: parts, speculator: speculator
        )

        XCTAssertEqual(cleaner.cleanCallCount, 1, "no new cleanup starts after Escape")
        XCTAssertEqual(output.summary, "Processing cancelled")
    }
}

extension CleanupSpeculatorTests {
    func testAnswerFromAnotherCleanupModelIsNotReused() async {
        let cleaner = MockTranscriptCleanup()
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
        // The model changed after the piece was cleaned.
        let speculator = CleanupSpeculator(pipeline: pipeline) { _ in
            var older = self.options()
            older.model = .qwen25_1_5b_q4_k_m
            return older
        }
        var current = options()
        current.model = .ministral3_3b_q4_k_m
        let parts = pieces([firstSentence, secondSentence])

        speculator.submit(parts[0], index: 0)
        await waitUntil { cleaner.speculateCallCount == 1 }
        _ = await pipeline.process(TranscribedPiece.join(parts), options: current, pieces: parts, speculator: speculator)

        XCTAssertEqual(speculator.hitCount, 0)
        XCTAssertEqual(cleaner.cleanCallCount, 2, "both pieces are cleaned with the selected model")
    }

    // MARK: - Requests the final pass will make

    func testEveryPieceIsPreparedInTheFirstPiecesLanguage() async {
        let cleaner = MockTranscriptCleanup()
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
        var languages: [String] = []
        let speculator = CleanupSpeculator(pipeline: pipeline) { language in
            languages.append(language)
            var options = self.options()
            options.language = language
            return options
        }
        speculator.submit(TranscribedPiece(range: 0..<16_000, text: firstSentence, language: "en"), index: 0)
        speculator.submit(TranscribedPiece(range: 16_000..<32_000, text: secondSentence, language: "de"), index: 1)
        await waitUntil { languages.count == 2 }
        XCTAssertEqual(languages, ["en", "en"], "the final pass reads the whole dictation in its first piece's language")
        await speculator.finish()
    }

    func testAPieceDecodedEarlyIsReusedWhenItDidntChange() async {
        let cleaner = MockTranscriptCleanup()
        cleaner.cleanHandler = { $0.replacingOccurrences(of: "could could", with: "could") }
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
        let speculator = CleanupSpeculator(pipeline: pipeline) { _ in self.options() }
        let parts = pieces([firstSentence, secondSentence])

        speculator.submit(parts[0], index: 0)
        // The tail, decoded early in the quiet before stop.
        speculator.submit(parts[1], index: 1)
        await waitUntil { cleaner.speculateCallCount == 2 }
        _ = await pipeline.process(
            TranscribedPiece.join(parts), options: options(), pieces: parts, speculator: speculator
        )
        XCTAssertEqual(speculator.hitCount, 2)
        XCTAssertEqual(cleaner.cleanCallCount, 0, "nothing is left to clean at stop")
    }

    func testAnOlderSubmissionFinishingLastIsDropped() async {
        let cleaner = MockTranscriptCleanup()
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
        var releaseFirst: CheckedContinuation<Void, Never>?
        var calls = 0
        let speculator = CleanupSpeculator(pipeline: pipeline) { _ in
            calls += 1
            // The first submission's preparation is held until the second
            // has been queued.
            if calls == 1 { await withCheckedContinuation { releaseFirst = $0 } }
            return self.options()
        }
        speculator.submit(TranscribedPiece(range: 0..<16_000, text: "we ran out of flower.", language: "en"), index: 0)
        await waitUntil { releaseFirst != nil }
        speculator.submit(TranscribedPiece(range: 0..<16_000, text: "we ran out of flour.", language: "en"), index: 0)
        await waitUntil { cleaner.speculateCallCount == 1 }
        releaseFirst?.resume()
        await speculator.waitUntilIdle()
        XCTAssertEqual(cleaner.speculatedTexts, ["we ran out of flour."], "the newer text wins")
    }
}
