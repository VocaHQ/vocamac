// CalmDictionaryDialogs.swift
// VocaMac
//
// The Dictionary page's dialogs: “Add to dictionary” (Word or Replacement),
// the same dialog for editing with Delete at the far left, and the full
// list of suggested words.

import SwiftUI

// MARK: - Requests

/// What the Dictionary editor dialog opens for.
enum CalmDictionaryEditorRequest: Identifiable {
    case add(DictionaryEntryKind)
    case editWord(String)
    case editReplacement(WordReplacement)

    var id: String {
        switch self {
        case .add(let kind): return "add:\(kind.rawValue)"
        case .editWord(let term): return "word:\(term)"
        case .editReplacement(let replacement): return "replacement:\(replacement.id.uuidString)"
        }
    }
}

// MARK: - Editor

/// Add a word or a replacement, or edit one. New items open with focus in
/// the first field; the primary button stays disabled until the entry is
/// valid, and a clash with an existing item says so under the field.
struct CalmDictionaryEditor: View {
    let request: CalmDictionaryEditorRequest

    @EnvironmentObject private var appState: AppState
    @Environment(\.calmDismissDialog) private var dismissDialog

    @State private var kind: DictionaryEntryKind
    @State private var word: String
    @State private var heard: String
    @State private var replacement: String
    @FocusState private var isWordFocused: Bool
    @FocusState private var isHeardFocused: Bool

    init(request: CalmDictionaryEditorRequest) {
        self.request = request
        switch request {
        case .add(let kind):
            _kind = State(initialValue: kind)
            _word = State(initialValue: "")
            _heard = State(initialValue: "")
            _replacement = State(initialValue: "")
        case .editWord(let term):
            _kind = State(initialValue: .word)
            _word = State(initialValue: term)
            _heard = State(initialValue: "")
            _replacement = State(initialValue: "")
        case .editReplacement(let item):
            _kind = State(initialValue: .replacement)
            _word = State(initialValue: "")
            _heard = State(initialValue: item.heardForms.joined(separator: ", "))
            _replacement = State(initialValue: item.replacement)
        }
    }

    private var isAdding: Bool {
        if case .add = request { return true }
        return false
    }

    private var title: String {
        switch request {
        case .add: return "Add to dictionary"
        case .editWord: return "Edit word"
        case .editReplacement: return "Edit replacement"
        }
    }

    private var check: DictionaryEntryCheck {
        switch (kind, request) {
        case (.word, .editWord(let term)):
            return appState.checkVocabularyTerm(word, editing: term)
        case (.word, _):
            return appState.checkVocabularyTerm(word)
        case (.replacement, .editReplacement(let item)):
            return appState.checkWordReplacement(heard: heard, replacement: replacement, editing: item.id)
        case (.replacement, _):
            return appState.checkWordReplacement(heard: heard, replacement: replacement)
        }
    }

