// AccuracyGuardsTests.swift
// VocaMac
//
// The rules that keep noise, a quiet mic, a seam between decoded pieces, or
// a guessed language from reaching the text.

import XCTest
@testable import VocaMac

// MARK: - Hallucination guard

final class HallucinationGuardDetectorTests: XCTestCase {

    func testOtherLanguagesStockPhrasesAreDroppedOverUnconfirmedSpeech() {
        let cases: [(String, String)] = [
            ("Untertitel im Auftrag des ZDF", "de"), ("Vielen Dank.", "de"),
            ("Sous-titres réalisés par la communauté d'Amara.org", "fr"),
            ("Gracias por ver el video.", "es"), ("ご視聴ありがとうございました", "ja"),
            ("Продолжение следует...", "ru"),
        ]
        for (text, language) in cases {
            XCTAssertEqual(HallucinationGuard.filter(text, speechUnconfirmed: true, language: language), "", text)
        }
    }

    func testAnotherLanguagesPhraseNeedsThatLanguageOrNone() {
        // "Danke" is German filler, not something to drop from French audio.
        XCTAssertEqual(HallucinationGuard.filter("Danke.", speechUnconfirmed: true, language: "fr"), "Danke.")
        XCTAssertEqual(HallucinationGuard.filter("Danke.", speechUnconfirmed: true, language: "auto"), "")
        // English filler is checked in every language.
        XCTAssertEqual(HallucinationGuard.filter("Thank you.", speechUnconfirmed: true, language: "de"), "")
    }

    func testConfirmedSpeechIsNeverTouched() {
        XCTAssertEqual(
            HallucinationGuard.filter("Vielen Dank.", detector: .confirmed, engineHeardNoSpeech: true, language: "de"),
            "Vielen Dank."
        )
    }

    func testAnUncheckedRecordingNeedsTheEnginesWord() {
        XCTAssertEqual(HallucinationGuard.filter("Thank you.", detector: .unchecked), "Thank you.")
        XCTAssertEqual(HallucinationGuard.filter("Thank you.", detector: .unchecked, engineHeardNoSpeech: true), "")
        XCTAssertEqual(
            HallucinationGuard.filter("Thank you for the notes.", detector: .unchecked, engineHeardNoSpeech: true),
            "Thank you for the notes."
        )
    }

    func testTheRouterJoinsDetectorEngineAndLevel() {
        let thanks = VocaTranscription(
            text: "Thank you.", duration: 0, detectedLanguage: "en", audioLengthSeconds: 1, modelUsed: .tiny
        )
        var unchecked = SpeechOnlyAudio(samples: [], speechUnchecked: true)
        XCTAssertEqual(TranscriptionRouter.guardedText(thanks, prepared: unchecked), "Thank you.")

        // Near-digital silence at the input says no one spoke.
        unchecked.rms = 0.000_01
        XCTAssertEqual(TranscriptionRouter.guardedText(thanks, prepared: unchecked), "")

        // So does a decoder guessing from start to end.
        var guessed = thanks
        guessed.quality = DecodeQuality(averageLogProbability: -2, compressionRatio: 1)
        XCTAssertEqual(
            TranscriptionRouter.guardedText(guessed, prepared: SpeechOnlyAudio(samples: [], speechUnchecked: true)), ""
        )
        XCTAssertEqual(TranscriptionRouter.guardedText(guessed, prepared: SpeechOnlyAudio(samples: [])), "Thank you.")
    }

    func testSkipSilenceOffStillDecodesEverythingButKnowsWhatTheDetectorSaid() {
        let samples = [Float](repeating: 0.1, count: 1_600)
        let off = { TranscriptionRouter.speechOnlyAudio(samples, decision: $0, trimsSilence: false, sampleCount: 1_600) }
        XCTAssertEqual(off(.noSpeech)?.detector, .unconfirmed, "decoded, but guarded")
        XCTAssertEqual(off(.unsure)?.detector, .unconfirmed)
        XCTAssertEqual(off(.trim([0..<800]))?.samples.count, 1_600, "nothing is trimmed")
        XCTAssertEqual(off(.trim([0..<800]))?.detector, .confirmed)
        XCTAssertEqual(off(.unchecked)?.detector, .unchecked)

        let on = { TranscriptionRouter.speechOnlyAudio(samples, decision: $0, trimsSilence: true, sampleCount: 1_600) }
        XCTAssertNil(on(.noSpeech))
        XCTAssertEqual(on(.keep)?.detector, .confirmed)
    }
}

