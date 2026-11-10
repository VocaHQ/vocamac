import AppKit
import WhisperKit
import XCTest
@testable import VocaMac

/// The pieces that take work off the wait between key-up and text.
final class StopToTextLatencyTests: XCTestCase {

    // MARK: - Silence detection while recording

    func testProcessedChunksMatchTheRecordingThatStartsWithThem() {
        let size = VoiceActivityStream.chunkSize
        let samples = (0..<(size * 3 + 100)).map { Float($0 % 97) / 97 }
        let hashes = (0..<2).map { VoiceActivityStream.fingerprint(samples[($0 * size)..<(($0 + 1) * size)]) }
        XCTAssertTrue(VoiceActivityStream.matches(chunkHashes: hashes, samples: samples))
        // A recording cut short at stop, before the processed audio ends.
        XCTAssertFalse(VoiceActivityStream.matches(chunkHashes: hashes, samples: Array(samples.prefix(size))))
        // Different audio in a processed chunk.
        var changed = samples
        changed[size + 5] += 0.5
        XCTAssertFalse(VoiceActivityStream.matches(chunkHashes: hashes, samples: changed))
    }

    func testAStreamWithoutALoadedDetectorLeavesTheBatchPass() async {
        let stream = VoiceActivityStream { nil }
        stream.append([Float](repeating: 0.1, count: VoiceActivityStream.chunkSize * 2), at: 0)
        let progress = await stream.finish()
        XCTAssertNil(progress)
    }

    func testFingerprintTellsSamplesApart() {
        let a: [Float] = [0, 0.25, -0.5]
        XCTAssertEqual(VoiceActivityStream.fingerprint(a[...]), VoiceActivityStream.fingerprint(a[...]))
        XCTAssertNotEqual(VoiceActivityStream.fingerprint(a[...]), VoiceActivityStream.fingerprint([0, 0.25, -0.49][...]))
    }

    // MARK: - Whisper runaway loops

    func testALoopStillRunningAtTheEndIsRunaway() {
        let text = Array(repeating: "Chalo.", count: 20).joined(separator: " ")
        XCTAssertTrue(TranscriptRepetition.isRunawayInProgress(text))
    }

    func testALoopFollowedByMoreWordsIsNotRunaway() {
        let text = Array(repeating: "Chalo.", count: 20).joined(separator: " ")
            + " and then we went home after dinner"
        XCTAssertFalse(TranscriptRepetition.isRunawayInProgress(text))
    }

    func testOneWordPastTheLoopIsNotRunaway() {
        // The decode has started moving on: stopping now would cut the rest
        // of the sentence.
        let text = Array(repeating: "Chalo.", count: 20).joined(separator: " ") + " and"
        XCTAssertFalse(TranscriptRepetition.isRunawayInProgress(text))
    }

    func testRepetitionSomeoneMightSayIsNotRunaway() {
        XCTAssertFalse(TranscriptRepetition.isRunawayInProgress("no no no no"))
        XCTAssertFalse(TranscriptRepetition.isRunawayInProgress("thank you, thank you, thank you"))
    }

    func testTheEarlyStopChecksEveryFewTokensAndStopsOnlyALoop() {
        let looped = Array(repeating: "Chalo.", count: 20).joined(separator: " ")
        let tokens = Array(repeating: 1, count: WhisperService.runawayCheckInterval * 3)
        XCTAssertEqual(WhisperService.stopRunawayLoop(Self.progress(looped, tokens: tokens)), false)
        XCTAssertNil(WhisperService.stopRunawayLoop(Self.progress(looped, tokens: tokens + [1])))
        XCTAssertNil(WhisperService.stopRunawayLoop(Self.progress("A normal sentence.", tokens: tokens)))
    }

    private static func progress(_ text: String, tokens: [Int]) -> TranscriptionProgress {
        TranscriptionProgress(timings: TranscriptionTimings(), text: text, tokens: tokens)
    }

    // MARK: - Cleanup prompt token count

