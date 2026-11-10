// CalmDictionaryTeachDialogs.swift
// VocaMac
//
// Two Dictionary dialogs that keep the word list working: “Say it”, which
// teaches a word by saying it a few times (`WordTeaching`), and the list of
// entries not said in a while, offered for removal.

import SwiftUI

// MARK: - Teach a word by saying it

/// The word a “Say it” dialog opens for.
struct CalmTeachWordRequest: Identifiable {
    let term: String
    var id: String { term }
}

/// Say a word up to three times; each take is decoded without hints and
/// the ways it was misheard are offered as spoken forms of the word. Nothing
/// is saved until Save. The take flow lives in `WordTeachingSession`.
struct CalmTeachWordDialog: View {
    @StateObject private var session: WordTeachingSession
    @Environment(\.calmDismissDialog) private var dismissDialog

    init(term: String, appState: AppState) {
        _session = StateObject(wrappedValue: WordTeachingSession(term: term, appState: appState))
    }

    private var term: String { session.term }

    var body: some View {
        let heard = session.heard
        CalmDialog(
            "Say “\(term)”",
            description: "Say the word the way you usually do. VocaMac listens without any hints and remembers "
                + "how the speech model hears it, so it comes out as “\(term)” next time.",
            width: CalmMetrics.dialogListWidth
        ) {
            status
            if let notice = session.notice {
                CalmInlineNotice(notice, tone: .warning)
            }
            if !heard.isEmpty {
                CalmList {
                    ForEach(heard) { item in
                        row(item)
                    }
                }
            }
        } footer: {
            CalmDialogFooter(
                primaryTitle: "Save",
                isPrimaryEnabled: session.canSave,
                onCancel: cancel,
                onPrimary: session.save
            ) {
                Button(session.takes == 0 ? "Say it" : "Say it again") {
                    Task { await session.startTake() }
                }
                .calmButton(.secondary)
                .disabled(!session.canStartTake)
            }
        }
        .onDisappear {
            Task { await session.cancel() }
        }
    }

    // MARK: Status

    @ViewBuilder
    private var status: some View {
        switch session.phase {
        case .ready:
            Text(readyMessage)
                .font(CalmFont.description)
                .foregroundStyle(CalmColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        case .listening:
            HStack(spacing: 10) {
                CalmSpinner()
                Text("Listening… say “\(term)”")
                    .font(CalmFont.body)
                    .foregroundStyle(CalmColor.ink)
                Spacer(minLength: 0)
                Button("Done") { Task { await session.finishTake() } }
                    .calmButton(.secondary, size: .small)
            }
        case .decoding:
            HStack(spacing: 10) {
                CalmSpinner()
                Text("Checking what the speech model heard…")
                    .font(CalmFont.body)
                    .foregroundStyle(CalmColor.ink)
            }
        }
    }

    private var readyMessage: String {
        let takes = session.takes
        if takes >= WordTeaching.maximumTakes {
            return "That’s \(WordTeaching.maximumTakes) takes. Choose what to save."
        }
        if !session.canStartTake {
            return "VocaMac is busy with a dictation. Say it once that finishes."
        }
        return takes == 0
            ? "Press Say it, then say the word once."
            : "Take \(takes + 1) of \(WordTeaching.maximumTakes): say it again, or save what was heard."
    }

    // MARK: Rows

    private func row(_ item: WordTeaching.Heard) -> some View {
        let isOn = session.selected.contains(item.form)
        return CalmListRow(padding: .compact, alignment: .center) {
            HStack(spacing: 10) {
                if item.isLearnable {
                    Button {
                        session.toggle(item.form)
                    } label: {
                        CalmCheckCircle(isOn: isOn)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Save “\(item.form)” as a way of hearing \(term)")
                    .accessibilityValue(isOn ? "On" : "Off")
                }
                Text("“\(item.form)”")
                    .font(CalmFont.body)
                    .foregroundStyle(CalmColor.ink)
                    .lineLimit(1)
                if item.count > 1 {
                    Text("×\(item.count)")
                        .font(CalmFont.description)
                        .foregroundStyle(CalmColor.muted)
                        .accessibilityLabel("\(item.count) times")
                }
                Spacer(minLength: 8)
                Text(note(for: item))
                    .font(CalmFont.description)
                    .foregroundStyle(CalmColor.muted)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func note(for item: WordTeaching.Heard) -> String {
        switch item.verdict {
        case .matches: return "Heard right"
        case .learnable: return "Becomes “\(term)”"
        case .ordinaryWord:
            return "An everyday word, so it isn’t replaced every time. The Dictionary still asks the model to listen for “\(term)”."
        case .alreadyLearned: return "Already learned"
        case .taken(let other): return "Already becomes “\(other)”"
        case .unlikely: return "Too long to be the word"
        }
    }

    private func cancel() {
        Task { await session.cancel() }
        dismissDialog?()
    }
}

// MARK: - Unused entries

/// “Not said in a while”: shown above the list when some entries haven't
/// turned up in a dictation for `TermUsage.unusedAfterDays`.
struct CalmDictionaryUnusedStrip: View {
    let count: Int
    let onReview: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("Not said in a while").calmType(.rowTitle)
            Text("\(count) entr\(count == 1 ? "y" : "ies") you haven’t dictated in \(TermUsage.unusedAfterDays) days")
                .font(CalmFont.description)
                .foregroundStyle(CalmColor.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Review", action: onReview)
                .calmLink(chevron: true)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, CalmMetrics.rowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .calmPanelBackground()
        .help("Unused words still go to the speech model as hints, where they can crowd out the ones you say.")
    }
}

/// Entries not said in a while, each with Remove, and Remove all.
struct CalmDictionaryUnusedDialog: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let items = appState.unusedDictionaryItems
        CalmDialog(
            "Not said in a while",
            description: "These haven’t turned up in a dictation for \(TermUsage.unusedAfterDays) days. "
                + "Speech models take only so many hints, so removing ones you no longer say helps the rest.",
            width: CalmMetrics.dialogListWidth
        ) {
            if items.isEmpty {
                Text("Nothing left to review.")
                    .font(CalmFont.description)
                    .foregroundStyle(CalmColor.muted)
            } else {
                CalmList {
                    ForEach(items) { item in
                        CalmListRow(padding: .compact, alignment: .center, alwaysShowsActions: true) {
                            Text(Self.title(item))
                                .font(CalmFont.body)
                                .foregroundStyle(CalmColor.ink)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } actions: {
                            Button("Remove") { appState.removeDictionaryItems([item]) }
                                .calmButton(.quiet, size: .small)
                        }
                    }
                }
                .calmDialogScrollingList()
            }
        } footer: {
            CalmDialogFooter(primaryTitle: "Done", cancelTitle: nil) {} leading: {
                if !items.isEmpty {
                    Button("Remove all") { appState.removeDictionaryItems(items) }
                        .calmButton(.quietAmber)
                }
            }
        }
    }

    private static func title(_ item: DictionaryListItem) -> String {
        switch item {
        case .word(let term): return term
        case .replacement(let replacement):
            return replacement.heardForms.joined(separator: ", ") + " → " + replacement.replacement
        }
    }
}
