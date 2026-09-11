// TranscriptCleanupService.swift
// VocaMac
//
// Downloads, loads, and runs a local GGUF cleanup model via LLM.swift.

import Combine
import Foundation
import LLM

@MainActor
final class TranscriptCleanupService: ObservableObject, TranscriptCleaning {

    @Published private(set) var modelState: CleanupModelState = .idle

    var objectWillChangePublisher: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }

    var isLoaded: Bool { activeLLM != nil }
    var loadedKind: CleanupModelKind? { activeLLM == nil ? nil : activeKind }

    /// Characters of transcript that still fit alongside `prompt`. Zero means
    /// the prompt has eaten the whole context and cleanup will never run.
    nonisolated func inputBudget(forPrompt prompt: String) -> Int {
        TranscriptCleanup.inputCharacterBudget(
            promptCharacters: prompt.count,
            maxTokenCount: Int(CleanupModelCatalog.recommended.maxTokenCount)
        )
    }

    private let modelsDirectory: URL
    private var activeLLM: LLM?
    private var activeKind: CleanupModelKind?

    /// The load in flight, so overlapping `load` calls join it instead of
    /// racing two llama.cpp contexts into memory at once. `generation` is the
    /// loadGeneration captured when this attempt started, so a joiner can tell
    /// a pre-unload wait from a post-unload re-enable.
    private var loadInFlight: (kind: CleanupModelKind, generation: Int, task: Task<Bool, Never>)?

    /// Which load attempt is allowed to install its model. Constructing a GGUF
    /// takes long enough for the user to turn cleanup off mid-load, and
    /// without this the finished load would put the model back — disabled, but
    /// resident, and reported as ready.
    private var loadGeneration = 0

    /// The download in flight, so the user can call it off.
    private var downloadTask: Task<Void, Never>?

    /// Which download attempt owns `modelState` and the destination file. A
    /// superseded attempt keeps running long enough to reach its own cleanup,
    /// and without this its late writes clobber the attempt that replaced it.
    private var downloadGeneration = 0

    /// A generation left running past its deadline. It still owns the model,
    /// so it has to finish before another one may start.
    private var pendingGeneration: Task<String, Never>?
    /// A Settings preview must not interrupt a dictation that owns the model.
    private var attemptInProgress = false

    /// Consecutive cleanups that produced nothing usable. A model that cannot
    /// do the job degrades into "the feature quietly does nothing", which is
    /// how the Qwen 3.5 context-reuse breakage hid — so say so instead.
    private var consecutiveFailures = 0
    private static let failureLimit = 3

    /// Seam for tests. Runs on the main actor once a load has registered its
    /// generation and in-flight entry but before the GGUF is constructed —
    /// the exact window in which an unload or a delete has to invalidate it.
    /// Async so a test can park a second load on the in-flight await before
    /// invalidating. Timing a fixed sleep into that window is unreliable: a
    /// load that fails fast can finish before the test ever observes it.
    var willBeginLoad: (() async -> Void)?

    /// Seam for tests; production checks reclaimable RAM against the catalog
    /// estimate, the same gate the speech models use (vocamac#251).
    var modelFitsInMemory: (CleanupModelDescriptor) -> Bool = {
        SystemInfo.canFitInMemory(requiredGB: $0.ramRequiredGB)
    }

    /// Hard ceiling on one cleanup pass. The transcript is waiting to be
    /// pasted, so the deadline hands back the raw text rather than waiting
    /// for llama.cpp to wind down.
    private static let timeoutSeconds: TimeInterval = 12

    /// Command Mode edits can be as long as the selection and the user is
    /// explicitly waiting for them, so they get a longer ceiling. Escape still
    /// stops one early through `cancelTransform`.
    private static let transformTimeoutSeconds: TimeInterval = 60

    /// Set while a Command Mode transform owns the model, so a cancel only
    /// stops that generation and never a dictation's cleanup.
    private var transformInProgress = false

    /// How long a straggler from a previous deadline gets to finish before
    /// this utterance gives up on cleanup entirely.
    private static let drainSeconds: TimeInterval = 3

    init(modelsDirectory: URL? = nil) {
        if let modelsDirectory {
            self.modelsDirectory = modelsDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.modelsDirectory = appSupport
                .appendingPathComponent("VocaMac", isDirectory: true)
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent("cleanup", isDirectory: true)
        }
    }

    func clean(_ text: String, prompt: String) async -> String {
        await attemptClean(text, prompt: prompt, recordingFailures: true, allowsTransform: false).output
    }

    func attempt(_ text: String, prompt: String) async -> CleanupAttempt {
        await attemptClean(text, prompt: prompt, recordingFailures: true, allowsTransform: false)
    }

    /// Same pass as `clean`, but reporting what happened and without letting a
    /// hand-typed experiment trip the give-up counter that guards dictation.
    func preview(_ text: String, prompt: String) async -> CleanupAttempt {
        await attemptClean(text, prompt: prompt, recordingFailures: false, allowsTransform: false)
    }

    func transform(_ text: String, prompt: String) async -> CleanupAttempt {
        transformInProgress = true
        defer { transformInProgress = false }
        return await attemptClean(text, prompt: prompt, recordingFailures: false, allowsTransform: true)
    }

    func cancelTransform() {
        guard transformInProgress else { return }
        activeLLM?.stop()
    }

    private func attemptClean(
        _ text: String,
        prompt: String,
        recordingFailures: Bool,
        allowsTransform: Bool
    ) async -> CleanupAttempt {
        let started = Date()
        func result(_ output: String, _ outcome: CleanupAttempt.Outcome) -> CleanupAttempt {
            CleanupAttempt(output: output, outcome: outcome, duration: Date().timeIntervalSince(started))
        }
        guard !attemptInProgress else {
            return result(text, .skipped("another rewrite is already running"))
        }
        attemptInProgress = true
        defer { attemptInProgress = false }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return result(text, .skipped("there is nothing to clean"))
        }

        guard let llm = activeLLM else {
            VocaLogger.info(.transcriptCleanup, "Cleanup skipped — model not ready")
            return result(text, .skipped("no cleanup model is loaded"))
        }

        // Already given up on this model; do not make every dictation pay for
        // an inference that has failed three times running.
        if recordingFailures, case .error = modelState, consecutiveFailures >= Self.failureLimit {
            return result(text, .skipped("cleanup gave up after \(consecutiveFailures) failures"))
        }

        let activePrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? TranscriptCleanup.defaultPrompt
            : prompt

        // Past the context budget the answer is cut off mid-sentence and gets
        // discarded anyway, so skip the wait rather than stall the paste.
        let budget = TranscriptCleanup.inputCharacterBudget(
            promptCharacters: activePrompt.count,
            maxTokenCount: Int(activeKind?.descriptor.maxTokenCount ?? 4096)
        )
        guard trimmed.count <= budget else {
            VocaLogger.info(
                .transcriptCleanup,
                "Transcript is \(trimmed.count) characters, over the \(budget)-character context budget — skipping cleanup"
            )
            return result(text, .skipped("the text is \(trimmed.count) characters and only \(budget) fit alongside the prompt"))
        }

        let formatted = TranscriptCleanup.formatInput(trimmed)

        do {
            let raw = try await runInference(
                llm: llm, prompt: activePrompt, input: formatted,
                timeout: allowsTransform ? Self.transformTimeoutSeconds : Self.timeoutSeconds
            )
            let accepted = allowsTransform
                ? TranscriptCleanup.acceptedTransformOutput(raw, original: trimmed)
                : TranscriptCleanup.acceptedOutput(raw, original: trimmed)
            if let accepted {
                if recordingFailures { consecutiveFailures = 0 }
                VocaLogger.info(.transcriptCleanup, "Cleanup produced \(accepted.count) characters")
                return result(accepted, accepted == trimmed ? .unchanged : .cleaned)
            }
            let why = raw.isEmpty || raw == "..." ? "the model returned nothing" : "the rewrite failed the safety check"
            if recordingFailures {
                recordFailure(reason: raw.isEmpty || raw == "..." ? "produced no output" : "produced unusable output")
            }
            let sanitized = TranscriptCleanup.sanitize(raw)
            return CleanupAttempt(
                output: text, outcome: .rejected(why), duration: Date().timeIntervalSince(started),
                rejectedCandidate: sanitized.isEmpty || sanitized == "..." ? nil : sanitized
            )
        } catch CleanupInferenceError.deadlineExceeded {
            let limit = Int(allowsTransform ? Self.transformTimeoutSeconds : Self.timeoutSeconds)
            if recordingFailures {
                recordFailure(reason: "did not answer within \(limit)s")
            }
            return result(text, .rejected("the model ran past its \(limit)s deadline"))
        } catch CleanupInferenceError.modelBusy {
            VocaLogger.warning(.transcriptCleanup, "Previous cleanup still winding down — using raw transcript")
            return result(text, .skipped("the previous cleanup is still finishing"))
        } catch {
            VocaLogger.warning(.transcriptCleanup, "Cleanup failed: \(error.localizedDescription)")
            return result(text, .rejected(error.localizedDescription))
        }
    }

    /// Count an unusable result and, once it is clearly not a one-off, put the
    /// reason on screen instead of leaving the user to wonder why nothing is
    /// being cleaned up.
    private func recordFailure(reason: String) {
        consecutiveFailures += 1
        VocaLogger.warning(
            .transcriptCleanup,
            "Cleanup \(reason) (\(consecutiveFailures) in a row)"
        )
        guard consecutiveFailures >= Self.failureLimit else { return }
        let name = activeKind?.descriptor.displayName ?? "The cleanup model"
        modelState = .error(
            "\(name) returned nothing usable \(consecutiveFailures) times in a row. "
            + "Dictation is using the raw transcript. Try reloading the model."
        )
    }

    /// Delete GGUFs the catalog no longer lists — a model dropped from the
    /// catalog would otherwise sit in Application Support forever.
    func pruneUnknownModels() {
        let known = CleanupModelCatalog.knownFileNames
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: modelsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where !known.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
            VocaLogger.info(.transcriptCleanup, "Removed retired cleanup model \(file.lastPathComponent)")
        }
    }

    func isDownloaded(_ kind: CleanupModelKind) -> Bool {
        isPlausibleFile(modelPath(for: kind), descriptor: kind.descriptor)
    }

    func download(_ kind: CleanupModelKind) async {
        // Run the transfer in a retained task so `cancelDownload` can reach it;
        // FileDownloader turns the cancellation into a stopped URLSession task
        // rather than a transfer that keeps running in the background.
        // Let the superseded attempt finish unwinding first: its `catch`
        // deletes the destination file, and run late that would delete what
        // this attempt is about to write.
        if let previous = downloadTask {
            previous.cancel()
            _ = await previous.value
        }
        downloadGeneration &+= 1
        let generation = downloadGeneration
        let task = Task<Void, Never> { [weak self] in
            await self?.performDownload(kind, generation: generation)
        }
        downloadTask = task
        await task.value
        if downloadTask == task {
            downloadTask = nil
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        // Retire the generation so nothing the cancelled attempt does on its
        // way out lands on screen.
        downloadGeneration &+= 1
        downloadTask = nil
        if case .downloading = modelState {
            modelState = .idle
        }
    }

    private func performDownload(_ kind: CleanupModelKind, generation: Int) async {
        let descriptor = kind.descriptor
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let destination = modelPath(for: kind)
        if isPlausibleFile(destination, descriptor: descriptor) {
            return
        }
        try? FileManager.default.removeItem(at: destination)

        // A new attempt clears whatever error the last one left on screen.
        setDownloadState(.downloading(kind: kind, progress: 0), generation: generation)
        do {
            try await FileDownloader.download(from: descriptor.url, to: destination) { [weak self] progress in
                // Progress arrives on a session queue and is hopped to the
                // main actor, so a final tick can land after the transfer has
                // already completed. The generation check keeps it from
                // resurrecting a "downloading" row.
                Task { @MainActor in
                    self?.setDownloadState(
                        .downloading(kind: kind, progress: progress),
                        generation: generation
                    )
                }
            }
            let digest = try ModelManager.sha256Hex(ofFileAt: destination)
            let size = fileSize(at: destination)
            guard digest.caseInsensitiveCompare(descriptor.expectedSHA256) == .orderedSame,
                  size == descriptor.expectedByteCount else {
                try? FileManager.default.removeItem(at: destination)
                setDownloadState(
                    .error("The download for \(descriptor.displayName) did not match its expected contents."),
                    generation: generation
                )
                VocaLogger.error(.transcriptCleanup, "Checksum mismatch for \(descriptor.displayName)")
                return
            }
            setDownloadState(.idle, generation: generation)
            VocaLogger.info(.transcriptCleanup, "Downloaded \(descriptor.displayName)")
        } catch is CancellationError {
            // Only the attempt that still owns the file may delete it.
            if generation == downloadGeneration {
                try? FileManager.default.removeItem(at: destination)
            }
            setDownloadState(.idle, generation: generation)
            VocaLogger.info(.transcriptCleanup, "Download cancelled: \(descriptor.displayName)")
        } catch {
            if generation == downloadGeneration {
                try? FileManager.default.removeItem(at: destination)
            }
            let message = "Failed to download \(descriptor.displayName): \(error.localizedDescription)"
            setDownloadState(.error(message), generation: generation)
            VocaLogger.error(.transcriptCleanup, message)
        }
    }

    /// Apply a download state only if this attempt is still the current one.
    private func setDownloadState(_ state: CleanupModelState, generation: Int) {
        guard generation == downloadGeneration else { return }
        modelState = state
    }

    func load(_ kind: CleanupModelKind) async {
        if activeKind == kind, activeLLM != nil {
            // The error message tells the user to reload, so a reload of the
            // model that has been failing must rebuild it — llama.cpp state is
            // exactly what a run of empty answers points at — rather than flip
            // the badge back to Ready and change nothing.
            if consecutiveFailures > 0 {
                VocaLogger.info(.transcriptCleanup, "Rebuilding \(kind.descriptor.displayName) after \(consecutiveFailures) failed cleanups")
                unload()
            } else {
                modelState = .ready
                return
            }
        }

        // Join a load already running for this model rather than starting a
        // second llama.cpp context; a load for a *different* model has to
        // finish first so the two never hold memory at the same time.
        if let inFlight = loadInFlight {
            let joinedSameKind = inFlight.kind == kind
            let generationAtEntry = loadGeneration
            _ = await inFlight.task.value
            // Every caller that entered before unload is obsolete, whether it
            // asked for the same model or a different one. Without this check
            // a different-kind waiter falls through and starts a fresh load
            // after cleanup was turned off.
            if generationAtEntry != loadGeneration {
                return
            }
            if joinedSameKind {
                // Installed — done.
                if activeKind == kind, activeLLM != nil {
                    return
                }
                // Same attempt failed on its own (OOM, bad file, etc.). The
                // joiner must not retry — that would double-init.
                if generationAtEntry == inFlight.generation {
                    return
                }
                // Caller entered after unload while the stale task was still
                // finishing: generation matches current but not the in-flight
                // attempt. Fall through to start a fresh load (re-enable).
            }
        }

        let descriptor = kind.descriptor
        let path = modelPath(for: kind)
        guard isPlausibleFile(path, descriptor: descriptor) else {
            modelState = .idle
            return
        }

        // Refuse a known-too-large load before llama.cpp maps the weights and
        // pushes the machine into swap, matching the speech-model gate.
        guard modelFitsInMemory(descriptor) else {
            let needed = String(format: "%.1f", descriptor.ramRequiredGB)
            let message = "Not enough free memory to load \(descriptor.displayName) "
                + "(~\(needed) GB needed). Free RAM or choose a smaller cleanup model."
            modelState = .error(message)
            VocaLogger.error(.transcriptCleanup, message)
            return
        }

        modelState = .loading(kind: kind)
        consecutiveFailures = 0
        activeLLM = nil
        activeKind = nil

        loadGeneration &+= 1
        let generation = loadGeneration
        let maxTokens = descriptor.maxTokenCount
        let task = Task<Bool, Never> { [weak self] in
            await self?.willBeginLoad?()
            let loading = Task.detached(priority: .userInitiated) {
                // repeatPenalty 1.0 (the library defaults to 1.2): the job is
                // to reproduce what was said, and penalising recently-seen
                // tokens makes the model drop the speaker's own repetitions.
                // On a repetition-heavy transcript the 1.2 default cut 11
                // occurrences of a word down to 7 and merged clauses; at 1.0
                // every clause survived.
                LLMBox(LLM(
                    from: path,
                    seed: 42,
                    topP: 0.9,
                    temp: 0.1,
                    repeatPenalty: 1.0,
                    maxTokenCount: maxTokens
                ))
            }
            let loaded = await loading.value.llm
            guard let self else { return false }
            return self.finishLoad(loaded, kind: kind, descriptor: descriptor, generation: generation)
        }
        loadInFlight = (kind: kind, generation: generation, task: task)
        _ = await task.value
        // Compare the task, not the kind: a same-kind retry can replace
        // loadInFlight after a stale join, and clearing by kind would drop it.
        if loadInFlight?.task == task {
            loadInFlight = nil
        }
    }

    func unload() {
        // A generation abandoned at a deadline keeps the model alive through
        // its own reference; ask it to stop so the weights are actually freed.
        activeLLM?.stop()
        activeLLM = nil
        activeKind = nil
        // The straggler belongs to the model just dropped; leaving the handle
        // around makes the next generation wait on — and stop() — a model it
        // has nothing to do with.
        pendingGeneration = nil
        // Retire any load still constructing so finishLoad cannot install it
        // after cleanup was turned off. Keep loadInFlight so a concurrent
        // load joins this one instead of starting a second llama init while
        // weights are still being mapped.
        loadGeneration &+= 1
        consecutiveFailures = 0
        modelState = .idle
        VocaLogger.info(.transcriptCleanup, "Unloaded cleanup model")
    }

    func delete(_ kind: CleanupModelKind) {
        try? FileManager.default.removeItem(at: modelPath(for: kind))
        // Mid-load, activeKind is nil — still invalidate so finishLoad cannot
        // install after the GGUF file is gone.
        if activeKind == kind || loadInFlight?.kind == kind {
            unload()
        }
        objectWillChange.send()
        VocaLogger.info(.transcriptCleanup, "Deleted \(kind.descriptor.displayName)")
    }

    // MARK: - Private

    /// Install a freshly constructed `LLM`, or report why it could not load.
    private func finishLoad(
        _ loaded: LLM?,
        kind: CleanupModelKind,
        descriptor: CleanupModelDescriptor,
        generation: Int
    ) -> Bool {
        // Unloaded or superseded while this one was still constructing. Drop
        // the model on the floor rather than install it: `loaded` is the only
        // strong reference, so returning here frees the weights.
        guard generation == loadGeneration else {
            loaded?.stop()
            VocaLogger.info(.transcriptCleanup, "Discarded a superseded load of \(descriptor.displayName)")
            return false
        }

        guard let loaded else {
            modelState = .error("Failed to load \(descriptor.displayName).")
            VocaLogger.error(.transcriptCleanup, "Failed to load \(descriptor.displayName)")
            return false
        }

        // The library's defaults print every token to stdout; the cleanup path
        // reads `output` once and streams nothing to the UI.
        loaded.postprocess = { (_: String) in }
        loaded.update = { (_: String?) in }
        loaded.updateThinking = { (_: String?) in }
        loaded.historyLimit = 0
        activeLLM = loaded
        activeKind = kind
        modelState = .ready
        VocaLogger.info(.transcriptCleanup, "Ready: \(descriptor.displayName)")
        return true
    }

    private func modelPath(for kind: CleanupModelKind) -> URL {
        modelsDirectory.appendingPathComponent(kind.descriptor.fileName)
    }

    private func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? -1)
    }

    private func isPlausibleFile(_ url: URL, descriptor: CleanupModelDescriptor) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return fileSize(at: url) == descriptor.expectedByteCount
    }

    private func runInference(
        llm: LLM, prompt: String, input: String, timeout: TimeInterval
    ) async throws -> String {
        // A generation abandoned at an earlier deadline still owns the model.
        // `LLM.respond` silently no-ops while the model is busy and leaves the
        // *previous* utterance's text in `output`, so reading it back would
        // paste the wrong transcript. Wait for the straggler, then give up on
        // cleaning this one rather than risk that.
        if let straggler = pendingGeneration {
            llm.stop()
            guard await Self.value(of: straggler, within: Self.drainSeconds) != nil else {
                throw CleanupInferenceError.modelBusy
            }
            pendingGeneration = nil
        }

        let box = LLMBox(llm)
        // Detached: `respond` runs the llama.cpp loop, and a Task inherited
        // from this main-actor method would run it on the main thread.
        let generation = Task.detached(priority: .userInitiated) { () -> String in
            guard let model = box.llm else { return "" }
            model.systemPrompt = prompt
            model.history = []
            await model.respond(to: input, thinking: .suppressed)
            return model.output
        }
        pendingGeneration = generation

        guard let output = await Self.value(of: generation, within: timeout) else {
            // Hand control back now: ask llama.cpp to wind down and drain the
            // task on the next call. Awaiting it here — which is what a task
            // group would do on its way out — is what makes a deadline soft.
            llm.stop()
            throw CleanupInferenceError.deadlineExceeded
        }
        pendingGeneration = nil
        return output
    }

    /// Awaits `task` for at most `seconds`, returning nil at the deadline and
    /// leaving the task running. Structured concurrency cannot express this:
    /// a task group awaits its children before it returns, and `Task.value`
    /// on a non-throwing task ignores the caller's cancellation.
    private static func value<T: Sendable>(
        of task: Task<T, Never>,
        within seconds: TimeInterval
    ) async -> T? {
        let gate = OneShotGate<T?>()
        let waiter = Task.detached(priority: .userInitiated) { gate.resume(with: await task.value) }
        let timer = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            gate.resume(with: nil)
        }
        defer {
            waiter.cancel()
            timer.cancel()
        }
        return await gate.value()
    }
}

