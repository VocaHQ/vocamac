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
/// is saved until Save.
struct CalmTeachWordDialog: View {
    let term: String

    @EnvironmentObject private var appState: AppState
    @Environment(\.calmDismissDialog) private var dismissDialog

    private enum Phase: Equatable {
        case ready
        case listening
        case decoding
    }

    @State private var phase: Phase = .ready
    @State private var takes = 0
    @State private var transcripts: [String] = []
    @State private var selected: Set<String> = []
    @State private var offered: Set<String> = []
    @State private var notice: String?
    @State private var autoStop: Task<Void, Never>?

    private var heard: [WordTeaching.Heard] {
        WordTeaching.review(
            term: term, transcripts: transcripts, replacements: appState.wordReplacements,
            isKnownWord: { appState.isKnownWord($0, appState.spellingLanguage) }
        )
    }

    private var chosenForms: [String] {
        heard.filter { $0.isLearnable && selected.contains($0.form) }.map(\.form)
    }

    var body: some View {
        let heard = heard
        CalmDialog(
            "Say “\(term)”",
            description: "Say the word the way you usually do. VocaMac listens without any hints and remembers "
                + "how the speech model hears it, so it comes out as “\(term)” next time.",
            width: CalmMetrics.dialogListWidth
        ) {
            status
            if let notice {
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
                isPrimaryEnabled: phase == .ready && !chosenForms.isEmpty,
                onCancel: cancel,
                onPrimary: save
            ) {
                Button(takes == 0 ? "Say it" : "Say it again", action: startTake)
                    .calmButton(.secondary)
                    .disabled(phase != .ready || takes >= WordTeaching.maximumTakes || !appState.canTeachWord)
            }
        }
        .onDisappear {
            autoStop?.cancel()
            if phase == .listening {
                Task { await appState.cancelTeachingTake() }
            }
        }
    }

    // MARK: Status

    @ViewBuilder
    private var status: some View {
        switch phase {
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
                Button("Done") { Task { await finishTake() } }
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
        if takes >= WordTeaching.maximumTakes {
            return "That’s \(WordTeaching.maximumTakes) takes. Choose what to save."
        }
        if !appState.canTeachWord {
            return "VocaMac is busy with a dictation. Say it once that finishes."
        }
        return takes == 0
            ? "Press Say it, then say the word once."
            : "Take \(takes + 1) of \(WordTeaching.maximumTakes): say it again, or save what was heard."
    }

    // MARK: Rows

    private func row(_ item: WordTeaching.Heard) -> some View {
        CalmListRow(padding: .compact, alignment: .center) {
            HStack(spacing: 10) {
                if item.isLearnable {
                    Button {
                        if selected.contains(item.form) {
                            selected.remove(item.form)
                        } else {
                            selected.insert(item.form)
                        }
                    } label: {
                        CalmCheckCircle(isOn: selected.contains(item.form))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Save “\(item.form)” as a way of hearing \(term)")
                    .accessibilityValue(selected.contains(item.form) ? "On" : "Off")
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

    // MARK: Actions

    private func startTake() {
        notice = nil
        phase = .listening
        Task { @MainActor in
            guard await appState.startTeachingTake() else {
                phase = .ready
                notice = "The microphone isn’t free right now. Try again in a moment."
                return
            }
            autoStop = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(WordTeaching.takeSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await finishTake()
            }
        }
    }

    private func finishTake() async {
        guard phase == .listening else { return }
        autoStop?.cancel()
        autoStop = nil
        phase = .decoding
        let text = await appState.finishTeachingTake()
        phase = .ready
        takes += 1
        guard let text else {
            notice = "The speech model couldn’t run. Check Settings › Models."
            return
        }
        guard !WordTeaching.spokenForm(of: text).isEmpty else {
            notice = "Nothing was heard. Say it again, a little closer to the microphone."
            return
        }
        transcripts.append(text)
        // New ways of hearing it start chosen; a choice the user changed stays.
        for item in heard where item.isLearnable && offered.insert(item.form).inserted {
            selected.insert(item.form)
        }
    }

    private func cancel() {
        autoStop?.cancel()
        if phase == .listening {
            Task { await appState.cancelTeachingTake() }
        }
        dismissDialog?()
    }

    private func save() {
        appState.teachWord(term, heardForms: chosenForms)
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
