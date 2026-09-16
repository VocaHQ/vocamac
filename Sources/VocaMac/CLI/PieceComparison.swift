// PieceComparison.swift
// VocaMac
//
// Offline check for "Process while speaking": decode (and clean) a recording
// whole and piece by piece, and report both texts and where the time went.

import Foundation

/// JSON for `--transcribe-file … --pieces`.
struct CLIPieceComparisonResponse: Codable, Equatable {
    struct Batch: Codable, Equatable {
        let text: String
        let decodeSeconds: Double
        let cleanedText: String?
        let cleanupSummary: String?
        let cleanupSeconds: Double?
        /// What the user waits after stop today: decode, then cleanup.
        let stopSeconds: Double

        enum CodingKeys: String, CodingKey {
            case text
            case decodeSeconds = "decode_seconds"
            case cleanedText = "cleaned_text"
            case cleanupSummary = "cleanup_summary"
            case cleanupSeconds = "cleanup_seconds"
            case stopSeconds = "stop_seconds"
        }
    }

    struct Piece: Codable, Equatable {
        let startSeconds: Double
        let endSeconds: Double
        let text: String
        let decodeSeconds: Double
        /// Cleanup run for this piece before stop; nil for the tail.
        let speculativeCleanupSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case startSeconds = "start_seconds"
            case endSeconds = "end_seconds"
            case text
            case decodeSeconds = "decode_seconds"
            case speculativeCleanupSeconds = "speculative_cleanup_seconds"
        }
    }

    struct PieceMode: Codable, Equatable {
        let text: String
        /// Word edit distance to the batch text over its word count.
        let wordDifferenceRate: Double
        /// A piece decoded to repeated text, so a live session would have
        /// given this recording to the batch path at stop.
        let fallsBackToBatch: Bool
        let tailDecodeSeconds: Double
        let cleanedText: String?
        let cleanupSummary: String?
        let finalCleanupSeconds: Double?
        let cleanupHits: Int?
        let cleanupMisses: Int?
        /// Projected wait after stop: the tail's decode plus the final pass,
        /// with every earlier piece already done while speaking.
        let stopSeconds: Double

        enum CodingKeys: String, CodingKey {
            case text
            case wordDifferenceRate = "word_difference_rate"
            case fallsBackToBatch = "falls_back_to_batch"
            case tailDecodeSeconds = "tail_decode_seconds"
            case cleanedText = "cleaned_text"
            case cleanupSummary = "cleanup_summary"
            case finalCleanupSeconds = "final_cleanup_seconds"
            case cleanupHits = "cleanup_hits"
            case cleanupMisses = "cleanup_misses"
            case stopSeconds = "stop_seconds"
        }
    }

    let model: String
    let engine: String
    let cleanupModel: String?
    let audioLengthSeconds: Double
    let batch: Batch
    let pieces: [Piece]
    let pieceMode: PieceMode

    enum CodingKeys: String, CodingKey {
        case model, engine, batch, pieces
        case cleanupModel = "cleanup_model"
        case audioLengthSeconds = "audio_length_seconds"
        case pieceMode = "piece_mode"
    }
}

enum WordDifference {
    /// Word-level edit distance from `reference` to `hypothesis`, over the
    /// reference's word count. Case and punctuation are ignored.
    static func rate(reference: String, hypothesis: String) -> Double {
        let expected = words(reference)
        let actual = words(hypothesis)
        guard !expected.isEmpty else { return actual.isEmpty ? 0 : 1 }
        var previous = Array(0...actual.count)
        for (i, word) in expected.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: actual.count)
            for (j, candidate) in actual.enumerated() {
                current[j + 1] = min(
                    previous[j + 1] + 1,
                    current[j] + 1,
                    previous[j] + (word == candidate ? 0 : 1)
                )
            }
            previous = current
        }
        return Double(previous[actual.count]) / Double(expected.count)
    }

    static func words(_ text: String) -> [String] {
        RewriteValidation.substrings(#"[\p{L}\p{N}']+"#, in: text.lowercased())
    }
}

