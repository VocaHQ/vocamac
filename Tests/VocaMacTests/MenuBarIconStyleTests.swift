// MenuBarIconStyleTests.swift
// VocaMac Tests

import XCTest
@testable import VocaMac

final class MenuBarIconStyleTests: XCTestCase {

    func testIdleUsesTheTemplateWaveform() {
        XCTAssertEqual(MenuBarIconStyle.style(for: .idle), .waveform)
    }

    func testRecordingUsesTheLiveWaveform() {
        XCTAssertEqual(MenuBarIconStyle.style(for: .recording), .waveformLive)
    }

    func testWaveformBarsFitTheirRectTallestInTheMiddle() {
        let area = CGRect(x: 0, y: 0, width: 18, height: 12)
        let bars = VocaWaveform.barRects(in: area)
        XCTAssertEqual(bars.count, 5)
        XCTAssertEqual(bars.first?.minX ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(bars.last?.maxX ?? -1, 18, accuracy: 0.001)
        XCTAssertEqual(bars[2].height, 12, accuracy: 0.001)
        XCTAssertTrue(bars.allSatisfy { area.contains($0) })
    }

    func testProcessingUsesSystemSymbol() {
        XCTAssertEqual(
            MenuBarIconStyle.style(for: .processing),
            .systemSymbol(name: "ellipsis.circle")
        )
    }

    func testCommandModeShowsAWandWhileListeningAndRewriting() {
        XCTAssertEqual(
            MenuBarIconStyle.style(for: .recording, isCommandMode: true),
            .systemSymbol(name: "wand.and.stars")
        )
        XCTAssertEqual(
            MenuBarIconStyle.style(for: .processing, isCommandMode: true),
            .systemSymbol(name: "wand.and.stars")
        )
        // An error or idle state is not Command Mode's to show.
        XCTAssertEqual(MenuBarIconStyle.style(for: .idle, isCommandMode: true), .waveform)
    }

    func testErrorUsesSystemSymbol() {
        XCTAssertEqual(
            MenuBarIconStyle.style(for: .error),
            .systemSymbol(name: "exclamationmark.triangle")
        )
    }
}
