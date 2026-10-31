// CalmNotesPage.swift
// VocaMac
//
// Notes: meetings, calls and memos recorded on this Mac. The list (with
// search), and a note's own view: its summary, the speakers (named by
// the user, never guessed), the transcript with timestamps, playback, and
// export. Below the list, how notes are made: speakers, summaries, and
// the export folder.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Notes in the sidebar.
struct CalmNotesPage: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var player = HistoryAudioPlayer.shared

    @State private var openNoteID: UUID?
    @State private var query = ""
    @State private var isSearching = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        // The store publishes on its own; read it through the app state's
        // so the page redraws with it.
        CalmNotesStoreReader(store: appState.voiceNoteStore) { notes in
            if let id = openNoteID, let note = notes.first(where: { $0.id == id }) {
                CalmNoteDetail(note: note, player: player) { openNoteID = nil }
            } else {
                list(notes)
            }
        }
    }

    // MARK: List

    private func list(_ notes: [VoiceNote]) -> some View {
        let shown = VoiceNoteStore.notes(notes, matching: query)
        return CalmPage(.list, spacing: 22) {
            CalmPageHeader("Notes", description: "Meetings, calls and memos, transcribed and summarized. \(appState.notesPrivacyNote)") {
                HStack(spacing: 8) {
                    if !notes.isEmpty { searchControl }
                    Button {
                        MeetingCaptureWindowManager.shared.open(appState: appState)
                    } label: {
                        CalmButtonLabel("New note", icon: .plus)
                    }
                    .calmButton(.primary)
                }
            }
            if notes.isEmpty {
                CalmEmptyState(icon: .notes, title: "No notes yet") {
                    Text("Record a meeting, a call or a memo. VocaMac writes the transcript, tells the speakers apart, and summarizes it.")
                }
            } else if shown.isEmpty {
                CalmNoResults(message: "No notes match “\(query)”.") { query = "" }
            } else {
                CalmPagedList(shown, resetKey: query) { note in
                    CalmNoteRow(note: note) { openNoteID = note.id }
                }
            }
            CalmNotesSettingsGroup()
        }
    }

    @ViewBuilder
    private var searchControl: some View {
        if isSearching {
            CalmSearchField(text: $query, prompt: "Search notes", focus: $isSearchFocused, onEscapeWhenEmpty: {
                query = ""
                isSearching = false
            })
            .onChange(of: isSearchFocused) { _, focused in
                if !focused, query.isEmpty { isSearching = false }
            }
            .frame(width: 240)
        } else {
            Button {
                isSearching = true
                DispatchQueue.main.async { isSearchFocused = true }
            } label: {
                CalmIcon(.search, size: 17)
            }
            .calmIconButton()
            .help("Search notes")
            .accessibilityLabel("Search notes")
        }
    }
}

/// Re-renders its content whenever the note store changes.
private struct CalmNotesStoreReader<Content: View>: View {
    @ObservedObject var store: VoiceNoteStore
    @ViewBuilder let content: ([VoiceNote]) -> Content

    var body: some View { content(store.notes) }
}

// MARK: - Row

private struct CalmNoteRow: View {
    let note: VoiceNote
    let open: () -> Void

