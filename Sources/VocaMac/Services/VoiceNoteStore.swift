// VoiceNoteStore.swift
// VocaMac
//
// Keeps voice notes under Application Support/VocaMac/Notes: `index.json`
// with every note's metadata, transcript and summary, and `<id>/audio.wav`.
// The note is saved as pending before its audio is written and long before
// it is transcribed, so quitting or crashing mid-way loses nothing: launch
// marks it interrupted and its audio can be transcribed again.

import Combine
import Foundation

/// Why a note could not be saved.
enum VoiceNoteStoreError: LocalizedError, Equatable {
    case audioNotSaved(String)
    case indexNotSaved(String)

    var errorDescription: String? {
        switch self {
        case .audioNotSaved(let reason): return "The audio could not be written (\(reason))."
        case .indexNotSaved(let reason): return "The notes list could not be written (\(reason))."
        }
    }
}

@MainActor
final class VoiceNoteStore: ObservableObject {
    /// Oldest notes beyond this count are deleted.
    static let maximumNotes = 1_000

    /// Total audio kept. Beyond it the oldest notes lose their audio first;
    /// their transcripts and summaries stay. A 20-minute meeting is about
    /// 38 MB at 16 kHz.
    static let maximumAudioBytes: Int64 = 2 << 30

    nonisolated static let audioFileName = "audio.wav"
    nonisolated private static let sampleRate = 16_000

    /// The audio cap in force; tests lower it.
    var audioByteLimit = VoiceNoteStore.maximumAudioBytes

    /// History's retention, applied after every note is added. Nil until
    /// the app sets it (tests that don't care).
    var retention: HistoryRetention?

    /// Newest first.
    @Published private(set) var notes: [VoiceNote] = []

    /// `nil` keeps notes in memory only (tests, and runs that must not touch
    /// the user's Application Support folder).
    let directory: URL?

    /// Serializes index and audio writes so they land in the order made.
    private let ioQueue = DispatchQueue(label: "com.vocamac.notes.io", qos: .userInitiated)

