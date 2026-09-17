// DownloadAndEngineTests.swift
// VocaMac Tests
//
// Download progress throttling, free-space checks, live-preview
// cancellation, and system-audio sample ownership.

import XCTest
@testable import VocaMac

// MARK: - ProgressThrottle

final class ProgressThrottleTests: XCTestCase {

    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 0
        var now: TimeInterval { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    func testFirstValueAlwaysPasses() {
        let clock = FakeClock()
        let throttle = ProgressThrottle(minimumInterval: 0.1, now: { clock.now })
        XCTAssertTrue(throttle.shouldDeliver(0.0))
    }

    func testUpdatesInsideTheIntervalAreDropped() {
        let clock = FakeClock()
        let throttle = ProgressThrottle(minimumInterval: 0.1, now: { clock.now })
        XCTAssertTrue(throttle.shouldDeliver(0.01))
        for step in 2...50 {
            clock.advance(0.001)
            XCTAssertFalse(throttle.shouldDeliver(Double(step) / 100))
        }
        clock.advance(0.1)
        XCTAssertTrue(throttle.shouldDeliver(0.51))
    }

    func testCompletionPassesEvenInsideTheInterval() {
        let clock = FakeClock()
        let throttle = ProgressThrottle(minimumInterval: 0.1, now: { clock.now })
        XCTAssertTrue(throttle.shouldDeliver(0.98))
        clock.advance(0.001)
        XCTAssertTrue(throttle.shouldDeliver(1.0))
    }

    func testNothingPassesAfterCompletion() {
        let clock = FakeClock()
        let throttle = ProgressThrottle(minimumInterval: 0.1, now: { clock.now })
        XCTAssertTrue(throttle.shouldDeliver(1.0))
        clock.advance(1)
        XCTAssertFalse(throttle.shouldDeliver(0.4), "A late tick must not move a finished bar backwards")
        XCTAssertFalse(throttle.shouldDeliver(1.0))
    }

    func testUnchangedValueIsDropped() {
        let clock = FakeClock()
        let throttle = ProgressThrottle(minimumInterval: 0.1, now: { clock.now })
        XCTAssertTrue(throttle.shouldDeliver(0.3))
        clock.advance(1)
        XCTAssertFalse(throttle.shouldDeliver(0.3))
    }

    func testWrapForwardsOnlyThrottledValues() {
        let clock = FakeClock()
        var received: [Double] = []
        let handler = ProgressThrottle.wrap(
            { received.append($0) },
            throttle: ProgressThrottle(minimumInterval: 0.1, now: { clock.now })
        )
        for step in 0..<1_000 {
            handler(Double(step) / 1_000)
        }
        handler(1.0)
        XCTAssertEqual(received, [0.0, 1.0])
    }
}

// MARK: - Free disk space

final class ModelDownloadDiskSpaceTests: XCTestCase {

    private let directory = URL(fileURLWithPath: "/tmp/does-not-matter", isDirectory: true)

    func testThrowsWhenTheVolumeIsTooFull() {
        XCTAssertThrowsError(
            try ModelManager.ensureFreeSpace(
                forModel: "Large v3",
                requiredBytes: 3_000_000_000,
                at: directory,
                availableCapacity: { _ in 1_000_000_000 }
            )
        ) { error in
            guard case ModelManagerError.insufficientDiskSpace(let model, let required, let available) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(model, "Large v3")
            XCTAssertEqual(required, 3_000_000_000)
            XCTAssertEqual(available, 1_000_000_000)
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Large v3"), message)
            XCTAssertTrue(message.contains("Free up some space"), message)
        }
    }

    func testPassesWhenThereIsEnoughRoom() {
        XCTAssertNoThrow(
            try ModelManager.ensureFreeSpace(
                forModel: "Tiny",
                requiredBytes: 100,
                at: directory,
                availableCapacity: { _ in 100 }
            )
        )
    }

    func testUnreadableCapacityDoesNotBlockTheDownload() {
        XCTAssertNoThrow(
            try ModelManager.ensureFreeSpace(
                forModel: "Tiny",
                requiredBytes: 100,
                at: directory,
                availableCapacity: { _ in nil }
            )
        )
    }

    func testRequiredBytesCoverTheModelAndArchiveStaging() {
        for size in ModelSize.allCases where !size.isSystemManaged {
            XCTAssertGreaterThan(ModelManager.requiredDownloadBytes(for: size), size.fileSizeBytes, "\(size)")
        }
        // An ONNX archive stays on disk until it has been extracted.
        XCTAssertGreaterThanOrEqual(
            ModelManager.requiredDownloadBytes(for: .canary180mFlash),
            ModelSize.canary180mFlash.fileSizeBytes * 2
        )
        XCTAssertEqual(ModelManager.requiredDownloadBytes(for: .appleSpeech), 0)
    }

