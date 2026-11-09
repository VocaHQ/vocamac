// TextDeliveryTests.swift
// VocaMac Tests
//
// Typing instead of pasting, Auto Send and its spoken cue, the typed
// fallback when a paste goes unread, and language ID's choices.

import AppKit
import XCTest
@testable import VocaMac

final class AutoSendCueTests: XCTestCase {

    func testCueAsItsOwnSentenceIsFound() {
        XCTAssertTrue(AutoSendCue.endsWithCue("Thanks, see you soon. Send it."))
        XCTAssertTrue(AutoSendCue.endsWithCue("Running late! Press enter"))
        XCTAssertTrue(AutoSendCue.endsWithCue("Send it."))
        XCTAssertTrue(AutoSendCue.endsWithCue("sounds good? HIT SEND!"))
    }

    func testCueInsideASentenceIsNotARequest() {
        XCTAssertFalse(AutoSendCue.endsWithCue("Let me know and I'll send it."))
        XCTAssertFalse(AutoSendCue.endsWithCue("When you're done, send it."))
        XCTAssertFalse(AutoSendCue.endsWithCue("Please resend it."))
        XCTAssertFalse(AutoSendCue.endsWithCue("Send it to Priya tomorrow."))
        XCTAssertFalse(AutoSendCue.endsWithCue(""))
    }

    func testRemovingTheCueKeepsThePunctuationBeforeIt() {
        XCTAssertEqual(AutoSendCue.removingCue(from: "Thanks. Send it. "), "Thanks.")
        XCTAssertEqual(AutoSendCue.removingCue(from: "Send it."), "")
        XCTAssertNil(AutoSendCue.removingCue(from: "I'll send it."))
    }
}

@MainActor
final class TextDeliveryPlanTests: XCTestCase {

    private let slack = RunningAppSnapshot(displayName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap")
    private let terminal = RunningAppSnapshot(displayName: "Terminal", bundleIdentifier: "com.apple.Terminal")

    private func deliver(
        spoken: String, text: String, app: RunningAppSnapshot?, codeOrTerminal: Bool = false,
        method: InsertionMethod = .automatic, typing: [AutoPauseAppEntry] = [],
        mode: AutoSendMode, sendApps: [AutoPauseAppEntry] = []
    ) -> (text: String, options: TextDeliveryOptions) {
        AppState.textDelivery(
            spoken: spoken, text: text, app: app, isCodeOrTerminal: codeOrTerminal,
            method: method, typingApps: typing, autoSendMode: mode, autoSendApps: sendApps
        )
    }

    func testTypingIsChosenGloballyOrForListedApps() {
        XCTAssertFalse(deliver(spoken: "hi", text: "Hi", app: slack, mode: .off).options.typesText)
        XCTAssertTrue(deliver(spoken: "hi", text: "Hi", app: slack, method: .typing, mode: .off).options.typesText)
        let listed = [AutoPauseAppEntry.from(snapshot: slack)]
        XCTAssertTrue(deliver(spoken: "hi", text: "Hi", app: slack, typing: listed, mode: .off).options.typesText)
        XCTAssertFalse(deliver(spoken: "hi", text: "Hi", app: terminal, typing: listed, mode: .off).options.typesText)
    }

    func testSpokenCueSendsAndIsRemoved() {
        let result = deliver(spoken: "See you soon. Send it.", text: "See you soon. Send it. ", app: slack, mode: .spokenCue)
        XCTAssertEqual(result.text, "See you soon.")
        XCTAssertTrue(result.options.pressesReturn)
    }

    func testCueOnlyInTheFinalTextNeverSends() {
        // Cleanup or selected text can't ask for Return: only what was heard can.
        let result = deliver(spoken: "see you soon", text: "See you soon. Send it.", app: slack, mode: .spokenCue)
        XCTAssertEqual(result.text, "See you soon. Send it.")
        XCTAssertFalse(result.options.pressesReturn)
    }

    func testCueReworddedByCleanupDoesNotSend() {
        let result = deliver(spoken: "See you soon. Send it.", text: "See you soon, and send it over.", app: slack, mode: .spokenCue)
        XCTAssertFalse(result.options.pressesReturn)
        XCTAssertEqual(result.text, "See you soon, and send it over.")
    }

    func testOffModeTypesTheCueAsWords() {
        let result = deliver(spoken: "Done. Send it.", text: "Done. Send it.", app: slack, mode: .off)
        XCTAssertEqual(result.text, "Done. Send it.")
        XCTAssertFalse(result.options.pressesReturn)
    }

    func testAlwaysModeSendsEverywhereButTerminalsAndEditors() {
        XCTAssertTrue(deliver(spoken: "hi", text: "Hi", app: slack, mode: .always).options.pressesReturn)
        XCTAssertFalse(deliver(spoken: "ls", text: "ls", app: terminal, codeOrTerminal: true, mode: .always).options.pressesReturn)
        XCTAssertFalse(deliver(spoken: "hi", text: "Hi", app: nil, mode: .always).options.pressesReturn)
    }

    func testListedTerminalMaySend() {
        let listed = [AutoPauseAppEntry.from(snapshot: terminal)]
        let result = deliver(
            spoken: "git status. Press enter.", text: "git status. Press enter.", app: terminal,
            codeOrTerminal: true, mode: .spokenCue, sendApps: listed
        )
        XCTAssertTrue(result.options.pressesReturn)
        XCTAssertEqual(result.text, "git status.")
    }

    func testCatalogTerminalsCountAsTerminalsWithoutAStyleRule() {
        XCTAssertTrue(AppState.isCodeOrTerminal(terminal, resolved: .plain))
        XCTAssertFalse(AppState.isCodeOrTerminal(slack, resolved: .plain))
    }

    func testAutoSendThroughADictation() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.autoSendMode = .spokenCue
        defer { UserDefaults.standard.removeObject(forKey: PreferenceKey.autoSendMode) }
        mocks.frontmostAppResolver.frontmostApp = slack
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "See you at five. Send it.", duration: 0.1, detectedLanguage: "en", audioLengthSeconds: 0.5, modelUsed: .tiny
        )
        mocks.audioEngine.stopRecordingResult = [Float](repeating: 0.2, count: 8_000)
        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.textInjector.lastDeliveryOptions?.pressesReturn, true)
        let typed = mocks.textInjector.lastInjectedText ?? ""
        XCTAssertFalse(typed.lowercased().contains("send it"), typed)
        XCTAssertTrue(typed.hasPrefix("See you at"), typed)
    }
}