extension HeadlessTranscriber {
    /// Run one comparison. Pieces are cut exactly as a live session would cut
    /// them; each earlier piece's cleanup runs to completion before the next
    /// piece arrives, as it would during real speech.
    func comparePieces(
        fileURL: URL,
        modelOverride: String?,
        languageOverride: String?,
        options: PieceComparisonOptions
    ) async throws -> CLIPieceComparisonResponse {
        let cleanupModel = options.cleanupModel
        let prepared = try await prepareTranscription(
            fileURL: fileURL, modelOverride: modelOverride, languageOverride: languageOverride
        )
        let samples = prepared.audio.samples
        let transcriber = prepared.transcriber
        let language = prepared.language

        func timed<T>(_ work: () async throws -> T) async rethrows -> (T, Double) {
            let start = ProcessInfo.processInfo.systemUptime
            let value = try await work()
            return (value, ProcessInfo.processInfo.systemUptime - start)
        }

        do {
            let (batch, batchSeconds) = try await timed {
                try await transcriber.transcribe(audioData: samples, language: language, translate: false, vocabulary: "")
            }

            var segmenter = SpeechSegmenter(configuration: StreamingCommitOptions(
                pauseSeconds: options.pauseSeconds, minPieceSeconds: options.minPieceSeconds
            ).segmenterConfiguration(
                maxPieceSeconds: TranscriptionRouter.maxPieceSeconds(for: prepared.model)
            ))
            var ranges: [Range<Int>] = []
            var offset = 0
            while offset < samples.count {
                let end = min(samples.count, offset + 1_600)
                ranges += segmenter.append(Array(samples[offset..<end]))
                offset = end
            }
            ranges += segmenter.finish()

            var pieces: [TranscribedPiece] = []
            var decodeSeconds: [Double] = []
            for range in ranges {
                let audio = Array(samples[range])
                guard !IncrementalAudioTranscriber.isSilent(audio) else {
                    pieces.append(TranscribedPiece(range: range, text: "", language: "auto"))
                    decodeSeconds.append(0)
                    continue
                }
                let (result, seconds) = try await timed {
                    try await transcriber.transcribe(
                        audioData: IncrementalAudioTranscriber.padded(audio),
                        language: language, translate: false, vocabulary: ""
                    )
                }
                pieces.append(TranscribedPiece(
                    range: range, text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    language: result.detectedLanguage
                ))
                decodeSeconds.append(seconds)
            }
            let pieceText = TranscribedPiece.join(pieces)
            let tailSeconds = decodeSeconds.last ?? 0
            let fallsBack = pieces.contains { RunawayText.isRunaway($0.text) }

            var cleanup: PieceCleanupMeasurement?
            if let cleanupModel, !fallsBack {
                cleanup = await measureCleanup(
                    kind: cleanupModel, batchText: batch.text, pieces: pieces,
                    language: batch.detectedLanguage
                )
            }

            if let cleanupModel, fallsBack {
                // Still measure today's path, which is what the user gets.
                cleanup = await measureCleanup(kind: cleanupModel, batchText: batch.text, pieces: [], language: batch.detectedLanguage)
            }
            let batchStopSeconds = batchSeconds + (cleanup?.batchSeconds ?? 0)
            return CLIPieceComparisonResponse(
                model: prepared.model.rawValue,
                engine: prepared.model.engine.cliIdentifier,
                cleanupModel: cleanupModel?.rawValue,
                audioLengthSeconds: prepared.audio.durationSeconds,
                batch: .init(
                    text: batch.text, decodeSeconds: batchSeconds,
                    cleanedText: cleanup?.batchText, cleanupSummary: cleanup?.batchSummary,
                    cleanupSeconds: cleanup?.batchSeconds,
                    stopSeconds: batchStopSeconds
                ),
                pieces: pieces.enumerated().map { index, piece in
                    .init(
                        startSeconds: Double(piece.range.lowerBound) / 16_000,
                        endSeconds: Double(piece.range.upperBound) / 16_000,
                        text: piece.text, decodeSeconds: decodeSeconds[index],
                        speculativeCleanupSeconds: cleanup?.speculativeSeconds.indices.contains(index) == true
                            ? cleanup?.speculativeSeconds[index] : nil
                    )
                },
                pieceMode: .init(
                    text: pieceText,
                    wordDifferenceRate: WordDifference.rate(reference: batch.text, hypothesis: pieceText),
                    fallsBackToBatch: fallsBack,
                    tailDecodeSeconds: tailSeconds,
                    cleanedText: cleanup?.pieceText, cleanupSummary: cleanup?.pieceSummary,
                    finalCleanupSeconds: cleanup?.finalSeconds,
                    cleanupHits: cleanup?.hits, cleanupMisses: cleanup?.misses,
                    stopSeconds: fallsBack ? batchStopSeconds : tailSeconds + (cleanup?.finalSeconds ?? 0)
                )
            )
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError(.transcriptionFailed, "Transcription failed: \(error.localizedDescription)")
        }
    }