// MARK: - Input level

final class InputLevelTests: XCTestCase {

    func testMeasurement() {
        let level = InputLevel.measure([0.5, -0.5, 0.5, -0.5])
        XCTAssertEqual(level.peak, 0.5)
        XCTAssertEqual(level.rms, 0.5, accuracy: 0.0001)
        XCTAssertEqual(level.clippedFraction, 0)
        XCTAssertEqual(InputLevel.measure([]).peak, 0)
    }

    func testAQuietRecordingIsLiftedToTheTargetPeak() {
        let quiet = InputLevel.Measurement(peak: 0.1, rms: 0.01, clippedFraction: 0)
        XCTAssertEqual(InputLevel.gain(for: quiet), 1, "-20 dBFS is loud enough")
        let low = InputLevel.Measurement(peak: 0.04, rms: 0.005, clippedFraction: 0)
        XCTAssertEqual(InputLevel.gain(for: low), InputLevel.maximumGain, "12.5x is capped")
        let moderate = InputLevel.Measurement(peak: 0.08 / 2, rms: 0.01, clippedFraction: 0)
        XCTAssertEqual(InputLevel.gain(for: moderate), InputLevel.maximumGain)
        // Just under the quiet line, a lift brings the peak to about -6 dBFS.
        let nearlyLoud = InputLevel.Measurement(peak: 0.049, rms: 0.01, clippedFraction: 0)
        XCTAssertEqual(0.049 * InputLevel.gain(for: nearlyLoud), 0.49, accuracy: 0.001)
    }

    func testGainIsCappedAndSilenceIsNeverLifted() {
        let whisper = InputLevel.Measurement(peak: 0.002, rms: 0.000_5, clippedFraction: 0)
        XCTAssertEqual(InputLevel.gain(for: whisper), InputLevel.maximumGain)
        let silence = InputLevel.Measurement(peak: 0.000_5, rms: 0.000_01, clippedFraction: 0)
        XCTAssertEqual(InputLevel.gain(for: silence), 1)
        XCTAssertEqual(InputLevel.gain(for: InputLevel.Measurement(peak: 0, rms: 0, clippedFraction: 0)), 1)
    }

    func testApplyingGainClampsToFullScale() {
        XCTAssertEqual(InputLevel.applying(10, to: [0.05, -0.2, 0.25]), [0.5, -1, 1])
        XCTAssertEqual(InputLevel.applying(1, to: [0.3]), [0.3])
    }

    func testWarnings() {
        var clipped = [Float](repeating: 0.2, count: 1_000)
        for index in 0..<5 { clipped[index] = 1 }
        XCTAssertEqual(InputLevel.warning(for: InputLevel.measure(clipped)), .clipping)
        XCTAssertEqual(InputLevel.warning(for: InputLevel.measure([Float](repeating: 0.005, count: 100))), .tooQuiet)
        XCTAssertNil(InputLevel.warning(for: InputLevel.measure([Float](repeating: 0, count: 100))), "muted, not quiet")
        XCTAssertNil(InputLevel.warning(for: InputLevel.measure([0.3, -0.3])))
    }
}

// MARK: - Decode quality and the Whisper retry

final class DecodeQualityTests: XCTestCase {

    func testSegmentsAreWeightedByTokens() throws {
        let quality = try XCTUnwrap(DecodeQuality(segments: [
            .init(averageLogProbability: -0.1, compressionRatio: 1.2, noSpeechProbability: nil, weight: 30),
            .init(averageLogProbability: -2.0, compressionRatio: 2.6, noSpeechProbability: nil, weight: 2),
        ]))
        XCTAssertEqual(quality.averageLogProbability, (-0.1 * 30 - 2.0 * 2) / 32, accuracy: 0.0001)
        XCTAssertEqual(quality.compressionRatio, 2.6)
        XCTAssertNil(quality.noSpeechProbability)
        XCTAssertNil(DecodeQuality(segments: []))
    }

    func testWhispersFallbackRule() {
        XCTAssertFalse(DecodeQuality(averageLogProbability: -0.3, compressionRatio: 1.5).needsRetry)
        XCTAssertTrue(DecodeQuality(averageLogProbability: -1.2, compressionRatio: 1.5).needsRetry)
        XCTAssertTrue(DecodeQuality(averageLogProbability: -0.3, compressionRatio: 2.8).needsRetry)
    }