    var body: some View {
        let check = check
        CalmDialog(title) {
            if isAdding {
                CalmSegmentedControl(
                    selection: $kind,
                    options: [CalmOption(.word, "Word"), CalmOption(.replacement, "Replacement")],
                    accessibilityLabel: "Add a"
                )
                .padding(.top, -6)
            }
            switch kind {
            case .word:
                CalmTextField("Word", text: $word, prompt: "e.g. Kubernetes", error: check.message, focus: $isWordFocused)
                    .help("Matches ignore case and spaces (“voca mac” → VocaMac) and fix close misspellings "
                          + "with every model. Whisper, Parakeet and Apple Speech also listen for these words.")
                Text("Names, product words and jargon you want spelled exactly like this.")
                    .calmType(.description)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, -8)
            case .replacement:
                HStack(alignment: .top, spacing: 12) {
                    CalmTextField("When I say", text: $heard, prompt: "e.g. get hub", error: check.message,
                                  focus: $isHeardFocused)
                        .help("Whole words only, ignoring case. Separate several spoken forms with commas. "
                              + "Raw transcription skips replacements.")
                    CalmTextField("Type", text: $replacement, prompt: "e.g. GitHub")
                }
            }
        } footer: {
            CalmDialogFooter(
                primaryTitle: isAdding ? "Add" : "Save",
                isPrimaryEnabled: check.isValid,
                onPrimary: save
            ) {
                if !isAdding {
                    Button("Delete", action: delete).calmButton(.quietAmber)
                }
            }
        }
        .onAppear { focusFirstField() }
        .onChange(of: kind) { _, _ in focusFirstField() }
    }

    private func focusFirstField() {
        DispatchQueue.main.async {
            if kind == .word { isWordFocused = true } else { isHeardFocused = true }
        }
    }

    private func save() {
        guard check.isValid else { return }
        switch (kind, request) {
        case (.word, .editWord(let term)):
            appState.renameVocabularyTerm(term, to: word)
        case (.word, _):
            appState.addVocabularyTerm(word)
        case (.replacement, .editReplacement(let item)):
            appState.updateWordReplacement(id: item.id, heard: heard, replacement: replacement)
        case (.replacement, _):
            appState.addWordReplacement(heard: heard, replacement: replacement)
        }
    }

    /// Removes the item with Undo on offer, then closes.
    private func delete() {
        switch request {
        case .add: break
        case .editWord(let term): appState.removeVocabularyTermWithUndo(term)
        case .editReplacement(let item): appState.removeWordReplacement(item)
        }
        dismissDialog?()
    }
}

// MARK: - Suggested words

/// Every suggested word, with what VocaMac typed and how often you fixed
/// it. Add puts the spelling in the dictionary; Dismiss stops suggesting it.
struct CalmDictionarySuggestionsDialog: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let suggestions = appState.dictionarySuggestions
        CalmDialog(
            "Suggested words",
            description: "Spellings you fixed after dictating. Add one and VocaMac spells it your way from now on.",
            width: CalmMetrics.dialogListWidth
        ) {
            if suggestions.isEmpty {
                Text("No suggestions left.")
                    .font(CalmFont.description)
                    .foregroundStyle(CalmColor.muted)
            } else if suggestions.count > Self.rowsWithoutScrolling {
                ScrollView { list(suggestions) }
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: CalmMetrics.Radius.list, style: .continuous))
            } else {
                list(suggestions)
            }
        } footer: {
            CalmDialogFooter(primaryTitle: "Done", cancelTitle: nil) {}
        }
    }

    private static let rowsWithoutScrolling = 5

    private func list(_ suggestions: [CorrectionSuggestion]) -> some View {
        CalmList {
            ForEach(suggestions) { suggestion in
                CalmListRow(padding: .compact, alignment: .center, alwaysShowsActions: true) {
                    HStack(spacing: 8) {
                        Text(suggestion.heard)
                            .strikethrough()
                            .foregroundStyle(CalmColor.muted)
                            .lineLimit(1)
                        CalmIcon(.arrowRight, size: 14)
                            .foregroundStyle(CalmColor.muted)
                            .accessibilityLabel("became")
                        Text(suggestion.corrected)
                            .foregroundStyle(CalmColor.ink)
                            .lineLimit(1)
                        if suggestion.occurrences > 1 {
                            Text("×\(suggestion.occurrences)")
                                .font(CalmFont.description)
                                .foregroundStyle(CalmColor.muted)
                                .accessibilityLabel("\(suggestion.occurrences) times")
                        }
                    }
                    .font(CalmFont.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                } actions: {
                    HStack(spacing: 6) {
                        Button("Dismiss") { appState.dismissDictionarySuggestion(suggestion) }
                            .calmButton(.quiet, size: .small)
                        Button("Add") { appState.acceptDictionarySuggestion(suggestion) }
                            .calmButton(.secondary, size: .small)
                    }
                }
            }
        }
    }
}
