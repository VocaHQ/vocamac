// AppleSpeechService.swift
// VocaMac
//
// Transcription via Apple's SpeechAnalyzer/SpeechTranscriber (macOS 26+).
// Model assets are downloaded and managed by the system, so this engine
// needs no download UI and adds nothing to VocaMac's model storage.
//
// The implementation is compiled only with an SDK that ships the
// SpeechAnalyzer API (Xcode 26+); older toolchains build a stub that reports
// the engine as unavailable so CI on earlier macOS keeps working.

import Foundation
import AVFoundation
#if canImport(Speech)
import Speech
#endif

// MARK: - AppleSpeechError

enum AppleSpeechError: LocalizedError {
    case unsupportedSystem
    case modelNotLoaded
    case localeNotSupported(String)
    case audioFormatUnavailable
    case transcriptionFailed(reason: String)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .unsupportedSystem:
            return "Apple Speech requires macOS 26 or later."
        case .modelNotLoaded:
            return "Apple Speech is not prepared. Please load the model first."
        case .localeNotSupported(let locale):
            return "Apple Speech does not support the language '\(locale)' on this Mac."
        case .audioFormatUnavailable:
            return "Apple Speech could not negotiate an audio format."
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .emptyAudio:
            return "No audio data to transcribe."
        }
    }
}

// MARK: - AppleSpeechService

final class AppleSpeechService: @unchecked Sendable {

    // MARK: - Properties

    /// Whether the running system and the SDK this binary was built with
    /// both support SpeechAnalyzer.
    static var isRuntimeSupported: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    /// Whether the engine has been prepared (assets checked/installed)
    private var isPrepared = false
    private var preparedSession: (any PreparedSpeechSession)?
    private var preparedLocale: String?

    var isModelLoaded: Bool { isPrepared }

    var loadedModelName: String? { isPrepared ? ModelSize.appleSpeech.rawValue : nil }

    // MARK: - Model Management

    /// Prepare the system speech engine: resolves the locale to dictate in
    /// and asks the OS to install transcription assets if they are missing.
    ///
    /// - Parameter language: ISO 639-1 code the user selected, or nil to
    ///   follow the system locale. This must match what `transcribe` will ask
    ///   for, otherwise load installs assets for one language and the first
    ///   dictation downloads another — or load fails because the system
    ///   locale is unsupported while the selected language is fine.
    func loadModel(
        language: String? = nil,
        onPhaseChange: ((String) -> Void)? = nil
    ) async throws {
        #if compiler(>=6.2)
        guard #available(macOS 26.0, *) else { throw AppleSpeechError.unsupportedSystem }

        VocaLogger.info(.appleSpeechService, "Preparing Apple Speech (system engine)...")
        let startTime = CFAbsoluteTimeGetCurrent()

        onPhaseChange?("Checking speech assets…")
        let locale = language.map { Locale(identifier: $0) } ?? Locale.current
        await unloadModel()
        preparedSession = try await AppleSpeechEngine.prepareSession(for: locale, onPhaseChange: onPhaseChange)
        preparedLocale = locale.identifier
        isPrepared = true

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        VocaLogger.info(.appleSpeechService, "Apple Speech ready in \(String(format: "%.2f", elapsed))s")
        #else
        throw AppleSpeechError.unsupportedSystem
        #endif
    }

    func unloadModel() async {
        isPrepared = false
        let session = preparedSession
        preparedSession = nil
        preparedLocale = nil
        await session?.cancel()
    }

    // MARK: - Transcription

    /// Transcribe audio data to text using the system speech engine.
    /// - Parameters:
    ///   - audioData: Array of Float32 PCM samples at 16kHz mono
    ///   - language: ISO 639-1 language code, or nil to use the system locale.
    ///     Translation and custom vocabulary are not supported by this engine.
    func transcribe(
        audioData: [Float],
        language: String? = nil
    ) async throws -> VocaTranscription {
        guard !audioData.isEmpty else { throw AppleSpeechError.emptyAudio }
        let cursor = AudioChunkCursor(audioData)
        return try await transcribe(
            chunks: AsyncThrowingStream(unfolding: { await cursor.next() }), language: language
        )
    }