    func testNoSpeechNeedsLowConfidenceToo() {
        XCTAssertTrue(DecodeQuality(averageLogProbability: -1.2, compressionRatio: 1, noSpeechProbability: 0.8).suggestsNoSpeech)
        XCTAssertFalse(DecodeQuality(averageLogProbability: -0.2, compressionRatio: 1, noSpeechProbability: 0.8).suggestsNoSpeech)
        // Without a no-speech probability, only a decode guessing throughout.
        XCTAssertFalse(DecodeQuality(averageLogProbability: -1.2, compressionRatio: 1).suggestsNoSpeech)
        XCTAssertTrue(DecodeQuality(averageLogProbability: -1.8, compressionRatio: 1).suggestsNoSpeech)
    }

    func testARetryIsKeptOnlyWhenItScoresBetter() {
        let original = DecodeQuality(averageLogProbability: -1.3, compressionRatio: 1.4)
        let better = DecodeQuality(averageLogProbability: -0.6, compressionRatio: 1.5)
        let worse = DecodeQuality(averageLogProbability: -1.5, compressionRatio: 1.2)
        let loopier = DecodeQuality(averageLogProbability: -0.5, compressionRatio: 3.0)
        XCTAssertTrue(WhisperService.acceptsLowConfidenceRetry("Ship it Friday.", quality: better, original: original, audioSeconds: 2))
        XCTAssertFalse(WhisperService.acceptsLowConfidenceRetry("Ship it Friday.", quality: worse, original: original, audioSeconds: 2))
        XCTAssertFalse(WhisperService.acceptsLowConfidenceRetry("", quality: better, original: original, audioSeconds: 2))
        XCTAssertFalse(loopier.isBetter(than: original), "more confident but repeating past the limit")
    }

    func testOnlyALowConfidenceDecodeWithWordsIsRetried() {
        let low = DecodeQuality(averageLogProbability: -1.4, compressionRatio: 1.3)
        XCTAssertTrue(WhisperService.shouldRetryLowConfidence("ship it friday", quality: low))
        XCTAssertFalse(WhisperService.shouldRetryLowConfidence("  ", quality: low))
        XCTAssertFalse(WhisperService.shouldRetryLowConfidence(
            "ship it friday", quality: DecodeQuality(averageLogProbability: -0.2, compressionRatio: 1.3)
        ))
    }
}

// MARK: - Language prior

final class LanguagePriorTests: XCTestCase {

    func testAReportedLanguageWins() {
        XCTAssertEqual(DictationOutputPipeline.languagePrior(reported: "fr", spoken: ["de"], text: "bonjour"), "fr")
    }

    func testOneSpokenLanguageStandsInForAuto() {
        XCTAssertEqual(DictationOutputPipeline.languagePrior(reported: "auto", spoken: ["de"], text: "um 5"), "de")
        XCTAssertNil(DictationOutputPipeline.languagePrior(reported: "auto", spoken: ["de", "en"], text: "um 5"))
        XCTAssertNil(DictationOutputPipeline.languagePrior(reported: nil, spoken: [], text: "hello"))
    }

    func testConfidentTextInAnotherLanguageOverrulesTheOnlySpokenOne() {
        let german = "Wir treffen uns morgen um fünf Uhr im Büro und besprechen den Plan für die nächste Woche."
        XCTAssertNil(DictationOutputPipeline.languagePrior(reported: "auto", spoken: ["en"], text: german))
    }

    func testNoEnglishSpokenMeansNoEnglishRules() {
        XCTAssertFalse(DictationOutputPipeline.isEnglishText("hello world", language: nil, spoken: ["de", "fr"]))
        XCTAssertTrue(DictationOutputPipeline.isEnglishText("hello world", language: nil, spoken: []))
        XCTAssertTrue(DictationOutputPipeline.isEnglishText("hallo", language: "en", spoken: ["de"]))
    }

    func testALeanTowardsAnotherSpokenLanguageIsEnough() {
        let german = "wir treffen uns um 5 Uhr"
        XCTAssertFalse(DictationOutputPipeline.isEnglishText(german, language: nil, spoken: ["en", "de"]))
        XCTAssertTrue(DictationOutputPipeline.isEnglishText(
            "let's meet at five and go over the plan", language: nil, spoken: ["en", "de"]
        ))
    }

