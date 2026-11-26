// VoiceActionAppLookupTests.swift
// VocaMac
//
// "Open Safari" must find Safari, which lives in the system cryptex.

import XCTest
@testable import VocaMac

@MainActor
final class VoiceActionAppLookupTests: XCTestCase {
    func testSafariIsFoundOnThisMac() throws {
        let cryptexSafari = "/System/Cryptexes/App/System/Applications/Safari.app"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: cryptexSafari), "Safari isn't in the cryptex on this OS")
        XCTAssertEqual(SystemVoiceActionPerformer.applicationURL(named: "safari")?.lastPathComponent, "Safari.app")
    }

    func testAppNameMatchesWithoutCaseOrSpaces() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Visual Studio Code.app"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        XCTAssertNotNil(SystemVoiceActionPerformer.applicationURL(named: "visual studio code", in: [folder]))
        XCTAssertNil(SystemVoiceActionPerformer.applicationURL(named: "vs code", in: [folder]),
                     "Nothing is opened on a guess")
    }
}