    struct PieceCleanupMeasurement {
        let batchText: String
        let batchSummary: String
        let batchSeconds: Double
        let pieceText: String
        let pieceSummary: String
        let finalSeconds: Double
        /// Per piece; nil for pieces not cleaned ahead (the tail, empty ones).
        let speculativeSeconds: [Double?]
        let hits: Int
        let misses: Int
    }

    @MainActor
    private func measureCleanup(
        kind: CleanupModelKind,
        batchText: String,
        pieces: [TranscribedPiece],
        language: String
    ) async -> PieceCleanupMeasurement {
        let cleaner = cleanerFactory()
        let pipeline = DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander())
        let options = DictationOutputOptions(
            profile: WritingProfile(format: .plain, rules: WritingStyle.plain.defaultRules),
            snippetList: [], cleanupEnabled: true, rewritingEnabled: false,
            model: kind, customPrompt: "", language: language,
            autoCapitalize: true, trailingSpace: false
        )
        // Load first, so neither side pays for it.
        await cleaner.load(kind)

        func now() -> Double { ProcessInfo.processInfo.systemUptime }
        var start = now()
        let batch = await pipeline.process(batchText, options: options)
        let batchSeconds = now() - start

        let speculator = CleanupSpeculator(pipeline: pipeline) { pieceLanguage in
            var pieceOptions = options
            pieceOptions.language = pieceLanguage
            return pieceOptions
        }
        var speculativeSeconds: [Double?] = Array(repeating: nil, count: pieces.count)
        for (index, piece) in pieces.enumerated().dropLast() where !piece.text.isEmpty {
            start = now()
            speculator.submit(piece, index: index)
            await speculator.waitUntilIdle()
            speculativeSeconds[index] = now() - start
        }
        start = now()
        let joined = TranscribedPiece.join(pieces)
        let final = await pipeline.process(
            joined, options: DictationOutputOptions(
                profile: options.profile, snippetList: [], cleanupEnabled: true, rewritingEnabled: false,
                model: kind, customPrompt: "",
                language: pieces.first { !$0.text.isEmpty }?.language ?? language,
                autoCapitalize: true, trailingSpace: false
            ),
            pieces: pieces, speculator: speculator
        )
        let finalSeconds = now() - start
        await speculator.finish()
        cleaner.unload()
        return PieceCleanupMeasurement(
            batchText: batch.text, batchSummary: batch.summary, batchSeconds: batchSeconds,
            pieceText: final.text, pieceSummary: final.summary, finalSeconds: finalSeconds,
            speculativeSeconds: speculativeSeconds,
            hits: speculator.hitCount, misses: speculator.missCount
        )
    }
}
