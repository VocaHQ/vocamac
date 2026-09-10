// DictationHistoryStore.swift
// VocaMac
//
// Persists dictation history under Application Support. The audio for a
// dictation is written before it is transcribed, so a crash, a failed decode,
// or an accidental cancel never loses what the user said.

import Foundation
import Combine

@MainActor
final class DictationHistoryStore: ObservableObject {

    /// Oldest entries beyond this count are deleted, audio and all.
    static let maximumEntries = 2_000

    /// Total audio kept on disk. Beyond this the oldest recordings lose their
    /// audio first; their text stays.
    static let maximumAudioBytes: Int64 = 1 << 30

    /// Newest first.
    @Published private(set) var entries: [DictationHistoryEntry] = []

    /// `nil` keeps history in memory only (tests, and runs that must not
    /// touch the user's Application Support folder).
    let directory: URL?

    /// Serializes every file write, so an index write can never race another
    /// and a retry's audio read always sees the finished WAV file.
    private let ioQueue = DispatchQueue(label: "com.vocamac.history.io", qos: .utility)

    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("VocaMac", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
    }

    init(directory: URL?) {
        self.directory = directory
        loadIndex()
    }

    // MARK: - Paths

    private var indexURL: URL? {
        directory?.appendingPathComponent("index.json")
    }

    var audioDirectory: URL? {
        directory?.appendingPathComponent("audio", isDirectory: true)
    }

    func audioURL(for entry: DictationHistoryEntry) -> URL? {
        guard let name = entry.audioFileName, let folder = audioDirectory else { return nil }
        return folder.appendingPathComponent(name)
    }

    // MARK: - Queries

    func entry(id: UUID) -> DictationHistoryEntry? {
        entries.first { $0.id == id }
    }

    /// Text of the most recent dictation that produced something, exactly as
    /// it was typed (trailing space included), for "paste last dictation".
    var latestDeliveredText: String? {
        guard let entry = entries.first(where: { $0.status == .completed && !$0.displayText.isEmpty }) else {
            return nil
        }
        return entry.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? entry.rawText : entry.finalText
    }

    /// The newest dictation when it failed, was interrupted, or was
    /// cancelled mid-transcription and its audio can still be retried. A later
    /// successful dictation supersedes it, so an old failure doesn't nag.
    var latestRecoverableEntry: DictationHistoryEntry? {
        guard let newest = entries.first, newest.status.needsRecovery, newest.hasAudio else { return nil }
        return newest
    }

    /// Entries whose text or app name contains every word of `query`.
    func search(_ query: String) -> [DictationHistoryEntry] {
        let words = query.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            let haystack = [entry.rawText, entry.finalText, entry.appName ?? ""]
                .joined(separator: " ")
                .lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    // MARK: - Recording a Dictation

    /// Record a dictation before it is transcribed and write its audio.
    /// Returns the id to finish it with.
    @discardableResult
    func begin(
        audio: [Float]?,
        target: RunningAppSnapshot?,
        modelID: String,
        language: String?,
        audioSeconds: Double,
        now: Date = Date()
    ) -> UUID {
        var entry = DictationHistoryEntry(
            createdAt: now,
            status: .pending,
            appName: target?.displayName,
            bundleIdentifier: target?.bundleIdentifier,
            processName: target?.processName,
            modelID: modelID,
            language: language,
            audioSeconds: audioSeconds
        )
        if let audio, !audio.isEmpty, let folder = audioDirectory {
            let name = "\(entry.id.uuidString).wav"
            entry.audioFileName = name
            entry.audioBytes = Int64(44 + audio.count * 2)
            let fileURL = folder.appendingPathComponent(name)
            ioQueue.async {
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FailedAudioDump.wavData(from: audio, sampleRate: 16_000).write(to: fileURL, options: .atomic)
                } catch {
                    VocaLogger.error(.history, "Could not save dictation audio: \(error.localizedDescription)")
                }
            }
        }
        entries.insert(entry, at: 0)
        enforceCaps()
        persist()
        return entry.id
    }

    /// Finish a dictation that produced a result (possibly empty).
    func complete(
        _ id: UUID,
        rawText: String,
        finalText: String,
        summary: String?,
        language: String?,
        transcriptionSeconds: Double?,
        keepAudio: Bool
    ) {
        update(id) { entry in
            entry.rawText = rawText
            entry.finalText = finalText
            entry.summary = summary
            if let language { entry.language = language }
            entry.transcriptionSeconds = transcriptionSeconds
            entry.errorMessage = nil
            let hasText = !entry.displayText.isEmpty
            entry.status = hasText ? .completed : .empty
            if hasText && !keepAudio {
                removeAudio(of: &entry)
            }
        }
    }

    func markFailed(_ id: UUID, message: String) {
        update(id) { entry in
            entry.status = .failed
            entry.errorMessage = message
        }
    }

    func markCancelled(_ id: UUID) {
        update(id) { entry in
            guard entry.status == .pending else { return }
            entry.status = .cancelled
        }
    }