enum CleanupInferenceError: Error {
    /// The model did not answer within the cleanup deadline.
    case deadlineExceeded
    /// A generation from an earlier deadline has not finished yet.
    case modelBusy
}

/// A continuation only the first caller can resume. Guards the continuation
/// with a lock the way `FileDownloader` does, since the two racers land on
/// different threads.
final class OneShotGate<T: Sendable>: @unchecked Sendable {
    // A three-state machine rather than a value plus a flag: `T` is itself an
    // Optional here, so "settled with nil" and "not settled yet" have to stay
    // distinguishable or the deadline case never resumes its waiter.
    private enum State {
        case waiting
        case suspended(CheckedContinuation<T, Never>)
        case settled(T)
    }

    private let lock = NSLock()
    private var state = State.waiting

    func value() async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            lock.lock()
            switch state {
            case .settled(let value):
                lock.unlock()
                continuation.resume(returning: value)
            case .waiting:
                state = .suspended(continuation)
                lock.unlock()
            case .suspended:
                lock.unlock()
                preconditionFailure("OneShotGate awaited more than once")
            }
        }
    }

    func resume(with value: T) {
        lock.lock()
        switch state {
        case .settled:
            lock.unlock()
        case .waiting:
            state = .settled(value)
            lock.unlock()
        case .suspended(let continuation):
            state = .settled(value)
            lock.unlock()
            continuation.resume(returning: value)
        }
    }
}

/// Lets `Task.detached` carry a non-Sendable `LLM` across isolation.
private final class LLMBox: @unchecked Sendable {
    let llm: LLM?
    init(_ llm: LLM?) {
        self.llm = llm
    }
}
