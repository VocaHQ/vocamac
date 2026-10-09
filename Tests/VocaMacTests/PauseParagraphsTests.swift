// PauseParagraphsTests.swift
// VocaMac Tests
//
// Paragraph breaks at long pauses: where the pauses are, where they fall in
// the text, when a break is made, and that the output pipeline keeps them.

import XCTest
import FluidAudio
@testable import VocaMac

// MARK: - Fixtures

/// Timed words laid out one after another: each word takes `wordSeconds`,
/// with `gap` after it, or the gap `gaps` gives for its index.
private func timedWords(
    _ text: String, wordSeconds: Double = 0.3, gap: Double = 0.1, gaps: [Int: Double] = [:]
) -> [TimedWord] {
    var time = 0.0
    return text.split(separator: " ").enumerated().map { index, word in
        let timed = TimedWord(word: " " + word, start: time, end: time + wordSeconds, probability: 0.9)
        time += wordSeconds + (gaps[index] ?? gap)
        return timed
    }
}

/// 16 kHz audio that is loud while a word is spoken and silent otherwise.
private func audio(for words: [TimedWord], loudBetween: [Range<Double>] = []) -> [Float] {
    let end = (words.last?.end ?? 0) + 0.5
    var samples = [Float](repeating: 0, count: Int(end * 16_000))
    for span in words.map({ $0.start..<$0.end }) + loudBetween {
        for index in Int(span.lowerBound * 16_000)..<min(samples.count, Int(span.upperBound * 16_000)) {
            samples[index] = 0.3 * sin(Float(index) * 0.2)
        }
    }
    return samples
}

private let firstParagraph = "We shipped the new onboarding flow last week and the early numbers look good."
private let secondParagraph = "Next we need to decide who owns the billing migration before the end of the month."
private var twoParagraphs: String { firstParagraph + " " + secondParagraph }
/// Index of the last word of `firstParagraph`.
private var firstParagraphEnd: Int { firstParagraph.split(separator: " ").count - 1 }

// MARK: - Layout

final class PauseParagraphsTests: XCTestCase {

    func testLongPauseBetweenSentencesStartsAParagraph() {
        let words = timedWords(twoParagraphs, gaps: [firstParagraphEnd: 2.5])
        let result = PauseParagraphs.apply(
            to: twoParagraphs, segments: [TimedSegment(start: 0, end: 30, text: twoParagraphs, words: words)],
            audio: audio(for: words)
        )
        XCTAssertEqual(result, firstParagraph + "\n\n" + secondParagraph)
    }

    func testShortPauseBetweenSentencesKeepsOneParagraph() {
        let words = timedWords(twoParagraphs, gaps: [firstParagraphEnd: 0.8])
        let result = PauseParagraphs.apply(
            to: twoParagraphs, segments: [TimedSegment(start: 0, end: 30, text: twoParagraphs, words: words)],
            audio: audio(for: words)
        )
        XCTAssertEqual(result, twoParagraphs)
    }

    func testPauseToThinkMidSentenceIsNotABreak() {
        // A long pause after "decide", which ends no sentence.
        let index = twoParagraphs.split(separator: " ").firstIndex(of: "decide") ?? 0
        let words = timedWords(twoParagraphs, gaps: [index: 3.0])
        let result = PauseParagraphs.apply(
            to: twoParagraphs, segments: [TimedSegment(start: 0, end: 30, text: twoParagraphs, words: words)],
            audio: audio(for: words)
        )
        XCTAssertEqual(result, twoParagraphs)
    }

    func testAShortSentenceIsNotLeftStandingAlone() {
        let text = "Okay. " + twoParagraphs
        let words = timedWords(text, gaps: [0: 3.0])
        let result = PauseParagraphs.apply(
            to: text, segments: [TimedSegment(start: 0, end: 30, text: text, words: words)],
            audio: audio(for: words)
        )
        XCTAssertEqual(result, text)
    }

