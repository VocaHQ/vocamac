// RecognitionHintsTests.swift
// VocaMac
//
// Dictionary vocabulary as a recognition hint for every engine that takes one.

import XCTest
@testable import VocaMac

final class RecognitionHintsTests: XCTestCase {

    // MARK: Terms

    func testTermsDropDuplicatesIgnoringCase() {
        XCTAssertEqual(RecognitionHints.terms(from: "GitHub, github\nVocaMac,, "), ["GitHub", "VocaMac"])
    }

    func testContextualStringsKeepTheUsersWordsWithinTheCap() {
        let many = (0..<150).map { "Term\($0)" }.joined(separator: ",")
        let strings = RecognitionHints.contextualStrings(from: many)
        XCTAssertEqual(strings.count, RecognitionHints.maximumContextualStrings)
        // The user's own terms come last in the recognition vocabulary.
        XCTAssertEqual(strings.last, "Term149")
    }

    func testBoostTermsSkipShortWordsAndStopwords() {
        XCTAssertEqual(RecognitionHints.boostTerms(from: "AWS, kubectl, with, NVIDIA, Jira"),
                       ["kubectl", "NVIDIA", "Jira"])
    }

    func testBoostTermsCountLettersAndDigitsOnly() {
        XCTAssertEqual(RecognitionHints.boostTerms(from: "C++, GPT-4"), ["GPT-4"])
    }

    func testHintableReplacements() {
        XCTAssertTrue(RecognitionHints.isHintableReplacement("GitHub"))
        XCTAssertTrue(RecognitionHints.isHintableReplacement("Visual Studio Code"))
        XCTAssertFalse(RecognitionHints.isHintableReplacement("me@example.com"))
        XCTAssertFalse(RecognitionHints.isHintableReplacement("https://vocamac.com"))
        XCTAssertFalse(RecognitionHints.isHintableReplacement("Thanks for reaching out to us"))
        XCTAssertFalse(RecognitionHints.isHintableReplacement("42"))
    }

    // MARK: Recognition vocabulary

    @MainActor
    func testReplacementTargetsJoinTheVocabularyBeforeUserTerms() {
        let prompt = AppState.recognitionVocabulary(
            "VocaMac", replacementTargets: ["GitHub", "vocamac", "me@example.com"], contextTerms: ["userId"]
        )
        XCTAssertEqual(prompt, "userId, GitHub, VocaMac")
    }

    @MainActor
    func testReplacementTargetsDefaultToNone() {
        XCTAssertEqual(AppState.recognitionVocabulary("VocaMac", contextTerms: []), "VocaMac")
    }

    // MARK: Parakeet boost safety

    private typealias Replacement = ParakeetVocabularyBoost.Replacement

    /// What FluidAudio's rescorer proposed for a real Parakeet transcript of
    /// "Please send the report to Namratha and ask her about the Zorblax
    /// rollout on Kubernetes tomorrow."
    private let observed = [
        Replacement(original: "Namratha", replacement: "Namrata"),
        Replacement(original: "Zorblak's", replacement: "Zorblax"),
        Replacement(original: "Kubernetes tomorrow.", replacement: "Kubectl"),
        Replacement(original: "ask her about", replacement: "NVIDIA"),
        Replacement(original: "send the report", replacement: "NVIDIA"),
    ]
    private let transcript = "Please send the report to Namratha and ask her about the Zorblak's rollout on Kubernetes tomorrow."
    private let terms = ["Namrata", "Zorblax", "Kubernetes", "NVIDIA", "kubectl"]

    func testBoostKeepsOnlyCloseSpellingsOfUserTerms() {
        let kept = ParakeetVocabularyBoost.accepted(observed, in: transcript, terms: terms, isKnownWord: { _ in false })
        XCTAssertEqual(kept.map(\.replacement), ["Namrata", "Zorblax"])
        XCTAssertEqual(
            ParakeetVocabularyBoost.apply(kept, to: transcript),
            "Please send the report to Namrata and ask her about the Zorblax rollout on Kubernetes tomorrow."
        )
    }

    func testBoostRefusesReplacementsOutsideTheVocabulary() {
        XCTAssertTrue(ParakeetVocabularyBoost.accepted(
            [Replacement(original: "Invidia", replacement: "Invidia2")], in: "ask Invidia", terms: ["NVIDIA"],
            isKnownWord: { _ in false }
        ).isEmpty)
    }

    func testBoostRefusesTooManyReplacements() {
        let text = "Namratha one two three four five six seven Namratha"
        let replacements = [
            Replacement(original: "Namratha", replacement: "Namrata"),
            Replacement(original: "Namratha", replacement: "Namrata"),
        ]
        XCTAssertEqual(ParakeetVocabularyBoost.maximumReplacements(wordCount: 9), 1)
        XCTAssertTrue(ParakeetVocabularyBoost.accepted(
            replacements, in: text, terms: ["Namrata"], isKnownWord: { _ in false }
        ).isEmpty)
    }

    func testBoostJoinsSpokenWordsIntoATerm() {
        let kept = ParakeetVocabularyBoost.accepted(
            [Replacement(original: "voca mack", replacement: "VocaMac")], in: "open voca mack now", terms: ["VocaMac"],
            isKnownWord: { $0 == "mack" }
        )
        XCTAssertEqual(ParakeetVocabularyBoost.apply(kept, to: "open voca mack now"), "open VocaMac now")
    }

    /// FluidAudio's rescorer proposed "server" → sergey on every clip of
    /// "Yes, please restart the server." with Sergey in the Dictionary.
    func testBoostKeepsRealWordsParakeetHeard() {
        let englishWords: Set<String> = ["server", "yes", "please", "restart", "the"]
        let text = "Yes, please restart the server."
        XCTAssertTrue(ParakeetVocabularyBoost.accepted(
            [Replacement(original: "server.", replacement: "sergey")], in: text, terms: ["sergey"],
            isKnownWord: englishWords.contains
        ).isEmpty)

        let misheard = [Replacement(original: "Sergei", replacement: "Sergey")]
        XCTAssertEqual(ParakeetVocabularyBoost.accepted(
            misheard, in: "I sent the report to Sergei yesterday", terms: ["Sergey"],
            isKnownWord: englishWords.contains
        ), misheard)
    }

    func testApplyKeepsPunctuationAndOrder() {
        let text = "Namratha, then Namratha."
        let result = ParakeetVocabularyBoost.apply(
            [Replacement(original: "Namratha,", replacement: "Namrata"),
             Replacement(original: "Namratha.", replacement: "Namrata")],
            to: text
        )
        XCTAssertEqual(result, "Namrata, then Namrata.")
    }

    // MARK: Router recovery

    func testOnlyRealDecodeFailuresCountTowardReload() {
        XCTAssertTrue(TranscriptionRouter.isModelFailure(WhisperError.transcriptionFailed(reason: "x")))
        XCTAssertTrue(TranscriptionRouter.isModelFailure(ParakeetError.transcriptionFailed(reason: "x")))
        XCTAssertFalse(TranscriptionRouter.isModelFailure(CancellationError()))
        XCTAssertFalse(TranscriptionRouter.isModelFailure(WhisperError.emptyAudio))
        XCTAssertFalse(TranscriptionRouter.isModelFailure(ParakeetError.modelNotLoaded))
        XCTAssertFalse(TranscriptionRouter.isModelFailure(AppleSpeechError.emptyAudio))
        XCTAssertFalse(TranscriptionRouter.isModelFailure(SherpaError.modelNotLoaded))
    }
}