    /// Own one prepared analyzer for one utterance. Finished sessions are never reused.
    func transcribe(chunks: AsyncThrowingStream<[Float], Error>, language: String?) async throws -> VocaTranscription {
        #if compiler(>=6.2)
        guard #available(macOS 26.0, *) else { throw AppleSpeechError.unsupportedSystem }
        guard isPrepared else { throw AppleSpeechError.modelNotLoaded }
        let locale = language.map { Locale(identifier: $0) } ?? Locale.current
        let start = CFAbsoluteTimeGetCurrent()
        let session: any PreparedSpeechSession
        if let preparedSession, preparedLocale == locale.identifier {
            session = preparedSession
            self.preparedSession = nil
        } else {
            await preparedSession?.cancel()
            preparedSession = nil
            session = try await AppleSpeechEngine.prepareSession(for: locale)
        }
        do {
            try Task.checkCancellation()
            let (text, count) = try await session.transcribe(chunks)
            return VocaTranscription(
                text: text, duration: CFAbsoluteTimeGetCurrent() - start,
                detectedLanguage: language ?? locale.language.languageCode?.identifier ?? "auto",
                audioLengthSeconds: Double(count) / 16_000, modelUsed: .appleSpeech
            )
        } catch {
            await session.cancel()
            throw error
        }
        #else
        throw AppleSpeechError.unsupportedSystem
        #endif
    }

}

// MARK: - AppleSpeechEngine (SpeechAnalyzer wrapper)

#if compiler(>=6.2)
@available(macOS 26.0, *)
enum AppleSpeechEngine {

    /// Sample rate of the audio VocaMac's AudioEngine produces.
    private static let inputSampleRate: Double = 16_000