    @MainActor
    func testGermanFromAGermanSpeakerKeepsUmWhenTheEngineSaysAuto() async {
        let cleaner = MockTranscriptCleanup()
        let result = await DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander()).process(
            "wir treffen uns um 5 Uhr",
            profile: WritingProfile(format: .plain, rules: WritingStyle.plain.defaultRules),
            snippetList: [], cleanupEnabled: false, rewritingEnabled: false,
            model: .defaultKind, customPrompt: "", language: "auto", autoCapitalize: true, trailingSpace: false,
            spokenLanguages: ["de"]
        )
        XCTAssertTrue(result.text.contains("um 5 Uhr"), result.text)
    }
}

// MARK: - Glossary respelling needs evidence

final class GlossaryConfidenceGateTests: XCTestCase {

    private func merge(_ lowConfidence: Set<String>?) -> String {
        EditMerge.merge(
            original: "ask cloud to review it", candidate: "Ask Claude to review it.", level: .medium,
            glossary: ["Claude"], lowConfidenceWords: lowConfidence,
            isKnownWord: { ["ask", "cloud", "to", "review", "it"].contains($0) }
        ).text
    }

    func testAWordTheEngineWasSureOfStays() {
        XCTAssertEqual(merge([]), "Ask cloud to review it.")
        XCTAssertEqual(merge(["review"]), "Ask cloud to review it.")
    }

    func testAnUnsureWordIsRespelled() {
        XCTAssertEqual(merge(["cloud"]), "Ask Claude to review it.")
    }

    func testWithoutConfidenceSpellingDecidesAsBefore() {
        XCTAssertEqual(merge(nil), "Ask Claude to review it.")
    }

    func testTheSameLettersNeedNoEvidence() {
        let text = EditMerge.merge(
            original: "we use open ai", candidate: "We use OpenAI.", level: .medium,
            glossary: ["OpenAI"], lowConfidenceWords: [],
            isKnownWord: { ["we", "use", "open", "ai"].contains($0) }
        ).text
        XCTAssertEqual(text, "We use OpenAI.")
    }
}

// MARK: - Seams

final class SeamRepairTests: XCTestCase {

    func testACutInRunningSpeechIsMended() {
        let mended = SeamRepair.repair(
            left: "We should move the.", right: "Meeting to Friday.", cutInPause: false, language: "en"
        )
        XCTAssertEqual(mended.left, "We should move the.", "\"Meeting\" can open a sentence")
        let joined = SeamRepair.repair(
            left: "We should move the meeting.", right: "To Friday afternoon.", cutInPause: false, language: "en"
        )
        XCTAssertEqual(joined.left, "We should move the meeting")
        XCTAssertEqual(joined.right, "to Friday afternoon.")
    }

    func testACutInAPauseIsLeftAlone() {
        let pair = SeamRepair.repair(left: "We met.", right: "And then left.", cutInPause: true, language: "en")
        XCTAssertEqual(pair.left, "We met.")
        XCTAssertEqual(pair.right, "And then left.")
    }

    func testOnlyAPlainFullStopAndAContinuationWord() {
        for (left, right) in [
            ("It was in the U.S.", "And then"), ("Wait...", "And then"), ("Done.", "I left"),
            ("Done.", "Priya left"), ("Done!", "And then"), ("Done.", "AND then"),
        ] {
            let pair = SeamRepair.repair(left: left, right: right, cutInPause: false, language: "en")
            XCTAssertEqual(pair.left, left, left)
            XCTAssertEqual(pair.right, right, right)
        }
    }

    func testOtherLanguagesAreLeftAlone() {
        let pair = SeamRepair.repair(left: "Wir gehen.", right: "Und dann", cutInPause: false, language: "de")
        XCTAssertEqual(pair.left, "Wir gehen.")
    }

    func testPauseDetection() {
        let speech = (0..<16_000).map { Float(sin(Double($0) * 0.3)) * 0.5 }
        let quiet = [Float](repeating: 0.001, count: 4_000)
        let samples = speech + quiet + speech
        XCTAssertTrue(SeamRepair.isPause(at: 18_000, in: samples))
        XCTAssertFalse(SeamRepair.isPause(at: 8_000, in: samples))
        XCTAssertTrue(SeamRepair.isPause(at: 0, in: samples), "an edge is no seam")
    }

    func testSherpaSegmentsAreMendedOnlyWhereTheCutWasInSpeech() throws {
        var texts = ["We should move the meeting.", "To Friday.", "And then lunch."]
        let decoded = try SherpaService.decodeSegments(
            [[0.1], [0.2], [0.3]], language: "en", recoversEmpty: false, cutsInPause: [false, true]
        ) { _ in (texts.removeFirst(), "") }
        XCTAssertEqual(decoded.text, "We should move the meeting to Friday. And then lunch.")
    }

