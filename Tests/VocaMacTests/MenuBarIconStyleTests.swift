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

    func testErrorUsesSystemSymbol() {
        XCTAssertEqual(
            MenuBarIconStyle.style(for: .error),
            .systemSymbol(name: "exclamationmark.triangle")
        )
    }
}
