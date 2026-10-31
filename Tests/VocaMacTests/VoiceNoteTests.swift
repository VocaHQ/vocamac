// VoiceNoteTests.swift
// VocaMacTests
//
// Voice notes: the store's files and crash recovery, speaker assignment,
// summary chunking and parsing, the Markdown export, mixing two inputs, and
// a note going through the app with fake engines.

import XCTest
@testable import VocaMac

// MARK: - Store

@MainActor
final class VoiceNoteStoreTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VocaMac-Notes-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testBeginWritesAudioAndAPendingNote() async throws {
        let directory = temporaryDirectory()
        let store = VoiceNoteStore(directory: directory)
        let id = try await store.begin(audio: [Float](repeating: 0.1, count: 32_000), source: .meeting)
        await store.flush()

        let note = try XCTUnwrap(store.note(id: id))
        XCTAssertEqual(note.status, .pending)
        XCTAssertEqual(note.durationSeconds, 2, accuracy: 0.001)
        let audio = try XCTUnwrap(store.audioURL(for: note))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(note.audioBytes, 44 + 32_000 * 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.json").path))
    }

    func testAPendingNoteFoundAtLaunchIsInterruptedAndKeepsItsAudio() async throws {
        let directory = temporaryDirectory()
        let store = VoiceNoteStore(directory: directory)
        let id = try await store.begin(audio: [0.2, 0.1, 0.3], source: .systemAudio)
        await store.flush()

        let reopened = VoiceNoteStore(directory: directory)
        let note = try XCTUnwrap(reopened.note(id: id))
        XCTAssertEqual(note.status, .interrupted)
        XCTAssertTrue(note.status.needsRetry)
        XCTAssertTrue(note.hasAudio)
    }

    func testMissingAudioIsForgottenAndStrayFoldersRemoved() async throws {
        let directory = temporaryDirectory()
        let store = VoiceNoteStore(directory: directory)
        let id = try await store.begin(audio: [0.2], source: .microphone)
        store.complete(id, text: "Hi", segments: [], modelID: "tiny", language: "en")
        await store.flush()
        let note = try XCTUnwrap(store.note(id: id))
        try FileManager.default.removeItem(at: try XCTUnwrap(store.audioURL(for: note)))
        let stray = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)

        let reopened = VoiceNoteStore(directory: directory)
        XCTAssertFalse(try XCTUnwrap(reopened.note(id: id)).hasAudio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertEqual(reopened.note(id: id)?.text, "Hi")
    }

    func testCompleteTitlesTheNoteFromItsWordsAndSearchFindsIt() async throws {
        let store = VoiceNoteStore(directory: nil)
        let id = try await store.begin(audio: [0.1], source: .meeting)
        store.complete(id, text: "Quarterly planning with the design team about the launch", segments: [], modelID: nil, language: nil)
        XCTAssertEqual(store.note(id: id)?.title, "Quarterly planning with the design team about the…")
        store.renameSpeaker(id, speaker: "1", to: "Priya")
        XCTAssertEqual(store.search("design priya").map(\.id), [id])
        XCTAssertTrue(store.search("budget").isEmpty)
        store.renameSpeaker(id, speaker: "1", to: "  ")
        XCTAssertNil(store.note(id: id)?.speakerNames["1"], "A blank name goes back to Speaker 1")
    }

    func testRetentionAndDeleteRemoveFolders() async throws {
        let directory = temporaryDirectory()
        let store = VoiceNoteStore(directory: directory)
        let old = try await store.begin(audio: [0.1], source: .meeting, now: Date(timeIntervalSinceNow: -10 * 86_400))
        store.complete(old, text: "old", segments: [], modelID: nil, language: nil)
        let recent = try await store.begin(audio: [0.1], source: .meeting)
        store.complete(recent, text: "new", segments: [], modelID: nil, language: nil)

        store.applyRetention(.week)
        await store.flush()
        XCTAssertEqual(store.notes.map(\.id), [recent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(old.uuidString).path))

        store.delete(recent)
        await store.flush()
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(recent.uuidString).path))
    }

    func testTheOldestNotesLoseTheirAudioFirstPastTheCap() async throws {
        let store = VoiceNoteStore(directory: temporaryDirectory())
        store.audioByteLimit = 100
        let first = try await store.begin(audio: [Float](repeating: 0.1, count: 20), source: .meeting, now: Date(timeIntervalSinceNow: -60))
        store.complete(first, text: "a", segments: [], modelID: nil, language: nil)
        let second = try await store.begin(audio: [Float](repeating: 0.1, count: 20), source: .meeting)
        XCTAssertFalse(try XCTUnwrap(store.note(id: first)).hasAudio)
        XCTAssertEqual(store.note(id: first)?.text, "a", "The words stay")
        XCTAssertTrue(try XCTUnwrap(store.note(id: second)).hasAudio)
    }

    func testTextNotesHaveNoAudio() {
        let store = VoiceNoteStore(directory: nil)
        let id = store.addText("  Buy milk. Call the plumber.  ", source: .scratchpad)
        let note = store.note(id: id)
        XCTAssertEqual(note?.text, "Buy milk. Call the plumber.")
        XCTAssertEqual(note?.status, .completed)
        XCTAssertFalse(note?.hasAudio ?? true)
        XCTAssertEqual(note?.title, "Buy milk. Call the plumber")
    }
}

