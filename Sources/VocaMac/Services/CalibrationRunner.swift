// CalibrationRunner.swift
// VocaMac
//
// Runs one recording through several speech models, one at a time, on a
// transcriber of its own so the dictation model's state is never touched.

import Foundation

/// A model the accuracy test can run.
struct CalibrationCandidate: Equatable, Sendable {
    let size: ModelSize
    let name: String
    /// What the engine loads it by (`ModelManaging.modelIdentifier(for:)`).
    let identifier: String
    let folder: URL?
}

/// Where the test is: which model, and how many are done.
struct CalibrationProgress: Equatable, Sendable {
    let modelName: String
    let index: Int
    let total: Int
    /// The model has never loaded on this macOS build, so CoreML compiles
    /// it first, which can take minutes.
    let isFirstLoad: Bool
}

/// Loads each candidate in turn, transcribes the recording, scores it, and
/// unloads it before the next, so at most one test model is in memory.
@MainActor
final class CalibrationRunner {
    /// A transcriber that transcribes in `language` (sherpa-onnx models bind
    /// it at load time).
    typealias TranscriberFactory = @MainActor (_ language: String?) -> SpeechTranscribing

    private let makeTranscriber: TranscriberFactory
    private let now: () -> TimeInterval
    private(set) var isCancelled = false

    init(
        makeTranscriber: @escaping TranscriberFactory = { language in
            TranscriptionRouter(languagePreferenceProvider: { language })
        },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.makeTranscriber = makeTranscriber
        self.now = now
    }

    /// Stop after the model being tested; finished rows are kept.
    func cancel() { isCancelled = true }

    /// Test every candidate on `samples` and return the rows, best first.
    ///
    /// - Parameters:
    ///   - isFirstLoad: Whether a model compiles before it loads, for the
    ///     progress line.
    ///   - canLoad: Whether there is memory for the model now; one that
    ///     doesn't fit is reported instead of loaded.
    ///   - didLoad: Called after a model loads, so the app can remember it
    ///     has compiled.
    func run(
        candidates: [CalibrationCandidate],
        samples: [Float],
        passage: CalibrationPassage,
        language: String?,
        isFirstLoad: (ModelSize) -> Bool = { _ in false },
        canLoad: (ModelSize) -> Bool = { _ in true },
        didLoad: (ModelSize) -> Void = { _ in },
        progress: (CalibrationProgress) -> Void = { _ in }
    ) async -> [CalibrationRow] {
        var rows: [CalibrationRow] = []
        for (index, candidate) in candidates.enumerated() {
            guard !isCancelled, !Task.isCancelled else { break }
            progress(CalibrationProgress(
                modelName: candidate.name, index: index, total: candidates.count,
                isFirstLoad: isFirstLoad(candidate.size)
            ))
            // Memory is checked again right before each load: the Mac may
            // have less free than when the test began.
            guard canLoad(candidate.size) else {
                rows.append(.failed(
                    modelID: candidate.size.rawValue, modelName: candidate.name,
                    reason: "Needs more free memory than this Mac has right now."
                ))
                continue
            }
            let transcriber = makeTranscriber(language)
            do {
                try await transcriber.loadModel(name: candidate.identifier, folder: candidate.folder)
                didLoad(candidate.size)
                let started = now()
                let result = try await transcriber.transcribe(
                    audioData: samples, language: language, translate: false, vocabulary: ""
                )
                let seconds = max(0, now() - started)
                rows.append(CalibrationScoring.row(
                    modelID: candidate.size.rawValue, modelName: candidate.name, passage: passage,
                    hypothesis: result.text, seconds: seconds
                ))
                VocaLogger.info(
                    .appState,
                    "Accuracy test: \(candidate.name) \(rows.last?.errorRateText ?? "?") WER in \(String(format: "%.2f", seconds))s"
                )
            } catch {
                VocaLogger.warning(.appState, "Accuracy test: \(candidate.name) failed: \(error.localizedDescription)")
                rows.append(.failed(
                    modelID: candidate.size.rawValue, modelName: candidate.name,
                    reason: "Couldn’t run: \(error.localizedDescription)"
                ))
            }
            await transcriber.unloadModel()
        }
        return CalibrationScoring.ranked(rows)
    }
}
