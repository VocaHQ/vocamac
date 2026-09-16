// CLITests.swift
// VocaMacTests

import AVFoundation
import XCTest
@testable import VocaMac

final class CLITests: XCTestCase {

    // MARK: - Dispatch and parsing

    func testNoCLIArgumentsRouteToGUI() {
        XCTAssertEqual(CLICommand.invocationMode(arguments: []), .gui)
    }

    func testRestartedArgumentRoutesToGUI() {
        // Settings -> Debug -> Restart relaunches with `open ... --args --restarted`.
        // That argv must reach VocaMacApp, not be rejected by the CLI parser.
        XCTAssertEqual(CLICommand.invocationMode(arguments: ["--restarted"]), .gui)
    }

    func testHelpRoutesToCLIAndDoesNotRunHeadlessServices() async {
        let dependencies = makeDependencies(selectedModel: .tiny)
        var standardOutput = Data()
        let entrypoint = CLIEntrypoint(
            headlessTranscriber: dependencies.headless,
            stdout: { standardOutput.append($0) },
            stderr: { _ in XCTFail("Help should not write an error.") }
        )

        XCTAssertEqual(CLICommand.invocationMode(arguments: ["--help"]), .cli)
        let exitCode = await entrypoint.run(arguments: ["--help"])
        XCTAssertEqual(exitCode, 0)
        XCTAssertTrue(String(decoding: standardOutput, as: UTF8.self).contains("--transcribe-file"))
        XCTAssertEqual(dependencies.audioLoader.loadCount, 0)
        XCTAssertTrue(dependencies.transcriber.loadRequests.isEmpty)
    }

    func testMissingTranscribeFileValueFails() {
        XCTAssertThrowsError(try CLICommand.parse(arguments: ["--transcribe-file", "--json"])) { error in
            XCTAssertCLIError(error, category: .invalidArguments)
        }
    }

    func testUnknownArgumentFails() {
        XCTAssertThrowsError(try CLICommand.parse(arguments: ["--unknown", "--json"])) { error in
            XCTAssertCLIError(error, category: .invalidArguments)
        }
    }

    // MARK: - Piece comparison

    func testPiecesFlagParsesWithItsOptions() throws {
        XCTAssertEqual(
            try CLICommand.parse(arguments: [
                "--transcribe-file", "a.wav", "--json", "--pieces",
                "--cleanup", "ministral3_3b_q4_k_m", "--min-piece-seconds", "5",
            ]),
            .comparePieces(path: "a.wav", model: nil, language: nil, options: PieceComparisonOptions(
                cleanupModel: .ministral3_3b_q4_k_m, pauseSeconds: 0.6, minPieceSeconds: 5
            ))
        )
    }

    func testPieceOptionsNeedPiecesAndValidValues() {
        for arguments in [
            ["--transcribe-file", "a.wav", "--json", "--cleanup", "ministral3_3b_q4_k_m"],
            ["--transcribe-file", "a.wav", "--json", "--pieces", "--cleanup", "gpt-5"],
            ["--transcribe-file", "a.wav", "--json", "--pieces", "--pause-seconds", "-1"],
            ["--list-models", "--json", "--pieces"],
        ] {
            XCTAssertThrowsError(try CLICommand.parse(arguments: arguments), "\(arguments)") { error in
                XCTAssertCLIError(error, category: .invalidArguments)
            }
        }
    }

    func testPieceComparisonDecodesWholeAndPieceByPiece() async throws {
        let dependencies = makeDependencies(selectedModel: .tiny)
        let tone = (0..<80_000).map { 0.3 * sin(Float($0) * 2 * .pi * 220 / 16_000) }
        let audio = tone + [Float](repeating: 0, count: 16_000) + Array(tone.prefix(48_000))
        dependencies.audioLoader.loadedAudio = LoadedAudioFile(samples: audio, durationSeconds: Double(audio.count) / 16_000)

        let response = try await dependencies.headless.comparePieces(
            fileURL: URL(fileURLWithPath: "/mock/audio.wav"), modelOverride: nil, languageOverride: nil,
            options: PieceComparisonOptions(cleanupModel: nil, pauseSeconds: 0.6, minPieceSeconds: 4)
        )

        XCTAssertEqual(response.batch.text, "mock transcription")
        XCTAssertEqual(response.pieces.count, 2)
        XCTAssertEqual(response.pieceMode.text, "mock transcription mock transcription")
        XCTAssertEqual(response.pieceMode.wordDifferenceRate, 1)
        XCTAssertFalse(response.pieceMode.fallsBackToBatch)
        XCTAssertNil(response.batch.cleanedText)
    }