    nonisolated static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("VocaMac", isDirectory: true)
            .appendingPathComponent("Notes", isDirectory: true)
    }

    /// - Parameter loadInBackground: Read the saved notes off the main
    ///   thread. A note added before they arrive is kept: the two lists merge.
    init(directory: URL?, loadInBackground: Bool = false) {
        self.directory = directory
        guard let directory else { return }
        if loadInBackground {
            loadTask = Task { [weak self] in
                let result = await Task.detached(priority: .utility) { Self.read(directory: directory) }.value
                self?.finishLoading(result)
            }
        } else {
            finishLoading(Self.read(directory: directory))
        }
    }

    private var loadTask: Task<Void, Never>?

    /// Resolves once the saved notes are in `notes`.
    func waitUntilLoaded() async {
        await loadTask?.value
    }

    private func finishLoading(_ result: (notes: [VoiceNote], changed: Bool)) {
        let added = notes.filter { note in !result.notes.contains { $0.id == note.id } }
        notes = (added + result.notes).sorted { $0.createdAt > $1.createdAt }
        loadTask = nil
        if result.changed || !added.isEmpty { save() }
    }

    // MARK: - Paths

    func folder(for id: UUID) -> URL? {
        directory?.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func audioURL(for note: VoiceNote) -> URL? {
        guard let name = note.audioFileName else { return nil }
        return folder(for: note.id)?.appendingPathComponent(name)
    }

    // MARK: - Queries

    func note(id: UUID) -> VoiceNote? {
        notes.first { $0.id == id }
    }

    /// Notes whose title, transcript, summary or speaker names contain every
    /// word of `query`, newest first.
    func search(_ query: String) -> [VoiceNote] {
        Self.notes(notes, matching: query)
    }

    nonisolated static func notes(_ notes: [VoiceNote], matching query: String) -> [VoiceNote] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return notes }
        return notes.filter { note in
            var haystack = [note.title, note.text] + Array(note.speakerNames.values)
            if let summary = note.summary {
                haystack += [summary.overview] + summary.decisions + summary.actionItems
            }
            let text = haystack.joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    // MARK: - Recording

    /// Save a note before it is transcribed. Returns once the note and its
    /// audio are on disk (in memory without a directory). Throws, leaving no
    /// note behind, when either can't be written, so the caller keeps the
    /// samples and can try again.
    @discardableResult
    func begin(audio: [Float], source: VoiceNoteSource, title: String? = nil, now: Date = Date()) async throws -> UUID {
        // Loading removes folders the saved index doesn't know; let it finish
        // before this note's folder exists.
        await waitUntilLoaded()
        let note = VoiceNote(
            createdAt: now,
            title: title ?? VoiceNote.defaultTitle(source: source, date: now),
            source: source,
            status: .pending,
            durationSeconds: Double(audio.count) / Double(Self.sampleRate),
            audioFileName: audio.isEmpty ? nil : Self.audioFileName,
            audioBytes: audio.isEmpty ? nil : DictationHistoryStore.wavByteCount(sampleCount: audio.count)
        )
        insert(note, applyingRetention: false)
        do {
            if let folder = folder(for: note.id), !audio.isEmpty {
                try await writeAudio(audio, into: folder)
            }
            try await writeIndexNow()
        } catch {
            VocaLogger.error(.history, "Could not save a note: \(error.localizedDescription)")
            notes.removeAll { $0.id == note.id }
            save()
            removeFolder(of: note.id)
            throw error
        }
        applyRetentionIfSet()
        enforceAudioCap()
        return note.id
    }

    private func writeAudio(_ audio: [Float], into folder: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ioQueue.async {
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try WAVEncoder.pcm16Mono(from: audio, sampleRate: Self.sampleRate)
                        .write(to: folder.appendingPathComponent(Self.audioFileName), options: .atomic)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: VoiceNoteStoreError.audioNotSaved(error.localizedDescription))
                }
            }
        }
    }

    /// Write the index now and say whether it worked, unlike `save()`,
    /// which only logs: a new note isn't saved until the index names it.
    private func writeIndexNow() async throws {
        guard let directory else { return }
        let snapshot = notes
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ioQueue.async {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try Self.makeEncoder().encode(snapshot)
                        .write(to: directory.appendingPathComponent("index.json"), options: .atomic)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: VoiceNoteStoreError.indexNotSaved(error.localizedDescription))
                }
            }
        }
    }

    /// A note with words and no audio (the Scratchpad).
    @discardableResult
    func addText(_ text: String, source: VoiceNoteSource, title: String? = nil, now: Date = Date()) -> UUID {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = VoiceNote(
            createdAt: now,
            title: title ?? Self.title(fromText: trimmed) ?? VoiceNote.defaultTitle(source: source, date: now),
            source: source,
            status: .completed,
            text: trimmed
        )
        insert(note)
        return note.id
    }

    /// Copy an existing recording in as a note (a long dictation from History).
    @discardableResult
    func importRecording(
        from audioFile: URL, text: String, segments: [VoiceNoteSegment], durationSeconds: Double,
        modelID: String?, language: String?, createdAt: Date
    ) async -> UUID? {
        await waitUntilLoaded()
        var note = VoiceNote(
            createdAt: createdAt,
            title: Self.title(fromText: text) ?? VoiceNote.defaultTitle(source: .history, date: createdAt),
            source: .history, status: .completed, durationSeconds: durationSeconds,
            segments: segments, text: text, modelID: modelID, language: language
        )
        if let folder = folder(for: note.id) {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = folder.appendingPathComponent(Self.audioFileName)
                try FileManager.default.copyItem(at: audioFile, to: destination)
                note.audioFileName = Self.audioFileName
                note.audioBytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            } catch {
                VocaLogger.warning(.history, "Could not copy a dictation's audio into Notes: \(error.localizedDescription)")
            }
        }
        insert(note)
        enforceAudioCap()
        return note.id
    }

    func complete(
        _ id: UUID, text: String, segments: [VoiceNoteSegment], modelID: String?, language: String?
    ) {
        update(id) { note in
            note.status = .completed
            note.text = text
            note.segments = segments
            note.modelID = modelID
            note.language = language
            note.errorMessage = nil
            if note.title == VoiceNote.defaultTitle(source: note.source, date: note.createdAt),
               let better = Self.title(fromText: text) {
                note.title = better
            }
        }
    }

    func fail(_ id: UUID, message: String) {
        update(id) { $0.status = .failed; $0.errorMessage = message }
    }

    /// Back to pending, for a retry from the saved audio.
    func markPending(_ id: UUID) {
        update(id) { $0.status = .pending; $0.errorMessage = nil }
    }

    func setSummary(_ id: UUID, _ summary: VoiceNoteSummary?) {
        update(id) { $0.summary = summary }
    }

    func rename(_ id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.title = trimmed }
    }

    func renameSpeaker(_ id: UUID, speaker: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { $0.speakerNames[speaker] = trimmed.isEmpty ? nil : trimmed }
    }

    func delete(_ id: UUID) {
        guard notes.contains(where: { $0.id == id }) else { return }
        notes.removeAll { $0.id == id }
        save()
        removeFolder(of: id)
    }

    // MARK: - Limits

    /// Delete notes older than `retention` allows (History's setting), and
    /// the oldest beyond the count cap.
    func applyRetention(_ retention: HistoryRetention, now: Date = Date()) {
        var removed: [UUID] = []
        if let age = retention.maximumAge {
            let cutoff = now.addingTimeInterval(-age)
            removed += notes.filter { $0.createdAt < cutoff && $0.status != .pending }.map(\.id)
        }
        let kept = notes.filter { !removed.contains($0.id) }
        if kept.count > Self.maximumNotes {
            removed += kept.suffix(kept.count - Self.maximumNotes).map(\.id)
        }
        guard !removed.isEmpty else { return }
        notes.removeAll { removed.contains($0.id) }
        save()
        removed.forEach(removeFolder(of:))
    }

    /// Drop the oldest notes' audio until the total fits the cap.
    private func enforceAudioCap() {
        var total = notes.compactMap(\.audioBytes).reduce(0, +)
        guard total > audioByteLimit else { return }
        for note in notes.reversed() where total > audioByteLimit {
            guard let bytes = note.audioBytes, note.status != .pending else { continue }
            if let url = audioURL(for: note) {
                ioQueue.async { try? FileManager.default.removeItem(at: url) }
            }
            update(note.id) { $0.audioFileName = nil; $0.audioBytes = nil }
            total -= bytes
        }
    }

    // MARK: - Saving

    /// Waits for queued writes; tests read the files after it.
    func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ioQueue.async { continuation.resume() }
        }
    }

    /// Add `note`, then apply the retention setting, so every source (a
    /// recording, the Scratchpad, History) keeps to the same limits.
    private func insert(_ note: VoiceNote, applyingRetention: Bool = true) {
        notes.insert(note, at: 0)
        notes.sort { $0.createdAt > $1.createdAt }
        save()
        if applyingRetention { applyRetentionIfSet() }
    }

    private func applyRetentionIfSet() {
        if let retention { applyRetention(retention) }
    }

    private func update(_ id: UUID, _ change: (inout VoiceNote) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[index])
        save()
    }

    private func save() {
        guard let directory else { return }
        let snapshot = notes
        ioQueue.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Self.makeEncoder().encode(snapshot)
                    .write(to: directory.appendingPathComponent("index.json"), options: .atomic)
            } catch {
                VocaLogger.error(.history, "Could not save notes: \(error.localizedDescription)")
            }
        }
    }

    private func removeFolder(of id: UUID) {
        guard let folder = folder(for: id) else { return }
        ioQueue.async { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: - Loading

    /// The saved notes, with leftovers of a crash resolved: pending notes
    /// become interrupted, audio that isn't there is forgotten, and folders
    /// no note owns are removed. `changed` says whether to save it back.
    nonisolated static func read(directory: URL) -> (notes: [VoiceNote], changed: Bool) {
        let fileManager = FileManager.default
        let index = directory.appendingPathComponent("index.json")
        var notes: [VoiceNote] = []
        var changed = false
        if let data = try? Data(contentsOf: index) {
            do {
                notes = try makeDecoder().decode([VoiceNote].self, from: data)
            } catch {
                // Keep the unreadable file, and every folder, for recovery.
                let aside = directory.appendingPathComponent(corruptIndexName)
                try? fileManager.removeItem(at: aside)
                try? fileManager.moveItem(at: index, to: aside)
                VocaLogger.error(.history, "Notes were unreadable and were set aside: \(error.localizedDescription)")
                return ([], false)
            }
        }
        for position in notes.indices {
            if notes[position].status == .pending {
                notes[position].status = .interrupted
                changed = true
            }
            if let name = notes[position].audioFileName,
               !fileManager.fileExists(atPath: directory
                .appendingPathComponent(notes[position].id.uuidString)
                .appendingPathComponent(name).path) {
                notes[position].audioFileName = nil
                notes[position].audioBytes = nil
                changed = true
            }
        }
        // While an unreadable index is kept for recovery, the folders it
        // names look unowned; removing them would destroy what it points at.
        let hasSetAsideIndex = fileManager.fileExists(atPath: directory.appendingPathComponent(corruptIndexName).path)
        if !hasSetAsideIndex {
            let owned = Set(notes.map(\.id.uuidString))
            let folders = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            for folder in folders where UUID(uuidString: folder) != nil && !owned.contains(folder) {
                try? fileManager.removeItem(at: directory.appendingPathComponent(folder))
            }
        }
        return (notes.sorted { $0.createdAt > $1.createdAt }, changed)
    }

    /// Where an unreadable index is moved, for recovery by hand.
    nonisolated static let corruptIndexName = "index.corrupt.json"

    nonisolated private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    nonisolated private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The first few words of `text`, as a title.
    nonisolated static func title(fromText text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).prefix(8)
        guard !words.isEmpty else { return nil }
        var title = words.joined(separator: " ")
        while let last = title.last, ".,;:!?".contains(last) { title.removeLast() }
        return words.count == 8 ? title + "…" : title
    }
}
