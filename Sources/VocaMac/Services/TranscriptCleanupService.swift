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

    /// Seam for tests; production checks reclaimable RAM against the catalog
    /// estimate, the same gate the speech models use (vocamac#251).
    var modelFitsInMemory: (CleanupModelDescriptor) -> Bool = {
        SystemInfo.canFitInMemory(requiredGB: $0.ramRequiredGB)
    }

    private static let timeoutSeconds: TimeInterval = 12

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
        } catch is CancellationError {
            VocaLogger.info(.transcriptCleanup, "Cleanup timed out — using raw transcript")
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
        let box = LLMBox(llm)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let model = box.llm
                guard let model else { return "" }
                model.systemPrompt = prompt
                model.history = []
                await model.respond(to: input, thinking: .suppressed)
                return model.output
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(Self.timeoutSeconds * 1_000_000_000))
                throw CancellationError()
            }
            do {
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return result
            } catch {
                box.llm?.stop()
                group.cancelAll()
                throw error
            }
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
