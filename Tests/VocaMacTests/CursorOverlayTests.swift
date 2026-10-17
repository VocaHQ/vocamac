// CursorOverlayTests.swift
// VocaMac
//
// Tests for CursorOverlayManager, IndicatorPhase, and MicIndicatorViewModel.

import XCTest
@testable import VocaMac

// MARK: - IndicatorPhase Tests

final class IndicatorPhaseTests: XCTestCase {

    func testAllPhasesExist() {
        // Verify all indicator phases can be instantiated
        let phases: [IndicatorPhase] = [.recording, .processing, .idle]
        XCTAssertEqual(phases.count, 3, "Should have exactly 3 indicator phases")
    }
}

// MARK: - Overlay Settings Tests

final class OverlaySettingsTests: XCTestCase {

    func testAllOverlayStylesHaveUserFacingNames() {
        XCTAssertEqual(OverlayStyle.allCases.count, 3)
        XCTAssertTrue(OverlayStyle.allCases.allSatisfy { !$0.displayName.isEmpty })
        XCTAssertTrue(OverlayStyle.allCases.allSatisfy { !$0.description.isEmpty })
    }

    func testOverlayPositionsIncludeCursorAndScreenEdges() {
        XCTAssertEqual(
            Set(OverlayPosition.allCases),
            Set([.nearCursor, .top, .bottom])
        )
    }
}

// MARK: - Overlay Layout Tests

final class OverlayLayoutTests: XCTestCase {

    func testMinimalOverlayIsTheDesignsFortyPointPill() {
        let content = OverlayLayout.contentSize(for: .minimal)
        XCTAssertEqual(content.height, 40)
        XCTAssertEqual(OverlayLayout.pillCornerRadius, 20)
        // The panel adds only the shadow room around the card.
        let insets = OverlayLayout.shadowInsets
        XCTAssertEqual(
            OverlayLayout.size(for: .minimal),
            CGSize(width: content.width + insets.left + insets.right, height: content.height + insets.top + insets.bottom)
        )
    }

    func testLivePanelIsFourHundredSixtyWideAndGrowsToFourLines() {
        XCTAssertEqual(OverlayLayout.contentSize(for: .live).width, 460)
        XCTAssertEqual(OverlayLayout.liveCornerRadius, 14)
        // Two lines of words, as on the board: 110 tall.
        XCTAssertEqual(OverlayLayout.liveHeight(lines: 2, hasHeader: false), 110)
        XCTAssertGreaterThan(OverlayLayout.liveHeight(lines: 4, hasHeader: false), OverlayLayout.liveHeight(lines: 3, hasHeader: false))
        // Past four lines the words scroll instead of the panel growing.
        XCTAssertEqual(OverlayLayout.liveHeight(lines: 9, hasHeader: false), OverlayLayout.liveHeight(lines: 4, hasHeader: false))
        XCTAssertGreaterThan(OverlayLayout.liveHeight(lines: 1, hasHeader: true), OverlayLayout.liveHeight(lines: 1, hasHeader: false))
    }

    func testFailurePillWrapsLongMessagesUpToThreeLines() {
        XCTAssertEqual(OverlayLayout.failureHeight(lines: 1), 40)
        XCTAssertGreaterThan(OverlayLayout.failureHeight(lines: 2), 40)
        XCTAssertEqual(OverlayLayout.failureHeight(lines: 7), OverlayLayout.failureHeight(lines: 3))
    }

    func testPanelOriginAndCardFrameRoundTrip() {
        let cardOrigin = CGPoint(x: 300, y: 200)
        let panelOrigin = OverlayLayout.panelOrigin(forCardOrigin: cardOrigin)
        let panelSize = OverlayLayout.size(for: .minimal)
        let card = OverlayLayout.cardFrame(inPanel: CGRect(origin: panelOrigin, size: panelSize))
        XCTAssertEqual(card.origin, cardOrigin)
        XCTAssertEqual(card.size, OverlayLayout.contentSize(for: .minimal))
    }

    func testBottomPositionSitsTwentyFourAboveTheDock() {
        let visible = CGRect(x: 0, y: 80, width: 1_440, height: 800)
        let card = CGSize(width: 340, height: 40)
        let bottom = OverlayPlacement.edgeOrigin(for: .bottom, cardSize: card, visibleFrame: visible)
        XCTAssertEqual(bottom, CGPoint(x: 550, y: 104))
        let top = OverlayPlacement.edgeOrigin(for: .top, cardSize: card, visibleFrame: visible)
        XCTAssertEqual(top.y + card.height, visible.maxY - OverlayLayout.topEdgeGap)
    }
}

// MARK: - Overlay Hit Area Tests