    /// Store the result of retrying an entry's audio.
    func recordRetry(
        _ id: UUID,
        rawText: String,
        finalText: String,
        summary: String?,
        language: String?,
        modelID: String,
        transcriptionSeconds: Double?
    ) {
        update(id) { entry in
            entry.rawText = rawText
            entry.finalText = finalText
            entry.summary = summary
            if let language { entry.language = language }
            entry.modelID = modelID
            entry.transcriptionSeconds = transcriptionSeconds
            entry.errorMessage = nil
            entry.retryCount += 1
            entry.status = entry.displayText.isEmpty ? .empty : .completed
        }
    }

    // MARK: - Deleting

    func delete(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries.remove(at: index)
        removeAudio(of: &entry)
        persist()
    }

    func deleteAll() {
        entries = []
        if let folder = audioDirectory {
            ioQueue.async {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        persist()
    }

    /// Drop the audio of every entry but keep the text.
    func deleteAllAudio() {
        for index in entries.indices {
            removeAudio(of: &entries[index])
        }
        persist()
    }

    /// Delete entries older than the retention window.
    func applyRetention(_ retention: HistoryRetention, now: Date = Date()) {
        guard let maximumAge = retention.maximumAge else { return }
        let cutoff = now.addingTimeInterval(-maximumAge)
        let expired = entries.filter { $0.createdAt < cutoff }
        guard !expired.isEmpty else { return }
        for var entry in expired {
            removeAudio(of: &entry)
        }
        entries.removeAll { $0.createdAt < cutoff }
        VocaLogger.info(.history, "Removed \(expired.count) history entr\(expired.count == 1 ? "y" : "ies") past \(retention.displayName)")
        persist()
    }

    // MARK: - Audio

    /// Load an entry's audio as 16 kHz mono samples.
    func loadAudio(for entry: DictationHistoryEntry) async throws -> [Float] {
        guard let url = audioURL(for: entry) else {
            throw HistoryError.audioUnavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            // Queued behind any write still in flight for this entry.
            ioQueue.async {
                do {
                    let loaded = try AudioFileLoader().loadAudio(at: url)
                    continuation.resume(returning: loaded.samples)
                } catch {
                    continuation.resume(throwing: HistoryError.audioUnreadable)
                }
            }
        }
    }

    /// Resolves once every write queued so far has finished. Tests use it to
    /// read the files back; the app never needs to wait.
    func waitForPendingWrites() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ioQueue.async { continuation.resume() }
        }
    }

    enum HistoryError: LocalizedError {
        case audioUnavailable
        case audioUnreadable

        var errorDescription: String? {
            switch self {
            case .audioUnavailable: return "This dictation has no saved audio."
            case .audioUnreadable: return "The saved audio for this dictation could not be read."
            }
        }
    }

    // MARK: - Private

    private func update(_ id: UUID, _ change: (inout DictationHistoryEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
        persist()
    }

    private func removeAudio(of entry: inout DictationHistoryEntry) {
        guard let url = audioURL(for: entry) else { return }
        entry.audioFileName = nil
        entry.audioBytes = nil
        ioQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func enforceCaps() {
        if entries.count > Self.maximumEntries {
            let overflow = entries[Self.maximumEntries...]
            for var entry in overflow {
                removeAudio(of: &entry)
            }
            entries.removeLast(entries.count - Self.maximumEntries)
        }

        var audioBytes = entries.reduce(Int64(0)) { $0 + ($1.audioBytes ?? 0) }
        var index = entries.count - 1
        // The newest entry is never stripped: it is the one most likely to
        // need a retry, and one recording alone cannot exceed the cap.
        while audioBytes > Self.maximumAudioBytes, index > 0 {
            if let bytes = entries[index].audioBytes {
                removeAudio(of: &entries[index])
                audioBytes -= bytes
            }
            index -= 1
        }
    }

    private func persist() {
        guard let indexURL, let directory else { return }
        // Entries are values, so the snapshot is encoded off the main thread.
        let snapshot = entries
        ioQueue.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(snapshot).write(to: indexURL, options: .atomic)
            } catch {
                VocaLogger.error(.history, "Could not save dictation history: \(error.localizedDescription)")
            }
        }
    }

    private func loadIndex() {
        guard let indexURL, FileManager.default.fileExists(atPath: indexURL.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var loaded = try decoder.decode([DictationHistoryEntry].self, from: Data(contentsOf: indexURL))
            var recovered = 0
            for index in loaded.indices where loaded[index].status == .pending {
                loaded[index].status = .interrupted
                recovered += 1
            }
            entries = loaded
            if recovered > 0 {
                VocaLogger.warning(.history, "\(recovered) dictation(s) were interrupted before they finished; their audio is kept for retry")
                persist()
            }
            removeOrphanedAudio()
        } catch {
            // Keep the unreadable file aside rather than overwrite it on the
            // next save, so nothing is lost to a decoding bug.
            let backup = indexURL.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: indexURL, to: backup)
            VocaLogger.error(.history, "Dictation history was unreadable and was set aside: \(error.localizedDescription)")
        }
    }

    /// Delete audio files no entry points at (a crash between writing the
    /// audio and writing the index).
    private func removeOrphanedAudio() {
        guard let folder = audioDirectory else { return }
        let referenced = Set(entries.compactMap(\.audioFileName))
        ioQueue.async {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
            for file in files where !referenced.contains(file) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
            }
        }
    }
}
