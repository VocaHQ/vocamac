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
        let record = CompiledModelRecord(defaults: defaults, osBuild: "27A1", compileCacheExists: { true })
        XCTAssertFalse(record.hasLoaded(.vocaHinglish))
    }

    func testRecordedLoadHoldsForTheSameBuild() throws {
        let defaults = try makeDefaults()
        CompiledModelRecord(defaults: defaults, osBuild: "27A1", compileCacheExists: { true }).recordLoad(.vocaHinglish)
        let record = CompiledModelRecord(defaults: defaults, osBuild: "27A1", compileCacheExists: { true })
        XCTAssertTrue(record.hasLoaded(.vocaHinglish))
        XCTAssertFalse(record.hasLoaded(.small))
    }

    func testAMacOSUpdateCountsAsAFirstLoadAgain() throws {
        let defaults = try makeDefaults()
        // CoreML recompiles after a macOS update.
        CompiledModelRecord(defaults: defaults, osBuild: "27A1", compileCacheExists: { true }).recordLoad(.vocaHinglish)
        XCTAssertFalse(CompiledModelRecord(defaults: defaults, osBuild: "27A2", compileCacheExists: { true }).hasLoaded(.vocaHinglish))
    }

    func testForgettingAModelMakesItsNextLoadAFirstLoad() throws {
        let defaults = try makeDefaults()
        let record = CompiledModelRecord(defaults: defaults, osBuild: "27A1", compileCacheExists: { true })
        record.recordLoad(.vocaHinglish)
        record.recordLoad(.small)
        record.forget(.vocaHinglish)
        XCTAssertFalse(record.hasLoaded(.vocaHinglish))
        XCTAssertTrue(record.hasLoaded(.small))
    }

    func testEachModelIsStoredUnderItsOwnKey() throws {
        // Separate keys let the app and the headless CLI record different
        // models at once; one shared value would lose the other's write.
        let defaults = try makeDefaults()
        let record = CompiledModelRecord(defaults: defaults, osBuild: "27A1", compileCacheExists: { true })
        record.recordLoad(.vocaHinglish)
        record.recordLoad(.small)
        XCTAssertEqual(defaults.string(forKey: PreferenceKey.compiledModelBuildPrefix + "voca-hinglish"), "27A1")
        XCTAssertEqual(defaults.string(forKey: PreferenceKey.compiledModelBuildPrefix + "small"), "27A1")
    }

    func testAnEmptiedCompileCacheMakesEveryLoadAFirstLoad() throws {
        let defaults = try makeDefaults()
        CompiledModelRecord(defaults: defaults, osBuild: "27A1", compileCacheExists: { true })
            .recordLoad(.vocaHinglish)
        let purged = CompiledModelRecord(defaults: defaults, osBuild: "27A1", compileCacheExists: { false })
        XCTAssertFalse(purged.hasLoaded(.vocaHinglish))
    }

    func testCurrentOSBuildIsABuildNumber() {
        let build = CompiledModelRecord.currentOSBuild
        XCTAssertFalse(build.isEmpty)
        XCTAssertFalse(build.contains(" "), build)
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