    /// Resolve a requested locale to one SpeechTranscriber supports.
    /// Falls back from an exact BCP-47 match to a same-language match.
    static func resolveSupportedLocale(matching locale: Locale) async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        if let exact = supported.first(where: {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }) {
            return exact
        }
        return supported.first {
            $0.language.languageCode == locale.language.languageCode
        }
    }

    /// Resolve assets and preheat before the first recording rather than after stop.
    fileprivate static func prepareSession(
        for locale: Locale, onPhaseChange: ((String) -> Void)? = nil
    ) async throws -> any PreparedSpeechSession {
        let interval = PerformanceTrace.begin("AppleSpeechPreparation")
        defer { PerformanceTrace.end(interval) }
        guard let resolved = await resolveSupportedLocale(matching: locale) else {
            throw AppleSpeechError.localeNotSupported(locale.identifier)
        }
        let transcriber = SpeechTranscriber(
            locale: resolved, transcriptionOptions: [], reportingOptions: [], attributeOptions: []
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onPhaseChange?("Downloading speech assets…")
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AppleSpeechError.audioFormatUnavailable
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        onPhaseChange?("Preparing speech recognition…")
        do {
            try await analyzer.prepareToAnalyze(in: format)
            try Task.checkCancellation()
            return ApplePreparedSpeechSession(analyzer: analyzer, transcriber: transcriber, format: format)
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }
}

@available(macOS 26.0, *)
private actor ApplePreparedSpeechSession: PreparedSpeechSession {
    let analyzer: SpeechAnalyzer
    let transcriber: SpeechTranscriber
    let format: AVAudioFormat
    private var started = false

    init(analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber, format: AVAudioFormat) {
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.format = format
    }

    func transcribe(_ chunks: AsyncThrowingStream<[Float], Error>) async throws -> (String, Int) {
        guard !started else { throw AppleSpeechError.modelNotLoaded }
        started = true
        let collector = Task { [transcriber] in
            var pieces: [String] = []
            for try await result in transcriber.results where result.isFinal {
                pieces.append(String(result.text.characters))
            }
            return pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let source = SpeechInputCursor(chunks: chunks, format: format)
        do {
            return try await withTaskCancellationHandler {
                let input = AsyncThrowingStream<AnalyzerInput, Error>(unfolding: { try await source.next() })
                let end = try await analyzer.analyzeSequence(input)
                if let end { try await analyzer.finalizeAndFinish(through: end) }
                else { await analyzer.cancelAndFinishNow() }
                let text = try await collector.value
                return (text, await source.sampleCount)
            } onCancel: {
                collector.cancel()
                Task { await self.cancel() }
            }
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            _ = try? await collector.value
            throw error
        }
    }

    func cancel() async { await analyzer.cancelAndFinishNow() }
}

/// Lazily convert only the next chunk requested by SpeechAnalyzer. The converter
/// spans chunks and drains once at EOF so resampling does not drop boundary frames.
@available(macOS 26.0, *)
actor SpeechInputCursor {
    private var iterator: AsyncThrowingStream<[Float], Error>.Iterator
    private let format: AVAudioFormat
    private let converter: AVAudioConverter?
    private(set) var sampleCount = 0
    private var ended = false

    init(chunks: AsyncThrowingStream<[Float], Error>, format: AVAudioFormat) {
        iterator = chunks.makeAsyncIterator()
        self.format = format
        converter = format == AudioEngine.whisperFormat ? nil : AVAudioConverter(from: AudioEngine.whisperFormat, to: format)
    }

    func next() async throws -> AnalyzerInput? {
        guard !ended else { return nil }
        // A single analyzer owns this iterator; move it out across the suspension.
        var currentIterator = iterator
        let samples = try await currentIterator.next()
        iterator = currentIterator
        try Task.checkCancellation()
        if samples == nil { ended = true }
        if let samples, samples.isEmpty { return try await next() }
        let count = samples?.count ?? 0
        sampleCount += count
        var input: AVAudioPCMBuffer?
        if let samples, !samples.isEmpty {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: AudioEngine.whisperFormat, frameCapacity: AVAudioFrameCount(count)),
                  let destination = buffer.floatChannelData?[0] else { throw AppleSpeechError.audioFormatUnavailable }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { destination.update(from: base, count: count) }
            }
            input = buffer
        }
        guard let converter else {
            guard format == AudioEngine.whisperFormat else { throw AppleSpeechError.audioFormatUnavailable }
            return input.map { AnalyzerInput(buffer: $0) }
        }
        let capacity = AVAudioFrameCount(ceil(Double(max(1, count)) * format.sampleRate / 16_000) + 1024)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AppleSpeechError.audioFormatUnavailable
        }
        let provider = SpeechConverterInput(buffer: input, isEnd: samples == nil)
        var error: NSError?
        let interval = PerformanceTrace.begin("AppleSpeechAudioConversion")
        let status = converter.convert(to: output, error: &error) { _, state in
            provider.next(state)
        }
        PerformanceTrace.end(interval)
        if let error { throw error }
        guard status != .error else { throw AppleSpeechError.audioFormatUnavailable }
        if output.frameLength == 0 { return ended ? nil : try await next() }
        return AnalyzerInput(buffer: output)
    }
}
/// AVAudioConverter invokes its input block synchronously and serially. This
/// holder owns the buffer until conversion returns; it never escapes to a task.
private final class SpeechConverterInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer?
    private let isEnd: Bool
    private var supplied = false
    init(buffer: AVAudioPCMBuffer?, isEnd: Bool) { self.buffer = buffer; self.isEnd = isEnd }
    func next(_ state: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard !supplied, let buffer else {
            state.pointee = isEnd ? .endOfStream : .noDataNow
            return nil
        }
        supplied = true
        state.pointee = .haveData
        return buffer
    }
}

#endif

/// Availability-erased session storage keeps the macOS 14 executable loadable.
private protocol PreparedSpeechSession: Sendable {
    func transcribe(_ chunks: AsyncThrowingStream<[Float], Error>) async throws -> (String, Int)
    func cancel() async
}