final class OverlayHitAreaTests: XCTestCase {
    /// Only the visible card takes the pointer: a measured pill is narrower
    /// than its 340-point slot, and the panel adds shadow room around it.
    func testVisibleCardIsTheMeasuredPillNotTheSlot() {
        let panel = CGRect(origin: CGPoint(x: 100, y: 200), size: OverlayLayout.size(for: .minimal))
        let slot = OverlayLayout.cardFrame(inPanel: panel)
        let pill = CGSize(width: 150, height: OverlayLayout.pillHeight)

        let nearCaret = OverlayLayout.visibleCardFrame(inPanel: panel, cardSize: pill, position: .nearCursor)
        XCTAssertEqual(nearCaret, CGRect(x: slot.minX, y: slot.maxY - pill.height, width: 150, height: pill.height))
        let top = OverlayLayout.visibleCardFrame(inPanel: panel, cardSize: pill, position: .top)
        XCTAssertEqual(top.midX, slot.midX)
        XCTAssertEqual(top.width, 150)

        // Empty room beside the pill and the shadow margin don't count.
        XCTAssertFalse(nearCaret.contains(CGPoint(x: slot.maxX - 5, y: slot.midY)))
        XCTAssertFalse(nearCaret.contains(CGPoint(x: panel.minX + 5, y: panel.minY + 5)))
        XCTAssertTrue(nearCaret.contains(CGPoint(x: nearCaret.midX, y: nearCaret.midY)))
    }

    func testUnmeasuredCardFallsBackToItsSlotAndNeverExceedsIt() {
        let panel = CGRect(origin: .zero, size: OverlayLayout.size(for: .live))
        let slot = OverlayLayout.cardFrame(inPanel: panel)
        XCTAssertEqual(OverlayLayout.visibleCardFrame(inPanel: panel, cardSize: .zero, position: .bottom), slot)
        let huge = OverlayLayout.visibleCardFrame(inPanel: panel, cardSize: CGSize(width: 2_000, height: 900), position: .bottom)
        XCTAssertEqual(huge, slot)
    }
}

// MARK: - Overlay Content Tests

final class OverlayContentTests: XCTestCase {

    func testStopHintNamesTheKeyAndMarksHandsFree() {
        XCTAssertEqual(OverlayStopHint.hold(key: "Right ⌥").instruction, "Let go of Right ⌥ to type")
        XCTAssertEqual(OverlayStopHint.doubleTap(key: "Right ⌥").instruction, "Double-tap Right ⌥ to type")
        XCTAssertEqual(OverlayStopHint.handsFree(shortcut: "⌃⌥H").instruction, "Press ⌃⌥H to type")
        XCTAssertNil(OverlayStopHint.handsFree(shortcut: nil).instruction)
        XCTAssertFalse(OverlayStopHint.hold(key: "F5").isHandsFree)
        XCTAssertTrue(OverlayStopHint.doubleTap(key: "F5").isHandsFree)
        XCTAssertTrue(OverlayStopHint.handsFree(shortcut: nil).isHandsFree)
        XCTAssertEqual(OverlayStopHint.press(key: "Right ⌥").instruction, "Press Right ⌥ to type")
        XCTAssertEqual(OverlayStopHint.commandHold.instruction, "Let go to apply")
        XCTAssertEqual(OverlayStopHint.commandPress(shortcut: "⌃⌥E").instruction, "Press ⌃⌥E to apply")
        XCTAssertFalse(OverlayStopHint.commandHold.isHandsFree)
        XCTAssertTrue(OverlayStopHint.commandPress(shortcut: nil).isHandsFree)
    }

    /// The finish hint follows how the session started: the key, the mouse
    /// button, something else (a deep link), hands-free, or Command Mode
    /// held versus quick-pressed.
    func testStopHintIsDerivedFromHowTheSessionStarted() {
        func hint(
            command: (isKeyHeld: Bool, shortcut: String?)? = nil, handsFree: Bool = false,
            trigger: DictationTrigger, mode: ActivationMode = .pushToTalk
        ) -> OverlayStopHint {
            OverlayStopHint.resolve(
                commandMode: command, isHandsFreeSession: handsFree, handsFreeShortcut: "⌃⌥H",
                trigger: trigger, mode: mode, dictationKey: "Right ⌥"
            )
        }
        XCTAssertEqual(hint(trigger: .dictationKey), .hold(key: "Right ⌥"))
        XCTAssertEqual(hint(trigger: .mouseButton), .hold(key: "the mouse button"))
        XCTAssertEqual(hint(trigger: .other), .press(key: "Right ⌥"))
        XCTAssertEqual(hint(trigger: .other, mode: .doubleTapToggle), .doubleTap(key: "Right ⌥"))
        XCTAssertEqual(hint(trigger: .mouseButton, mode: .doubleTapToggle), .doubleTap(key: "the mouse button"))
        XCTAssertEqual(hint(handsFree: true, trigger: .dictationKey), .handsFree(shortcut: "⌃⌥H"))
        XCTAssertEqual(hint(command: (true, "⌃⌥E"), trigger: .other), .commandHold)
        XCTAssertEqual(hint(command: (false, "⌃⌥E"), handsFree: true, trigger: .other), .commandPress(shortcut: "⌃⌥E"))
    }

