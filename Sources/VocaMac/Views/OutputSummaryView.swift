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
