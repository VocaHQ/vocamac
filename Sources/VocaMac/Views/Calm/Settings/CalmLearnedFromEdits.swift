// CalmLearnedFromEdits.swift
// VocaMac
//
// What VocaMac learned from the user's edits, where they can take it back:
// fillers they always delete (Settings › General, under the typed text
// rules) and apps where they start in lowercase (Styles). Both show only
// once something has been learned.

import SwiftUI

/// "Words you always remove": fillers learned from the user's edits.
struct CalmLearnedFillersGroup: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if !appState.personalFillers.isEmpty {
            CalmGroup("Words you always remove") {
                CalmPanel {
                    ForEach(appState.personalFillers, id: \.self) { word in
                        CalmRow(
                            "“\(word)”",
                            description: PersonalFillers.commaBound.contains(word)
                                ? "Left out where it opens a sentence before a comma, as you did" : "Left out of your dictations, as you did"
                        ) {
                            Button("Keep it") { appState.removePersonalFillerWithUndo(word) }
                                .calmButton()
                                .accessibilityLabel("Keep “\(word)” in dictations")
                        }
                    }
                }
            }
        }
    }
}

/// Apps where dictation starts in lowercase because the user kept
/// lowercasing it.
struct CalmLearnedCasingGroup: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if !appState.learnedLowercaseApps.isEmpty {
            CalmGroup("Learned from your edits") {
                CalmPanel {
                    ForEach(appState.learnedLowercaseApps) { app in
                        CalmRow(app.displayName, description: "Starts in lowercase · Learned") {
                            Button("Use capitals") { appState.removeLearnedLowercaseAppWithUndo(app) }
                                .calmButton()
                                .accessibilityLabel("Start with a capital in \(app.displayName) again")
                        }
                    }
                }
            }
        }
    }
}
