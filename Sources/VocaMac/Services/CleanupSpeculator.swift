// CleanupSpeculator.swift
// VocaMac
//
// Cleans up each finished piece of a dictation while the user is still
// speaking, so the pass at stop only has to clean what changed.

import Foundation

/// Runs the cleanup model on pieces as they are decoded, and hands the answers
/// to the final pass when its request is exactly the same.
///
/// Correctness never depends on this: the final pass asks for each part of the
/// text by its exact prompt and model input, and anything not found here, or
/// changed since (a spoken correction reaching back, a different writing
/// style), is cleaned again at stop. One generation runs at a time, because
/// llama.cpp here serves a single sequence. If pieces arrive faster than the
/// model answers, only the two newest waiting pieces are kept (a piece and
/// the tail decoded early after it); older ones are cleaned at stop.
///
/// Created per recording and never reused.
@MainActor
final class CleanupSpeculator {
    /// Options for a piece in the given engine-reported language, or nil to
    /// skip it. Async because they may wait on screen context.
    typealias OptionsProvider = @MainActor (_ language: String) async -> DictationOutputOptions?

    private let pipeline: DictationOutputPipeline
    private let options: OptionsProvider

    private var completed: [CleanupRequestKey: CleanupAttempt] = [:]
    private var running: (key: CleanupRequestKey, task: Task<CleanupAttempt, Never>)?
    /// Requests not started yet, oldest piece first.
    private var waiting: [(index: Int, request: CleanupRequest)] = []
    static let maxWaiting = 2
    /// No new job starts once the final pass has begun, or after a cancel.
    private var isSealed = false
    /// Escape or recovery: the dictation is abandoned, so the final pass
    /// stops cleaning its remaining parts too.
    private(set) var isCancelled = false
    /// The running job already asked to stop, so it isn't stopped twice.
    private var stoppedKey: CleanupRequestKey?

    /// Text of every piece submitted, by index, so each request is prepared
    /// the way the final pass prepares the whole dictation: in the language
    /// of its first piece, judged English (or not) from all of it so far.
    private var submittedTexts: [Int: (text: String, language: String)] = [:]
    /// The newest submission for each piece. Preparing a request suspends,
    /// so an older one for the same piece can finish last; it is dropped.
    private var latestSubmission: [Int: Int] = [:]
    private var submissionCounter = 0

    private(set) var submittedCount = 0
    private var preparingCount = 0
    private(set) var hitCount = 0
    private(set) var missCount = 0
    private(set) var cancelledCount = 0

    init(pipeline: DictationOutputPipeline, options: @escaping OptionsProvider) {
        self.pipeline = pipeline
        self.options = options
    }

    // MARK: - While recording

    /// A piece was decoded. Its text goes through the same stages the final
    /// pass runs, and the resulting model request is queued.
    func submit(_ piece: TranscribedPiece, index: Int) {
        guard !isSealed, !piece.text.isEmpty else { return }
        submittedCount += 1
        preparingCount += 1
        submittedTexts[index] = (piece.text, piece.language)
        submissionCounter += 1
        let submission = submissionCounter
        latestSubmission[index] = submission
        // The final pass reads the whole dictation in the language the engine
        // reported for its first piece; a later piece labelled differently
        // would otherwise build a request the final pass never makes.
        let ordered = submittedTexts.sorted { $0.key < $1.key }
        let language = ordered.first?.value.language ?? piece.language
        let textSoFar = TranscribedPiece.join(ordered.filter { $0.key <= index }.map(\.value.text))
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.preparingCount -= 1 }
            guard !self.isSealed, let options = await self.options(language) else { return }
            let isEnglishText = DictationOutputPipeline.knownLanguage(options.language)
                .map(DictationOutputPipeline.isEnglish)
                ?? RewriteValidation.likelyEnglish(textSoFar)
            guard let request = await self.pipeline.cleanupRequest(
                      for: piece.text, options: options, isEnglishText: isEnglishText
                  ),
                  !self.isSealed, self.latestSubmission[index] == submission else { return }
            self.enqueue(request, index: index)
        }
    }

    /// Wait until every submitted piece has been cleaned or dropped. For
    /// benchmarks that feed pieces faster than real speech would.
    func waitUntilIdle() async {
        while preparingCount > 0 || running != nil || !waiting.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func enqueue(_ request: CleanupRequest, index: Int) {
        guard completed[request.key] == nil, running?.key != request.key else { return }
        waiting.removeAll { $0.index == index }
        waiting.append((index, request))
        waiting.sort { $0.index < $1.index }
        if waiting.count > Self.maxWaiting {
            waiting.removeFirst(waiting.count - Self.maxWaiting)
        }
        startNextIfIdle()
    }

    private func startNextIfIdle() {
        guard running == nil, !isSealed, !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        let key = next.request.key
        let pipeline = pipeline
        let task = Task { @MainActor in
            let interval = PerformanceTrace.begin("PieceCleanup")
            defer { PerformanceTrace.end(interval) }
            return await pipeline.speculate(next.request)
        }
        running = (key, task)
        Task { @MainActor [weak self] in
            let attempt = await task.value
            guard let self else { return }
            self.store(attempt, for: key)
            if self.running?.key == key { self.running = nil }
            self.startNextIfIdle()
        }
    }

    private func store(_ attempt: CleanupAttempt, for key: CleanupRequestKey) {
        // Skipped means the model never answered this request (cancelled,
        // busy, not loaded): the final pass should try it itself.
        if case .skipped = attempt.outcome { return }
        completed[key] = attempt
    }

    // MARK: - At stop

    /// The final pass is about to ask for `needed`. Stop queueing, drop the
    /// waiting piece (the final pass cleans it in order anyway), and stop a
    /// running generation nobody needs any more. Returns once the model is no
    /// longer busy with such a job.
    func beginFinal(needed: Set<CleanupRequestKey>) async {
        isSealed = true
        waiting.removeAll()
        guard let running, !needed.contains(running.key) else { return }
        if running.key != stoppedKey {
            stoppedKey = running.key
            cancelledCount += 1
            PerformanceTrace.event("SpeculativeCleanupCancelled")
            pipeline.cleaner.cancelCleanup()
        }
        _ = await running.task.value
    }

    /// The answer to `key` if one was computed ahead of time. Waits for a
    /// running job first, so a nil return always leaves the model free for the
    /// caller.
    func claim(_ key: CleanupRequestKey) async -> CleanupAttempt? {
        isSealed = true
        waiting.removeAll()
        if let running {
            let attempt = await running.task.value
            store(attempt, for: running.key)
        }
        if let attempt = completed[key] {
            hitCount += 1
            PerformanceTrace.event("SpeculativeCleanupHit")
            return attempt
        }
        missCount += 1
        PerformanceTrace.event("SpeculativeCleanupMiss")
        return nil
    }

    /// Escape, auto-pause, Force Recovery: stop now and never start again.
    func cancelAll() {
        isCancelled = true
        isSealed = true
        waiting.removeAll()
        guard let running, running.key != stoppedKey else { return }
        stoppedKey = running.key
        cancelledCount += 1
        PerformanceTrace.event("SpeculativeCleanupCancelled")
        pipeline.cleaner.cancelCleanup()
    }

    /// Stop anything left and wait until the model is free. For callers that
    /// are done with the dictation; the app itself only cancels, so a paste
    /// never waits on work it doesn't need.
    func finish() async {
        cancelAll()
        if let running {
            _ = await running.task.value
        }
    }
}