    func testPromptTokenCountIsReusedOnlyForTheSameModelAndPrompt() {
        final class Model {}
        let model = Model()
        let other = Model()
        let cache = PromptTokenCountCache(model: ObjectIdentifier(model), prompt: "Clean this.", count: 812)
        XCTAssertEqual(cache.count(model: ObjectIdentifier(model), prompt: "Clean this."), 812)
        XCTAssertNil(cache.count(model: ObjectIdentifier(model), prompt: "Clean this!"))
        XCTAssertNil(cache.count(model: ObjectIdentifier(other), prompt: "Clean this."))
    }

    // MARK: - Vocabulary after the decode

    func testAnEngineThatNeedsTheVocabularyFirstWaitsForIt() async throws {
        let transcriber = MockWhisperService()
        _ = try await transcriber.transcribe(
            audioData: [0.1], language: nil, translate: false,
            vocabularyAfterDecode: { "Namrata, VocaMac" }
        )
        XCTAssertEqual(transcriber.lastVocabulary, "Namrata, VocaMac")
    }
}

// MARK: - Abandoned silence streams

@MainActor
final class AbandonedVoiceActivityStreamTests: XCTestCase {

    func testACancelledRecordingReleasesItsSilenceStream() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.isRecording = true
        appState.appStatus = .recording

        await appState.cancelRecording()

        XCTAssertEqual(mocks.whisperService.cancelVoiceActivityStreamCallCount, 1)
    }

    func testForceRecoveryReleasesTheSilenceStream() {
        let (appState, mocks) = AppState.makeTestState()
        appState.isRecording = true

        appState.forceRecovery()

        XCTAssertEqual(mocks.whisperService.cancelVoiceActivityStreamCallCount, 1)
    }
}

// MARK: - Clipboard copied at key-up

@MainActor
final class PreparedClipboardSnapshotTests: XCTestCase {

    func testAClipboardCopiedAtKeyUpIsPutBackAfterThePaste() async {
        let board = NSPasteboard(name: .init("com.vocamac.tests.\(UUID())"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("original", forType: .string)
        var pasted: String?
        let injector = TextInjector(pasteboard: board, accessibilityTrustedOverride: true,
                                    accessibilityInjectionOverride: { _ in false }, pasteActionOverride: {
            pasted = board.string(forType: .string)
        }, frontmostPIDProvider: { 123 })
        injector.prepareClipboardSnapshot()
        let held = await injector.preparedClipboardSnapshotForTesting()
        XCTAssertTrue(held)
        injector.inject(text: "dictation", preserveClipboard: true)
        await TextInjector.waitForInjectionQueueIdleForTesting()
        XCTAssertEqual(pasted, "dictation")
        XCTAssertEqual(board.string(forType: .string), "original")
        let stillHeld = await injector.preparedClipboardSnapshotForTesting()
        XCTAssertFalse(stillHeld, "the copy is not kept past its paste")
    }

    func testAClipboardChangedSinceKeyUpIsCopiedAgain() async {
        let board = NSPasteboard(name: .init("com.vocamac.tests.\(UUID())"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("original", forType: .string)
        let injector = TextInjector(pasteboard: board, accessibilityTrustedOverride: true,
                                    accessibilityInjectionOverride: { _ in false }, pasteActionOverride: {},
                                    frontmostPIDProvider: { 123 })
        injector.prepareClipboardSnapshot()
        _ = await injector.preparedClipboardSnapshotForTesting()
        // The user copies something else while the speech is decoded.
        board.clearContents()
        board.setString("copied while speaking", forType: .string)
        injector.inject(text: "dictation", preserveClipboard: true)
        await TextInjector.waitForInjectionQueueIdleForTesting()
        XCTAssertEqual(board.string(forType: .string), "copied while speaking")
    }

    func testAnUnusedCopyIsReleased() async {
        let board = NSPasteboard(name: .init("com.vocamac.tests.\(UUID())"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("original", forType: .string)
        let injector = TextInjector(pasteboard: board, accessibilityTrustedOverride: true, frontmostPIDProvider: { 123 })
        injector.prepareClipboardSnapshot()
        _ = await injector.preparedClipboardSnapshotForTesting()
        injector.releasePreparedClipboardSnapshot()
        await TextInjector.waitForInjectionQueueIdleForTesting()
        let held = await injector.preparedClipboardSnapshotForTesting()
        XCTAssertFalse(held)
    }
}
