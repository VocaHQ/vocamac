import SwiftUI

/// Effective choices, including a pending one-off, instead of a preset name
/// that could conceal cleanup or rewriting enabled elsewhere.
struct OutputSummaryView: View {
    @EnvironmentObject var appState: AppState
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            Text(appState.nextWritingProfile == nil
                 ? (appState.writingStyleTargetApp?.displayName).map { "Next dictation in \($0)" } ?? "Next dictation"
                 : "Next dictation only")
                .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
            Text(appState.nextOutputSummary.description)
                .font(compact ? .caption : .callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(appState.speechProcessingDescription, systemImage: appState.speechProcessingIsRemote ? "network" : "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
            if appState.transcriptCleanupEnabled,
               appState.nextOutputProfile.cleanup == .inherit,
               (appState.nextOutputProfile.cleanupLevel ?? appState.transcriptCleanupLevel) != .none {
                Text(!appState.nextOutputProfile.format.supportsWording && !appState.cleanupEndpoint.isLocal
                     ? "Code and Terminal text stays on this Mac for cleanup"
                     : appState.cleanupProcessingDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !appState.websiteStyleBindings.isEmpty {
                Text("A matching website rule can override these settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Original and final text stay together when inspecting an output change.
struct TranscriptComparisonView: View {
    let original: String
    let final: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                column("Original", text: original).frame(minWidth: 180)
                column("Final text", text: final).frame(minWidth: 180)
            }
            VStack(alignment: .leading, spacing: 12) {
                column("Original", text: original)
                column("Final text", text: final)
            }
        }
    }

    private func column(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Text(text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
