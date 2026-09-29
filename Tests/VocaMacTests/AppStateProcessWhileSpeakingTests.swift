import XCTest
@testable import VocaMac

@MainActor
final class AppStateProcessWhileSpeakingTests: XCTestCase {
    private let first = TranscribedPiece(range: 0..<2, text: "so we could could ship it on friday.", language: "en")
    private let second = TranscribedPiece(range: 2..<3, text: "then we talk about the review.", language: "en")

    /// A live session that consumes the audio and returns `pieces` as if it
    /// had decoded them while recording.
    private func committedSession(_ pieces: [TranscribedPiece]) -> (String?) -> RecordingTranscription? {
        { language in
            RecordingTranscription(language: language) { chunks in
                var count = 0
                for try await chunk in chunks { count += chunk.count }
                return VocaTranscription(
                    text: TranscribedPiece.join(pieces), duration: 0, detectedLanguage: "en",
                    audioLengthSeconds: Double(count) / 16_000, modelUsed: .tiny, pieces: pieces
                )
            }
        }
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    func testSettingIsOffByDefaultAndRecordingsDontCommitPieces() async {
        let (app, mocks) = AppState.makeTestState()
        XCTAssertFalse(app.processWhileSpeaking)
        await app.startRecording()
        XCTAssertNil(mocks.whisperService.lastStreamingCommit)
        await app.cancelRecording()
    }

    func testSettingAsksTheEngineForPieces() async {
        let (app, mocks) = AppState.makeTestState()
        app.processWhileSpeaking = true
        await app.startRecording()
        let commit = mocks.whisperService.lastStreamingCommit
        XCTAssertNotNil(commit)
        XCTAssertNotNil(commit?.vocabulary, "Whisper reads recognition vocabulary per piece")
        XCTAssertEqual(commit?.revisesPrevious, true)
        await app.cancelRecording()
    }

    func testPreviewsAndTranslationStayOnTheBatchPath() async {
        let (app, mocks) = AppState.makeTestState()
        app.processWhileSpeaking = true
        await app.startRecording(injectResult: false)
        XCTAssertNil(mocks.whisperService.lastStreamingCommit, "previews and practice show batch output")
        await app.cancelRecording()

        app.translationEnabled = true
        await app.startRecording()
        XCTAssertNil(mocks.whisperService.lastStreamingCommit, "Whisper translation always decodes in batch")
        await app.cancelRecording()
    }

    func testCommandModeNeedsTheWholeInstruction() async {
        let selection = MockSelectedTextService()
        selection.selectedText = "This sentence is unnecessarily long."
        let (app, mocks) = AppState.makeTestState(selectedTextService: selection)
        app.processWhileSpeaking = true
        app.transcriptCleanupEnabled = true
        await app.beginCommandMode()
        XCTAssertTrue(app.isRecording)
        XCTAssertNil(mocks.whisperService.lastStreamingCommit)
        await app.cancelRecording()
    }

    func testPiecesCleanedWhileRecordingAreReusedAtStop() async {
        let (app, mocks) = AppState.makeTestState()
        app.processWhileSpeaking = true
        app.transcriptCleanupEnabled = true
        app.appendTrailingSpace = false
        mocks.transcriptCleanup.cleanHandler = { $0.replacingOccurrences(of: "could could", with: "could") }
        mocks.whisperService.streamingFactory = committedSession([first, second])

        await app.startRecording()
        mocks.whisperService.lastStreamingCommit?.onPiece?(0, first)
        await waitUntil { mocks.transcriptCleanup.speculateCallCount == 1 }
        mocks.audioEngine.onAudioSamples?([0.2, 0.3], 0)
        mocks.audioEngine.onAudioSamples?([0.4], 2)
        mocks.audioEngine.stopRecordingResult = [0.2, 0.3, 0.4]
        await app.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.textInjector.lastInjectedText, "So we could ship it on friday. Then we talk about the review.")
        XCTAssertNil(mocks.whisperService.lastTranscribedAudioData, "no batch decode")
        XCTAssertEqual(mocks.transcriptCleanup.speculateCallCount, 1)
        XCTAssertEqual(mocks.transcriptCleanup.cleanCallCount, 1, "only the last piece is cleaned after stop")
        XCTAssertLessThanOrEqual(mocks.transcriptCleanup.maxConcurrentModelCalls, 1)
    }