// MARK: - Speakers

final class SpeakerAssignmentTests: XCTestCase {
    private func word(_ text: String, _ start: Double, _ end: Double) -> TimedWord {
        TimedWord(word: text, start: start, end: end)
    }

    func testWordsSplitAtTheSpeakerChange() {
        let segment = TimedSegment(start: 0, end: 4, text: "", words: [
            word(" Hello", 0, 0.5), word(" there.", 0.5, 1), word(" Hi,", 2, 2.4), word(" thanks.", 2.4, 3),
        ])
        let turns = [SpeakerTurn(start: 0, end: 1.2, speaker: "S7"), SpeakerTurn(start: 1.8, end: 3.2, speaker: "S2")]
        let result = SpeakerAssignment.assign(segments: [segment], turns: turns)
        XCTAssertEqual(result, [
            VoiceNoteSegment(start: 0, end: 1, text: "Hello there.", speaker: "1"),
            VoiceNoteSegment(start: 2, end: 3, text: "Hi, thanks.", speaker: "2"),
        ])
    }

    func testSpeakersAreNumberedByFirstAppearance() {
        let turns = SpeakerAssignment.renumber([
            SpeakerTurn(start: 5, end: 6, speaker: "A"), SpeakerTurn(start: 0, end: 1, speaker: "B"),
            SpeakerTurn(start: 7, end: 8, speaker: "B"),
        ])
        XCTAssertEqual(turns.map(\.speaker), ["1", "2", "1"])
    }

    func testSegmentsWithoutWordsUseTheirOwnSpan() {
        let segments = [
            TimedSegment(start: 0, end: 3, text: "First part"),
            TimedSegment(start: 3, end: 5, text: "still first"),
            TimedSegment(start: 6, end: 9, text: "Second voice"),
        ]
        let turns = [SpeakerTurn(start: 0, end: 5.5, speaker: "x"), SpeakerTurn(start: 5.5, end: 9, speaker: "y")]
        let result = SpeakerAssignment.assign(segments: segments, turns: turns)
        XCTAssertEqual(result.map(\.text), ["First part still first", "Second voice"])
        XCTAssertEqual(result.map(\.speaker), ["1", "2"])
    }

    func testAWordInAGapGoesToTheNearestTurnOrKeepsTheLastSpeaker() {
        let turns = [SpeakerTurn(start: 0, end: 1, speaker: "1"), SpeakerTurn(start: 5, end: 6, speaker: "2")]
        XCTAssertEqual(SpeakerAssignment.speaker(from: 1.2, to: 1.4, turns: turns), "1")
        XCTAssertNil(SpeakerAssignment.speaker(from: 2.8, to: 3.0, turns: turns))
        let result = SpeakerAssignment.assign(segments: [
            TimedSegment(start: 0, end: 4, text: "", words: [word("one", 0.2, 0.6), word("two", 2.8, 3.0)]),
        ], turns: turns)
        XCTAssertEqual(result, [VoiceNoteSegment(start: 0.2, end: 3.0, text: "one two", speaker: "1")])
    }

    func testNoTurnsKeepsSegmentsWithoutSpeakers() {
        let result = SpeakerAssignment.assign(
            segments: [TimedSegment(start: 1, end: 2, text: " b "), TimedSegment(start: 0, end: 1, text: "a"),
                       TimedSegment(start: 2, end: 3, text: "  ")],
            turns: []
        )
        XCTAssertEqual(result, [
            VoiceNoteSegment(start: 0, end: 1, text: "a", speaker: nil),
            VoiceNoteSegment(start: 1, end: 2, text: "b", speaker: nil),
        ])
    }

