// StatsSettingsTab.swift
// VocaMac
//
// View for displaying user usage statistics.

import SwiftUI

struct StatsSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var showingResetConfirmation = false
    @State private var shareState: ShareState = .idle
    /// Bumped on every share state change so a pending reset can only clear the
    /// state it was scheduled for. Keying the reset on the destination let a
    /// second share to the same network inherit the first one's countdown.
    @State private var shareStateToken = 0

    /// One state rather than two independent flags: "Copied!" and "Opening X…"
    /// are mutually exclusive, and a copy made during an open share window used
    /// to go unacknowledged.
    private enum ShareState: Equatable {
        case idle
        case copied
        case opened(StatsShareDestination, cardCopied: Bool)
        case failed(String)
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        // Fixed locale so the "yyyy-MM-dd" keys (written with a Gregorian calendar)
        // parse back correctly regardless of the user's default calendar/locale.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Key Metrics
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        VocaSectionHeader(title: "Lifetime Totals")
                        Spacer()
                        Menu {
                            ForEach(StatsShareDestination.allCases) { destination in
                                Button("Share on \(destination.displayName)") {
                                    share(to: destination)
                                }
                            }
                            Divider()
                            Button("Copy Card Image") { copyCardImage() }
                        } label: {
                            Label(shareLabel, systemImage: shareIcon)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .controlSize(.small)
                        .help("Post your stats card, or copy it to the clipboard")
                        .padding(.trailing, 8)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 0) {
                            StatPill(
                                icon: "text.word.spacing",
                                label: "Total Words",
                                value: StatsShareComposer.formatCount(appState.statsManager.stats.totalWords)
                            )
                            StatPill(
                                icon: "waveform",
                                label: "Transcriptions",
                                value: StatsShareComposer.formatCount(appState.statsManager.stats.totalTranscriptions)
                            )
                            StatPill(
                                icon: "timer",
                                label: "Total Time",
                                value: formatDuration(appState.statsManager.stats.totalAudioDurationSeconds)
                            )
                        }

                        if let note = shareNote {
                            Label(note.text, systemImage: note.icon)
                                .font(.caption)
                                .foregroundStyle(note.isError ? Color.red : Color.secondary)
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeInOut(duration: 0.2), value: shareState)
                    .vocaCard()
                }

                // Performance & Streaks
                HStack(alignment: .top, spacing: 20) {
                    VocaSettingsGroup("Speed") {
                        Text("\(String(format: "%.1f", appState.statsManager.stats.averageWPM))")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                        + Text(" WPM").font(.headline).foregroundColor(.secondary)

                        Text("Speaking Speed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VocaSettingsGroup("Streak") {
                        Text("\(appState.statsManager.stats.currentStreak)")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                        + Text(" days").font(.headline).foregroundColor(.secondary)

                        Text("Best: \(appState.statsManager.stats.bestStreak) days")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Daily Activity
                VocaSettingsGroup("Recent Activity") {
                    let days = recentDays()
                    if days.isEmpty {
                        Text("No activity recorded yet. Start transcribing to see your progress!")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(days, id: \.self) { day in
                                HStack {
                                    Text(formatDateString(day))
                                        .font(.subheadline)
                                    Spacer()
                                    Text("\(appState.statsManager.stats.dailyWordCounts[day] ?? 0) words")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                }
                                if day != days.last {
                                    Divider()
                                }
                            }
                        }
                    }
            }

                // Reset Button — left-aligned like every other control here.
                Button(role: .destructive) {
                    showingResetConfirmation = true
                } label: {
                    Label("Reset All Statistics", systemImage: "trash")
                }
                .controlSize(.small)
                .padding(.top, 8)
            }
            .padding()
        }
        .alert("Reset All Statistics?", isPresented: $showingResetConfirmation) {
            Button("Reset", role: .destructive) {
                appState.statsManager.resetStats()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all your usage statistics. This action cannot be undone.")
        }
    }

    private var shareLabel: String {
        switch shareState {
        case .idle, .failed: return "Share"
        case .copied: return "Copied!"
        case .opened(let destination, _): return "Opening \(destination.displayName)…"
        }
    }

    private var shareIcon: String {
        switch shareState {
        case .idle: return "square.and.arrow.up"
        case .copied, .opened: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        }
    }

    /// The line under the pills. Never claims the card is on the clipboard
    /// unless it is: the user pastes whatever is there into a public post.
    private var shareNote: (text: String, icon: String, isError: Bool)? {
        switch shareState {
        case .idle, .copied:
            return nil
        case .opened(let destination, let cardCopied):
            guard cardCopied else {
                return (
                    "Couldn't copy the card image, so your \(destination.displayName) post has the text only.",
                    "exclamationmark.triangle",
                    true
                )
            }
            return (
                "Card copied! Just paste it into your \(destination.displayName) post.",
                "doc.on.clipboard",
                false
            )
        case .failed(let message):
            return (message, "exclamationmark.triangle", true)
        }
    }

    private func setShareState(_ state: ShareState, clearingAfter seconds: Double) {
        shareStateToken += 1
        let token = shareStateToken
        shareState = state
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if shareStateToken == token { shareState = .idle }
        }
    }

    /// Social composers cannot take an attachment, so the card lands on the
    /// clipboard and the user pastes it into the prefilled post.
    private func share(to destination: StatsShareDestination) {
        let snapshot = StatsShareSnapshot.from(appState.statsManager.stats)
        switch StatsShareExporter.share(snapshot, to: destination) {
        case .shared:
            setShareState(.opened(destination, cardCopied: true), clearingAfter: 4)
        case .sharedWithoutCard:
            setShareState(.opened(destination, cardCopied: false), clearingAfter: 6)
        case .failed:
            setShareState(.failed("Couldn't open \(destination.displayName)."), clearingAfter: 6)
        }
    }

    private func copyCardImage() {
        let snapshot = StatsShareSnapshot.from(appState.statsManager.stats)
        guard StatsShareExporter.copyImage(toClipboard: snapshot) else {
            setShareState(.failed("Couldn't copy the card image."), clearingAfter: 6)
            return
        }
        setShareState(.copied, clearingAfter: 2)
    }

    private func formatDuration(_ seconds: Double) -> String {
        return Self.durationFormatter.string(from: seconds) ?? "\(Int(seconds))s"
    }

    private func recentDays() -> [String] {
        let keys = Array(appState.statsManager.stats.dailyWordCounts.keys)
        return keys.sorted(by: >).prefix(7).map { String($0) }
    }

    private func formatDateString(_ dateString: String) -> String {
        guard let date = Self.dateFormatter.date(from: dateString) else { return dateString }

        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }

        return Self.displayDateFormatter.string(from: date)
    }
}

struct StatPill: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(VocaDesign.accent)

            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
    }
}