    func testTheAudioDecidesWhetherAGapIsAPause() {
        // Whisper stretches words into the silence around them: the timed
        // gap is small, but the recording is quiet for two seconds.
        var words = timedWords(twoParagraphs, gaps: [firstParagraphEnd: 3.0])
        let quietAudio = audio(for: words)
        words[firstParagraphEnd].end += 1.0
        words[firstParagraphEnd + 1].start -= 1.0
        let stretched = PauseParagraphs.apply(
            to: twoParagraphs, segments: [TimedSegment(start: 0, end: 30, text: twoParagraphs, words: words)],
            audio: quietAudio
        )
        XCTAssertEqual(stretched, firstParagraph + "\n\n" + secondParagraph)

        // A long timed gap the speaker filled with an "um" the engine left
        // out is no pause.
        let gapped = timedWords(twoParagraphs, gaps: [firstParagraphEnd: 2.4])
        let gapStart = gapped[firstParagraphEnd].end, gapEnd = gapped[firstParagraphEnd + 1].start
        let filled = PauseParagraphs.apply(
            to: twoParagraphs, segments: [TimedSegment(start: 0, end: 30, text: twoParagraphs, words: gapped)],
            audio: audio(for: gapped, loudBetween: [(gapStart + 0.3)..<(gapEnd - 0.3)])
        )
        XCTAssertEqual(filled, twoParagraphs)
    }

    func testAFullStopEmittedLateStillBreaksAfterItsSentence() {
        // Parakeet emits a sentence's full stop as the next word starts, so
        // "good." seems to last the whole pause.
        var words = timedWords(twoParagraphs, gaps: [firstParagraphEnd: 2.6])
        let quietAudio = audio(for: words)
        words[firstParagraphEnd].end = words[firstParagraphEnd + 1].start
        let result = PauseParagraphs.apply(
            to: twoParagraphs, segments: [TimedSegment(start: 0, end: 30, text: twoParagraphs, words: words)],
            audio: quietAudio
        )
        XCTAssertEqual(result, firstParagraph + "\n\n" + secondParagraph)
    }

    func testQuietBeforeTheFirstWordOrAfterTheLastIsNoBoundary() {
        let words = timedWords("one two three", gaps: [1: 2.0]).map { $0.mappingTimes { $0 + 3 } }
        XCTAssertNil(PauseParagraphs.nearestBoundary(to: 0..<3, in: words))
        XCTAssertNil(PauseParagraphs.nearestBoundary(to: 10..<12, in: words))
        XCTAssertEqual(PauseParagraphs.nearestBoundary(to: 3.8..<5.6, in: words), 1)
    }

    func testWithoutAudioTheTimedGapStandsIn() {
        let words = timedWords(twoParagraphs, gaps: [firstParagraphEnd: 2.5])
        let result = PauseParagraphs.apply(
            to: twoParagraphs, segments: [TimedSegment(start: 0, end: 30, text: twoParagraphs, words: words)],
            audio: nil
        )
        XCTAssertEqual(result, firstParagraph + "\n\n" + secondParagraph)
    }

    func testWithoutWordTimingsNothingChanges() {
        let result = PauseParagraphs.apply(
            to: twoParagraphs, segments: [TimedSegment(start: 0, end: 30, text: twoParagraphs)],
            audio: nil
        )
        XCTAssertEqual(result, twoParagraphs)
    }

    func testTextThatAlreadyHasLinesIsLeftAlone() {
        let text = firstParagraph + "\n" + secondParagraph
        let words = timedWords(twoParagraphs, gaps: [firstParagraphEnd: 2.5])
        let result = PauseParagraphs.apply(
            to: text, segments: [TimedSegment(start: 0, end: 30, text: text, words: words)], audio: nil
        )
        XCTAssertEqual(result, text)
    }

    func testABreakNextToAWordTheTextChangedIsSkipped() {
        // The engine's timed word after the pause ("Nest") isn't the text's
        // ("Next"): where the pause falls is unclear.
        let heard = twoParagraphs.replacingOccurrences(of: "Next", with: "Nest")
        let words = timedWords(heard, gaps: [firstParagraphEnd: 2.5])
        let result = PauseParagraphs.apply(
            to: twoParagraphs, segments: [TimedSegment(start: 0, end: 30, text: heard, words: words)], audio: nil
        )
        XCTAssertEqual(result, twoParagraphs, "The word after the pause differs, so the break isn't made")

        let farther = twoParagraphs.replacingOccurrences(of: "billing", with: "building")
        let fartherWords = timedWords(farther, gaps: [firstParagraphEnd: 2.5])
        let kept = PauseParagraphs.apply(
            to: twoParagraphs, segments: [TimedSegment(start: 0, end: 30, text: farther, words: fartherWords)],
            audio: nil
        )
        XCTAssertEqual(kept, firstParagraph + "\n\n" + secondParagraph)
    }