@MainActor
final class TextInjectorDeliveryTests: XCTestCase {

    private func board() -> NSPasteboard {
        let board = NSPasteboard(name: .init("com.vocamac.tests.\(UUID())"))
        board.clearContents()
        board.setString("original", forType: .string)
        return board
    }

    func testTypingOptionTypesInsteadOfPasting() async {
        let board = board()
        defer { board.releaseGlobally() }
        var typed: [String] = []
        var pasted = false
        var returns = 0
        let injector = TextInjector(
            pasteboard: board, accessibilityTrustedOverride: true, accessibilityInjectionOverride: { _ in false },
            pasteActionOverride: { pasted = true }, frontmostPIDProvider: { 123 },
            typeTextOverride: { typed.append($0) }, returnKeyOverride: { returns += 1 },
            secureInputProvider: { false }
        )
        injector.inject(text: "hello", preserveClipboard: true,
                        options: TextDeliveryOptions(typesText: true, pressesReturn: true))
        await TextInjector.waitForInjectionQueueIdleForTesting()
        XCTAssertEqual(typed, ["hello"])
        XCTAssertFalse(pasted)
        XCTAssertEqual(returns, 1)
        XCTAssertEqual(board.string(forType: .string), "original")
    }

    func testUnreadPasteIsTypedInstead() async {
        let board = board()
        defer { board.releaseGlobally() }
        var typed: [String] = []
        let injector = TextInjector(
            pasteboard: board, accessibilityTrustedOverride: true, accessibilityInjectionOverride: { _ in false },
            pasteActionOverride: {}, frontmostPIDProvider: { 123 },
            typeTextOverride: { typed.append($0) }, secureInputProvider: { false }, pasteReceiptTimeout: 0.2
        )
        injector.inject(text: "dictation", preserveClipboard: true)
        await TextInjector.waitForInjectionQueueIdleForTesting()
        XCTAssertEqual(typed, ["dictation"])
        XCTAssertEqual(board.string(forType: .string), "original")
    }

    func testReadPasteIsNotTypedAgainAndThenSends() async {
        let board = board()
        defer { board.releaseGlobally() }
        var typed: [String] = []
        var returns = 0
        let injector = TextInjector(
            pasteboard: board, accessibilityTrustedOverride: true, accessibilityInjectionOverride: { _ in false },
            pasteActionOverride: { _ = board.string(forType: .string) }, frontmostPIDProvider: { 123 },
            typeTextOverride: { typed.append($0) }, returnKeyOverride: { returns += 1 }, secureInputProvider: { false }
        )
        injector.inject(text: "dictation", preserveClipboard: true, options: TextDeliveryOptions(pressesReturn: true))
        await TextInjector.waitForInjectionQueueIdleForTesting()
        XCTAssertTrue(typed.isEmpty)
        XCTAssertEqual(returns, 1)
    }

