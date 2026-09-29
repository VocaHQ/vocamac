// MenuBarIconStyleTests.swift
// VocaMac Tests

import XCTest
@testable import VocaMac

final class MenuBarIconStyleTests: XCTestCase {

    func testIdleUsesSystemMic() {
        XCTAssertEqual(MenuBarIconStyle.style(for: .idle), .systemSymbolTemplate(name: "mic.fill"))
    }

    func testRecordingUsesTintedMark() {
        XCTAssertEqual(MenuBarIconStyle.style(for: .recording), .brandMarkTinted)
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
        XCTAssertEqual(MenuBarIconStyle.style(for: .idle, isCommandMode: true), .systemSymbolTemplate(name: "mic.fill"))
    }

    func testErrorUsesSystemSymbol() {
        XCTAssertEqual(
            MenuBarIconStyle.style(for: .error),
            .systemSymbol(name: "exclamationmark.triangle")
        )
    }
}