    func testAnEmptySegmentBreaksTheSeam() throws {
        var texts = ["We met.", "", "And then left."]
        let decoded = try SherpaService.decodeSegments(
            [[0.1], [0.2], [0.3]], language: "en", recoversEmpty: false, cutsInPause: [false, false]
        ) { _ in (texts.removeFirst(), "") }
        XCTAssertEqual(decoded.text, "We met. And then left.")
    }
}

// MARK: - Hint ordering by use

final class TermUsageTests: XCTestCase {

    func testTermsFoundInTheTextAreCounted() {
        let now = Date(timeIntervalSince1970: 1_000)
        let usage = TermUsage.recording(
            "Ask Claude about kubectl.", terms: ["Claude", "kubectl", "Priya", "claude"], in: [:], now: now
        )
        XCTAssertEqual(usage["claude"], TermUsage(count: 1, lastUsed: now))
        XCTAssertEqual(usage["kubectl"]?.count, 1)
        XCTAssertNil(usage["priya"])
        let again = TermUsage.recording("claude again", terms: ["Claude"], in: usage, now: now.addingTimeInterval(5))
        XCTAssertEqual(again["claude"]?.count, 2)
    }

    func testOnlyWholeWordsCount() {
        XCTAssertFalse(TermUsage.contains("Ray", in: "the array is empty"))
        XCTAssertTrue(TermUsage.contains("Ray", in: "ask ray, then"))
        XCTAssertTrue(TermUsage.contains("C++", in: "write it in C++."))
    }

    func testRecentlyUsedTermsGoLastWhereTheyAreKept() {
        let usage: [String: TermUsage] = [
            "alpha": TermUsage(count: 3, lastUsed: Date(timeIntervalSince1970: 200)),
            "gamma": TermUsage(count: 1, lastUsed: Date(timeIntervalSince1970: 100)),
        ]
        XCTAssertEqual(TermUsage.ordered(["Alpha", "Beta", "Gamma", "Delta"], by: usage), ["Beta", "Delta", "Gamma", "Alpha"])
        XCTAssertEqual(TermUsage.ordered(["A", "B"], by: [:]), ["A", "B"])
    }

    @MainActor
    func testTheRecognitionVocabularyIsOrderedByUse() {
        let usage = ["vocamac": TermUsage(count: 4, lastUsed: Date())]
        XCTAssertEqual(
            AppState.recognitionVocabulary("VocaMac, Namrata", contextTerms: ["Screen"], usage: usage),
            "Screen, Namrata, VocaMac"
        )
    }

    func testStorageRoundTrips() {
        let usage = ["claude": TermUsage(count: 2, lastUsed: Date(timeIntervalSince1970: 1_234))]
        XCTAssertEqual(TermUsage.decode(TermUsage.encode(usage)), usage)
        XCTAssertEqual(TermUsage.decode(["bad": [1.0]]), [:])
    }
}

// MARK: - Apple Speech word timings

final class AppleSpeechWordPlacementTests: XCTestCase {

    func testWordsGoToTheSegmentTheyFallIn() {
        let tracker = FinalizedPieceTracker(language: "en") { _, _ in }
        tracker.finalized("Hello there.", endSeconds: 1.5, words: [
            TimedWord(word: "Hello", start: 0.1, end: 0.5, probability: 0.9),
            TimedWord(word: "there.", start: 0.6, end: 1.0, probability: 0.4),
        ])
        tracker.finalized(" Bye.", endSeconds: 3, words: [TimedWord(word: "Bye.", start: 2, end: 2.4, probability: 0.8)])
        let segments = tracker.attachingWords(to: [
            TimedSegment(start: 0, end: 1.5, text: "Hello there."), TimedSegment(start: 1.5, end: 3, text: "Bye."),
        ])
        XCTAssertEqual(segments.map { $0.words.map(\.word) }, [["Hello", "there."], ["Bye."]])
        XCTAssertEqual(RecognitionConfidence.lowConfidenceWords(in: segments), ["there"])
    }

    func testNoWordsLeavesSegmentsAlone() {
        let tracker = FinalizedPieceTracker(language: "en") { _, _ in }
        let segments = [TimedSegment(start: 0, end: 1, text: "Hi")]
        XCTAssertEqual(tracker.attachingWords(to: segments), segments)
    }
}
