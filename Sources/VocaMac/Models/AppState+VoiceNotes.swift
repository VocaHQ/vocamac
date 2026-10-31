// AppState+VoiceNotes.swift
// VocaMac
//
// Voice notes from start to finish: save the recording, transcribe it with
// the selected speech model, tell the speakers apart, write the transcript,
// copy it to the export folder, and summarize it with the Command Mode
// model. Each step after the transcript is optional and can fail without
// losing what came before.

import Foundation

extension AppState {

    // MARK: Settings

    static let notesIdentifySpeakersKey = "vocamac.notes.identifySpeakers"
    static let notesAutoSummarizeKey = "vocamac.notes.autoSummarize"

    /// Tell speakers apart in notes. On by default.
    var notesIdentifySpeakers: Bool {
        get { UserDefaults.standard.object(forKey: Self.notesIdentifySpeakersKey) as? Bool ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.notesIdentifySpeakersKey)
        }
    }

    /// Summarize a note as soon as it is transcribed. On by default.
    var notesAutoSummarize: Bool {
        get { UserDefaults.standard.object(forKey: Self.notesAutoSummarizeKey) as? Bool ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.notesAutoSummarizeKey)
        }
    }

    var noteExportFolder: URL? { NoteExportFolder().url }

    func setNoteExportFolder(_ folder: URL?) {
        objectWillChange.send()
        guard let folder else {
            NoteExportFolder().forget()
            return
        }
        do {
            try NoteExportFolder().remember(folder)
            // Everything already finished goes there too.
            for note in voiceNoteStore.notes where note.status == .completed {
                exportToFolder(note.id)
            }
        } catch {
            showTemporaryError("Could not use that folder: \(error.localizedDescription)")
        }
    }

    // MARK: Recording a note

    /// Save `samples` as a note and process it. Returns the note's id once
    /// the audio is on disk; transcription and the rest carry on after.
    /// Throws when the note couldn't be saved, so the recording isn't lost.
    @discardableResult
    func saveNote(samples: [Float], source: VoiceNoteSource) async throws -> UUID {
        voiceNoteStore.retention = historyRetention
        let id = try await voiceNoteStore.begin(audio: samples, source: source)
        Task { @MainActor [weak self] in await self?.processNote(id, samples: samples) }
        return id
    }

    /// Save the Scratchpad's text as a note.
    @discardableResult
    func saveScratchpadAsNote() -> UUID? {
        let text = scratchpadText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        voiceNoteStore.retention = historyRetention
        let id = voiceNoteStore.addText(text, source: .scratchpad)
        exportToFolder(id)
        return id
    }

    /// Dictations at least this long can be kept as a note.
    static let noteWorthyDictationSeconds = 120.0

    /// Keep a long dictation from History as a note, with its audio.
    @discardableResult
    func saveHistoryEntryAsNote(_ entryID: UUID) async -> UUID? {
        guard let entry = historyStore.entry(id: entryID), let audio = historyStore.audioURL(for: entry) else { return nil }
        let segments = SpeakerAssignment.assign(segments: entry.segments ?? [], turns: [])
        voiceNoteStore.retention = historyRetention
        guard let id = await voiceNoteStore.importRecording(
            from: audio, text: entry.displayText, segments: segments, durationSeconds: entry.audioSeconds,
            modelID: entry.modelID, language: entry.language, createdAt: entry.createdAt
        ) else { return nil }
        exportToFolder(id)
        if notesAutoSummarize { await summarizeNote(id) }
        return id
    }

    /// Transcribe a note again from its saved audio, with the current model.
    func retryNote(_ id: UUID) async {
        guard let note = voiceNoteStore.note(id: id), let url = voiceNoteStore.audioURL(for: note) else { return }
        do {
            let samples = try AudioFileLoader().loadAudio(at: url).samples
            await processNote(id, samples: samples)
        } catch {
            voiceNoteStore.fail(id, message: "The saved audio could not be read: \(error.localizedDescription)")
        }
    }

    // MARK: Processing

    /// Transcribe, tell speakers apart, export, summarize.
    func processNote(_ id: UUID, samples: [Float]) async {
        voiceNoteStore.markPending(id)
        let transcription: VocaTranscription
        do {
            transcription = try await transcribeCapturedAudio(samples)
        } catch {
            guard !Task.isCancelled else { return }
            voiceNoteStore.fail(id, message: error.localizedDescription)
            VocaLogger.warning(.appState, "A note could not be transcribed: \(error.localizedDescription)")
            return
        }

        let turns = await speakerTurns(in: samples)
        var timed = transcription.segments
        var text = transcription.text
        // Without timings from the engine (the ONNX models), transcribe each
        // speaker's turn on its own instead.
        if timed.isEmpty, !turns.isEmpty, let perTurn = await transcribeTurns(turns, in: samples) {
            timed = perTurn
            text = perTurn.map(\.text).joined(separator: " ")
        }
        if timed.isEmpty, !text.isEmpty {
            timed = [TimedSegment(start: 0, end: Double(samples.count) / 16_000, text: text)]
        }
        voiceNoteStore.complete(
            id, text: text, segments: SpeakerAssignment.assign(segments: timed, turns: turns),
            modelID: transcription.modelUsed.rawValue, language: transcription.detectedLanguage
        )
        exportToFolder(id)
        if notesAutoSummarize { await summarizeNote(id) }
    }

    /// Who spoke when, or no turns when speakers aren't wanted, can't be
    /// told apart here, or there is only one.
    private func speakerTurns(in samples: [Float]) async -> [SpeakerTurn] {
        guard notesIdentifySpeakers, speakerDiarizer.unavailableReason == nil else { return [] }
        do {
            let turns = try await speakerDiarizer.turns(in: samples)
            // One voice needs no labels.
            return Set(turns.map(\.speaker)).count > 1 ? turns : []
        } catch {
            VocaLogger.warning(.appState, "Speakers could not be told apart: \(error.localizedDescription)")
            return []
        }
    }

    /// Transcribe each run of one speaker separately. Nil when any part fails.
    private func transcribeTurns(_ turns: [SpeakerTurn], in samples: [Float]) async -> [TimedSegment]? {
        var segments: [TimedSegment] = []
        for run in Self.speakerRuns(turns) {
            let lower = max(0, Int(run.start * 16_000)), upper = min(samples.count, Int(run.end * 16_000))
            guard upper - lower >= 8_000 else { continue }
            guard let result = try? await transcribeCapturedAudio(Array(samples[lower..<upper])) else { return nil }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { segments.append(TimedSegment(start: run.start, end: run.end, text: text)) }
        }
        return segments
    }

    /// Consecutive turns of one speaker joined, so each decode gets whole
    /// sentences rather than fragments.
    nonisolated static func speakerRuns(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
        var runs: [SpeakerTurn] = []
        for turn in turns.sorted(by: { $0.start < $1.start }) {
            if let last = runs.last, last.speaker == turn.speaker, turn.start - last.end < 2 {
                runs[runs.count - 1].end = max(last.end, turn.end)
            } else {
                runs.append(turn)
            }
        }
        return runs
    }

    // MARK: Summary

    /// Summarize a note with the Command Mode model, and keep the result.
    /// Returns why not, or nil when it worked.
    @discardableResult
    func summarizeNote(_ id: UUID) async -> String? {
        guard let note = voiceNoteStore.note(id: id) else { return nil }
        let transcript = NoteSummarizer.transcriptText(for: note)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "There is nothing to summarize." }
        let engine = commandModeEngine
        let modelName = engine.displayName
        let run = await runOnCommandEngine(prompt: NoteSummarizer.partPrompt) { transformer, budget in
            await NoteSummarizer.summarize(transcript, budget: budget, model: modelName) { text, prompt in
                let attempt = await transformer.summarize(text, prompt: prompt)
                switch attempt.outcome {
                case .cleaned: return .success(attempt.output)
                // The transcript back unchanged is not a summary.
                case .unchanged: return .failure(.model("it repeated the transcript"))
                case .rejected(let why), .skipped(let why): return .failure(.model(why))
                }
            }
        }
        if let problem = run.problem {
            VocaLogger.info(.appState, "Note not summarized: \(problem)")
            return problem
        }
        switch run.value {
        case .success(var summary)?:
            summary.place = VoiceNoteSummaryPlace(engine: engine)
            voiceNoteStore.setSummary(id, summary)
            exportToFolder(id)
            return nil
        case .failure(let failure)?:
            let why: String
            switch failure {
            case .empty: why = "There is nothing to summarize."
            case .model(let reason): why = "The model could not summarize it: \(reason)"
            case .unreadable: why = "The model's answer was not a summary."
            }
            VocaLogger.warning(.appState, "Note summary failed: \(why)")
            return why
        case nil:
            return nil
        }
    }

    // MARK: Export

    /// Copy a finished note into the export folder, if one is set.
    func exportToFolder(_ id: UUID) {
        guard let note = voiceNoteStore.note(id: id), note.status == .completed else { return }
        do {
            try NoteExportFolder().write(note)
        } catch {
            VocaLogger.warning(.appState, "Could not write a note to the export folder: \(error.localizedDescription)")
        }
    }

    // MARK: - Privacy

    /// Where a note's recording and text go, for the Notes page. Notes use
    /// the dictation model and the Command Mode engine, and either can be a
    /// server the user set up.
    var notesPrivacyNote: String {
        let speechIsRemote = ModelSize(rawValue: selectedModelSize)?.engine == .customEndpoint
        let summaryIsRemote: Bool = {
            if case .endpoint = commandModeEngine { return true }
            return false
        }()
        switch (speechIsRemote, summaryIsRemote) {
        case (false, false):
            return "Nothing leaves this Mac."
        case (true, false):
            return "Recordings go to your Custom Endpoint to be transcribed. Summaries are written on this Mac."
        case (false, true):
            return "Transcripts are written on this Mac. Summaries are written by the server Command Mode uses."
        case (true, true):
            return "Recordings go to your Custom Endpoint, and summaries are written by the server Command Mode uses."
        }
    }
}
