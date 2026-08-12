// StatsSettingsTab.swift
// VocaMac
//
// View for displaying user usage statistics.

import SwiftUI

struct StatsSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var showingResetConfirmation = false
    @State private var shareCopied = false

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
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Lifetime Totals", systemImage: "chart.bar.fill")
                                .font(.headline)
                            Spacer()
                            Button {
                                let snapshot = StatsShareSnapshot.from(appState.statsManager.stats)
                                if StatsShareExporter.copyImage(toClipboard: snapshot) {
                                    shareCopied = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                        shareCopied = false
                                    }
                                }
                            } label: {
                                Label(
                                    shareCopied ? "Copied!" : "Share",
                                    systemImage: shareCopied ? "checkmark" : "square.and.arrow.up"
                                )
                            }
                            .controlSize(.small)
                            .help("Copy a stats card image to the clipboard")
                        }

                        HStack(spacing: 0) {
                            StatPill(
                                icon: "text.wordspacing",
                                label: "Total Words",
                                value: "\(appState.statsManager.stats.totalWords)",
                                color: .blue
                            )
                            StatPill(
                                icon: "waveform",
                                label: "Transcriptions",
                                value: "\(appState.statsManager.stats.totalTranscriptions)",
                                color: .purple
                            )
                            StatPill(
                                icon: "timer",
                                label: "Total Time",
                                value: formatDuration(appState.statsManager.stats.totalAudioDurationSeconds),
                                color: .orange
                            )
                        }
                    }
                    .padding(8)
                }

                // Performance & Streaks
                HStack(spacing: 20) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Speed", systemImage: "speedometer")
                                .font(.headline)
                                .padding(.bottom, 4)

                            Text("\(String(format: "%.1f", appState.statsManager.stats.averageWPM))")
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                            + Text(" WPM").font(.headline).foregroundColor(.secondary)

                            Text("Speaking Speed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Streak", systemImage: "flame.fill")
                                .font(.headline)
                                .foregroundStyle(.orange)
                                .padding(.bottom, 4)

                            Text("\(appState.statsManager.stats.currentStreak)")
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                            + Text(" days").font(.headline).foregroundColor(.secondary)

                            Text("Best: \(appState.statsManager.stats.bestStreak) days")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                }

                // Daily Activity
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Recent Activity", systemImage: "calendar")
                            .font(.headline)
                            .padding(.bottom, 4)

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
                    .padding(8)
                }

                // Reset Button
                Button(role: .destructive) {
                    showingResetConfirmation = true
                } label: {
                    Label("Reset All Statistics", systemImage: "trash")
                }
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 20)
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
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)

            Text(value)
                .font(.title3)
                .fontWeight(.bold)

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
    }
}