    func testAlignmentJoinsWordPiecesAndIgnoresPunctuation() {
        let textWords = PauseParagraphs.words(in: "Hello, world. Bye now.")
        let timed = [
            TimedWord(word: " Hel", start: 0, end: 0.2),
            TimedWord(word: "lo", start: 0.2, end: 0.4),
            TimedWord(word: " world.", start: 0.5, end: 0.9),
            TimedWord(word: " bye", start: 3, end: 3.2),
            TimedWord(word: " now", start: 3.3, end: 3.5)
        ]
        let boundaries = PauseParagraphs.alignedBoundaries(timed: timed, textWords: textWords)
        XCTAssertEqual(boundaries.map(\.0), [1, 2, 3], "No boundary inside \"Hello\"")
        XCTAssertEqual(boundaries.map(\.1), [0, 1, 2])
    }

    func testSentenceEnds() {
        XCTAssertTrue(PauseParagraphs.endsSentence("month."))
        XCTAssertTrue(PauseParagraphs.endsSentence("really?\""))
        XCTAssertTrue(PauseParagraphs.endsSentence("(done!)"))
        XCTAssertFalse(PauseParagraphs.endsSentence("month,"))
        XCTAssertFalse(PauseParagraphs.endsSentence("Dr."))
        XCTAssertFalse(PauseParagraphs.endsSentence("3.5"))
    }

    // MARK: Quiet stretches

    func testQuietStretchesFindsSilenceBetweenSpeech() {
        let words = timedWords("one two three", gap: 0.1, gaps: [1: 2.0])
        let stretches = PauseParagraphs.quietStretches(in: audio(for: words), minimumSeconds: 1.0)
        XCTAssertEqual(stretches.count, 1, "The trailing half second is too short to count")
        let pause = stretches.first
        XCTAssertNotNil(pause)
        XCTAssertEqual(pause?.lowerBound ?? 0, words[1].end, accuracy: 0.03)
        XCTAssertEqual(pause?.upperBound ?? 0, words[2].start, accuracy: 0.03)
    }

    func testAWhisperIsSpeechNextToItsOwnSilence() {
        // Quiet speech (about -40 dBFS) still stands out from silence.
        var samples = [Float](repeating: 0, count: 16_000 * 3)
        for index in 0..<16_000 { samples[index] = 0.01 * sin(Float(index) * 0.2) }
        for index in 32_000..<48_000 { samples[index] = 0.01 * sin(Float(index) * 0.2) }
        let stretches = PauseParagraphs.quietStretches(in: samples, minimumSeconds: 0.5)
        XCTAssertEqual(stretches.count, 1)
        XCTAssertEqual(stretches.first?.lowerBound ?? 0, 1.0, accuracy: 0.03)
        XCTAssertEqual(stretches.first?.upperBound ?? 0, 2.0, accuracy: 0.03)
    }

    // MARK: Greeting

    func testGreetingGetsALineOfItsOwn() {
        XCTAssertEqual(
            PauseParagraphs.separatingGreeting("Hi Sarah, thanks for sending the deck over."),
            "Hi Sarah,\n\nThanks for sending the deck over."
        )
        XCTAssertEqual(
            PauseParagraphs.separatingGreeting("Good morning team, the build is green again."),
            "Good morning team,\n\nThe build is green again."
        )
    }

    func testNotEveryHeyIsAGreeting() {
        for text in [
            "Hey, can you send me the deck?",
            "Hi Sarah, thanks.",
            "Hello there.",
            "Highlights from the call, mostly good news."
        ] {
            XCTAssertEqual(PauseParagraphs.separatingGreeting(text), text)
        }
    }
}

// MARK: - Styles

final class PauseParagraphsStyleTests: XCTestCase {
    func testOnlyProseStylesTakeParagraphs() {
        XCTAssertEqual(
            Set(WritingStyle.allCases.filter(\.allowsParagraphs)),
            [.plain, .email, .notes]
        )
    }
}

// MARK: - Parakeet word timings

final class ParakeetTimedWordsTests: XCTestCase {
    func testTokensJoinIntoWords() {
        let tokens = [
            TokenTiming(token: " hel", tokenId: 1, startTime: 0.0, endTime: 0.2, confidence: 0.9),
            TokenTiming(token: "lo", tokenId: 2, startTime: 0.2, endTime: 0.3, confidence: 0.6),
            TokenTiming(token: ",", tokenId: 3, startTime: 0.3, endTime: 0.32, confidence: 0.8),
            TokenTiming(token: " world", tokenId: 4, startTime: 2.0, endTime: 2.4, confidence: 0.95)
        ]
        let segments = ParakeetService.timedSegments(from: tokens, text: "hello, world")
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "hello, world")
        XCTAssertEqual(segments[0].words.map(\.word), ["hello,", "world"])
        XCTAssertEqual(segments[0].words[0].end, 0.3, accuracy: 0.001, "Punctuation doesn't stretch the word")
        XCTAssertEqual(segments[0].words[0].probability ?? 0, 0.6, accuracy: 0.001)
        XCTAssertEqual(segments[0].start, 0)
        XCTAssertEqual(segments[0].end, 2.4, accuracy: 0.001)
    }

    func testNoTokensNoSegments() {
        XCTAssertTrue(ParakeetService.timedSegments(from: [], text: "").isEmpty)
    }
}

