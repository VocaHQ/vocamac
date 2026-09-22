// CompiledModelRecordTests.swift
// VocaMac

import XCTest
@testable import VocaMac

final class CompiledModelRecordTests: XCTestCase {

    private let suiteName = "CompiledModelRecordTests"
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testANewModelHasNotLoaded() {
        let record = CompiledModelRecord(defaults: defaults, osBuild: "27A1")
        XCTAssertFalse(record.hasLoaded(.vocaHinglish))
    }

    func testRecordedLoadHoldsForTheSameBuild() {
        CompiledModelRecord(defaults: defaults, osBuild: "27A1").recordLoad(.vocaHinglish)
        let record = CompiledModelRecord(defaults: defaults, osBuild: "27A1")
        XCTAssertTrue(record.hasLoaded(.vocaHinglish))
        XCTAssertFalse(record.hasLoaded(.small))
    }

    func testAMacOSUpdateCountsAsAFirstLoadAgain() {
        // CoreML recompiles after a macOS update.
        CompiledModelRecord(defaults: defaults, osBuild: "27A1").recordLoad(.vocaHinglish)
        XCTAssertFalse(CompiledModelRecord(defaults: defaults, osBuild: "27A2").hasLoaded(.vocaHinglish))
    }

    func testForgettingAModelMakesItsNextLoadAFirstLoad() {
        let record = CompiledModelRecord(defaults: defaults, osBuild: "27A1")
        record.recordLoad(.vocaHinglish)
        record.recordLoad(.small)
        record.forget(.vocaHinglish)
        XCTAssertFalse(record.hasLoaded(.vocaHinglish))
        XCTAssertTrue(record.hasLoaded(.small))
    }
}
