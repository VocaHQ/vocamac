// CalmHomePage.swift
// VocaMac
//
// Home: the dictation feed (the old History page) grouped by day, with a
// search field behind the header's search button, and a side column with
// the word / speed / streak card and the “Edit text by voice” tip.
// History's storage controls live in Settings › Privacy and History.

import SwiftUI

/// Home: the dictation feed (old History page) and the side card.
struct CalmHomePage: View {
    @EnvironmentObject private var appState: AppState
    @Environment(CalmNavigator.self) private var navigator
    @ObservedObject private var player = HistoryAudioPlayer.shared

    @State private var isSearching = false
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    @State private var columnWidth: CGFloat = 844

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The side column's width and the gap before it: the design's 250 / 24
    /// once the page column is 800 wide, narrower below that so the feed
    /// keeps room for its text.
    static func sideLayout(for columnWidth: CGFloat) -> (width: CGFloat, gap: CGFloat) {
        columnWidth >= 800 ? (250, 24) : (224, 20)
    }

    var body: some View {
        CalmPage(.list) {
            CalmPageHeader("Welcome back") { searchControl }
            HStack(alignment: .top, spacing: Self.sideLayout(for: columnWidth).gap) {
                CalmHomeFeed(query: trimmedQuery, player: player) { query = "" }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .settingsTarget("history")
                CalmHomeSideColumn()
                    .frame(width: Self.sideLayout(for: columnWidth).width)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                if width > 0, abs(width - columnWidth) > 0.5 { columnWidth = width }
            }
        }
        .onDisappear { player.stop() }
    }

    // MARK: Search

    @ViewBuilder
    private var searchControl: some View {
        if isSearching {
            CalmSearchField(text: $query, prompt: "Search dictations", focus: $isSearchFocused)
                .frame(width: 280)
                .onChange(of: isSearchFocused) { _, focused in
                    if !focused, query.isEmpty { closeSearch() }
                }
                .onExitCommand { closeSearch() }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
        } else {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { isSearching = true }
                DispatchQueue.main.async { isSearchFocused = true }
            } label: {
                CalmIcon(.search, size: 18)
            }
            .calmIconButton()
            .help("Search dictations")
            .accessibilityLabel("Search dictations")
        }
    }

    private func closeSearch() {
        query = ""
        withAnimation(.easeOut(duration: 0.18)) { isSearching = false }
    }
}

// MARK: - Feed

/// The feed column: an unsaved-changes notice, a history-off notice, then
/// the day groups, or an empty state.
private struct CalmHomeFeed: View {
    let query: String
    @ObservedObject var player: HistoryAudioPlayer
    let onClearSearch: () -> Void

    @EnvironmentObject private var appState: AppState
    @Environment(CalmNavigator.self) private var navigator
    /// The search and day grouping, redone only when history or the query
    /// changes, not on every AppState change.
    @State private var memo = CalmMemo<FeedKey, [CalmFeedDay]>()

    private struct FeedKey: Equatable {
        let historyRevision: Int
        let query: String
    }