    func testWordDifferenceCountsEditsOverReferenceWords() {
        XCTAssertEqual(WordDifference.rate(reference: "Ship it on Friday.", hypothesis: "ship it on friday"), 0)
        XCTAssertEqual(WordDifference.rate(reference: "ship it on friday", hypothesis: "ship it friday"), 0.25)
        XCTAssertEqual(WordDifference.rate(reference: "ship it", hypothesis: "we ship it now"), 1)
        XCTAssertEqual(WordDifference.rate(reference: "", hypothesis: ""), 0)
    }

    // MARK: - Preference and model resolution

    func testOmittedModelReadsInjectedAppSelection() async throws {
        let dependencies = makeDependencies(selectedModel: .parakeetV2)

        let response = try await dependencies.headless.transcribe(
            fileURL: URL(fileURLWithPath: "/mock/audio.wav"),
            modelOverride: nil,
            languageOverride: nil
        )

        XCTAssertEqual(response.model, ModelSize.parakeetV2.rawValue)
        XCTAssertEqual(response.engine, "parakeet")
        XCTAssertEqual(dependencies.transcriber.loadRequests.first?.name, ModelSize.parakeetV2.rawValue)
    }

    func testMissingModelPreferenceFallsBackToTiny() async throws {
        // AppState's @AppStorage default is ModelSize.tiny, so a fresh install
        // (or prefs that never persisted the key) must behave the same headlessly.
        let dependencies = makeDependencies(selectedModelIdentifier: nil)

        let response = try await dependencies.headless.transcribe(
            fileURL: URL(fileURLWithPath: "/mock/audio.wav"),
            modelOverride: nil,
            languageOverride: nil
        )

        XCTAssertEqual(response.model, ModelSize.tiny.rawValue)
    }

    func testAppPreferencesReaderUsesInjectedDefaultsDomain() throws {
        let suiteName = "VocaMac.CLITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(ModelSize.small.rawValue, forKey: PreferenceKey.selectedModelSize)
        defaults.set("de", forKey: PreferenceKey.selectedLanguage)

        let reader = AppCLIPreferencesReader(defaults: defaults)

        XCTAssertEqual(reader.selectedModelIdentifier, ModelSize.small.rawValue)
        XCTAssertEqual(reader.selectedLanguageIdentifier, "de")
    }

    func testExplicitModelOverridesWithoutChangingPreferences() async throws {
        let dependencies = makeDependencies(selectedModel: .tiny)

        let response = try await dependencies.headless.transcribe(
            fileURL: URL(fileURLWithPath: "/mock/audio.wav"),
            modelOverride: ModelSize.parakeetV2.rawValue,
            languageOverride: nil
        )

        XCTAssertEqual(response.model, ModelSize.parakeetV2.rawValue)
        XCTAssertEqual(dependencies.preferences.selectedModelIdentifier, ModelSize.tiny.rawValue)
    }

    func testSelectedIdentifiersRouteToEveryEngine() async throws {
        let cases: [(ModelSize, String)] = [
            (.small, "whisperkit"),
            (.parakeetV2, "parakeet"),
            (.appleSpeech, "apple_speech"),
            (.moonshineTiny, "sherpa_onnx"),
        ]

        for (model, expectedEngine) in cases {
            let dependencies = makeDependencies(selectedModel: model)
            let response = try await dependencies.headless.transcribe(
                fileURL: URL(fileURLWithPath: "/mock/audio.wav"),
                modelOverride: nil,
                languageOverride: nil
            )

            XCTAssertEqual(response.engine, expectedEngine, "Wrong engine for \(model.rawValue)")
            XCTAssertEqual(
                dependencies.transcriber.loadRequests.first?.name,
                dependencies.modelManager.modelIdentifier(for: model)
            )
            XCTAssertEqual(
                TranscriptionRouter.engine(
                    forModelIdentifier: dependencies.modelManager.modelIdentifier(for: model)
                ),
                model.engine
            )
        }
    }

