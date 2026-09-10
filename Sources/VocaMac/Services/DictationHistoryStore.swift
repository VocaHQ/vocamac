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

    /// Serializes audio file writes, reads, and deletions, so a retry's read
    /// always sees the finished WAV file. The index and journal are written
    /// synchronously on the main actor.
    private let ioQueue = DispatchQueue(label: "com.vocamac.history.io", qos: .utility)

    private static let sampleRate = 16_000

    /// Size of a 16-bit mono WAV file with a 44-byte header.
    static func wavByteCount(sampleCount: Int) -> Int64 {
        Int64(44 + sampleCount * 2)
    }

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

    /// Record a dictation before it is transcribed. Returns once its audio
    /// is on disk, so a crash or failure during transcription can't lose it,
    /// with the id to finish it with.
    ///
    /// The entry is journaled, naming its WAV file, *before* the file is
    /// written. So every recording on disk belongs to an entry the journal
    /// knows about, and a file nothing refers to can only be left over from
    /// a deletion — launch removes it and never brings deleted audio back. If
    /// VocaMac dies before the write finishes, or the write fails, the entry
    /// ends up without audio instead of pointing at a file that isn't there.
    @discardableResult
    func begin(
        audio: [Float]?,
        target: RunningAppSnapshot?,
        modelID: String,
        language: String?,
        audioSeconds: Double,
        now: Date = Date()
    ) async -> UUID {
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
        let id = entry.id
        let pendingAudio: (samples: [Float], folder: URL, name: String)?
        if let audio, !audio.isEmpty, let folder = audioDirectory {
            let name = "\(id.uuidString).wav"
            entry.audioFileName = name
            entry.audioBytes = Self.wavByteCount(sampleCount: audio.count)
            pendingAudio = (audio, folder, name)
        } else {
            pendingAudio = nil
        }
        entries.insert(entry, at: 0)
        appendToJournal(JournalRecord(upsert: entry))

        if let pendingAudio {
            let fileURL = pendingAudio.folder.appendingPathComponent(pendingAudio.name)
            let saved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                ioQueue.async {
                    do {
                        try FileManager.default.createDirectory(at: pendingAudio.folder, withIntermediateDirectories: true)
                        try FailedAudioDump.wavData(from: pendingAudio.samples, sampleRate: Self.sampleRate)
                            .write(to: fileURL, options: .atomic)
                        continuation.resume(returning: true)
                    } catch {
                        VocaLogger.error(.history, "Could not save dictation audio: \(error.localizedDescription)")
                        continuation.resume(returning: false)
                    }
                }
            }
            if !saved {
                update(id) { entry in
                    entry.audioFileName = nil
                    entry.audioBytes = nil
                }
            }
        }
        enforceCaps()
        return id
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
        // Saves the deletion, then deletes the recording.
        appendToJournal(JournalRecord(delete: id))
    }

    func deleteAll() {
        entries = []
        pendingAudioRemovals = []
        // Only wipe the recordings once the empty history is saved.
        guard compact(), let folder = audioDirectory else { return }
        ioQueue.async {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Drop the audio of every entry but keep the text.
    func deleteAllAudio() {
        for index in entries.indices {
            removeAudio(of: &entries[index])
        }
        compact()
    }

    /// Delete entries older than the retention window.
    func applyRetention(_ retention: HistoryRetention, now: Date = Date()) {
        guard let maximumAge = retention.maximumAge else { return }
        let cutoff = now.addingTimeInterval(-maximumAge)
        let expired = entries.filter { $0.createdAt < cutoff }
        guard !expired.isEmpty else { return }
        for var entry in expired {
            removeAudio(of: &entry)
            appendToJournal(JournalRecord(delete: entry.id))
        }
        entries.removeAll { $0.createdAt < cutoff }
        VocaLogger.info(.history, "Removed \(expired.count) history entr\(expired.count == 1 ? "y" : "ies") past \(retention.displayName)")
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

    /// Resolves once every audio file operation queued so far has finished.
    /// Tests use it to read the files back; the app never needs to wait.
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
        appendToJournal(JournalRecord(upsert: entries[index]))
    }

    /// Recordings to delete once the change that drops them is on disk.
    private var pendingAudioRemovals: [URL] = []

    /// Drop an entry's audio. The file itself is only deleted after the
    /// journal or index write that records this change has succeeded (see
    /// `flushAudioRemovals`), so an exit in between can never leave an entry
    /// on disk whose audio is already gone.
    private func removeAudio(of entry: inout DictationHistoryEntry) {
        guard let url = audioURL(for: entry) else { return }
        entry.audioFileName = nil
        entry.audioBytes = nil
        pendingAudioRemovals.append(url)
    }

    /// Delete recordings whose removal is now saved.
    private func flushAudioRemovals() {
        guard !pendingAudioRemovals.isEmpty else { return }
        let urls = pendingAudioRemovals
        pendingAudioRemovals = []
        ioQueue.async {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func enforceCaps() {
        if entries.count > Self.maximumEntries {
            let overflow = entries[Self.maximumEntries...]
            for var entry in overflow {
                removeAudio(of: &entry)
                appendToJournal(JournalRecord(delete: entry.id))
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
                appendToJournal(JournalRecord(upsert: entries[index]))
                audioBytes -= bytes
            }
            index -= 1
        }
    }

    // MARK: - Index and Journal
    //
    // Every change is appended to `journal.jsonl` synchronously as one small
    // line, so it is on disk before VocaMac moves on and survives a crash or
    // force quit. The full `index.json` is rewritten only now and then — at
    // launch, after bulk changes, and once the journal grows — and the
    // journal is replayed over it on the next launch.

    /// One journal line: an entry's latest state, or its deletion.
    private struct JournalRecord: Codable {
        var upsert: DictationHistoryEntry?
        var delete: UUID?
    }

    /// Journal lines before the index is rewritten and the journal cleared.
    static let compactionThreshold = 500

    private var journalURL: URL? {
        directory?.appendingPathComponent("journal.jsonl")
    }

    private var journalLineCount = 0

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func appendToJournal(_ record: JournalRecord) {
        guard let directory, let journalURL else { return }
        do {
            var line = try Self.encoder.encode(record)
            line.append(0x0A)
            if !FileManager.default.fileExists(atPath: journalURL.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: journalURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: journalURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            journalLineCount += 1
            flushAudioRemovals()
            if journalLineCount >= Self.compactionThreshold {
                compact()
            }
        } catch {
            VocaLogger.error(.history, "Could not append to the history journal: \(error.localizedDescription)")
            compact()
        }
    }

    /// Write the whole history to `index.json`, then clear the journal. The
    /// journal is only removed after the index is safely replaced, so a
    /// failure here loses nothing.
    @discardableResult
    private func compact() -> Bool {
        guard let directory, let indexURL else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encoder.encode(entries).write(to: indexURL, options: .atomic)
            if let journalURL {
                try? FileManager.default.removeItem(at: journalURL)
            }
            journalLineCount = 0
            flushAudioRemovals()
            return true
        } catch {
            VocaLogger.error(.history, "Could not save dictation history: \(error.localizedDescription)")
            return false
        }
    }

    /// Apply journal lines over the loaded index. A torn last line (VocaMac
    /// died mid-write) is skipped.
    private func replayJournal(onto entries: inout [DictationHistoryEntry]) -> Bool {
        guard let journalURL, let data = try? Data(contentsOf: journalURL), !data.isEmpty else { return false }
        var byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let record = try? Self.decoder.decode(JournalRecord.self, from: Data(line)) else {
                VocaLogger.warning(.history, "Skipped an unreadable history journal line")
                continue
            }
            if let entry = record.upsert {
                byID[entry.id] = entry
            } else if let id = record.delete {
                byID[id] = nil
            }
        }
        entries = byID.values.sorted { $0.createdAt > $1.createdAt }
        return true
    }

    private func loadIndex() {
        var loaded: [DictationHistoryEntry] = []
        var indexWasUnreadable = false
        if let indexURL, FileManager.default.fileExists(atPath: indexURL.path) {
            do {
                loaded = try Self.decoder.decode([DictationHistoryEntry].self, from: Data(contentsOf: indexURL))
            } catch {
                // Keep the unreadable file aside rather than overwrite it on the
                // next save, and keep its recordings too.
                indexWasUnreadable = true
                let backup = indexURL.deletingPathExtension().appendingPathExtension("corrupt.json")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.moveItem(at: indexURL, to: backup)
                VocaLogger.error(.history, "Dictation history was unreadable and was set aside: \(error.localizedDescription)")
            }
        }

        var changed = replayJournal(onto: &loaded)
        for index in loaded.indices {
            if loaded[index].status == .pending {
                loaded[index].status = .interrupted
                changed = true
            }
            // Never advertise audio that isn't there.
            if let name = loaded[index].audioFileName, let folder = audioDirectory,
               !FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
                loaded[index].audioFileName = nil
                loaded[index].audioBytes = nil
                changed = true
            }
        }

        // With the index unreadable, "unreferenced" would mean every
        // recording it listed; leave them for the set-aside file.
        if !indexWasUnreadable {
            removeUnreferencedAudio(referenced: Set(loaded.compactMap(\.audioFileName)))
        }

        entries = loaded
        let interrupted = loaded.filter { $0.status == .interrupted }.count
        if interrupted > 0 {
            VocaLogger.warning(.history, "\(interrupted) dictation(s) didn't finish; their audio is kept for retry")
        }
        if changed {
            compact()
        }
    }

    /// Delete files in the audio folder no entry refers to. Because an entry
    /// is journaled before its audio is written, these can only be recordings
    /// whose deletion was saved but whose file removal hadn't run yet (or a
    /// temporary file from a write that never finished). Deleted audio stays
    /// deleted.
    private func removeUnreferencedAudio(referenced: Set<String>) {
        guard let folder = audioDirectory,
              let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for file in files where !referenced.contains(file) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
    }
}