    func testClipboardFallbackIsANeutralCopiedNotice() {
        XCTAssertEqual(OverlayNotice.from(message: TextInjector.accessibilityOffMessage), .copied("Copied — press ⌘V to paste"))
        XCTAssertEqual(OverlayNotice.from(message: "Microphone access is off."), .error("Microphone access is off."))
    }

    func testOnlyTheLastChangedWordsAreUnconfirmed() {
        // New words appended: everything already shown is settled.
        XCTAssertEqual(OverlayLiveTranscript.confirmedLength(previous: "hello world", current: "hello world again"), 11)
        // The last word was revised: it and what follows are unsettled.
        XCTAssertEqual(OverlayLiveTranscript.confirmedLength(previous: "hello world", current: "hello worlds"), 6)
        XCTAssertEqual(OverlayLiveTranscript.confirmedLength(previous: "", current: "hello"), 0)
        XCTAssertEqual(OverlayLiveTranscript.confirmedLength(previous: "hi there", current: "hi there"), 8)
    }

    func testCountdownAndClockText() {
        XCTAssertEqual(OverlayCopy.clock(4), "0:04")
        XCTAssertEqual(OverlayCopy.clock(72), "1:12")
        XCTAssertEqual(OverlayCopy.countdown(10), "0:10 left")
    }

    func testCompactShortcutTextRunsModifiersTogether() {
        XCTAssertEqual(CalmKeyCaps.compactText(for: HotKeyCombo(keyCode: 61, modifiers: [])), "Right ⌥")
        XCTAssertEqual(CalmKeyCaps.compactText(for: HotKeyCombo(keyCode: 9, modifiers: [.control, .option])), "⌃⌥V")
    }

    func testCommandReviewTitleIsTheInstructionCapitalised() {
        let review = CommandReview(
            kind: .edit, instruction: "  make this shorter.", original: "a", result: "b", engineName: "Qwen"
        )
        XCTAssertEqual(CommandReviewView.title(for: review), "Make this shorter")
        let empty = CommandReview(kind: .answer, instruction: "", original: "a", result: "b", engineName: "Qwen")
        XCTAssertEqual(CommandReviewView.title(for: empty), "Answer")
    }
}

// MARK: - Overlay Placement Tests

final class OverlayPlacementTests: XCTestCase {

    private let visibleFrame = CGRect(x: 0, y: 0, width: 1_000, height: 700)
    private let panelSize = OverlayLayout.size(for: .minimal)

    func testPointOutsideScreenIsClampedBackIntoVisibleFrame() {
        let origin = OverlayPlacement.clampedOrigin(
            CGPoint(x: 1_008, y: 200),
            panelSize: panelSize,
            visibleFrames: [visibleFrame]
        )

        XCTAssertEqual(origin.x, 1000 - OverlayLayout.size(for: .minimal).width)
        XCTAssertEqual(origin.y, 200)
    }

    func testCaretNearRightEdgePlacesOverlayOnItsLeft() {
        let origin = OverlayPlacement.origin(
            near: CGRect(x: 980, y: 500, width: 2, height: 18),
            panelSize: panelSize,
            visibleFrames: [visibleFrame]
        )

        XCTAssertLessThan(origin.x, 980)
        XCTAssertGreaterThanOrEqual(origin.x, visibleFrame.minX)
        XCTAssertLessThanOrEqual(origin.x + panelSize.width, visibleFrame.maxX)
    }

    func testCaretNearBottomPlacesOverlayAboveIt() {
        let caret = CGRect(x: 20, y: 2, width: 2, height: 18)
        let origin = OverlayPlacement.origin(
            near: caret,
            panelSize: panelSize,
            visibleFrames: [visibleFrame]
        )

        XCTAssertGreaterThan(origin.y, caret.maxY)
        XCTAssertLessThanOrEqual(origin.y + panelSize.height, visibleFrame.maxY)
    }

    func testNearestDisplayIsUsedForOffEdgePoint() {
        let leftDisplay = CGRect(x: -1_200, y: 0, width: 1_200, height: 700)
        let origin = OverlayPlacement.clampedOrigin(
            CGPoint(x: -1_212, y: 120),
            panelSize: panelSize,
            visibleFrames: [visibleFrame, leftDisplay]
        )

        XCTAssertEqual(origin.x, leftDisplay.minX)
        XCTAssertEqual(origin.y, 120)
    }
}

// MARK: - Waveform Metrics Tests

final class OverlayWaveformMetricsTests: XCTestCase {