    var body: some View {
        CalmListRow(padding: .compact, alignment: .center, alwaysShowsActions: true) {
            VStack(alignment: .leading, spacing: 3) {
                Text(note.title)
                    .font(CalmFont.rowTitle)
                    .foregroundStyle(CalmColor.ink)
                    .lineLimit(1)
                Text(CalmNoteText.subtitle(note))
                    .font(CalmFont.note)
                    .foregroundStyle(CalmColor.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } actions: {
            if note.status == .pending {
                ProgressView().controlSize(.small)
            } else if note.status.needsRetry {
                CalmTag(note.status.displayName, tone: .warning)
            }
            Button(action: open) { CalmIcon(.chevRight, size: 15) }
                .calmIconButton()
                .accessibilityLabel("Open \(note.title)")
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}

// MARK: - Detail

private struct CalmNoteDetail: View {
    @EnvironmentObject private var appState: AppState
    let note: VoiceNote
    @ObservedObject var player: HistoryAudioPlayer
    let close: () -> Void

    @State private var isSummarizing = false
    @State private var notice: String?
    @State private var renaming: CalmNoteRename?
    @State private var confirmsDelete = false

    var body: some View {
        CalmPage(.list, spacing: 22) {
            CalmPageHeader(note.title, description: CalmNoteText.subtitle(note), back: CalmBack("Notes", action: close)) {
                actions
            }
            if let notice { CalmInlineNotice(notice, tone: .warning) }
            if note.status == .pending {
                CalmInlineNotice("Transcribing with \(appState.speechProcessingDescription)…", tone: .info)
            } else if note.status.needsRetry {
                CalmStatusRow(note.status.displayName, description: note.errorMessage ?? "The transcript didn't finish.", tone: .warning) {
                    Button("Transcribe again") { Task { await appState.retryNote(note.id) } }
                        .calmButton(.primary)
                        .disabled(!note.hasAudio)
                }
            }
            summary
            if !note.speakers.isEmpty { speakers }
            transcript
        }
        .calmDialog(item: $renaming) { request in
            CalmNoteRenameDialog(request: request) { name in
                switch request.target {
                case .title: appState.voiceNoteStore.rename(note.id, title: name)
                case .speaker(let id): appState.voiceNoteStore.renameSpeaker(note.id, speaker: id, to: name)
                }
                appState.exportToFolder(note.id)
            }
        }
        .calmDialog(isPresented: $confirmsDelete) {
            CalmDialog("Delete this note?", description: "Its transcript, summary and audio are removed from this Mac.") {
                CalmDialogFooter(primaryTitle: "Delete", primaryKind: .destructive) {
                    if let url = appState.voiceNoteStore.audioURL(for: note), player.playingURL == url { player.stop() }
                    appState.voiceNoteStore.delete(note.id)
                    close()
                }
            }
        }
    }

    private var audioURL: URL? { appState.voiceNoteStore.audioURL(for: note) }

    private var actions: some View {
        HStack(spacing: 8) {
            if let audioURL {
                let isPlaying = player.playingURL == audioURL
                Button(isPlaying ? "Stop" : "Play") { player.toggle(audioURL) }
                    .calmButton(.secondary)
            }
            Menu {
                Button("Copy transcript") { appState.copyToClipboard(NoteExporter.plainText(note)) }
                Button("Copy as Markdown") { appState.copyToClipboard(NoteExporter.markdown(note)) }
                Divider()
                ForEach(NoteExportFormat.allCases) { format in
                    Button("Save as \(format.title)…") { save(format) }
                }
                Divider()
                Button("Rename…") { renaming = CalmNoteRename(target: .title, current: note.title) }
                Button("Delete…", role: .destructive) { confirmsDelete = true }
            } label: {
                CalmIconMenuLabel("More actions", icon: .more, size: 18, weight: 2.4)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(CalmIconButtonStyle())
            .fixedSize()
            .help("More")
        }
    }

    // MARK: Summary

    @ViewBuilder
    private var summary: some View {
        CalmGroup("Summary") {
            CalmPanel {
                if let summary = note.summary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        if !summary.overview.isEmpty {
                            Text(summary.overview).font(CalmFont.body).foregroundStyle(CalmColor.ink)
                        }
                        bulletList("Decisions", summary.decisions)
                        bulletList("Action items", summary.actionItems)
                        Text("\(summary.provenance) Check it against the transcript.")
                            .font(CalmFont.note)
                            .foregroundStyle(CalmColor.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .textSelection(.enabled)
                }
                CalmRow(
                    note.summary == nil ? "Summarize" : "Summarize again",
                    description: "Uses your Command Mode model. Long notes are summarized part by part."
                ) {
                    HStack(spacing: 8) {
                        if isSummarizing { ProgressView().controlSize(.small) }
                        Button(note.summary == nil ? "Summarize" : "Again") { summarize() }
                            .calmButton(.secondary)
                            .disabled(isSummarizing || note.status != .completed)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bulletList(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(CalmFont.rowTitle).foregroundStyle(CalmColor.ink)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text("•  \(item)").font(CalmFont.body).foregroundStyle(CalmColor.ink2)
                }
            }
        }
    }

    private func summarize() {
        isSummarizing = true
        notice = nil
        Task {
            notice = await appState.summarizeNote(note.id)
            isSummarizing = false
        }
    }

    // MARK: Speakers

    private var speakers: some View {
        CalmGroup("Speakers") {
            CalmPanel {
                ForEach(note.speakers, id: \.self) { speaker in
                    CalmRow(note.speakerName(speaker), description: CalmNoteText.speakingTime(note, speaker: speaker)) {
                        Button("Name…") {
                            renaming = CalmNoteRename(target: .speaker(speaker), current: note.speakerNames[speaker] ?? "")
                        }
                        .calmButton(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        CalmGroup("Transcript") {
            VStack(alignment: .leading, spacing: 14) {
                if note.segments.isEmpty {
                    Text(note.text.isEmpty ? "No transcript yet." : note.text)
                        .font(CalmFont.body)
                        .foregroundStyle(note.text.isEmpty ? CalmColor.muted : CalmColor.ink)
                } else {
                    ForEach(Array(note.segments.enumerated()), id: \.offset) { _, segment in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(NoteExporter.clock(segment.start))
                                    .font(CalmFont.note.monospacedDigit())
                                    .foregroundStyle(CalmColor.muted)
                                if let speaker = segment.speaker {
                                    Text(note.speakerName(speaker))
                                        .font(CalmFont.rowTitle)
                                        .foregroundStyle(CalmNoteText.color(for: speaker, in: note))
                                }
                            }
                            Text(segment.text).font(CalmFont.body).foregroundStyle(CalmColor.ink)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .calmPanelBackground()
            .textSelection(.enabled)
        }
    }

    private func save(_ format: NoteExportFormat) {
        let panel = NSSavePanel()
        panel.title = "Save Note"
        panel.nameFieldStringValue = NoteExporter.fileName(note, format: format)
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try NoteExporter.data(note, format: format).write(to: url, options: .atomic)
        } catch {
            notice = "Could not save the note: \(error.localizedDescription)"
        }
    }
}

// MARK: - Settings

/// How notes are made: speakers, summaries, the export folder.
private struct CalmNotesSettingsGroup: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        CalmGroup("Settings") {
            CalmPanel {
                let unavailable = appState.speakerDiarizer.unavailableReason
                CalmToggleRow(
                    "Tell speakers apart",
                    description: unavailable ?? "Labels who said what. The speaker models download once, about 30 MB.",
                    isOn: Binding(get: { appState.notesIdentifySpeakers }, set: { appState.notesIdentifySpeakers = $0 })
                )
                .disabled(unavailable != nil)
                CalmToggleRow(
                    "Summarize new notes",
                    description: "Writes an overview, decisions and action items with your Command Mode model.",
                    isOn: Binding(get: { appState.notesAutoSummarize }, set: { appState.notesAutoSummarize = $0 })
                )
                CalmRow(
                    "Also save to a folder",
                    description: appState.noteExportFolder.map { "Every note is written to \($0.path) as Markdown." }
                        ?? "Write each note as Markdown into a folder, such as an Obsidian vault."
                ) {
                    HStack(spacing: 8) {
                        if appState.noteExportFolder != nil {
                            Button("Stop") { appState.setNoteExportFolder(nil) }.calmButton(.quiet)
                        }
                        Button(appState.noteExportFolder == nil ? "Choose…" : "Change…", action: chooseFolder)
                            .calmButton(.secondary)
                    }
                }
                Text("Notes follow History’s retention setting (Settings › Privacy and History).")
                    .font(CalmFont.note)
                    .foregroundStyle(CalmColor.muted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
        .settingsTarget("notes-settings")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder for Notes"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.setNoteExportFolder(url)
    }
}

// MARK: - Rename

private struct CalmNoteRename: Identifiable {
    enum Target: Equatable { case title, speaker(String) }
    let target: Target
    let current: String
    var id: String {
        switch target {
        case .title: return "title"
        case .speaker(let speaker): return "speaker-\(speaker)"
        }
    }
}

private struct CalmNoteRenameDialog: View {
    let request: CalmNoteRename
    let onSave: (String) -> Void
    @State private var text = ""

    var body: some View {
        CalmDialog(request.target == .title ? "Rename note" : "Name this speaker",
                   description: request.target == .title ? nil : "Only on this note. VocaMac never guesses names.") {
            CalmTextField(nil, text: $text, prompt: request.target == .title ? "Title" : "Name")
        } footer: {
            CalmDialogFooter(primaryTitle: "Save") { onSave(text) }
        }
        .onAppear { text = request.current }
    }
}

// MARK: - Words

/// The words and colours the Notes page uses.
enum CalmNoteText {
    /// "Meeting · 28 Oct, 14:05 · 42:10 · 3 speakers".
    static func subtitle(_ note: VoiceNote) -> String {
        var parts = [note.source.displayName, note.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if note.durationSeconds > 0 { parts.append(NoteExporter.clock(note.durationSeconds)) }
        let speakers = note.speakers.count
        if speakers > 1 { parts.append("\(speakers) speakers") }
        if note.summary != nil { parts.append("Summarized") }
        if note.status != .completed { parts.append(note.status.displayName) }
        return parts.joined(separator: " · ")
    }

    /// "Spoke for 12 min".
    static func speakingTime(_ note: VoiceNote, speaker: String) -> String {
        let seconds = note.segments.filter { $0.speaker == speaker }.reduce(0) { $0 + max(0, $1.end - $1.start) }
        let minutes = Int((seconds / 60).rounded())
        return minutes < 1 ? "Spoke for under a minute" : "Spoke for \(minutes) min"
    }

    private static let palette: [Color] = [CalmColor.accent, CalmColor.violet, CalmColor.amber, CalmColor.ink2]

    /// Each speaker keeps one colour through the transcript.
    static func color(for speaker: String, in note: VoiceNote) -> Color {
        let index = note.speakers.firstIndex(of: speaker) ?? 0
        return palette[index % palette.count]
    }
}
