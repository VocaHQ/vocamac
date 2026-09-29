// OverlayPreviewControllerTests.swift
// VocaMac
//
// Tests for the Settings overlay preview.

import XCTest
@testable import VocaMac

@MainActor
final class OverlayPreviewControllerTests: XCTestCase {

    private func makeController(
        overlay: MockCursorOverlay,
        idle: @escaping () -> Bool = { true },
        duration: Duration = .milliseconds(80)
    ) -> OverlayPreviewController {
        OverlayPreviewController(
            overlay: overlay, isIdle: idle, duration: duration, tick: .milliseconds(10)
        )
    }

    func testPreviewShowsThenHidesTheOverlay() async throws {
        let overlay = MockCursorOverlay()
        let controller = makeController(overlay: overlay)

        controller.start(style: .minimal, position: .top)
        XCTAssertEqual(overlay.showCallCount, 1)
        XCTAssertEqual(overlay.lastStyle, .minimal)
        XCTAssertEqual(overlay.lastPosition, .top)
        XCTAssertEqual(overlay.transitionToRecordingCallCount, 1)
        XCTAssertTrue(controller.isRunning)

        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(overlay.hideCallCount, 1)
        XCTAssertFalse(controller.isRunning)
        XCTAssertNotNil(overlay.lastAudioLevel)
    }

    func testLivePanelPreviewShowsSampleWords() {
        let overlay = MockCursorOverlay()
        let controller = makeController(overlay: overlay)

        controller.start(style: .live, position: .bottom)

        XCTAssertEqual(overlay.lastTranscript, OverlayPreviewController.sampleTranscript)
        XCTAssertEqual(overlay.liveWordsAvailable, true)
        controller.stop()
    }

    func testMinimalPreviewShowsNoWords() {
        let overlay = MockCursorOverlay()
        let controller = makeController(overlay: overlay)

        controller.start(style: .minimal, position: .bottom)

        XCTAssertNil(overlay.lastTranscript)
        XCTAssertEqual(overlay.liveWordsAvailable, false)
        controller.stop()
    }

    func testOffStyleDoesNothing() {
        let overlay = MockCursorOverlay()
        let controller = makeController(overlay: overlay)

        controller.start(style: .off, position: .top)

        XCTAssertEqual(overlay.showCallCount, 0)
        XCTAssertFalse(controller.isRunning)
    }

    func testDoesNotStartDuringADictation() {
        let overlay = MockCursorOverlay()
        let controller = makeController(overlay: overlay, idle: { false })

        controller.start(style: .live, position: .top)

        XCTAssertEqual(overlay.showCallCount, 0)
        XCTAssertFalse(controller.isRunning)
    }

    func testStopHidesTheOverlayOnce() {
        let overlay = MockCursorOverlay()
        let controller = makeController(overlay: overlay)
        controller.start(style: .live, position: .top)

        controller.stop()
        controller.stop()

        XCTAssertEqual(overlay.hideCallCount, 1)
        XCTAssertFalse(controller.isRunning)
    }

    func testLeavesTheOverlayAloneOnceADictationTakesOver() async throws {
        let overlay = MockCursorOverlay()
        var idle = true
        let controller = makeController(overlay: overlay, idle: { idle }, duration: .seconds(5))
        controller.start(style: .live, position: .top)

        idle = false
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(overlay.hideCallCount, 0)
        XCTAssertFalse(controller.isRunning)
    }
}
