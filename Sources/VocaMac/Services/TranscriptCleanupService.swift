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

    private let modelsDirectory: URL
    private var activeLLM: LLM?
    private var activeKind: CleanupModelKind?

    /// The load in flight, so overlapping `load` calls join it instead of
    /// racing two llama.cpp contexts into memory at once.
    private var loadInFlight: (kind: CleanupModelKind, task: Task<Bool, Never>)?

    /// The download in flight, so the user can call it off.
    private var downloadTask: Task<Void, Never>?

    /// A generation left running past its deadline. It still owns the model,
    /// so it has to finish before another one may start.
    private var pendingGeneration: Task<String, Never>?

    /// Seam for tests; production checks reclaimable RAM against the catalog
    /// estimate, the same gate the speech models use (vocamac#251).
    var modelFitsInMemory: (CleanupModelDescriptor) -> Bool = {
        SystemInfo.canFitInMemory(requiredGB: $0.ramRequiredGB)
    }

    /// Hard ceiling on one cleanup pass. The transcript is waiting to be
    /// pasted, so the deadline hands back the raw text rather than waiting
    /// for llama.cpp to wind down.
    private static let timeoutSeconds: TimeInterval = 12

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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        guard let llm = activeLLM else {
            VocaLogger.info(.transcriptCleanup, "Cleanup skipped — model not ready")
            return text
        }

        let activePrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? TranscriptCleanup.defaultPrompt
            : prompt
        let formatted = TranscriptCleanup.formatInput(trimmed)

        do {
            let raw = try await runInference(llm: llm, prompt: activePrompt, input: formatted)
            if let accepted = TranscriptCleanup.acceptedOutput(raw, original: trimmed) {
                VocaLogger.info(.transcriptCleanup, "Cleanup produced \(accepted.count) characters")
                return accepted
            }
            VocaLogger.warning(.transcriptCleanup, "Discarded unusable cleanup output")
            return text
        } catch CleanupInferenceError.deadlineExceeded {
            VocaLogger.info(.transcriptCleanup, "Cleanup hit its deadline — using raw transcript")
            return text
        } catch CleanupInferenceError.modelBusy {
            VocaLogger.warning(.transcriptCleanup, "Previous cleanup still winding down — using raw transcript")
            return text
        } catch {
            VocaLogger.warning(.transcriptCleanup, "Cleanup failed: \(error.localizedDescription)")
            return text
        }
    }

    func isDownloaded(_ kind: CleanupModelKind) -> Bool {
        isPlausibleFile(modelPath(for: kind), descriptor: kind.descriptor)
    }

    func download(_ kind: CleanupModelKind) async {
        // Run the transfer in a retained task so `cancelDownload` can reach it;
        // FileDownloader turns the cancellation into a stopped URLSession task
        // rather than a transfer that keeps running in the background.
        downloadTask?.cancel()
        let task = Task<Void, Never> { [weak self] in await self?.performDownload(kind) }
        downloadTask = task
        await task.value
        if downloadTask == task {
            downloadTask = nil
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
    }

    private func performDownload(_ kind: CleanupModelKind) async {
        let descriptor = kind.descriptor
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let destination = modelPath(for: kind)
        if isPlausibleFile(destination, descriptor: descriptor) {
            return
        }
        try? FileManager.default.removeItem(at: destination)

        // A new attempt clears whatever error the last one left on screen.
        modelState = .downloading(kind: kind, progress: 0)
        do {
            try await FileDownloader.download(from: descriptor.url, to: destination) { [weak self] progress in
                Task { @MainActor in
                    self?.modelState = .downloading(kind: kind, progress: progress)
                }
            }
            let digest = try ModelManager.sha256Hex(ofFileAt: destination)
            let size = fileSize(at: destination)
            guard digest.caseInsensitiveCompare(descriptor.expectedSHA256) == .orderedSame,
                  size == descriptor.expectedByteCount else {
                try? FileManager.default.removeItem(at: destination)
                modelState = .error("The download for \(descriptor.displayName) did not match its expected contents.")
                VocaLogger.error(.transcriptCleanup, "Checksum mismatch for \(descriptor.displayName)")
                return
            }
            modelState = .idle
            VocaLogger.info(.transcriptCleanup, "Downloaded \(descriptor.displayName)")
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: destination)
            modelState = .idle
            VocaLogger.info(.transcriptCleanup, "Download cancelled: \(descriptor.displayName)")
        } catch {
            try? FileManager.default.removeItem(at: destination)
            let message = "Failed to download \(descriptor.displayName): \(error.localizedDescription)"
            modelState = .error(message)
            VocaLogger.error(.transcriptCleanup, message)
        }
    }

    func load(_ kind: CleanupModelKind) async {
        if activeKind == kind, activeLLM != nil {
            modelState = .ready
            return
        }

        // Join a load already running for this model rather than starting a
        // second llama.cpp context; a load for a *different* model has to
        // finish first so the two never hold memory at the same time.
        if let inFlight = loadInFlight {
            let joinedSameKind = inFlight.kind == kind
            _ = await inFlight.task.value
            if joinedSameKind {
                return
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
        activeLLM = nil
        activeKind = nil

        let maxTokens = descriptor.maxTokenCount
        let task = Task<Bool, Never> { [weak self] in
            let loading = Task.detached(priority: .userInitiated) {
                LLMBox(LLM(from: path, seed: 42, topP: 0.9, temp: 0.1, maxTokenCount: maxTokens))
            }
            let loaded = await loading.value.llm
            guard let self else { return false }
            return await self.finishLoad(loaded, kind: kind, descriptor: descriptor)
        }
        loadInFlight = (kind: kind, task: task)
        _ = await task.value
        if loadInFlight?.kind == kind {
            loadInFlight = nil
        }
    }

    func unload() {
        // A generation abandoned at a deadline keeps the model alive through
        // its own reference; ask it to stop so the weights are actually freed.
        activeLLM?.stop()
        activeLLM = nil
        activeKind = nil
        modelState = .idle
        VocaLogger.info(.transcriptCleanup, "Unloaded cleanup model")
    }

    func delete(_ kind: CleanupModelKind) {
        try? FileManager.default.removeItem(at: modelPath(for: kind))
        if activeKind == kind {
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
        descriptor: CleanupModelDescriptor
    ) -> Bool {
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

    private func runInference(llm: LLM, prompt: String, input: String) async throws -> String {
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

        guard let output = await Self.value(of: generation, within: Self.timeoutSeconds) else {
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
