// CompiledModelRecordTests.swift
// VocaMac

import XCTest
@testable import VocaMac

final class CompiledModelRecordTests: XCTestCase {

    private let suiteName = "CompiledModelRecordTests"

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    /// A clean defaults suite for one test.
    private func makeDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testANewModelHasNotLoaded() throws {
        let defaults = try makeDefaults()
        let record = CompiledModelRecord(defaults: defaults, osBuild: "27A1")
        XCTAssertFalse(record.hasLoaded(.vocaHinglish))
    }

    func testRecordedLoadHoldsForTheSameBuild() throws {
        let defaults = try makeDefaults()
        CompiledModelRecord(defaults: defaults, osBuild: "27A1").recordLoad(.vocaHinglish)
        let record = CompiledModelRecord(defaults: defaults, osBuild: "27A1")
        XCTAssertTrue(record.hasLoaded(.vocaHinglish))
        XCTAssertFalse(record.hasLoaded(.small))
    }

    func testAMacOSUpdateCountsAsAFirstLoadAgain() throws {
        let defaults = try makeDefaults()
        // CoreML recompiles after a macOS update.
        CompiledModelRecord(defaults: defaults, osBuild: "27A1").recordLoad(.vocaHinglish)
        XCTAssertFalse(CompiledModelRecord(defaults: defaults, osBuild: "27A2").hasLoaded(.vocaHinglish))
    }

    func testForgettingAModelMakesItsNextLoadAFirstLoad() throws {
        let defaults = try makeDefaults()
        let record = CompiledModelRecord(defaults: defaults, osBuild: "27A1")
        record.recordLoad(.vocaHinglish)
        record.recordLoad(.small)
        record.forget(.vocaHinglish)
        XCTAssertFalse(record.hasLoaded(.vocaHinglish))
        XCTAssertTrue(record.hasLoaded(.small))
    }

    func testRecordsForDifferentModelsDoNotOverwriteEachOther() throws {
        // The app and the headless CLI keep separate record values; a write
        // from one must not discard what the other recorded.
        let defaults = try makeDefaults()
        let app = CompiledModelRecord(defaults: defaults, osBuild: "27A1")
        let cli = CompiledModelRecord(defaults: defaults, osBuild: "27A1")
        app.recordLoad(.vocaHinglish)
        cli.recordLoad(.small)
        app.forget(.tiny)
        XCTAssertTrue(app.hasLoaded(.vocaHinglish))
        XCTAssertTrue(app.hasLoaded(.small))
    }

    func testFirstCoreMLLoadExplainsTheWait() {
        XCTAssertEqual(
            ModelSize.vocaHinglish.loadingStatus(forPhase: "Loading model…", isFirstLoad: true),
            ModelSize.firstLoadStatus
        )
        XCTAssertEqual(
            ModelSize.parakeetV3.loadingStatus(forPhase: "Preparing Parakeet…", isFirstLoad: true),
            ModelSize.firstLoadStatus
        )
    }

    func testLaterLoadsAndCPUModelsKeepTheEnginePhase() {
        XCTAssertEqual(
            ModelSize.vocaHinglish.loadingStatus(forPhase: "Loading model…", isFirstLoad: false),
            "Loading model…"
        )
        // sherpa-onnx runs on the CPU; nothing is compiled.
        XCTAssertEqual(
            ModelSize.canary180mFlash.loadingStatus(forPhase: "Loading ONNX model…", isFirstLoad: true),
            "Loading ONNX model…"
        )
    }
}