    func testAccessibilityInsertThenReturn() async {
        var returns = 0
        let injector = TextInjector(
            accessibilityTrustedOverride: true, accessibilityInjectionOverride: { _ in true },
            pasteActionOverride: { XCTFail("no paste after an AX insert") }, frontmostPIDProvider: { 123 },
            returnKeyOverride: { returns += 1 }
        )
        injector.inject(text: "hi", preserveClipboard: true, options: TextDeliveryOptions(pressesReturn: true))
        await TextInjector.waitForInjectionQueueIdleForTesting()
        XCTAssertEqual(returns, 1)
    }

    func testEmptyTextWithReturnOnlyPressesReturn() async {
        var returns = 0
        let injector = TextInjector(
            accessibilityTrustedOverride: true,
            accessibilityInjectionOverride: { _ in XCTFail("nothing to insert"); return false },
            pasteActionOverride: { XCTFail("nothing to paste") }, frontmostPIDProvider: { 123 },
            returnKeyOverride: { returns += 1 }
        )
        injector.inject(text: "", preserveClipboard: true, options: TextDeliveryOptions(pressesReturn: true))
        injector.inject(text: "", preserveClipboard: true, options: .standard)
        await TextInjector.waitForInjectionQueueIdleForTesting()
        XCTAssertEqual(returns, 1)
    }

    func testSecureInputIsNeverTyped() async {
        var typed: [String] = []
        var failure: String?
        var returns = 0
        let injector = TextInjector(
            accessibilityTrustedOverride: true, frontmostPIDProvider: { 123 },
            typeTextOverride: { typed.append($0) }, returnKeyOverride: { returns += 1 }, secureInputProvider: { true }
        )
        injector.onFailure = { failure = $0 }
        injector.inject(text: "secret", preserveClipboard: true,
                        options: TextDeliveryOptions(typesText: true, pressesReturn: true))
        await TextInjector.waitForInjectionQueueIdleForTesting()
        XCTAssertTrue(typed.isEmpty)
        XCTAssertEqual(returns, 0)
        XCTAssertNotNil(failure)
    }

    func testOnlyAPromiseNobodyReadIsAFailedPaste() {
        XCTAssertEqual(TextInjector.outcomeWithoutReceipt(readBeforePaste: false, readAfterPaste: false), .notRead)
        XCTAssertEqual(TextInjector.outcomeWithoutReceipt(readBeforePaste: true, readAfterPaste: false), .unobserved)
        XCTAssertEqual(TextInjector.outcomeWithoutReceipt(readBeforePaste: false, readAfterPaste: true), .confirmed)
    }

    func testTypingChunksNeverSplitACharacterAndSeparateLineBreaks() {
        let chunks = TextInjector.typingChunks("ab👍🏽cd\nef", maxUnits: 4)
        XCTAssertEqual(chunks.joined(), "ab👍🏽cd\nef")
        XCTAssertTrue(chunks.contains("\n"))
        XCTAssertTrue(chunks.contains("👍🏽"), "\(chunks)")
        XCTAssertTrue(chunks.allSatisfy { $0 == "👍🏽" || $0.utf16.count <= 4 })
    }
}

final class LanguageIdentificationTests: XCTestCase {

    func testCandidatesAreTheUsersLanguagesTheModelSupports() {
        XCTAssertEqual(
            LanguageIdentification.candidates(spoken: ["en", "de", "hi"], supported: ["en", "de", "fr"]),
            ["en", "de"]
        )
        XCTAssertNil(LanguageIdentification.candidates(spoken: ["en", "hi"], supported: ["en", "de"]))
        XCTAssertNil(LanguageIdentification.candidates(spoken: ["de"], supported: ["en", "de"]))
    }

    func testChoiceIsRestrictedToTheCandidates() {
        let scores: [String: Float] = ["nl": -0.1, "de": -0.7, "en": -1.2]
        XCTAssertEqual(LanguageIdentification.choose(scores: scores, among: ["en", "de"]), "de")
        XCTAssertNil(LanguageIdentification.choose(scores: scores, among: ["fr", "es"]))
    }

    func testShortRecordingsAreLeftAloneAndLongOnesClipped() {
        XCTAssertNil(LanguageIdentification.clip([Float](repeating: 0, count: 8_000)))
        XCTAssertEqual(LanguageIdentification.clip([Float](repeating: 0, count: 16_000 * 30))?.count, 16_000 * 10)
    }

    func testOnlyCanaryAndCohereAreToldTheirLanguage() {
        let fixed = ModelSize.allCases.filter { SherpaModelCatalog.spec(for: $0)?.fixedLanguageChoices != nil }
        XCTAssertFalse(fixed.isEmpty)
        for size in fixed {
            switch SherpaModelCatalog.spec(for: size)?.kind {
            case .canary, .cohereTranscribe: break
            default: XCTFail("\(size) should detect its own language")
            }
        }
    }
}