    func testSherpaRouterRequestsInjectedOneRequestLanguage() async {
        var languageProviderCallCount = 0
        let router = TranscriptionRouter(languagePreferenceProvider: {
            languageProviderCallCount += 1
            return "de"
        })

        do {
            // This model is intentionally not installed in CI. The provider
            // must still be consulted before SherpaService rejects its files.
            try await router.loadModel(name: ModelSize.moonshineTiny.rawValue)
        } catch {
            // Missing local model files are expected and unrelated to routing.
        }

        XCTAssertEqual(languageProviderCallCount, 1)
    }

    func testOmittedLanguageReadsPreferenceAndAutoBecomesNil() async throws {
        let selectedLanguage = makeDependencies(selectedModel: .small)
        selectedLanguage.preferences.selectedLanguageIdentifier = "fr"
        _ = try await selectedLanguage.headless.transcribe(
            fileURL: URL(fileURLWithPath: "/mock/audio.wav"),
            modelOverride: nil,
            languageOverride: nil
        )
        XCTAssertEqual(selectedLanguage.transcriber.lastLanguage, "fr")

        let automaticLanguage = makeDependencies(selectedModel: .small)
        automaticLanguage.preferences.selectedLanguageIdentifier = "auto"
        _ = try await automaticLanguage.headless.transcribe(
            fileURL: URL(fileURLWithPath: "/mock/audio.wav"),
            modelOverride: nil,
            languageOverride: nil
        )
        XCTAssertNil(automaticLanguage.transcriber.lastLanguage)
    }

    func testMissingUnsupportedAndUndownloadedModelsAreDistinct() async {
        let unknown = makeDependencies(selectedModelIdentifier: "does-not-exist")
        await assertTranscriptionFailure(unknown.headless, category: .modelNotFound)

        let unsupported = makeDependencies(selectedModel: .parakeetV2)
        unsupported.modelManager.supportedModels.removeAll { $0 == .parakeetV2 }
        await assertTranscriptionFailure(unsupported.headless, category: .modelUnsupported)

        let undownloaded = makeDependencies(selectedModel: .small)
        undownloaded.modelManager.downloadedModels.remove(.small)
        await assertTranscriptionFailure(undownloaded.headless, category: .modelNotDownloaded)
    }

    func testListModelsJSONMarksSelectedModel() async throws {
        let dependencies = makeDependencies(selectedModel: .parakeetV2)
        var standardOutput = Data()
        let entrypoint = CLIEntrypoint(
            headlessTranscriber: dependencies.headless,
            stdout: { standardOutput.append($0) },
            stderr: { _ in XCTFail("Model listing should not fail.") }
        )

        let exitCode = await entrypoint.run(arguments: ["--list-models", "--json"])
        XCTAssertEqual(exitCode, 0)
        let response = try JSONDecoder().decode(CLIModelListResponse.self, from: standardOutput)
        let selected = try XCTUnwrap(response.models.first(where: \.selected))
        XCTAssertEqual(selected.id, ModelSize.parakeetV2.rawValue)
        XCTAssertEqual(selected.engine, "parakeet")
        XCTAssertTrue(selected.downloaded)
        XCTAssertTrue(selected.supported)
        XCTAssertFalse(selected.systemManaged)
    }

    // MARK: - Transcription JSON

