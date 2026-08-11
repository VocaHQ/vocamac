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

    func testMinimalOverlayUsesCompactStableDimensions() {
        XCTAssertEqual(OverlayLayout.contentSize(for: .minimal), CGSize(width: 108, height: 44))
        let size = OverlayLayout.size(for: .minimal)
        XCTAssertEqual(size.width, 108 + OverlayLayout.glowBleed * 2)
        XCTAssertEqual(size.height, 44 + OverlayLayout.glowBleed * 2)
    }

    func testLiveOverlayIsShorterThanTheOriginalPanel() {
        let content = OverlayLayout.contentSize(for: .live)
        let size = OverlayLayout.size(for: .live)

        XCTAssertEqual(content, CGSize(width: 240, height: 72))
        XCTAssertEqual(size.width, 240 + OverlayLayout.glowBleed * 2)
        XCTAssertLessThan(content.width, 360)
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

    func testWaveformUsesNineBarsWithAVisibleFloor() {
        let heights = OverlayWaveformMetrics.heights(for: 0)

        XCTAssertEqual(heights.count, 9)
        XCTAssertTrue(heights.allSatisfy { $0 == 3 })
    }

    func testWaveformRespondsToAudioLevelAndClampsInput() {
        let quiet = OverlayWaveformMetrics.heights(for: 0.1)
        let loud = OverlayWaveformMetrics.heights(for: 1.0)
        let overdriven = OverlayWaveformMetrics.heights(for: 4.0)
        let whisper = OverlayWaveformMetrics.heights(for: 0.05)

        XCTAssertGreaterThan(loud.max() ?? 0, quiet.max() ?? 0)
        XCTAssertEqual(overdriven, loud)
        XCTAssertTrue(loud.allSatisfy { $0 <= 18 })
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