    func testWaveformUsesTheDesignsEightBarsWithAVisibleFloor() {
        let heights = OverlayWaveformMetrics.heights(for: 0)

        XCTAssertEqual(heights.count, 8)
        XCTAssertTrue(heights.allSatisfy { $0 == 3 })
    }

    func testWaveformRespondsToAudioLevelAndClampsInput() {
        let quiet = OverlayWaveformMetrics.heights(for: 0.1)
        let loud = OverlayWaveformMetrics.heights(for: 1.0)
        let overdriven = OverlayWaveformMetrics.heights(for: 4.0)
        let whisper = OverlayWaveformMetrics.heights(for: 0.05)

        XCTAssertGreaterThan(loud.max() ?? 0, quiet.max() ?? 0)
        XCTAssertEqual(overdriven, loud)
        XCTAssertTrue(loud.allSatisfy { $0 <= 16 })
        // Quiet speech should still lift bars well above the floor after gain.
        XCTAssertGreaterThan(whisper.max() ?? 0, 5)
    }

    func testWaveformMovesBetweenAudioUpdates() {
        let firstFrame = OverlayWaveformMetrics.heights(for: 0.7, tick: 1, maximumHeight: 16)
        let secondFrame = OverlayWaveformMetrics.heights(for: 0.7, tick: 2, maximumHeight: 16)

        XCTAssertNotEqual(firstFrame, secondFrame)
        XCTAssertTrue(secondFrame.allSatisfy { $0 >= 3 && $0 <= 16 })
    }
}

// MARK: - MicIndicatorViewModel Tests

@MainActor
final class MicIndicatorViewModelTests: XCTestCase {

    func testDefaultState() {
        let viewModel = MicIndicatorViewModel()

        XCTAssertEqual(viewModel.phase, .idle, "Default phase should be idle")
        XCTAssertEqual(viewModel.audioLevel, 0.0, "Default audio level should be 0")
    }

    func testPhaseTransitions() {
        let viewModel = MicIndicatorViewModel()

        viewModel.phase = .recording
        XCTAssertEqual(viewModel.phase, .recording)

        viewModel.phase = .processing
        XCTAssertEqual(viewModel.phase, .processing)

        viewModel.phase = .idle
        XCTAssertEqual(viewModel.phase, .idle)
    }

    func testLivePanelSizeFollowsTheWords() {
        let viewModel = MicIndicatorViewModel()
        viewModel.style = .live
        viewModel.phase = .recording
        let empty = viewModel.contentSize
        viewModel.setTranscript(String(repeating: "Words keep coming as the dictation goes on and on. ", count: 3))
        XCTAssertGreaterThan(viewModel.contentSize.height, empty.height)
        viewModel.setTranscript(String(repeating: "Words keep coming as the dictation goes on and on. ", count: 30))
        XCTAssertEqual(viewModel.liveLineCount, OverlayLayout.liveMaxLines)
        XCTAssertEqual(viewModel.contentSize.width, 460)
    }

    func testTranscriptTracksItsSettledPart() {
        let viewModel = MicIndicatorViewModel()
        viewModel.setTranscript("one two")
        XCTAssertEqual(viewModel.confirmedTranscriptLength, 0)
        viewModel.setTranscript("one two three")
        XCTAssertEqual(viewModel.confirmedTranscriptLength, 7)
    }

    func testAudioLevelUpdates() {
        let viewModel = MicIndicatorViewModel()

        viewModel.audioLevel = 0.5
        XCTAssertEqual(viewModel.audioLevel, 0.5, accuracy: 0.001)

        viewModel.audioLevel = 1.0
        XCTAssertEqual(viewModel.audioLevel, 1.0, accuracy: 0.001)

        viewModel.audioLevel = 0.0
        XCTAssertEqual(viewModel.audioLevel, 0.0, accuracy: 0.001)
    }
}

// MARK: - CursorOverlayManager Tests

@MainActor
final class CursorOverlayManagerTests: XCTestCase {

    func testInitialState() {
        let manager = CursorOverlayManager()
        XCTAssertNotNil(manager)
    }

    func testHideIsIdempotent() {
        let manager = CursorOverlayManager()
        manager.hide()
        manager.hide()
        manager.hide()
    }

    func testTransitionToProcessingWithoutShow() {
        let manager = CursorOverlayManager()
        manager.transitionToProcessing()
    }

    func testUpdateAudioLevelWithoutShow() {
        let manager = CursorOverlayManager()
        manager.updateAudioLevel(0.5)
        manager.updateAudioLevel(0.0)
        manager.updateAudioLevel(1.0)
    }

    func testShowWithOffStyleDoesNotRequireAWindow() {
        let manager = CursorOverlayManager()
        manager.show(style: .off, position: .bottom)
        manager.hide()
    }
}