    func testSuccessJSONIncludesContractFieldsAndLanguage() async throws {
        let dependencies = makeDependencies(selectedModel: .parakeetV2)
        dependencies.transcriber.mockTranscriptionResult = VocaTranscription(
            text: "Transcribed text",
            duration: 0.72,
            detectedLanguage: "en",
            audioLengthSeconds: 4.3,
            modelUsed: .parakeetV2
        )
        dependencies.audioLoader.loadedAudio = LoadedAudioFile(
            samples: [0.2, -0.2],
            durationSeconds: 4.3
        )
        var standardOutput = Data()
        let entrypoint = CLIEntrypoint(
            headlessTranscriber: dependencies.headless,
            stdout: { standardOutput.append($0) },
            stderr: { _ in XCTFail("Transcription should not fail.") }
        )

        let exitCode = await entrypoint.run(arguments: [
            "--transcribe-file", "/mock/audio.wav", "--language", "en", "--json",
        ])
        XCTAssertEqual(exitCode, 0)
        let response = try JSONDecoder().decode(CLITranscriptionResponse.self, from: standardOutput)
        XCTAssertEqual(response.text, "Transcribed text")
        XCTAssertEqual(response.model, ModelSize.parakeetV2.rawValue)
        XCTAssertEqual(response.engine, "parakeet")
        XCTAssertEqual(response.detectedLanguage, "en")
        XCTAssertEqual(response.durationSeconds, 0.72)
        XCTAssertEqual(response.audioLengthSeconds, 4.3)
        XCTAssertEqual(dependencies.transcriber.lastLanguage, "en")
    }