// MARK: - Through the output pipeline

@MainActor
final class PauseParagraphsPipelineTests: XCTestCase {

    private func process(
        _ input: String, cleaner: MockTranscriptCleanup, format: WritingStyle = .plain,
        enabled: Bool = true, laysOutParagraphs: Bool = true, pieces: [TranscribedPiece] = []
    ) async -> DictationOutputResult {
        await DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander()).process(
            input,
            profile: WritingProfile(format: format, rules: format.defaultRules, intent: .preserve, cleanup: .inherit),
            snippetList: [], cleanupEnabled: enabled, rewritingEnabled: false,
            model: .defaultKind, customPrompt: "", cleanupLevel: .medium,
            language: "en", autoCapitalize: true, trailingSpace: false,
            laysOutParagraphs: laysOutParagraphs, pieces: pieces
        )
    }

    func testEachParagraphIsCleanedOnItsOwnAndTheBreakIsKept() async {
        let cleaner = MockTranscriptCleanup()
        var inputs: [String] = []
        cleaner.cleanHandler = { text in
            inputs.append(text)
            return text
        }
        let input = "So um, we shipped the new onboarding flow last week.\n\n"
            + "Next, um, we need to decide who owns the billing migration."
        let result = await process(input, cleaner: cleaner)
        XCTAssertEqual(inputs.count, 2, "\(inputs)")
        XCTAssertFalse(inputs.contains { $0.contains("\n") }, "The model never sees a line break: \(inputs)")
        XCTAssertTrue(result.text.contains(".\n\nNext"), result.text)
    }

    func testFormattingOnlyKeepsTheBreak() async {
        let input = "we shipped the new onboarding flow last week.\n\nnext we need to decide who owns billing."
        let result = await process(input, cleaner: MockTranscriptCleanup(), format: .email, enabled: false)
        XCTAssertEqual(
            result.text,
            "We shipped the new onboarding flow last week.\n\nNext we need to decide who owns billing."
        )
    }

    func testEmailGreetingIsSeparatedOnlyWhenLayoutIsOn() async {
        let input = "Hi Sarah, thanks for sending the deck over."
        let on = await process(input, cleaner: MockTranscriptCleanup(), format: .email, enabled: false)
        XCTAssertEqual(on.text, "Hi Sarah,\n\nThanks for sending the deck over.")

        let off = await process(
            input, cleaner: MockTranscriptCleanup(), format: .email, enabled: false, laysOutParagraphs: false
        )
        XCTAssertEqual(off.text, input)

        let chat = await process(input, cleaner: MockTranscriptCleanup(), format: .chat, enabled: false)
        XCTAssertEqual(chat.text, input, "Only emails get a greeting line")
    }

    func testPiecesStillMatchAcrossAParagraphBreak() {
        // The live session decoded two pieces; a pause inside the first one
        // became a paragraph break in the whole text.
        let pieces = [
            TranscribedPiece(range: 0..<16_000, text: "First sentence here. Second sentence here.", language: "en"),
            TranscribedPiece(range: 16_000..<32_000, text: "Third sentence here.", language: "en")
        ]
        let whole = "First sentence here.\n\nSecond sentence here. Third sentence here."
        let slices = DictationOutputPipeline.splittingParagraphs(
            DictationOutputPipeline.slices(of: whole, pieces: pieces) { $0 }
        )
        XCTAssertEqual(slices.map(\.text), ["First sentence here.", "Second sentence here.", "Third sentence here."])
        XCTAssertEqual(slices.map(\.separatorBefore), ["", "\n\n", " "])
    }

    func testSplittingLeavesTextWithoutBlankLinesAlone() {
        let slice = DictationOutputPipeline.TextSlice(text: "One line.\nAnother line.", separatorBefore: " ")
        XCTAssertEqual(DictationOutputPipeline.splittingParagraphs([slice]), [slice])
    }
}