    func testBareWordsJoinWithSpacesAndPunctuationSticks() {
        XCTAssertEqual(SpeakerAssignment.joinWords(["Hello", ",", "world", "."]), "Hello, world.")
        XCTAssertEqual(SpeakerAssignment.joinWords([" Hello", " world"]), "Hello world")
    }

    func testRunsOfOneSpeakerJoinAcrossShortGaps() {
        let runs = AppState.speakerRuns([
            SpeakerTurn(start: 0, end: 2, speaker: "1"), SpeakerTurn(start: 2.5, end: 4, speaker: "1"),
            SpeakerTurn(start: 4, end: 6, speaker: "2"), SpeakerTurn(start: 9, end: 10, speaker: "2"),
        ])
        XCTAssertEqual(runs, [
            SpeakerTurn(start: 0, end: 4, speaker: "1"), SpeakerTurn(start: 4, end: 6, speaker: "2"),
            SpeakerTurn(start: 9, end: 10, speaker: "2"),
        ])
    }

    func testDiarizationIsOffOnMacOS14() {
        XCTAssertNotNil(FluidSpeakerDiarizer.unavailableReason(osMajorVersion: 14))
        XCTAssertNil(FluidSpeakerDiarizer.unavailableReason(osMajorVersion: 15))
    }
}

// MARK: - Summaries

@MainActor
final class NoteSummarizerChunkingTests: XCTestCase {
    func testShortTextIsOnePart() {
        XCTAssertEqual(NoteSummarizer.chunks("Hello there.", budget: 500), ["Hello there."])
        XCTAssertEqual(NoteSummarizer.chunks("   ", budget: 500), [])
    }

