// SpokenLanguageIdentifier.swift
// VocaMac
//
// Picks which of the user's languages a recording is in, for models that
// must be told their language before decoding (Canary, Cohere Transcribe).
// Without it they decode everything as the language they were loaded with,
// English by default. Uses Whisper Tiny's language detection when that
// model is on this Mac, and only ever chooses among the languages the user
// listed in Settings › Language.

import Foundation
import WhisperKit

/// Chooses the language of a recording among a few candidates.
protocol SpokenLanguageIdentifying: AnyObject, Sendable {
    /// Get ready in the background, so the first dictation doesn't wait.
    func prepare()
    /// The language of `audio` among `candidates`, or nil when it can't
    /// tell yet (model not on this Mac, still loading, or failed).
    func identify(_ audio: [Float], among candidates: [String]) async -> String?
    /// Free the model.
    func unload()
}

enum LanguageIdentification {
    /// Audio given to language ID: the first seconds are enough, and a
    /// shorter clip keeps the pass short.
    static let maxSeconds: Double = 10

    /// Recordings shorter than this are left alone: a word or two says too
    /// little about the language, and a wrong guess garbles the whole thing.
    static let minSeconds: Double = 1.0

    /// The user's languages the model can decode, when there is a choice to
    /// make (at least two). Nil when there is nothing to choose.
    static func candidates(spoken: [String], supported: Set<String>) -> [String]? {
        var seen = Set<String>()
        let usable = spoken.map { $0.lowercased() }.filter { supported.contains($0) && seen.insert($0).inserted }
        return usable.count >= 2 ? usable : nil
    }

    /// The most likely of `candidates` by Whisper's language scores (log
    /// probabilities or probabilities; only their order matters). Nil when
    /// none of them was scored.
    static func choose(scores: [String: Float], among candidates: [String]) -> String? {
        candidates
            .compactMap { code in scores[code].map { (code, $0) } }
            .filter { !$1.isNaN }
            .max { $0.1 < $1.1 }?
            .0
    }

    /// The start of `audio` used for language ID, or nil when it is too short.
    static func clip(_ audio: [Float], sampleRate: Double = 16_000) -> [Float]? {
        guard Double(audio.count) / sampleRate >= minSeconds else { return nil }
        return Array(audio.prefix(Int(maxSeconds * sampleRate)))
    }
}

/// Language ID with a separate Whisper Tiny, loaded from the copy VocaMac
/// installs (it ships in the app). Never downloads anything.
///
/// Unchecked: `kit`, `loadTask` and `generation` are only touched under `lock`.
final class WhisperLanguageIdentifier: SpokenLanguageIdentifying, @unchecked Sendable {
    private let lock = NSLock()
    private var kit: WhisperKit?
    private var loadTask: Task<Void, Never>?
    /// Bumped by every `prepare()` that starts a load and by `unload()`. A
    /// load publishes its model only while its generation is current, so an
    /// `unload()` during the load is never undone when the load finishes.
    private var generation = 0
    private let modelFolder: @Sendable () -> URL?

    init(modelFolder: @escaping @Sendable () -> URL? = { ModelManager().modelFolder(for: .tiny) }) {
        self.modelFolder = modelFolder
    }

    func prepare() {
        lock.withLock {
            guard kit == nil, loadTask == nil else { return }
            generation += 1
            let loadGeneration = generation
            loadTask = Task.detached(priority: .utility) { [self] in
                let loaded = await Self.load(folder: modelFolder())
                lock.withLock {
                    guard generation == loadGeneration else { return }
                    kit = loaded
                    loadTask = nil
                }
            }
        }
    }

    func identify(_ audio: [Float], among candidates: [String]) async -> String? {
        guard let clip = LanguageIdentification.clip(audio) else { return nil }
        guard let kit = lock.withLock({ kit }) else {
            // Not ready: start loading for next time rather than make this
            // dictation wait for a model load.
            prepare()
            return nil
        }
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let detected = try await kit.detectLangauge(audioArray: clip)
            let chosen = LanguageIdentification.choose(scores: detected.langProbs, among: candidates)
            VocaLogger.info(
                .sherpaService,
                "Language ID chose \(chosen ?? "nothing") among \(candidates.joined(separator: ", ")) in "
                    + String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start) + "s"
            )
            return chosen
        } catch {
            VocaLogger.debug(.sherpaService, "Language ID failed: \(error.localizedDescription)")
            return nil
        }
    }

    func unload() {
        lock.withLock {
            generation += 1
            loadTask?.cancel()
            loadTask = nil
            kit = nil
        }
    }

    private static func load(folder: URL?) async -> WhisperKit? {
        guard let folder else {
            VocaLogger.debug(.sherpaService, "Language ID unavailable: Whisper Tiny isn't installed")
            return nil
        }
        do {
            let config = WhisperKitConfig(modelFolder: folder.path, verbose: false, prewarm: false, load: true, download: false)
            return try await WhisperKit(config)
        } catch {
            VocaLogger.warning(.sherpaService, "Language ID model failed to load: \(error.localizedDescription)")
            return nil
        }
    }
}
