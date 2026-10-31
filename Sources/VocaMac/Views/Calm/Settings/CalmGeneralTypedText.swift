// CalmGeneralTypedText.swift
// VocaMac
//
// Settings › General › Typed text in every app: spacing, capitals,
// numbers, emoji and paragraph breaks.

import SwiftUI

/// The rules for typed text in every app (the old Formatting page). They
/// apply whatever the style, so they sit in General rather than on Styles,
/// which is about how each app's text reads.
struct CalmTypedTextGroup: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        CalmGroup("Typed text in every app") {
            CalmPanel {
                CalmToggleRow(
                    "Add a space after each dictation",
                    description: "Keeps dictations from running together",
                    isOn: $appState.appendTrailingSpace
                )
                .settingsTarget("trailing-space")
                CalmToggleRow(
                    "Capitalize sentences",
                    description: "Starts each sentence with a capital letter",
                    isOn: $appState.autoCapitalize
                )
                .settingsTarget("auto-capitalize")
                CalmRow("Numbers", description: appState.numberWriting.settingsDescription) {
                    CalmDropdown(
                        selection: Binding(get: { appState.numberWriting }, set: { appState.numberWriting = $0 }),
                        options: [NumberWriting.automatic, .digits, .words].map { CalmOption($0, $0.settingsTitle) }
                    )
                }
                .settingsTarget("numbers-as-digits")
                CalmToggleRow(
                    "Use symbols and ordinals",
                    description: appState.numberWriting != .words
                        ? "“fifty percent” becomes “50%” and “June twenty second” “June 22”"
                        : "Needs numbers written as digits",
                    isOn: $appState.numberSymbols
                )
                .calmDisabledByParent(appState.numberWriting == .words)
                .settingsTarget("number-symbols")
                CalmToggleRow(
                    "Spoken emoji",
                    description: "Say “party emoji” to type 🎉",
                    isOn: $appState.spokenEmoji
                )
                .settingsTarget("spoken-emoji")
                CalmToggleRow(
                    "Paragraph breaks",
                    description: "A pause between sentences starts a new paragraph. Plain, Email and Notes only",
                    isOn: $appState.pauseParagraphs
                )
                .settingsTarget("pause-paragraphs")
            }
        }
    }
}

extension NumberWriting {
    var settingsTitle: String {
        switch self {
        case .automatic: return "Automatic"
        case .digits: return "Digits"
        case .words: return "As spoken"
        }
    }

    var settingsDescription: String {
        switch self {
        case .automatic:
            return "Digits in chat and code. Elsewhere “two ideas” stays a word, “twenty three” becomes “23”. English only"
        case .digits: return "“six pm” becomes “6 pm” and “two ideas” “2 ideas”. English only"
        case .words: return "Numbers stay as the words you said"
        }
    }
}