    func testUnicodeTranscriptJSONIsValid() async throws {
        let dependencies = makeDependencies(selectedModel: .small)
        let transcript = "नमस्ते — こんにちは 👋\nnext line"
        dependencies.transcriber.mockTranscriptionResult = VocaTranscription(
            text: transcript,
            duration: 0.1,
            detectedLanguage: "hi",
            audioLengthSeconds: 1,
            modelUsed: .small
        )
        var standardOutput = Data()
        let entrypoint = CLIEntrypoint(
            headlessTranscriber: dependencies.headless,
            stdout: { standardOutput.append($0) },
            stderr: { _ in XCTFail("Transcription should not fail.") }
        )

        let exitCode = await entrypoint.run(arguments: [
            "--transcribe-file", "/mock/audio.wav", "--json",
        ])
        XCTAssertEqual(exitCode, 0)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: standardOutput) as? [String: Any]
        )
        XCTAssertEqual(object["text"] as? String, transcript)
    }

    // MARK: - Audio conversion

    func testStereoNon16kHzWAVConvertsToMono16kHzSamples() throws {
        let url = temporaryURL(extension: "wav")
        let sourceRate = 44_100.0
        let frameCount: AVAudioFrameCount = 4_410
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceRate,
            channels: 2,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<Int(frameCount) {
            let sample = Float(sin(2 * Double.pi * 440 * Double(frame) / sourceRate)) * 0.25
            channels[0][frame] = sample
            channels[1][frame] = sample * 0.5
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        let loaded = try AudioFileLoader().loadAudio(at: url)

        XCTAssertEqual(loaded.samples.count, 1_600, accuracy: 2)
        XCTAssertEqual(loaded.durationSeconds, 0.1, accuracy: 0.001)
        XCTAssertTrue(loaded.samples.contains(where: { abs($0) > 0.01 }))
    }

    func testEmptyAndInvalidAudioAreRejected() throws {
        let emptyURL = temporaryURL(extension: "wav")
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        _ = try AVAudioFile(forWriting: emptyURL, settings: format.settings)

        XCTAssertThrowsError(try AudioFileLoader().loadAudio(at: emptyURL)) { error in
            XCTAssertCLIError(error, category: .invalidAudio)
        }

        let invalidURL = temporaryURL(extension: "wav")
        try Data("not audio".utf8).write(to: invalidURL)
        XCTAssertThrowsError(try AudioFileLoader().loadAudio(at: invalidURL)) { error in
            XCTAssertCLIError(error, category: .invalidAudio)
        }
    }

    func testSilentAudioIsRejected() throws {
        let url = temporaryURL(extension: "wav")
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800))
        buffer.frameLength = 800
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<800 {
            channel[frame] = 0
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        XCTAssertThrowsError(try AudioFileLoader().loadAudio(at: url)) { error in
            XCTAssertCLIError(error, category: .invalidAudio)
        }
    }

    func testHeadlessTranscriptionRecordsTheLoad() async throws {
        let suiteName = "CLITests.compiledModels"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let record = CompiledModelRecord(defaults: defaults, osBuild: "27A1", compileCacheExists: { true })
        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.small]
        let headless = HeadlessTranscriber(
            modelManager: modelManager,
            preferences: MockCLIPreferences(
                selectedModelIdentifier: ModelSize.small.rawValue,
                selectedLanguageIdentifier: "auto"
            ),
            audioLoader: MockAudioFileLoader(),
            transcriber: MockWhisperService(),
            compiledModels: record
        )

        _ = try await headless.transcribe(
            fileURL: URL(fileURLWithPath: "/mock/audio.wav"),
            modelOverride: nil,
            languageOverride: nil
        )

        XCTAssertTrue(record.hasLoaded(.small))
    }

    // MARK: - Helpers

    private func makeDependencies(selectedModel: ModelSize) -> TestDependencies {
        makeDependencies(selectedModelIdentifier: selectedModel.rawValue)
    }

    private func makeDependencies(selectedModelIdentifier: String?) -> TestDependencies {
        let modelManager = MockModelManager()
        modelManager.downloadedModels = Set(ModelSize.allCases.filter { !$0.isSystemManaged })
        let preferences = MockCLIPreferences(
            selectedModelIdentifier: selectedModelIdentifier,
            selectedLanguageIdentifier: "auto"
        )
        let audioLoader = MockAudioFileLoader()
        let transcriber = MockWhisperService()
        let headless = HeadlessTranscriber(
            modelManager: modelManager,
            preferences: preferences,
            audioLoader: audioLoader,
            transcriber: transcriber
        )
        return TestDependencies(
            modelManager: modelManager,
            preferences: preferences,
            audioLoader: audioLoader,
            transcriber: transcriber,
            headless: headless
        )
    }

    private func assertTranscriptionFailure(
        _ headless: HeadlessTranscriber,
        category: CLIErrorCategory
    ) async {
        do {
            _ = try await headless.transcribe(
                fileURL: URL(fileURLWithPath: "/mock/audio.wav"),
                modelOverride: nil,
                languageOverride: nil
            )
            XCTFail("Expected \(category.rawValue).")
        } catch {
            XCTAssertCLIError(error, category: category)
        }
    }

    private func XCTAssertCLIError(
        _ error: Error,
        category: CLIErrorCategory,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let cliError = error as? CLIError else {
            return XCTFail("Expected CLIError, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(cliError.category, category, file: file, line: line)
    }

    private func temporaryURL(extension pathExtension: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocaMac-CLITests-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private struct TestDependencies {
    let modelManager: MockModelManager
    let preferences: MockCLIPreferences
    let audioLoader: MockAudioFileLoader
    let transcriber: MockWhisperService
    let headless: HeadlessTranscriber
}

private final class MockCLIPreferences: CLIPreferencesReading {
    var selectedModelIdentifier: String?
    var selectedLanguageIdentifier: String?

    init(selectedModelIdentifier: String?, selectedLanguageIdentifier: String?) {
        self.selectedModelIdentifier = selectedModelIdentifier
        self.selectedLanguageIdentifier = selectedLanguageIdentifier
    }
}

private final class MockAudioFileLoader: AudioFileLoading {
    var loadedAudio = LoadedAudioFile(samples: [0.1, -0.1], durationSeconds: 1)
    var loadCount = 0

    func loadAudio(at url: URL) throws -> LoadedAudioFile {
        loadCount += 1
        return loadedAudio
    }
}

final class SingleInstanceTests: XCTestCase {
    func testOnlyOtherGUIVocaMacExecutablesAreTerminated() {
        let output = """
          100 VocaMac          /Applications/VocaMac.app/Contents/MacOS/VocaMac
          200 VocaMac          /usr/local/bin/VocaMac --transcribe-file /tmp/a b.wav --json
          300 tail             tail -f /Users/me/Library/Logs/VocaMac/vocamac.log
          400 xcodebuild       xcodebuild -scheme VocaMac build
          500 VocaMac          /Users/me/vocamac/.build/debug/VocaMac -hidden-flag
          600 VocaMac          /Applications/VocaMac.app/Contents/MacOS/VocaMac
        """
        XCTAssertEqual(
            VocaMacApp.previousGUIInstancePIDs(psOutput: output, currentPID: 600),
            [100, 500]
        )
    }
}