    func testLongTextSplitsAtLinesAndEveryPartFits() {
        let lines = (1...40).map { "Speaker \($0 % 2 + 1): This is line number \($0) of the meeting transcript." }
        let parts = NoteSummarizer.chunks(lines.joined(separator: "\n"), budget: 300)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 300 })
        XCTAssertEqual(parts.joined(separator: "\n"), lines.joined(separator: "\n"), "Nothing is lost or reordered")
    }

    func testAnOverlongLineSplitsAtSentencesThenWords() {
        let sentence = String(repeating: "word ", count: 30).trimmingCharacters(in: .whitespaces) + "."
        let line = Array(repeating: sentence, count: 6).joined(separator: " ")
        let parts = NoteSummarizer.chunks(line, budget: 200)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 200 })
        XCTAssertEqual(parts.joined(separator: " ").split(separator: " ").count, line.split(separator: " ").count)
    }

    func testTranscriptTextNamesSpeakers() {
        var note = VoiceNote(title: "x", source: .meeting, segments: [
            VoiceNoteSegment(start: 0, end: 1, text: "Ship it Friday.", speaker: "1"),
            VoiceNoteSegment(start: 1, end: 2, text: "Agreed.", speaker: "2"),
        ])
        note.speakerNames["1"] = "Priya"
        XCTAssertEqual(NoteSummarizer.transcriptText(for: note), "Priya: Ship it Friday.\nSpeaker 2: Agreed.")
    }

    func testParseReadsTheThreeSections() throws {
        let answer = """
        SUMMARY:
        The team planned the launch.
        DECISIONS:
        - Ship on Friday
        - None
        ACTION ITEMS:
        1. Priya: write the release notes
        * Someone: book the room
        """
        let summary = try XCTUnwrap(NoteSummarizer.parse(answer, model: "Ministral"))
        XCTAssertEqual(summary.overview, "The team planned the launch.")
        XCTAssertEqual(summary.decisions, ["Ship on Friday"])
        XCTAssertEqual(summary.actionItems, ["Priya: write the release notes", "Someone: book the room"])
        XCTAssertEqual(summary.model, "Ministral")
    }

    func testParseAcceptsMarkdownAndInlineHeadings() throws {
        let summary = try XCTUnwrap(NoteSummarizer.parse("**Summary:** A quick sync.\n## Action items\n- None", model: nil))
        XCTAssertEqual(summary.overview, "A quick sync.")
        XCTAssertTrue(summary.actionItems.isEmpty)
        XCTAssertNil(NoteSummarizer.parse("DECISIONS:\n- None\nACTION ITEMS:\n- None", model: nil))
    }

    func testLongTranscriptsAreSummarizedInPartsThenMerged() async throws {
        let transcript = (1...30).map { "Line \($0) of a long meeting about the budget." }.joined(separator: "\n")
        var prompts: [String] = []
        let result = await NoteSummarizer.summarize(transcript, budget: 400, model: nil) { _, prompt in
            prompts.append(prompt)
            return .success("SUMMARY:\nBudget talk.\nDECISIONS:\n- None\nACTION ITEMS:\n- Sam: send numbers")
        }
        let summary = try result.get()
        XCTAssertEqual(summary.actionItems, ["Sam: send numbers"])
        XCTAssertGreaterThan(prompts.filter { $0 == NoteSummarizer.partPrompt }.count, 1)
        XCTAssertEqual(prompts.last, NoteSummarizer.mergePrompt)
    }

    func testAModelFailureStopsTheSummary() async {
        let result = await NoteSummarizer.summarize("Hello.", budget: 400, model: nil) { _, _ in .failure(.model("busy")) }
        XCTAssertEqual(result.failureValue, .model("busy"))
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

// MARK: - Export

final class NoteExporterTests: XCTestCase {
    private func sampleNote() -> VoiceNote {
        VoiceNote(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID(),
            createdAt: Date(timeIntervalSince1970: 1_793_200_000),
            title: "Weekly sync: launch",
            source: .meeting,
            status: .completed,
            durationSeconds: 75.4,
            segments: [
                VoiceNoteSegment(start: 0, end: 4, text: "Let's ship on Friday.", speaker: "1"),
                VoiceNoteSegment(start: 62, end: 70, text: "Fine by me, I'll write the notes.", speaker: "2"),
            ],
            text: "Let's ship on Friday. Fine by me, I'll write the notes.",
            speakerNames: ["1": "Priya"],
            summary: VoiceNoteSummary(
                overview: "The team agreed the launch date.", decisions: ["Ship on Friday"],
                actionItems: ["Speaker 2: write the release notes"], model: "Ministral", createdAt: Date(timeIntervalSince1970: 0)
            )
        )
    }

    func testMarkdownMatchesTheGoldenFile() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let golden = """
        # Weekly sync: launch

        - Date: 2026-10-28 15:06
        - Source: Meeting
        - Length: 01:15
        - Speakers: Priya, Speaker 2

        ## Summary

        The team agreed the launch date.

        ### Decisions

        - Ship on Friday

        ### Action items

        - [ ] Speaker 2: write the release notes

        ## Transcript

        **[00:00] Priya:** Let's ship on Friday.

        **[01:02] Speaker 2:** Fine by me, I'll write the notes.

        """
        XCTAssertEqual(NoteExporter.markdown(sampleNote(), timeZone: utc), golden)
    }

    func testFileNamesAreSortableAndSafe() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(NoteExporter.fileName(sampleNote(), format: .markdown, timeZone: utc), "2026-10-28 15-06 Weekly sync- launch.md")
    }

    func testPlainTextAndJSON() throws {
        XCTAssertEqual(
            NoteExporter.plainText(sampleNote()),
            "Priya: Let's ship on Friday.\n\nSpeaker 2: Fine by me, I'll write the notes.\n"
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VoiceNote.self, from: NoteExporter.data(sampleNote(), format: .json))
        XCTAssertEqual(decoded, sampleNote())
    }

    func testClock() {
        XCTAssertEqual(NoteExporter.clock(0), "00:00")
        XCTAssertEqual(NoteExporter.clock(3_725), "1:02:05")
    }

    func testExportFolderWritesMarkdown() throws {
        let suite = "VocaMac-NoteFolder-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VocaMac-Vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        let exportFolder = NoteExportFolder(defaults: defaults)
        XCTAssertNil(try exportFolder.write(sampleNote()), "No folder, nothing written")
        try exportFolder.remember(folder)
        let written = try XCTUnwrap(try exportFolder.write(sampleNote()))
        XCTAssertTrue(try String(contentsOf: written, encoding: .utf8).hasPrefix("# Weekly sync: launch"))
        exportFolder.forget()
        XCTAssertNil(exportFolder.url)
    }
}

// MARK: - Mixing

final class NoteAudioMixerTests: XCTestCase {
    func testTracksLineUpByTheirStartTimes() {
        let mixed = NoteAudioMixer.mix([0.1, 0.1, 0.1], [0.2, 0.2], secondStartsAfter: 1, sampleRate: 1)
        XCTAssertEqual(mixed.count, 3)
        XCTAssertEqual(mixed[0], 0.1, accuracy: 0.0001)
        XCTAssertEqual(mixed[1], 0.3, accuracy: 0.0001)
        XCTAssertEqual(mixed[2], 0.3, accuracy: 0.0001)
        XCTAssertEqual(NoteAudioMixer.mix([0.5], [0.5], secondStartsAfter: -2, sampleRate: 1), [0.5, 0, 0.5])
    }

