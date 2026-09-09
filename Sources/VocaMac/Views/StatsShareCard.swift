// StatsShareCard.swift
// VocaMac
//
// Branded stats card rendered to an image, copied to the clipboard and
// optionally posted to a social composer.
// Forced dark appearance so clipboard shares match the in-app Stats look.

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

    private let cardBackground = Color(red: 0.11, green: 0.12, blue: 0.14)
    private let chipBackground = Color.white.opacity(0.06)
    private let brandGreen = Color(nsColor: BrandAssets.brandGreen)

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        formatter.calendar = calendar
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                BrandLogoView(size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("VocaMac")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                    Text("My usage")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
            }

            HStack(spacing: 10) {
                shareMetric(
                    title: "Words",
                    value: StatsShareComposer.formatCount(snapshot.totalWords),
                    accent: brandGreen
                )
                shareMetric(
                    title: "Sessions",
                    value: StatsShareComposer.formatCount(snapshot.totalTranscriptions),
                    accent: brandGreen
                )
                shareMetric(
                    title: "Time",
                    value: Self.durationFormatter.string(from: snapshot.totalAudioDurationSeconds) ?? "0m",
                    accent: .orange
                )
            }

            HStack(spacing: 10) {
                shareMetric(title: "Speed", value: String(format: "%.0f WPM", snapshot.averageWPM), accent: brandGreen)
                shareMetric(title: "Streak", value: "\(snapshot.currentStreak)d", accent: .orange)
                shareMetric(title: "Best", value: "\(snapshot.bestStreak)d", accent: Color(red: 1.0, green: 0.45, blue: 0.2))
            }

            HStack {
                Capsule()
                    .fill(brandGreen.opacity(0.85))
                    .frame(width: 28, height: 4)
                Spacer()
                Text("vocamac.com")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(28)
        .frame(width: 560)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(cardBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    brandGreen.opacity(0.4),
                    lineWidth: 1.2
                )
        }
        .environment(\.colorScheme, .dark)
    }

    private func shareMetric(title: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.45))
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
            Capsule()
                .fill(accent)
                .frame(width: 18, height: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(chipBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// What `StatsShareExporter.share` managed to do, so the UI can tell the user
/// whether the card is actually on the clipboard.
enum StatsShareOutcome: Equatable {
    /// Composer opened and the card image is on the clipboard.
    case shared
    /// Composer opened, but the card image could not be copied.
    case sharedWithoutCard
    /// Nothing opened.
    case failed
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

    /// Copies the card image, then opens the destination's composer with the
    /// post text prefilled so the user can paste the image in.
    ///
    /// Web share intents cannot carry an attachment, so the clipboard copy is
    /// how the image gets there. A failed copy is reported separately rather
    /// than folded into success: telling the user to paste when the clipboard
    /// still holds their previous content would put that content in a public
    /// post.
    @MainActor
    static func share(_ snapshot: StatsShareSnapshot, to destination: StatsShareDestination) -> StatsShareOutcome {
        guard let url = StatsShareComposer.composerURL(for: snapshot, destination: destination) else {
            VocaLogger.error(.general, "Stats share: could not build a \(destination.displayName) composer URL")
            return .failed
        }

        let copiedImage = copyImage(toClipboard: snapshot)
        if !copiedImage {
            VocaLogger.warning(.general, "Stats share: card image could not be copied")
        }

        guard NSWorkspace.shared.open(url) else {
            VocaLogger.error(.general, "Stats share: could not open the \(destination.displayName) composer")
            return .failed
        }

        return copiedImage ? .shared : .sharedWithoutCard
    }
}
