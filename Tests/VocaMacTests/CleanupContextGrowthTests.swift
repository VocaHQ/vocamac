// CleanupContextGrowthTests.swift
// VocaMac
//
// Opt-in, against a real GGUF: the reload to full context for long input,
// the fallback when that reload fails, and cancelling during the reload.
//
//   VOCAMAC_CONTEXT_GROWTH_MODELS=~/Library/Application\ Support/VocaMac/models/cleanup \
//   swift test --filter CleanupContextGrowthTests
//
// Uses Qwen 2.5 1.5B (8,192-token context, starts at 4,096).

import XCTest
@testable import VocaMac

@MainActor
final class CleanupContextGrowthTests: XCTestCase {

    private let kind = CleanupModelKind.qwen25_1_5b_q4_k_m

    /// About 2,000 words in short paragraphs: more than one pass at 4,096
    /// tokens with the cleanup prompt, one pass at 8,192.
    private var longDictation: String {
        let sentences = [
            "so um I think we should move the launch to next week because the build is not ready yet.",
            "the team has been working really hard on the onboarding flow and it looks a lot better now.",
            "we still need to check the memory use on older Macs with eight gigabytes of RAM.",
            "can you send the report to the whole group before Friday morning.",
            "I talked to the designer and she wants the settings page to be simpler.",
            "there are a few bugs left in the export feature that we need to fix first.",
            "the release notes should mention the new models and the smaller downloads.",
        ]
        return (0..<30).map { paragraph in
            (0..<4).map { sentences[($0 * 3 + paragraph) % sentences.count] }.joined(separator: " ")
        }.joined(separator: "\n\n")
    }

    private func makeService() throws -> TranscriptCleanupService {
        guard let path = ProcessInfo.processInfo.environment["VOCAMAC_CONTEXT_GROWTH_MODELS"] else {
            throw XCTSkip("Set VOCAMAC_CONTEXT_GROWTH_MODELS to a folder holding \(kind.descriptor.fileName)")
        }
        let service = TranscriptCleanupService(modelsDirectory: URL(fileURLWithPath: path))
        guard service.isDownloaded(kind) else { throw XCTSkip("Download \(kind.descriptor.displayName) first") }
        return service
    }

    private func isSkipped(_ attempt: CleanupAttempt) -> Bool {
        if case .skipped = attempt.outcome { return true }
        return false
    }

    func testLongInputGrowsTheContextAndIsCleaned() async throws {
        let service = try makeService()
        service.modelFitsInMemory = { _, _ in true }
        var loads = 0
        service.willBeginLoad = { loads += 1 }
        await service.load(kind)

        let attempt = await service.preview(longDictation, prompt: "")

        XCTAssertFalse(isSkipped(attempt), "\(attempt.outcome)")
        XCTAssertEqual(loads, 2, "Loaded once at 4,096, once more at 8,192")
        XCTAssertTrue(service.isLoaded)
    }

    func testAFailedReloadFallsBackToTheSmallerModelAndItsParts() async throws {
        let service = try makeService()
        var memoryChecks = 0
        // The first load fits, the full-context reload is refused, the
        // fallback to the starting size fits again.
        service.modelFitsInMemory = { _, _ in
            memoryChecks += 1
            return memoryChecks != 2
        }
        await service.load(kind)

        let attempt = await service.preview(longDictation, prompt: "")

        XCTAssertEqual(memoryChecks, 3)
        XCTAssertTrue(service.isLoaded, "A refused reload must not leave cleanup with no model")
        XCTAssertFalse(isSkipped(attempt), "The planned parts still run: \(attempt.outcome)")
    }

    func testCancellingDuringTheReloadStopsThePass() async throws {
        let service = try makeService()
        service.modelFitsInMemory = { _, _ in true }
        var loads = 0
        service.willBeginLoad = { [weak service] in
            loads += 1
            // Escape pressed while the model reloads at full context.
            if loads == 2 { service?.cancelCleanup() }
        }
        await service.load(kind)

        let started = Date()
        let attempt = await service.attempt(longDictation, prompt: "")

        XCTAssertEqual(attempt.outcome, .skipped("cleanup was cancelled"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 15, "No generation after the cancel")
    }
}