    func testLoudMixesAreScaledInsteadOfClipping() {
        let mixed = NoteAudioMixer.mix([0.8, -0.8], [0.8, 0.0], secondStartsAfter: 0, sampleRate: 1)
        XCTAssertEqual(mixed[0], 1, accuracy: 0.0001)
        XCTAssertEqual(mixed[1], -0.5, accuracy: 0.0001)
        XCTAssertEqual(NoteAudioMixer.mix([], [0.3], secondStartsAfter: 5), [0.3])
    }
}

// MARK: - Through the app

@MainActor
final class AppStateVoiceNoteTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppState.notesIdentifySpeakersKey)
        UserDefaults.standard.removeObject(forKey: AppState.notesAutoSummarizeKey)
        super.tearDown()
    }

    func testANoteIsTranscribedAndSplitBySpeaker() async throws {
        let diarizer = FakeSpeakerDiarizer(turns: [
            SpeakerTurn(start: 0, end: 2, speaker: "A"), SpeakerTurn(start: 2, end: 4, speaker: "B"),
        ])
        let whisper = MockWhisperService()
        whisper.mockTranscriptionResult = VocaTranscription(
            text: "Hello there. Hi.", duration: 0.5, detectedLanguage: "en", audioLengthSeconds: 4, modelUsed: .tiny,
            segments: [
                TimedSegment(start: 0, end: 1.5, text: "Hello there."),
                TimedSegment(start: 2.2, end: 3, text: "Hi."),
            ]
        )
        let (appState, _) = AppState.makeTestState(whisperService: whisper, speakerDiarizer: diarizer)
        appState.notesAutoSummarize = false

        let id = try await appState.voiceNoteStore.begin(audio: [Float](repeating: 0.1, count: 64_000), source: .meeting)
        await appState.processNote(id, samples: [Float](repeating: 0.1, count: 64_000))

        let note = try XCTUnwrap(appState.voiceNoteStore.note(id: id))
        XCTAssertEqual(note.status, .completed)
        XCTAssertEqual(note.segments.map(\.speaker), ["1", "2"])
        XCTAssertEqual(note.text, "Hello there. Hi.")
        XCTAssertEqual(note.modelID, ModelSize.tiny.rawValue)
    }

    func testOneVoiceGetsNoSpeakerLabels() async throws {
        let diarizer = FakeSpeakerDiarizer(turns: [SpeakerTurn(start: 0, end: 4, speaker: "A")])
        let whisper = MockWhisperService()
        whisper.mockTranscriptionResult = VocaTranscription(
            text: "Just me.", duration: 0.5, detectedLanguage: "en", audioLengthSeconds: 4, modelUsed: .tiny
        )
        let (appState, _) = AppState.makeTestState(whisperService: whisper, speakerDiarizer: diarizer)
        appState.notesAutoSummarize = false
        let id = try await appState.voiceNoteStore.begin(audio: [0.1], source: .microphone)
        await appState.processNote(id, samples: [Float](repeating: 0.1, count: 64_000))
        let note = try XCTUnwrap(appState.voiceNoteStore.note(id: id))
        XCTAssertEqual(note.segments.map(\.speaker), [nil])
        XCTAssertEqual(note.segments.first?.text, "Just me.")
    }

    func testAFailedTranscriptionKeepsTheNoteForRetry() async throws {
        let whisper = MockWhisperService()
        whisper.shouldThrow = true
        let (appState, _) = AppState.makeTestState(whisperService: whisper)
        appState.notesAutoSummarize = false
        let id = try await appState.voiceNoteStore.begin(audio: [0.1], source: .systemAudio)
        await appState.processNote(id, samples: [0.1, 0.2])
        let note = try XCTUnwrap(appState.voiceNoteStore.note(id: id))
        XCTAssertEqual(note.status, .failed)
        XCTAssertNotNil(note.errorMessage)
    }

    func testTheScratchpadSavesAsATextNote() {
        let (appState, _) = AppState.makeTestState()
        appState.scratchpadText = "Remember the milk"
        defer { appState.scratchpadText = "" }
        let id = appState.saveScratchpadAsNote()
        XCTAssertEqual(appState.voiceNoteStore.note(id: try XCTUnwrap(id))?.source, .scratchpad)
        appState.scratchpadText = "  "
        XCTAssertNil(appState.saveScratchpadAsNote())
    }

    func testNotesOpenInTheSidebar() {
        XCTAssertEqual(CalmNavigation.destination(for: .notes), .main(.notes))
    }
}
