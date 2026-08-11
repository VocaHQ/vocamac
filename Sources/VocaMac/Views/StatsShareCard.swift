// StatsShareCard.swift
// VocaMac
//
// Branded stats card rendered to an image and copied to the clipboard.

import AppKit
import SwiftUI

/// Snapshot of stats used when rendering a shareable card.
struct StatsShareSnapshot: Equatable {
    var totalWords: Int
    var totalTranscriptions: Int
    var totalAudioDurationSeconds: Double
    var averageWPM: Double
    var currentStreak: Int
    var bestStreak: Int

    static func from(_ stats: UserStats) -> StatsShareSnapshot {
        StatsShareSnapshot(
            totalWords: stats.totalWords,
            totalTranscriptions: stats.totalTranscriptions,
            totalAudioDurationSeconds: stats.totalAudioDurationSeconds,
            averageWPM: stats.averageWPM,
            currentStreak: stats.currentStreak,
            bestStreak: stats.bestStreak
        )
    }
}

struct StatsShareCard: View {
    let snapshot: StatsShareSnapshot

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                BrandLogoView(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("VocaMac")
                        .font(.title2.weight(.bold))
                    Text("My dictation stats")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 12) {
                shareMetric(title: "Words", value: "\(snapshot.totalWords)")
                shareMetric(title: "Sessions", value: "\(snapshot.totalTranscriptions)")
                shareMetric(
                    title: "Time",
                    value: Self.durationFormatter.string(from: snapshot.totalAudioDurationSeconds) ?? "0m"
                )
            }

            HStack(spacing: 12) {
                shareMetric(title: "Speed", value: String(format: "%.0f WPM", snapshot.averageWPM))
                shareMetric(title: "Streak", value: "\(snapshot.currentStreak)d")
                shareMetric(title: "Best", value: "\(snapshot.bestStreak)d")
            }

            Text("vocamac.com")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(24)
        .frame(width: 520)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func shareMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

enum StatsShareExporter {
    /// Renders the branded card and copies a PNG to the general pasteboard.
    @MainActor
    static func copyImage(toClipboard snapshot: StatsShareSnapshot) -> Bool {
        let card = StatsShareCard(snapshot: snapshot)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return false
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setData(png, forType: .png)
    }
}