    func testEscapeStopsCleanupRunningForTheRecording() async {
        let (app, mocks) = AppState.makeTestState()
        app.processWhileSpeaking = true
        app.transcriptCleanupEnabled = true
        var release: CheckedContinuation<Void, Never>?
        mocks.transcriptCleanup.onSpeculate = { await withCheckedContinuation { release = $0 } }
        mocks.transcriptCleanup.onCancelCleanup = { release?.resume(); release = nil }
        mocks.whisperService.streamingFactory = committedSession([first, second])

        await app.startRecording()
        mocks.whisperService.lastStreamingCommit?.onPiece?(0, first)
        await waitUntil { release != nil }
        await app.cancelRecording()

        XCTAssertGreaterThanOrEqual(mocks.transcriptCleanup.cancelCleanupCallCount, 1)
        XCTAssertNil(release)
        XCTAssertEqual(mocks.textInjector.injectCallCount, 0)
    }

    func testPiecesThatDontCoverTheRecordingFallBackToBatch() async {
        let (app, mocks) = AppState.makeTestState()
        app.processWhileSpeaking = true
        mocks.whisperService.streamingFactory = committedSession([first])

        await app.startRecording()
        mocks.audioEngine.onAudioSamples?([0.2, 0.3, 0.4], 0)
        mocks.audioEngine.stopRecordingResult = [0.2, 0.3, 0.4]
        await app.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.whisperService.lastTranscribedAudioData, [0.2, 0.3, 0.4])
        XCTAssertEqual(app.lastTranscription?.text, "mock transcription")
        XCTAssertEqual(app.lastTranscription?.pieces, [])
    }

    func testSettingIsSearchableAndArchived() {
        let entry = SettingsSearchIndex.matches(query: "faster").first { $0.id == "process-while-speaking" }
        XCTAssertEqual(entry?.page, .dictation, "it speeds up transcription without Smart Cleanup too")
        XCTAssertTrue(SettingsArchiveService.keys.contains(PreferenceKey.processWhileSpeaking))
    }

    // MARK: - Follow-ups

    func testCorrectionsOnlyWhenPiecesArentCleanedAhead() async {
        let (app, mocks) = AppState.makeTestState()
        app.processWhileSpeaking = true
        app.transcriptCleanupEnabled = true
        await app.startRecording()
        XCTAssertEqual(mocks.whisperService.lastStreamingCommit?.revisesPrevious, false,
                       "a corrected piece would be cleaned twice")
        await app.cancelRecording()
    }

    func testLowPowerModeKeepsRecordingsOnTheBatchPath() async {
        let (app, mocks) = AppState.makeTestState()
        app.processWhileSpeaking = true
        app.isPowerConstrained = { true }
        await app.startRecording()
        XCTAssertNil(mocks.whisperService.lastStreamingCommit)
        await app.cancelRecording()

        app.isPowerConstrained = { false }
        await app.startRecording()
        XCTAssertNotNil(mocks.whisperService.lastStreamingCommit)
        await app.cancelRecording()
    }

    func testPowerConstraintReadsLowPowerModeAndHeat() {
        XCTAssertEqual(
            AppState.systemIsPowerConstrained(),
            ProcessInfo.processInfo.isLowPowerModeEnabled
                || [.serious, .critical].contains(ProcessInfo.processInfo.thermalState)
        )
    }

    func testOnlySessionsThatStopOnSilenceDecodeEarly() async {
        let (app, mocks) = AppState.makeTestState()
        let originalMode = app.activationMode
        let originalSilence = app.silenceDuration
        defer {
            app.activationMode = originalMode
            app.silenceDuration = originalSilence
        }
        app.processWhileSpeaking = true
        app.activationMode = .pushToTalk
        await app.startRecording()
        XCTAssertNil(mocks.whisperService.lastStreamingCommit?.earlyDecodeQuietSeconds,
                     "push to talk stops on key-up, right after the last word")
        await app.cancelRecording()

        app.activationMode = .doubleTapToggle
        app.silenceDuration = 2
        await app.startRecording()
        let commit = mocks.whisperService.lastStreamingCommit
        XCTAssertEqual(commit?.earlyDecodeQuietSeconds ?? 0, 2.0 / 3, accuracy: 0.001)
        XCTAssertEqual(commit?.isReadyForEarlyDecode?(), true, "no context terms can change the vocabulary")
        XCTAssertNotNil(commit?.onTentativePiece)
        await app.cancelRecording()
    }

    func testPiecesSkipTheVocabularyForAModelThatTakesNoPrompt() async {
        let (app, mocks) = AppState.makeTestState()
        let originalModel = app.selectedModelSize
        let originalMode = app.activationMode
        defer {
            app.selectedModelSize = originalModel
            app.activationMode = originalMode
        }
        app.processWhileSpeaking = true
        app.activationMode = .doubleTapToggle

        app.selectedModelSize = ModelSize.small.rawValue
        await app.startRecording()
        XCTAssertNotNil(mocks.whisperService.lastStreamingCommit?.vocabulary)
        XCTAssertNotNil(mocks.whisperService.lastStreamingCommit?.isReadyForEarlyDecode)
        await app.cancelRecording()

        // Nothing to read or wait for: the vocabulary never reaches the model.
        app.selectedModelSize = ModelSize.vocaHinglish.rawValue
        await app.startRecording()
        XCTAssertNotNil(mocks.whisperService.lastStreamingCommit, "pieces still decode while speaking")
        XCTAssertNil(mocks.whisperService.lastStreamingCommit?.vocabulary)
        XCTAssertNil(mocks.whisperService.lastStreamingCommit?.isReadyForEarlyDecode)
        await app.cancelRecording()
    }

    func testEarlyDecodeQuietFitsTheSilenceBeforeStop() {
        XCTAssertEqual(AppState.earlyDecodeQuietSeconds(silenceDuration: 0.5), 0.3)
        XCTAssertEqual(AppState.earlyDecodeQuietSeconds(silenceDuration: 1.5), 0.5, accuracy: 0.001)
        XCTAssertEqual(AppState.earlyDecodeQuietSeconds(silenceDuration: 30), 1.0)
    }

    func testTailDecodedEarlyIsCleanedBeforeStop() async {
        let (app, mocks) = AppState.makeTestState()
        app.processWhileSpeaking = true
        app.transcriptCleanupEnabled = true
        app.appendTrailingSpace = false
        mocks.transcriptCleanup.cleanHandler = { $0.replacingOccurrences(of: "could could", with: "could") }
        mocks.whisperService.streamingFactory = committedSession([first, second])

        await app.startRecording()
        let commit = mocks.whisperService.lastStreamingCommit
        commit?.onPiece?(0, first)
        commit?.onTentativePiece?(1, second)
        await waitUntil { mocks.transcriptCleanup.speculateCallCount == 2 }
        mocks.audioEngine.onAudioSamples?([0.2, 0.3, 0.4], 0)
        mocks.audioEngine.stopRecordingResult = [0.2, 0.3, 0.4]
        await app.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.textInjector.lastInjectedText, "So we could ship it on friday. Then we talk about the review.")
        XCTAssertEqual(mocks.transcriptCleanup.cleanCallCount, 0, "nothing is left to clean after stop")
    }

    func testWaitAfterStopIsRecordedForStats() async {
        let (app, mocks) = AppState.makeTestState()
        app.processWhileSpeaking = true
        mocks.whisperService.streamingFactory = committedSession([first, second])
        await app.startRecording()
        mocks.audioEngine.onAudioSamples?([0.2, 0.3, 0.4], 0)
        mocks.audioEngine.stopRecordingResult = [0.2, 0.3, 0.4]
        await app.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.statsManager.recordedStopWaits.count, 1)
        XCTAssertEqual(mocks.statsManager.recordedStopWaits.first?.processedWhileSpeaking, true)

        app.processWhileSpeaking = false
        await app.startRecording()
        mocks.audioEngine.stopRecordingResult = [0.2, 0.3, 0.4]
        await app.stopRecordingAndTranscribe()
        XCTAssertEqual(mocks.statsManager.recordedStopWaits.last?.processedWhileSpeaking, false)
    }
}
