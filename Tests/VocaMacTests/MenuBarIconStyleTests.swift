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

    func testSilentModeShowsLipsWhileTheCameraIsInUse() {
        XCTAssertEqual(MenuBarIconStyle.style(for: .recording, isSilentMode: true), .systemSymbol(name: "mouth.fill"))
        XCTAssertEqual(MenuBarIconStyle.style(for: .processing, isSilentMode: true), .systemSymbol(name: "mouth.fill"))
        XCTAssertEqual(MenuBarIconStyle.style(for: .idle, isSilentMode: true), .systemSymbolTemplate(name: "mic.fill"))
    }

    func testTheDictationKeyRecordingSilentlyShowsAtRest() {
        XCTAssertEqual(MenuBarIconStyle.style(for: .idle, silentByDefault: true), .systemSymbolTemplate(name: "mouth"))
        // Something to fix still shows first.
        XCTAssertEqual(
            MenuBarIconStyle.style(for: .idle, silentByDefault: true, readiness: .blocked),
            .notReadyTemplate(badged: true)
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
