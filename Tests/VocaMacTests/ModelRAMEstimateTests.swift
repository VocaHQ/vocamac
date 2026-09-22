// ModelRAMEstimateTests.swift
// VocaMac
//
// Pins the size-based RAM estimates to measured peaks, so a change to a fit
// or a model's size cannot quietly underestimate a model the gate lets load.

import XCTest
@testable import VocaMac

final class ModelRAMEstimateTests: XCTestCase {

    /// Peaks in GB measured with `scripts/measure-model-ram.sh` (see
    /// `ModelRAMFit`), the larger of the 100 s and 10 min runs where both ran.
    ///
    /// First loads ran with CoreML's compile cache deleted: app footprint
    /// plus the Neural Engine compiler's growth. Large v3 Turbo Compact was
    /// measured under the Large v3 Latest Compact id, which this M1 Pro
    /// supports.
    static let measuredFirstLoadGB: [ModelSize: Double] = [
        .tiny: 0.096,
        .small: 0.280,
        .largeV3LatestTurboCompact: 2.099,
        .vocaHinglish: 3.060,
        .parakeetTdtCtc110m: 0.151,
        .parakeetV2: 0.181,
        .parakeetV3: 0.259,
        .moonshineTiny: 0.194,
        .senseVoiceSmall: 0.594,
        .canary180mFlash: 0.795,
        .qwen3Asr06B: 2.489,
    ]

    /// Later loads, from the compile cache: app footprint plus the rise in
    /// wired memory, where the Neural Engine keeps the weights. sherpa-onnx
    /// has no compile, so its first loads are its loads.
    static let measuredLoadedGB: [ModelSize: Double] = [
        .small: 0.838,
        .parakeetV2: 0.608,
        .moonshineTiny: 0.194,
        .senseVoiceSmall: 0.594,
        .canary180mFlash: 0.795,
        .qwen3Asr06B: 2.489,
    ]

    func testFirstLoadEstimatesCoverEveryMeasuredFirstLoad() {
        for (size, peakGB) in Self.measuredFirstLoadGB {
            XCTAssertGreaterThanOrEqual(size.firstLoadRAMRequiredGB, peakGB, "\(size)")
        }
    }

    func testLoadedEstimatesCoverEveryMeasuredLoad() {
        for (size, peakGB) in Self.measuredLoadedGB {
            XCTAssertGreaterThanOrEqual(size.ramRequiredGB, peakGB, "\(size)")
        }
    }

    func testFirstLoadNeverNeedsLessThanLaterLoads() {
        for size in ModelSize.allCases {
            XCTAssertGreaterThanOrEqual(size.firstLoadRAMRequiredGB, size.ramRequiredGB, "\(size)")
        }
    }

    func testEstimatesNeverShrinkAsFilesGrowWithinAnEngine() {
        for engine in TranscriptionEngine.allCases {
            for palettized in [false, true] {
                let sizes = ModelSize.allCases
                    .filter { $0.engine == engine && $0.hasPalettizedWeights == palettized }
                    .sorted { $0.fileSizeBytes < $1.fileSizeBytes }
                for (smaller, larger) in zip(sizes, sizes.dropFirst()) {
                    XCTAssertLessThanOrEqual(
                        smaller.ramRequiredGB, larger.ramRequiredGB, "\(smaller) vs \(larger)"
                    )
                    XCTAssertLessThanOrEqual(
                        smaller.firstLoadRAMRequiredGB, larger.firstLoadRAMRequiredGB,
                        "\(smaller) vs \(larger)"
                    )
                }
            }
        }
    }

    func testEstimatesAreAtLeastHalfAGigabyte() {
        for size in ModelSize.allCases {
            XCTAssertGreaterThanOrEqual(size.ramRequiredGB, 0.5, "\(size)")
        }
    }

    func testOnlyAppleSpeechHasNoFit() {
        for size in ModelSize.allCases {
            XCTAssertEqual(ModelRAMFit.loaded(for: size) == nil, size == .appleSpeech, "\(size)")
        }
    }

    func testOnlyPalettizedWhisperBuildsNeedMoreOnTheirFirstLoad() {
        for size in ModelSize.allCases {
            let expands = size.engine == .whisperKit && size.hasPalettizedWeights
            XCTAssertEqual(size.firstLoadRAMRequiredGB > size.ramRequiredGB, expands, "\(size)")
        }
    }

    func testGateUsesTheFirstLoadEstimateOnlyForAFirstLoad() {
        let size = ModelSize.vocaHinglish
        let between = (size.ramRequiredGB + size.firstLoadRAMRequiredGB) / 2
        let availableBytes = UInt64(between * 1024 * 1024 * 1024)
        XCTAssertTrue(
            SystemInfo.canFitModelInMemory(
                size, isFirstLoad: false, physicalMemoryGB: 16, availableBytes: availableBytes
            )
        )
        XCTAssertFalse(
            SystemInfo.canFitModelInMemory(
                size, isFirstLoad: true, physicalMemoryGB: 16, availableBytes: availableBytes
            )
        )
    }

    func testCompactWhisperModelsReloadOnAn8GBMac() {
        // The old 4–5 GB guesses refused these on 8 GB Macs unless nearly
        // everything else was closed, even though a load from the compile
        // cache needs well under 1 GB.
        let compactModels: [ModelSize] = [
            .largeV3LatestTurboCompact, .distilLargeV3Compact,
            .distilLargeV3TurboCompact, .largeV3LatestCompact, .vocaHinglish,
        ]
        for size in compactModels {
            XCTAssertTrue(
                SystemInfo.canFitModelInMemory(
                    size,
                    physicalMemoryGB: 8,
                    availableBytes: 3 * 1024 * 1024 * 1024
                ),
                "\(size)"
            )
        }
    }
}