    func testCapacityIsMeasuredAtTheNearestExistingDirectory() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        let capacity = ModelManager.volumeAvailableCapacity(at: missing)
        XCTAssertNotNil(capacity)
        XCTAssertGreaterThan(capacity ?? 0, 0)
    }

    func testSystemManagedModelsSkipTheSpaceCheck() async throws {
        let manager = ModelManager(availableCapacity: { _ in 0 })
        var progress: [Double] = []
        try await manager.downloadModel(size: .appleSpeech) { progress.append($0) }
        XCTAssertEqual(progress, [1.0])
    }

    func testCancellingWithNoDownloadIsHarmless() {
        ModelManager().cancelDownload(for: .small)
    }
}

// MARK: - Live preview

final class IncrementalPartialCancellationTests: XCTestCase {

    private final class DecodeProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var inFlight = 0
        private(set) var maxInFlight = 0
        private(set) var partialStarted = false
        private(set) var partialWasCancelled = false

        func begin() -> Int {
            lock.withLock {
                calls += 1
                inFlight += 1
                maxInFlight = max(maxInFlight, inFlight)
                if calls == 1 { partialStarted = true }
                return calls
            }
        }

        func end(cancelled: Bool, call: Int) {
            lock.withLock {
                inFlight -= 1
                if call == 1, cancelled { partialWasCancelled = true }
            }
        }
    }

    func testStreamEndCancelsTheRunningPartialDecode() async throws {
        let probe = DecodeProbe()
        let (chunks, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        let partials = LockedStrings()

        let run = Task {
            try await IncrementalAudioTranscriber.run(
                chunks: chunks,
                updateEverySamples: 16_000,
                transcribe: { samples in
                    let call = probe.begin()
                    do {
                        if call == 1 {
                            // A preview decode that would take far longer than the test allows.
                            try await Task.sleep(nanoseconds: 30_000_000_000)
                        }
                        probe.end(cancelled: false, call: call)
                    } catch {
                        probe.end(cancelled: true, call: call)
                        throw error
                    }
                    return VocaTranscription(
                        text: call == 1 ? "partial" : "final",
                        duration: 0,
                        detectedLanguage: "en",
                        audioLengthSeconds: Double(samples.count) / 16_000,
                        modelUsed: .tiny
                    )
                },
                onPartial: { partials.append($0) }
            )
        }

        continuation.yield([Float](repeating: 0, count: 16_000))
        let deadline = Date().addingTimeInterval(5)
        while !probe.partialStarted, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(probe.partialStarted)

        let stoppedAt = Date()
        continuation.yield([Float](repeating: 0, count: 8_000))
        continuation.finish()
        let result = try await run.value

        XCTAssertEqual(result.text, "final")
        XCTAssertEqual(result.audioLengthSeconds, 1.5, accuracy: 0.0001)
        XCTAssertLessThan(Date().timeIntervalSince(stoppedAt), 3, "The final decode waited behind the preview")
        XCTAssertTrue(probe.partialWasCancelled)
        XCTAssertEqual(probe.maxInFlight, 1, "The engine must never run two decodes at once")
        XCTAssertTrue(partials.values.isEmpty)
    }

    private final class LockedStrings: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        var values: [String] { lock.withLock { storage } }
        func append(_ value: String) { lock.withLock { storage.append(value) } }
    }
}

// MARK: - System audio

final class SystemAudioSampleOwnershipTests: XCTestCase {

    func testTakingSamplesReleasesTheRecording() {
        let accumulator = SystemAudioAccumulator(maximumDurationSeconds: 1)
        accumulator.reset(sampleRate: 16_000)
        XCTAssertFalse(accumulator.appendMonoSamples([0.1, 0.2, 0.3]))

        XCTAssertEqual(accumulator.takeNormalizedSamples(), [0.1, 0.2, 0.3])
        XCTAssertEqual(accumulator.normalizedSamples(), [])
    }

    func testResetWithAnInvalidRateDoesNotTrap() {
        let accumulator = SystemAudioAccumulator(maximumDurationSeconds: 1)
        accumulator.reset(sampleRate: 0)
        XCTAssertTrue(accumulator.appendMonoSamples([0.1]))
        XCTAssertEqual(accumulator.normalizedSamples(), [])
    }
}
