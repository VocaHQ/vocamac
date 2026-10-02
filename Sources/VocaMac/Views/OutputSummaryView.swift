// OutputSummaryView.swift
// VocaMac
//
// What a dictation will get, and how a preview changed it.

import SwiftUI

/// One line under the menu's Style row saying what the next dictation gets:
/// format, cleanup and tone as they resolve for the app in front, a one-off
/// choice included. A second line appears only when something leaves this Mac.
struct NextDictationSummary: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            (Text(appState.nextWritingProfile == nil ? "Next dictation" : "Next dictation only")
                .fontWeight(.medium)
                .foregroundStyle(.primary)
             + Text("  \(appState.nextOutputSummary.description)"))
                .fixedSize(horizontal: false, vertical: true)
            if let notice = appState.nextDictationRemoteNotice {
                Label(notice, systemImage: "network")
                    .labelStyle(.titleAndIcon)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
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