    var body: some View {
        let days = memo.value(for: FeedKey(historyRevision: appState.historyStore.revision, query: query)) {
            CalmFeedDay.groups(appState.historyStore.search(query))
        }
        VStack(alignment: .leading, spacing: 22) {
            if appState.historyStore.hasUnsavedChanges {
                CalmPanel {
                    CalmStatusRow(
                        "Recent changes aren’t saved yet",
                        description: "VocaMac keeps trying. Check that your disk has free space.",
                        tone: .warning
                    ) { EmptyView() }
                }
            }
            if !appState.historyEnabled, !appState.historyStore.entries.isEmpty {
                CalmPanel {
                    CalmStatusRow(
                        "History is off",
                        description: "New dictations aren’t saved. These are from before.",
                        tone: .info
                    ) {
                        Button("Settings", action: openPrivacy).calmButton(.secondary)
                    }
                }
            }
            if days.isEmpty {
                emptyState
            } else {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(days) { day in
                        CalmDaySection(CalmDaySection<EmptyView>.caption(for: day.day)) {
                            CalmList {
                                ForEach(day.entries) { entry in
                                    CalmFeedRow(entry: entry, player: player)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !query.isEmpty {
            CalmNoResults(message: "No dictations match “\(query)”.", onClear: onClearSearch)
        } else if !appState.historyEnabled {
            CalmEmptyState(icon: .lock, title: "History is off") {
                VStack(spacing: 12) {
                    Text("VocaMac types what you say but doesn’t keep a copy, so there’s nothing to show here.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Turn it on in Privacy and History", action: openPrivacy).calmLink(chevron: true)
                }
            }
        } else {
            CalmEmptyState(icon: .mic, title: "No dictations yet") {
                ViewThatFits(in: .horizontal) {
                    CalmKeyedLine(
                        [.text(appState.dictationKeyVerb), .keys(appState.dictationKeyCaps),
                         .text("and speak in any app. Your words show up here.")],
                        spacing: 4, capSize: .inline
                    )
                    VStack(spacing: 4) {
                        CalmKeyedLine(
                            [.text(appState.dictationKeyVerb), .keys(appState.dictationKeyCaps), .text("and speak in any app.")],
                            spacing: 4, capSize: .inline
                        )
                        Text("Your words show up here.")
                    }
                }
            }
        }
    }

    private func openPrivacy() {
        navigator.openSettings(.privacy, target: "history-retention")
    }
}

// MARK: - Feed row

/// One dictation: time and app on the left, the text (three lines, then
/// Show more), its tags, and on hover a copy button and a more menu.
private struct CalmFeedRow: View {
    let entry: DictationHistoryEntry
    @ObservedObject var player: HistoryAudioPlayer

    @EnvironmentObject private var appState: AppState
    @State private var isExpanded = false
    @State private var isClamped = false
    @State private var showsOriginal = false
    @State private var showsTimestamps = false

    /// Lines shown before “Show more”.
    private static let clampLines = 3

    private var isRetrying: Bool { appState.retryingHistoryEntryID == entry.id }
    private var audioURL: URL? { entry.hasAudio ? appState.historyStore.audioURL(for: entry) : nil }
    private var isPlaying: Bool { audioURL != nil && player.playingURL == audioURL }

    var body: some View {
        CalmListRow {
            CalmTimeColumn(time: CalmFormat.feedTime(entry.createdAt), app: entry.appName)
                .help(timeHelp)
            VStack(alignment: .leading, spacing: 8) {
                textBlock
                tags
                if showsOriginal, let original = entry.originalText {
                    fold(entry.isCommandEdit ? "Before the edit" : "What you said") {
                        Text(original.trimmingCharacters(in: .whitespacesAndNewlines))
                            .calmType(.description)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if showsTimestamps, let segments = entry.segments, !segments.isEmpty {
                    fold("Timestamps") { timestamps(segments) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } actions: {
            if isRetrying {
                CalmSpinner(size: 16)
                    .frame(width: CalmMetrics.iconButtonSize, height: CalmMetrics.iconButtonSize)
            }
            if !entry.displayText.isEmpty {
                Button { appState.copyToClipboard(entry.displayText) } label: {
                    CalmIcon(.copy, size: 16)
                }
                .calmIconButton()
                .help("Copy")
                .accessibilityLabel(entry.isCommandEdit ? "Copy edit" : "Copy dictation")
            }
            moreMenu
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Text

    @ViewBuilder
    private var textBlock: some View {
        if entry.displayText.isEmpty {
            Text(entry.errorMessage ?? (entry.status == .empty ? "No words were heard." : "No text yet."))
                .font(CalmFont.body)
                .foregroundStyle(CalmColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.displayText)
                    .calmType(.body)
                    .lineLimit(isExpanded ? nil : Self.clampLines)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shown in
                        clampedHeight = shown
                    }
                    .background(alignment: .topLeading) {
                        // The full text, unseen, to tell whether the clamp cut anything.
                        Text(entry.displayText)
                            .calmType(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { full in
                                fullHeight = full
                            }
                            .accessibilityHidden(true)
                    }
                if isClamped || isExpanded {
                    Button(isExpanded ? "Show less" : "Show more") { isExpanded.toggle() }
                        .calmLink()
                        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                }
            }
            .onChange(of: fullHeight) { updateClamp() }
            .onChange(of: clampedHeight) { updateClamp() }
        }
    }

    @State private var fullHeight: CGFloat = 0
    @State private var clampedHeight: CGFloat = 0

    private func updateClamp() {
        guard !isExpanded else { return }
        let clamped = fullHeight > clampedHeight + 1
        if clamped != isClamped { isClamped = clamped }
    }

    // MARK: Tags

    @ViewBuilder
    private var tags: some View {
        let status = statusTag
        if entry.isCommandEdit || status != nil || entry.retryCount > 0 {
            HStack(spacing: 6) {
                if entry.isCommandEdit {
                    CalmCommandEditTag()
                        .help("A Command Mode edit of selected text")
                    let instruction = entry.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !instruction.isEmpty {
                        Text("“\(instruction)”")
                            .font(CalmFont.note)
                            .foregroundStyle(CalmColor.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .accessibilityLabel("Instruction: \(instruction)")
                    }
                }
                if let status { CalmTag(status.text, tone: status.tone) }
                if entry.retryCount > 0 { CalmTag("Retried") }
            }
        }
    }

    private var statusTag: (text: String, tone: CalmTone)? {
        switch entry.status {
        case .completed: return nil
        case .failed, .interrupted: return (entry.status.displayName, .warning)
        case .pending, .cancelled, .empty: return (entry.status.displayName, .neutral)
        }
    }

    // MARK: Folds

    private func fold<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CalmCaption(title)
            content()
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(CalmColor.line).frame(height: 1) }
    }

    private func timestamps(_ segments: [TimedSegment]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(segments.indices, id: \.self) { index in
                let segment = segments[index]
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(TranscriptTimestamp.display(segment.start)) – \(TranscriptTimestamp.display(segment.end))")
                        .font(CalmFont.note.weight(.semibold))
                        .foregroundStyle(CalmColor.muted)
                    let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        Text(text).calmType(.description).fixedSize(horizontal: false, vertical: true)
                    }
                    if !segment.words.isEmpty {
                        Text(segment.words.map { "\(TranscriptTimestamp.display($0.start)) \($0.word)" }.joined(separator: "   "))
                            .font(.system(size: 11.5))
                            .foregroundStyle(CalmColor.muted)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: More menu

    private var moreMenu: some View {
        Menu {
            if !entry.displayText.isEmpty {
                Button { appState.copyToClipboard(entry.displayText) } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            if let original = entry.originalText {
                Button {
                    // An edit's original is copied exactly, whitespace and
                    // all, so pasting it back restores the selection.
                    appState.copyToClipboard(entry.isCommandEdit
                        ? original
                        : original.trimmingCharacters(in: .whitespacesAndNewlines))
                } label: {
                    Label(entry.isCommandEdit ? "Copy text before the edit" : "Copy what I said",
                          systemImage: entry.isCommandEdit ? "arrow.uturn.backward" : "mic")
                }
                Button { showsOriginal.toggle() } label: {
                    Label(showsOriginal
                          ? (entry.isCommandEdit ? "Hide text before the edit" : "Hide what I said")
                          : (entry.isCommandEdit ? "Show text before the edit" : "Show what I said"),
                          systemImage: "text.quote")
                }
            }
            if let segments = entry.segments, !segments.isEmpty {
                Button { showsTimestamps.toggle() } label: {
                    Label(showsTimestamps ? "Hide timestamps" : "Show timestamps", systemImage: "clock")
                }
            }
            if let audioURL {
                Divider()
                Button { player.toggle(audioURL) } label: {
                    Label(isPlaying ? "Stop audio" : "Play audio", systemImage: isPlaying ? "stop" : "play")
                }
                Button {
                    Task { await appState.retryHistoryEntry(entry.id) }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .disabled(appState.retryingHistoryEntryID != nil)
                .help("Transcribe again with the current model and copy the result")
            }
            Divider()
            Button(role: .destructive) {
                if isPlaying { player.stop() }
                appState.deleteHistoryEntry(entry.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            CalmIconMenuLabel("More actions", icon: .more, size: 18, weight: 2.4)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(CalmIconButtonStyle())
        .focusEffectDisabled()
        .fixedSize()
        .help("More")
        .accessibilityLabel("More actions")
    }

    private var timeHelp: String {
        let when = entry.createdAt.formatted(date: .abbreviated, time: .shortened)
        guard entry.audioSeconds > 0 else { return when }
        return "\(when) · \(CalmFormat.duration(entry.audioSeconds)) of audio"
    }
}

/// The small violet “Edit” tag on a Command Mode edit (violet is Command
/// Mode's colour only).
private struct CalmCommandEditTag: View {
    var body: some View {
        Text("Edit")
            .font(CalmFont.tag)
            .foregroundStyle(CalmColor.violet)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: CalmMetrics.tagHeight)
            .background(
                RoundedRectangle(cornerRadius: CalmMetrics.Radius.key, style: .continuous)
                    .fill(CalmColor.violet.opacity(0.12))
            )
    }
}

// MARK: - Side column

/// Words, words a minute and the streak, then the Command Mode tip.
private struct CalmHomeSideColumn: View {
    @EnvironmentObject private var appState: AppState
    @Environment(CalmNavigator.self) private var navigator
    /// The summary and streak week, recomputed only when the stats,
    /// history or day change.
    @State private var memo = CalmMemo<CalmInsightsInputs, (summary: CalmInsightsSummary, week: [CalmStreakDay])>()

    var body: some View {
        let (summary, week) = memo.value(for: appState.insightsInputs) {
            let calendar = appState.statsCalendar
            let week = CalmActivityCalendar.streakWeek(
                CalmActivityCalendar.lastSevenDays(stats: appState.statsManager.stats, calendar: calendar),
                calendar: calendar
            )
            return (appState.insightsSummary(), week)
        }
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 16) {
                CalmBigNumber(value: CalmFormat.number(summary.lifetimeWords), unit: summary.lifetimeWords == 1 ? "word" : "words")
                CalmBigNumber(value: CalmFormat.number(summary.wordsPerMinute), unit: "words a minute")
                VStack(alignment: .leading, spacing: 12) {
                    CalmBigNumber(value: CalmFormat.number(summary.currentStreak), unit: "day streak")
                    CalmStreakWeek(days: week)
                    Button("See your year") { navigator.show(.insights) }
                        .calmLink(chevron: true)
                        .padding(.top, 2)
                }
                .padding(.top, 16)
                .overlay(alignment: .top) { Rectangle().fill(CalmColor.line).frame(height: 1) }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .calmPanelBackground()

            if appState.commandModeIsUsable, let caps = appState.commandModeShortcutCaps {
                CalmTipCard(
                    dismissKey: "home.editByVoice", title: "Edit text by voice",
                    actionTitle: "Try it", action: showCommands
                ) {
                    ViewThatFits(in: .horizontal) {
                        CalmKeyedLine([.text("Select text, press"), .keys(caps)], spacing: 4, capSize: .inline)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Select text, press")
                            CalmKeyCombo(caps, size: .inline)
                        }
                    }
                    Text("and say what to change.")
                }
            }
        }
    }

    private func showCommands() { navigator.show(.commands) }
}
