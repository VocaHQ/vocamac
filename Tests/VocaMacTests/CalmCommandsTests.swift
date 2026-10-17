// CalmCommandsTests.swift
// VocaMacTests
//
// The v3 Commands page's rules: Command Mode on and off through its
// shortcut, the status it shows, the model line, saved-command drafts,
// the starter set, and the page's copy.

import XCTest
@testable import VocaMac

@MainActor
final class CalmCommandsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "CalmCommandsTests"

    private let controlOptionE = HotKeyCombo(keyCode: 14, modifiers: [.control, .option])
    private let suggestedE = HotKeyCombo(keyCode: 14, modifiers: [.control, .option, .command])

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: On and off

    func testCommandModeIsOnOnlyWithAShortcut() {
        let (state, _) = AppState.makeTestState()
        XCTAssertFalse(state.isCommandModeOn)
        state.setShortcut(controlOptionE, for: .commandMode)
        XCTAssertTrue(state.isCommandModeOn)
    }

    func testTurningOffClearsAndRemembersTheShortcut() {
        let (state, _) = AppState.makeTestState()
        state.setShortcut(controlOptionE, for: .commandMode)

        XCTAssertTrue(state.setCommandModeOn(false, defaults: defaults))

        XCTAssertNil(state.shortcut(for: .commandMode))
        XCTAssertEqual(defaults.string(forKey: AppState.calmCommandsLastShortcutKey), controlOptionE.storageString)
    }

    func testTurningBackOnRestoresTheRememberedShortcut() {
        let (state, _) = AppState.makeTestState()
        state.setShortcut(controlOptionE, for: .commandMode)
        state.setCommandModeOn(false, defaults: defaults)

        XCTAssertTrue(state.setCommandModeOn(true, defaults: defaults))

        XCTAssertEqual(state.shortcut(for: .commandMode), controlOptionE)
    }

    /// Saved commands belong to Command Mode: turning it off takes their
    /// shortcuts off the listener too, and turning it on puts them back.
    func testSavedCommandShortcutsFollowCommandMode() {
        let (state, mocks) = AppState.makeTestState()
        state.setShortcut(controlOptionE, for: .commandMode)
        let saved = SavedCommand(name: "Shorter", instruction: "Make it shorter", shortcut: suggestedE.storageString)
        state.savedCommands = [saved]
        XCTAssertEqual(mocks.hotKeyManager.shortcuts[.savedCommand(saved.id)], suggestedE)

        state.setCommandModeOn(false, defaults: defaults)
        XCTAssertNil(mocks.hotKeyManager.shortcuts[.savedCommand(saved.id)])
        XCTAssertNil(mocks.hotKeyManager.shortcuts[.commandMode])

        state.setCommandModeOn(true, defaults: defaults)
        XCTAssertEqual(mocks.hotKeyManager.shortcuts[.savedCommand(saved.id)], suggestedE)
        XCTAssertEqual(state.shortcut(for: .savedCommand(saved.id)), suggestedE, "the command keeps its keys")
    }

    func testTurningOnWithNothingRememberedUsesTheSuggestion() {
        let (state, _) = AppState.makeTestState()

        XCTAssertTrue(state.setCommandModeOn(true, defaults: defaults))

        XCTAssertEqual(state.shortcut(for: .commandMode), suggestedE)
    }

    func testTurningOnSkipsARememberedShortcutTakenSinceThen() {
        let (state, _) = AppState.makeTestState()
        state.setShortcut(controlOptionE, for: .commandMode)
        state.setCommandModeOn(false, defaults: defaults)
        state.setShortcut(controlOptionE, for: .handsFreeToggle)

        XCTAssertTrue(state.setCommandModeOn(true, defaults: defaults))

        XCTAssertEqual(state.shortcut(for: .commandMode), suggestedE)
    }

    func testTurningOnFailsWhenNoKeysAreFree() {
        let (state, _) = AppState.makeTestState()
        // Take every suggested combination.
        state.setShortcut(ShortcutValidation.commandModeSuggestions[0], for: .handsFreeToggle)
        state.setShortcut(ShortcutValidation.commandModeSuggestions[1], for: .pasteLastDictation)
        state.savedCommands = [
            SavedCommand(name: "Fix", instruction: "fix it", shortcut: ShortcutValidation.commandModeSuggestions[2].storageString),
        ]

        XCTAssertFalse(state.setCommandModeOn(true, defaults: defaults))
        XCTAssertFalse(state.isCommandModeOn)
    }

    // MARK: Status

    func testStatusIsOffWithASuggestionWithoutAShortcut() {
        let (state, _) = AppState.makeTestState()
        XCTAssertEqual(state.calmCommandsStatus, .off(suggestion: suggestedE))
    }

    func testStatusAsksForTheMissingLocalModel() {
        let (state, mocks) = AppState.makeTestState()
        state.setShortcut(controlOptionE, for: .commandMode)
        state.commandModeEngineStorage = CleanupModelKind.ministral3_3b_q4_k_m.rawValue
        mocks.transcriptCleanup.downloadedKinds = []

        XCTAssertEqual(state.calmCommandsStatus, .needsDownload(.ministral3_3b_q4_k_m))
    }

    func testStatusShowsTheDownloadOfThatModel() {
        let (state, mocks) = AppState.makeTestState()
        state.setShortcut(controlOptionE, for: .commandMode)
        state.commandModeEngineStorage = CleanupModelKind.ministral3_3b_q4_k_m.rawValue
        mocks.transcriptCleanup.downloadedKinds = []
        mocks.transcriptCleanup.modelState = .downloading(kind: .ministral3_3b_q4_k_m, progress: 0.4)

        XCTAssertEqual(state.calmCommandsStatus, .downloading(.ministral3_3b_q4_k_m, progress: 0.4))
    }

    func testStatusIsReadyWithAShortcutAndADownloadedModel() {
        let (state, _) = AppState.makeTestState()
        state.setShortcut(controlOptionE, for: .commandMode)
        state.commandModeEngineStorage = CleanupModelKind.ministral3_3b_q4_k_m.rawValue

        XCTAssertEqual(state.calmCommandsStatus, .ready)
    }

    // MARK: Model line

    func testModelLineSaysWhenTheModelIsShared() {
        let (state, _) = AppState.makeTestState()
        state.transcriptCleanupModel = CleanupModelKind.ministral3_3b_q4_k_m.rawValue
        state.commandModeEngineStorage = CleanupModelKind.ministral3_3b_q4_k_m.rawValue

        XCTAssertTrue(state.sharesAIModel)
        XCTAssertEqual(state.calmCommandsModelLine, "Ministral 3 3B · shared with Smart Cleanup")
    }

    func testModelLineSaysWhenTheModelIsMissing() {
        let (state, mocks) = AppState.makeTestState()
        state.transcriptCleanupModel = CleanupModelKind.qwen25_0_5b_q4_k_m.rawValue
        state.commandModeEngineStorage = CleanupModelKind.qwen3_4b_instruct_2507_q4_k_m.rawValue
        mocks.transcriptCleanup.downloadedKinds = [.qwen25_0_5b_q4_k_m]

        XCTAssertEqual(state.calmCommandsModelLine, "Qwen 3 4B Instruct · not downloaded")
    }

    func testModelLineForAModelOfItsOwn() {
        let (state, _) = AppState.makeTestState()
        state.transcriptCleanupModel = CleanupModelKind.qwen25_0_5b_q4_k_m.rawValue
        state.commandModeEngineStorage = CleanupModelKind.qwen3_4b_instruct_2507_q4_k_m.rawValue

        XCTAssertEqual(state.calmCommandsModelLine, "Qwen 3 4B Instruct · on this Mac")
    }

    // MARK: Drafts

    func testNewDraftIsInvalidUntilItHasANameAndAnInstruction() {
        var draft = CalmSavedCommandDraft()
        XCTAssertTrue(draft.isNew)
        XCTAssertFalse(draft.isValid(in: []))
        draft.name = "Shorter"
        XCTAssertFalse(draft.isValid(in: []))
        draft.instruction = "   "
        XCTAssertFalse(draft.isValid(in: []))
        draft.instruction = "make this shorter"
        XCTAssertTrue(draft.isValid(in: []))
    }

    func testDraftNameMayNotClashWithAnotherCommandAsHeard() {
        let existing = SavedCommand(name: "Shorter", instruction: "make this shorter")
        var draft = CalmSavedCommandDraft()
        draft.name = "shorter!"
        draft.instruction = "cut it down"

        XCTAssertEqual(draft.nameProblem(in: [existing]), "“Shorter” already answers to that name.")
        XCTAssertFalse(draft.isValid(in: [existing]))
    }

    func testEditingDraftDoesNotClashWithItself() {
        let existing = SavedCommand(name: "Shorter", instruction: "make this shorter")
        let draft = CalmSavedCommandDraft(editing: existing)

        XCTAssertFalse(draft.isNew)
        XCTAssertNil(draft.nameProblem(in: [existing]))
        XCTAssertTrue(draft.isValid(in: [existing]))
    }

    func testDraftKeepsTheShortcutOfTheCommandItEdits() {
        let existing = SavedCommand(name: "Fix", instruction: "fix it", shortcut: controlOptionE.storageString)
        XCTAssertEqual(CalmSavedCommandDraft(editing: existing).shortcut, controlOptionE)
    }

    func testAppliedDraftAddsANewCommandTrimmed() {
        let existing = SavedCommand(name: "Shorter", instruction: "make this shorter")
        var draft = CalmSavedCommandDraft()
        draft.name = "  Formal "
        draft.instruction = " make it more formal\n"
        draft.shortcut = controlOptionE

        let result = draft.applied(to: [existing])

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], existing)
        XCTAssertEqual(result[1], SavedCommand(id: draft.id, name: "Formal", instruction: "make it more formal",
                                               shortcut: controlOptionE.storageString))
    }

    func testAppliedDraftReplacesTheCommandInPlace() {
        let first = SavedCommand(name: "Shorter", instruction: "make this shorter", shortcut: controlOptionE.storageString)
        let second = SavedCommand(name: "Formal", instruction: "make it formal")
        var draft = CalmSavedCommandDraft(editing: first)
        draft.instruction = "half the length"
        draft.shortcut = nil

        let result = draft.applied(to: [first, second])

        XCTAssertEqual(result.map(\.id), [first.id, second.id])
        XCTAssertEqual(result[0].instruction, "half the length")
        XCTAssertEqual(result[0].shortcut, "")
    }

    func testSavingAndDeletingThroughAppState() {
        let (state, _) = AppState.makeTestState()
        var draft = CalmSavedCommandDraft()
        draft.name = "Shorter"
        draft.instruction = "make this shorter"

        state.saveCommandDraft(draft)
        XCTAssertEqual(state.savedCommands.map(\.name), ["Shorter"])

        state.deleteSavedCommand(draft.id)
        XCTAssertTrue(state.savedCommands.isEmpty)
    }

    func testStartersAreAddedWithoutDuplicatingANameAlreadySaved() {
        let (state, _) = AppState.makeTestState()
        state.savedCommands = [SavedCommand(name: "shorter", instruction: "my own shorter")]

        state.addStarterCommands()

        XCTAssertEqual(state.savedCommands.map(\.name), ["shorter", "Fix grammar", "More formal"])
        XCTAssertEqual(state.savedCommands[0].instruction, "my own shorter")
        // Each gets a fresh id, so adding them twice can't reuse one.
        XCTAssertFalse(state.savedCommands.contains { command in SavedCommand.starters.contains { $0.id == command.id } })
    }

    // MARK: Copy

    func testHeroMessageFollowsThePreviewSetting() {
        XCTAssertFalse(CalmCommandsText.heroMessage(review: .never).contains("preview"))
        XCTAssertTrue(CalmCommandsText.heroMessage(review: .longSelections).contains("Long edits show a preview first"))
        XCTAssertTrue(CalmCommandsText.heroMessage(review: .always).contains("Every edit shows a preview first"))
    }

    func testReviewTitlesUseTheDesignWords() {
        XCTAssertEqual(CommandReviewMode.allCases.map(CalmCommandsText.reviewTitle), ["Never", "Long edits", "Always"])
    }

    func testWritingModelNamesMatchSettingsModels() {
        XCTAssertEqual(CalmModelText.name(.ministral3_3b_q4_k_m), "Ministral 3 3B")
        XCTAssertEqual(CalmModelText.name(.qwen25_0_5b_q4_k_m), "Qwen 2.5 0.5B")
        XCTAssertEqual(CalmModelText.name(.qwen3_4b_instruct_2507_q4_k_m), "Qwen 3 4B Instruct")
    }

    func testShortcutsSummary() {
        XCTAssertEqual(CalmCommandsText.shortcutsSummary(" \n"), "None yet, so no shortcut can run")
        XCTAssertEqual(CalmCommandsText.shortcutsSummary("Morning"), "Morning")
        XCTAssertEqual(CalmCommandsText.shortcutsSummary("Morning, Log water"), "Morning, Log water")
        XCTAssertEqual(CalmCommandsText.shortcutsSummary("A\nB\nC\nD"), "A, B and 2 more")
    }

    func testCommandNameFallsBackToUntitled() {
        XCTAssertEqual(CalmCommandsText.commandName(SavedCommand(name: "  ", instruction: "x")), "Untitled")
        XCTAssertEqual(CalmCommandsText.commandName(SavedCommand(name: "Fix", instruction: "x")), "Fix")
    }

    func testKeysAreWrittenTogether() {
        XCTAssertEqual(CalmCommandsText.keys(suggestedE), "⌃⌥⌘E")
    }
}
