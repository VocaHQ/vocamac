// DictionarySettingsPage.swift
// VocaMac
//
// Settings → Dictionary: vocabulary, replacements, suggested words, and the
// switches for learning from corrections and reading on-screen names.

import SwiftUI

struct DictionarySettingsPage: View {
    @EnvironmentObject var appState: AppState
    @State private var newTerm = ""
    @State private var newHeard = ""
    @State private var newReplacement = ""

    var body: some View {
        VocaSettingsPageContent {
            if !appState.dictionarySuggestions.isEmpty {
                VocaSettingsGroup("Suggested Words", subtitle: "Spellings you fixed after dictating. Add one and VocaMac will spell it your way next time.") {
                    ForEach(appState.dictionarySuggestions) { suggestion in
                        DictionarySuggestionRow(suggestion: suggestion)
                        if suggestion.id != appState.dictionarySuggestions.last?.id { Divider() }
                    }
                }
            }

            VocaSettingsGroup("Vocabulary", subtitle: "Names, brands, and jargon you want spelled exactly this way, with every speech model.") {
                if appState.vocabularyTerms.isEmpty {
                    Text("No words yet. Try names of people, products, or tools you say often.")
                        .foregroundStyle(.secondary)
                } else {
                    FlowTermList(terms: appState.vocabularyTerms) { term in
                        appState.removeVocabularyTerm(term)
                    }
                }
                HStack {
                    TextField("Add a word, e.g. Kubernetes", text: $newTerm)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addTerm)
                    Button("Add", action: addTerm)
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("VocaMac matches what it hears to these words ignoring case and spaces (“voca mac” → VocaMac) and fixes close misspellings of longer words. Whisper models also use the first words as a recognition hint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VocaSettingsGroup("Replacements", subtitle: "Words a model keeps getting wrong, and what to type instead.") {
                if appState.wordReplacements.isEmpty {
                    Text("No replacements yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($appState.wordReplacements) { $replacement in
                        WordReplacementRow(replacement: $replacement)
                        Divider()
                    }
                }
                HStack {
                    TextField("When I say, e.g. get hub", text: $newHeard)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Type, e.g. GitHub", text: $newReplacement)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addReplacement)
                    Button("Add", action: addReplacement)
                        .disabled(newHeard.trimmingCharacters(in: .whitespaces).isEmpty
                                  || newReplacement.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Matching ignores case and only replaces whole words. Separate several spoken forms with commas. Replacements apply to every speech model; Raw dictation skips them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VocaSettingsGroup("Learning") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Learn from my corrections")
                        Text(appState.learnCorrectionsMode.description)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    Picker("Learn from my corrections", selection: $appState.learnCorrectionsMode) {
                        ForEach(LearnCorrectionsMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
                SettingsToggleRow(
                    title: "Spell names from the screen",
                    detail: "When you start dictating, VocaMac reads the text you can see in the field you're typing into and spells matching names and code identifiers the same way (“user id” → userId in code editors). It's read on this Mac, used once, and never saved.",
                    isOn: $appState.useScreenContext
                )
                Text("Both need Accessibility permission and never read password fields.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func addTerm() {
        appState.addVocabularyTerm(newTerm)
        newTerm = ""
    }

    private func addReplacement() {
        appState.addWordReplacement(heard: newHeard, replacement: newReplacement)
        newHeard = ""
        newReplacement = ""
    }
}

struct DictionarySuggestionRow: View {
    @EnvironmentObject var appState: AppState
    let suggestion: CorrectionSuggestion

    var body: some View {
        HStack {
            Text(suggestion.heard).strikethrough().foregroundStyle(.secondary)
            Image(systemName: "arrow.right").foregroundStyle(.secondary).font(.caption)
            Text(suggestion.corrected).fontWeight(.medium)
            if suggestion.occurrences > 1 {
                Text("×\(suggestion.occurrences)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add") { appState.acceptDictionarySuggestion(suggestion) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("Dismiss") { appState.dismissDictionarySuggestion(suggestion) }
                .controlSize(.small)
        }
    }
}

struct WordReplacementRow: View {
    @EnvironmentObject var appState: AppState
    @Binding var replacement: WordReplacement

    var body: some View {
        HStack {
            TextField("When I say", text: $replacement.heard)
                .textFieldStyle(.roundedBorder)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            TextField("Type", text: $replacement.replacement)
                .textFieldStyle(.roundedBorder)
            Button(role: .destructive) {
                let id = replacement.id
                appState.wordReplacements.removeAll { $0.id == id }
            } label: {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Remove Replacement")
            .accessibilityLabel("Remove Replacement")
        }
    }
}

/// Vocabulary terms as removable chips that wrap onto new lines.
struct FlowTermList: View {
    let terms: [String]
    let onRemove: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(terms, id: \.self) { term in
                HStack(spacing: 4) {
                    Text(term)
                    Button {
                        onRemove(term)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(term)")
                    .accessibilityLabel("Remove \(term)")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12), in: Capsule())
            }
        }
    }
}

/// Minimal wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width.isFinite ? width : widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
