// HistorySettingsPage.swift
// VocaMac
//
// Settings → History: every past dictation with its text, the original
// transcript, the audio, and a way to retry it.

import AVFoundation
import SwiftUI

struct HistorySettingsPage: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var player = HistoryAudioPlayer.shared
    @State private var query = ""
    @State private var confirmingDeleteAll = false

    private var entries: [DictationHistoryEntry] {
        appState.historyStore.search(query)
    }

    var body: some View {
        VocaSettingsPageContent {
            if appState.historyStore.hasUnsavedChanges {
                Label("Recent history changes couldn't be saved to disk. VocaMac keeps trying; check that your disk has free space.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .vocaCard()
            }

            VocaSettingsGroup("Keep History") {
                SettingsToggleRow(
                    title: "Save dictation history",
                    detail: "Keep what you dictated on this Mac so you can copy it, paste it again, or retry it. Nothing leaves your Mac.",
                    isOn: $appState.historyEnabled
                )
                Divider()
                SettingsToggleRow(
                    title: "Keep audio recordings",
                    detail: "Needed to play back or retry a dictation. Audio is always kept for dictations that failed or were interrupted, until they're retried or deleted.",
                    isOn: $appState.historyKeepsAudio
                )
                .disabled(!appState.historyEnabled)
                Divider()
                HStack {
                    Text("Keep dictations for")
                    Spacer()
                    Picker("Keep dictations for", selection: $appState.historyRetention) {
                        ForEach(HistoryRetention.allCases) { retention in
                            Text(retention.displayName).tag(retention)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: appState.historyRetention) { appState.applyHistoryRetention() }
                }
                .disabled(!appState.historyEnabled)
                Divider()
                HStack {
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete Audio") { appState.deleteAllHistoryAudio() }
                        .disabled(appState.historyStore.entries.allSatisfy { !$0.hasAudio })
                    Button("Delete All…", role: .destructive) { confirmingDeleteAll = true }
                        .disabled(appState.historyStore.entries.isEmpty)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VocaSectionHeader(title: "Dictations", systemImage: nil, subtitle: nil)
                    Spacer()
                    TextField("Search", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }
                if entries.isEmpty {
                    Text(query.isEmpty ? "Your dictations will appear here." : "No dictations match “\(query)”.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .vocaCard()
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(entries) { entry in
                            HistoryEntryRow(entry: entry, player: player)
                                .vocaCard()
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete all dictation history?",
            isPresented: $confirmingDeleteAll
        ) {
            Button("Delete All", role: .destructive) {
                player.stop()
                appState.clearHistory()
            }
        } message: {
            Text("This removes every saved dictation and recording from this Mac.")
        }
        .onDisappear { player.stop() }
    }

    private var summaryText: String {
        let entries = appState.historyStore.entries
        let bytes = entries.reduce(Int64(0)) { $0 + ($1.audioBytes ?? 0) }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "\(entries.count) dictation\(entries.count == 1 ? "" : "s") · \(size) of audio"
    }
}

struct HistoryEntryRow: View {
    @EnvironmentObject var appState: AppState
    let entry: DictationHistoryEntry
    @ObservedObject var player: HistoryAudioPlayer
    @State private var showsOriginal = false
    @State private var isOriginalHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRetrying: Bool { appState.retryingHistoryEntryID == entry.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(entry.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let app = entry.appName {
                    Text("·").font(.caption).foregroundStyle(.tertiary)
                    Text(app).font(.caption).foregroundStyle(.secondary)
                }
                Text("·").font(.caption).foregroundStyle(.tertiary)
                Text(String(format: "%.1fs", entry.audioSeconds)).font(.caption).foregroundStyle(.secondary)
                if entry.status != .completed {
                    Text(entry.status.displayName)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(statusColor)
                }
                if entry.retryCount > 0 {
                    Text("Retried").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                actions
            }

            if entry.displayText.isEmpty {
                Text(entry.errorMessage ?? (entry.status == .empty ? "No words were heard." : "No text yet."))
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                Text(entry.displayText)
                    .textSelection(.enabled)
                    .lineLimit(showsOriginal ? nil : 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if entry.hasEditedOutput {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                            showsOriginal.toggle()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(VocaDesign.accent.opacity(0.12))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(VocaDesign.accent)
                                    .rotationEffect(.degrees(showsOriginal ? 90 : 0))
                            }
                            .frame(width: 20, height: 20)

                            Text("Original transcript")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)

                            if let summary = entry.summary {
                                Text(summary)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(VocaDesign.accent)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(VocaDesign.accent.opacity(0.10), in: Capsule())
                            }

                            Spacer(minLength: 8)

                            Text(showsOriginal ? "Hide" : "Show")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Original transcript")
                    .accessibilityValue(showsOriginal ? "Expanded" : "Collapsed")
                    .accessibilityHint("Shows the text before cleanup and writing style changes")

                    if showsOriginal {
                        Divider()
                            .padding(.horizontal, 10)

                        Text(entry.rawText.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                }
                .background(
                    Color.primary.opacity(isOriginalHovered ? 0.065 : 0.035),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(VocaDesign.line))
                .onHover { isOriginalHovered = $0 }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 10) {
            if !entry.displayText.isEmpty {
                Button { appState.copyToClipboard(entry.displayText) } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy")
                .accessibilityLabel("Copy dictation")
            }
            if entry.hasEditedOutput {
                Button { appState.copyToClipboard(entry.rawText.trimmingCharacters(in: .whitespacesAndNewlines)) } label: {
                    Image(systemName: "text.badge.minus")
                }
                .help("Copy the original transcript, before cleanup and styling")
                .accessibilityLabel("Copy original transcript")
            }
            if entry.hasAudio, let url = appState.historyStore.audioURL(for: entry) {
                Button { player.toggle(url) } label: {
                    Image(systemName: player.playingURL == url ? "stop.fill" : "play.fill")
                }
                .help(player.playingURL == url ? "Stop" : "Play recording")
                .accessibilityLabel(player.playingURL == url ? "Stop playback" : "Play recording")

                if isRetrying {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await appState.retryHistoryEntry(entry.id) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Transcribe again with the current model and copy the result")
                    .accessibilityLabel("Retry transcription")
                    .disabled(appState.retryingHistoryEntryID != nil)
                }
            }
            Button(role: .destructive) {
                if let url = appState.historyStore.audioURL(for: entry), player.playingURL == url { player.stop() }
                appState.deleteHistoryEntry(entry.id)
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete")
            .accessibilityLabel("Delete dictation")
        }
        .buttonStyle(.borderless)
    }

    private var statusColor: Color {
        switch entry.status {
        case .failed, .interrupted: return .orange
        case .cancelled, .empty: return .secondary
        case .pending: return .yellow
        case .completed: return VocaDesign.success
        }
    }
}

/// Plays one history recording at a time.
@MainActor
final class HistoryAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = HistoryAudioPlayer()

    @Published private(set) var playingURL: URL?
    private var player: AVAudioPlayer?

    func toggle(_ url: URL) {
        if playingURL == url {
            stop()
            return
        }
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.play()
            self.player = player
            playingURL = url
        } catch {
            VocaLogger.warning(.history, "Could not play recording: \(error.localizedDescription)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingURL = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
