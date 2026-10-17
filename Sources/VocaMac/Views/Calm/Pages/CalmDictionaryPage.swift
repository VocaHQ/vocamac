// CalmDictionaryPage.swift
// VocaMac
//
// Dictionary: the feature card with suggested words, tabs All / Words /
// Replacements with learning mode and search at the right, the list of
// vocabulary words and replacements, and Parakeet's vocabulary boost under
// it. Adding and editing happen in `CalmDictionaryEditor`. “Spell names
// from the screen” lives in Settings › Privacy and History.

import SwiftUI

/// Dictionary: vocabulary, replacements and suggestions.
struct CalmDictionaryPage: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.settingsSearchTarget) private var searchTarget

    @AppStorage(CalmFeatureCard<EmptyView>.storageKey(CalmDictionaryPage.heroKey)) private var isHeroDismissed = false
    @State private var filter: DictionaryListFilter = .all
    @State private var isSearching = false
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool
    @State private var editor: CalmDictionaryEditorRequest?
    @State private var showsSuggestions = false

    /// The feature card's dismissal key.
    static let heroKey = "dictionary"

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        CalmPage(.list, spacing: 22) {
            CalmPageHeader("Dictionary") {
                Button {
                    // On the Replacements tab, add a replacement.
                    editor = .add(filter == .replacements ? .replacement : .word)
                } label: {
                    CalmButtonLabel("Add new", icon: .plus)
                }
                .calmButton(.primary)
            }
            tabBar
            if isSearching {
                searchField
            }
            if !isSearching {
                if !isHeroDismissed {
                    hero
                } else if !appState.dictionarySuggestions.isEmpty {
                    CalmDictionarySuggestedStrip { showsSuggestions = true }
                }
            }
            CalmDictionaryList(filter: filter, query: trimmedQuery, onEdit: edit) { query = "" }
                .settingsTarget("vocabulary", aliases: ["word-replacements"])
            if appState.showsVocabularyBoostOption {
                CalmPanel { CalmVocabularyBoostRow() }
            }
        }
        .calmDialog(item: $editor) { request in
            CalmDictionaryEditor(request: request)
        }
        .calmDialog(isPresented: $showsSuggestions) {
            CalmDictionarySuggestionsDialog()
        }
        .onChange(of: searchTarget, initial: true) { _, target in
            // A search result for vocabulary or replacements opens its tab.
            guard let tab = DictionaryListFilter.forSearchTarget(target) else { return }
            closeSearch()
            filter = tab
        }
    }

    // MARK: Tabs

    private var tabBar: some View {
        CalmTabs(selection: $filter, tabs: DictionaryListFilter.allCases.map { CalmOption($0, $0.title) }) {
            HStack(spacing: 14) {
                CalmLearnModeMenu(mode: $appState.learnCorrectionsMode)
                    .settingsTarget("learn-corrections")
                Button {
                    isSearching ? closeSearch() : openSearch()
                } label: {
                    CalmIcon(.search, size: 17)
                }
                .calmIconButton()
                .help(isSearching ? "Close search" : "Search the dictionary")
                .accessibilityLabel(isSearching ? "Close search" : "Search the dictionary")
            }
        }
    }

    // MARK: Search

    private var searchField: some View {
        CalmSearchField(text: $query, prompt: "Search words and replacements", focus: $isSearchFocused)
            .onChange(of: isSearchFocused) { _, focused in
                if !focused, query.isEmpty { closeSearch() }
            }
            .onExitCommand { closeSearch() }
            .transition(.opacity)
    }

    private func openSearch() {
        withAnimation(.easeOut(duration: 0.18)) { isSearching = true }
        DispatchQueue.main.async { isSearchFocused = true }
    }

    private func closeSearch() {
        query = ""
        withAnimation(.easeOut(duration: 0.18)) { isSearching = false }
    }

    // MARK: Feature card

    private var hero: some View {
        let suggestions = appState.dictionarySuggestions
        let shown = suggestions.prefix(Self.heroChipLimit)
        return CalmFeatureCard(
            dismissKey: Self.heroKey,
            title: Text("VocaMac spells the way ") + Text("you").italic() + Text(" do."),
            message: "Add names, product words and jargon so they come out right every time. "
                + "Words you correct after dictating show up here as suggestions.",
            waveHeights: [40, 86, 130, 64, 150, 96, 52, 110, 30]
        ) {
            // Wraps: suggested words can be long and the window narrow.
            FlowLayout(spacing: 8) {
                Button("Add a word") { editor = .add(.word) }
                    .calmButton(.heroPrimary)
                ForEach(Array(shown)) { suggestion in
                    CalmSuggestionHeroChip(suggestion: suggestion)
                }
                if suggestions.count > shown.count {
                    Button {
                        showsSuggestions = true
                    } label: {
                        CalmHeroChipLabel("\(suggestions.count - shown.count) more", icon: nil)
                    }
                    .calmButton(.heroChip)
                    .help("See every suggested word")
                }
            }
            .padding(.top, 4)
        }
    }

    /// Suggestion chips on the feature card before the rest fold into “N more”.
    private static let heroChipLimit = 3

    private func edit(_ item: DictionaryListItem) {
        switch item {
        case .word(let term): editor = .editWord(term)
        case .replacement(let replacement): editor = .editReplacement(replacement)
        }
    }
}

// MARK: - Learning mode

/// “Learn from my corrections” with a compact dropdown: Off, Suggest or
/// Automatic. The model has three states, so this replaces the design's
/// switch.
private struct CalmLearnModeMenu: View {
    @Binding var mode: LearnCorrectionsMode

    var body: some View {
        HStack(spacing: 10) {
            Text("Learn from my corrections")
                .font(CalmFont.description)
                .foregroundStyle(CalmColor.muted)
                .lineLimit(1)
            Menu {
                Picker("", selection: $mode) {
                    ForEach(LearnCorrectionsMode.allCases) { option in
                        Text(Self.title(for: option)).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(Self.title(for: mode))
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(CalmCompactDropdownButtonStyle())
            .focusEffectDisabled()
            .fixedSize()
            .help(mode.description)
            .accessibilityLabel("Learn from my corrections")
            .accessibilityValue(Self.title(for: mode))
        }
    }

    static func title(for mode: LearnCorrectionsMode) -> String {
        switch mode {
        case .off: return "Off"
        case .suggest: return "Suggest"
        case .automatic: return "Automatic"
        }
    }
}

/// A dropdown's closed button at the small size (h28 r8, SF 13), for a
/// tab bar where the full h34 dropdown would make the row taller.
struct CalmCompactDropdownButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CalmCompactDropdownBody(configuration: configuration)
    }
}

private struct CalmCompactDropdownBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CalmMetrics.Radius.smallButton, style: .continuous)
        let outline = isFocused ? CalmColor.ink : (isHovered && isEnabled ? CalmColor.muted : CalmColor.line2)
        HStack(spacing: 6) {
            configuration.label
                .font(CalmFont.sf(13, weight: 550))
                .foregroundStyle(CalmColor.ink)
                .lineLimit(1)
            CalmIcon(.chevDown, size: 12)
                .foregroundStyle(CalmColor.muted)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: CalmMetrics.smallButtonHeight)
        .background(shape.fill(CalmColor.content))
        .overlay(shape.strokeBorder(outline, lineWidth: 1))
        .contentShape(shape)
        .calmFieldFocusRing(isFocused && isEnabled, radius: CalmMetrics.Radius.smallButton)
        .calmDisabledDimming()
        .onHover { isHovered = $0 }
    }
}

// MARK: - Suggestions

/// A suggested word on the feature card: click adds it; the context menu
/// can also dismiss it.
private struct CalmSuggestionHeroChip: View {
    let suggestion: CorrectionSuggestion

    @EnvironmentObject private var appState: AppState

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { appState.acceptDictionarySuggestion(suggestion) }
        } label: {
            CalmHeroChipLabel(suggestion.corrected)
        }
        .calmButton(.heroChip)
        .help(CalmDictionarySuggestionText.help(for: suggestion))
        .contextMenu {
            Button("Add “\(suggestion.corrected)”") { appState.acceptDictionarySuggestion(suggestion) }
            Button("Dismiss") { appState.dismissDictionarySuggestion(suggestion) }
        }
        .accessibilityLabel("Add \(suggestion.corrected)")
        .accessibilityAction(named: "Dismiss") { appState.dismissDictionarySuggestion(suggestion) }
    }
}

/// Shared wording for suggestions.
enum CalmDictionarySuggestionText {
    /// “You changed “cube or netties” to “Kubernetes” 3 times.”
    static func help(for suggestion: CorrectionSuggestion) -> String {
        let times = suggestion.occurrences > 1 ? " \(suggestion.occurrences) times" : ""
        return "You changed “\(suggestion.heard)” to “\(suggestion.corrected)”\(times)."
    }
}

/// Once the feature card is dismissed, suggestions show in this small
/// strip: each chip adds its word or dismisses it, and “See all” opens the
/// full list with what was heard.
private struct CalmDictionarySuggestedStrip: View {
    let onSeeAll: () -> Void

    @EnvironmentObject private var appState: AppState

    private static let chipLimit = 4

    var body: some View {
        let suggestions = appState.dictionarySuggestions
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Suggested").calmType(.rowTitle)
                Text("Words you fixed after dictating")
                    .font(CalmFont.description)
                    .foregroundStyle(CalmColor.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(suggestions.count > Self.chipLimit ? "See all \(suggestions.count)" : "See all", action: onSeeAll)
                    .calmLink(chevron: true)
            }
            HStack(spacing: 8) {
                ForEach(Array(suggestions.prefix(Self.chipLimit))) { suggestion in
                    CalmSuggestionChip(suggestion: suggestion)
                }
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, CalmMetrics.rowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .calmPanelBackground()
    }
}

/// A suggested word with add (the word and its plus) and dismiss (×).
private struct CalmSuggestionChip: View {
    let suggestion: CorrectionSuggestion

    @EnvironmentObject private var appState: AppState

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CalmMetrics.Radius.smallButton, style: .continuous)
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { appState.acceptDictionarySuggestion(suggestion) }
            } label: {
                HStack(spacing: 6) {
                    Text(suggestion.corrected).lineLimit(1)
                    CalmIcon(.plus, size: 12, weight: 2)
                }
                .font(CalmFont.buttonSmall)
                .foregroundStyle(CalmColor.ink)
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .frame(height: CalmMetrics.smallButtonHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(CalmPlainFocusStyle(radius: CalmMetrics.Radius.smallButton))
            .focusEffectDisabled()
            .help(CalmDictionarySuggestionText.help(for: suggestion))
            .accessibilityLabel("Add \(suggestion.corrected)")
            Button {
                withAnimation(.easeOut(duration: 0.18)) { appState.dismissDictionarySuggestion(suggestion) }
            } label: {
                CalmIcon(.close, size: 11, weight: 2)
            }
            .calmIconButton(size: 22)
            .padding(.trailing, 3)
            .help("Dismiss")
            .accessibilityLabel("Dismiss \(suggestion.corrected)")
        }
        .background(shape.fill(CalmColor.content))
        .overlay(shape.strokeBorder(CalmColor.line2, lineWidth: 1))
    }
}

// MARK: - List

/// The words and replacements for the current tab and search, or the
/// matching empty state.
private struct CalmDictionaryList: View {
    let filter: DictionaryListFilter
    let query: String
    let onEdit: (DictionaryListItem) -> Void
    let onClearSearch: () -> Void

    @EnvironmentObject private var appState: AppState

    var body: some View {
        let items = appState.dictionaryItems(filter: filter, query: query)
        if items.isEmpty {
            emptyState
        } else {
            CalmList {
                ForEach(items) { item in
                    CalmDictionaryRow(item: item) { onEdit(item) }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !query.isEmpty {
            CalmNoResults(message: "Nothing matches “\(query)”.", onClear: onClearSearch)
        } else {
            switch filter {
            case .all:
                CalmEmptyState(
                    icon: .dictionary, title: "Your dictionary is empty",
                    message: "Add names and jargon to spell your way, or a word a model keeps getting wrong."
                )
            case .words:
                CalmEmptyState(
                    icon: .dictionary, title: "No words yet",
                    message: "Add names, product words and jargon you want spelled exactly your way."
                )
            case .replacements:
                CalmEmptyState(
                    icon: .dictionary, title: "No replacements yet",
                    message: "When a model keeps hearing a word wrong, say what to type instead, like “get hub” → GitHub."
                )
            }
        }
    }
}

/// A word (“Priya Raman”) or a replacement (“btw → by the way”) with its
/// edit button. Clicking the row also edits it.
private struct CalmDictionaryRow: View {
    let item: DictionaryListItem
    let onEdit: () -> Void

    var body: some View {
        CalmListRow(padding: .compact, alignment: .center, alwaysShowsActions: true) {
            label
                .font(CalmFont.body)
                .foregroundStyle(CalmColor.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        } actions: {
            Button(action: onEdit) {
                CalmIcon(.edit, size: 15)
            }
            .calmIconButton()
            .help("Edit")
            .accessibilityLabel("Edit \(title)")
        }
        .onTapGesture(perform: onEdit)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var label: some View {
        switch item {
        case .word(let term):
            Text(term).lineLimit(2)
        case .replacement(let replacement):
            HStack(spacing: 8) {
                Text(replacement.heardForms.joined(separator: ", ")).lineLimit(2)
                CalmIcon(.arrowRight, size: 14)
                    .foregroundStyle(CalmColor.muted)
                    .accessibilityLabel("becomes")
                Text(replacement.replacement).lineLimit(2)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var title: String {
        switch item {
        case .word(let term): return term
        case .replacement(let replacement): return replacement.replacement
        }
    }
}

// MARK: - Vocabulary boost

/// Download, progress and removal of Parakeet's vocabulary boost model.
struct CalmVocabularyBoostRow: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        CalmRow("Vocabulary boost for Parakeet") {
            detail
        } trailing: {
            switch appState.vocabularyBoostStatus {
            case .notDownloaded:
                Button("Download (98 MB)") { appState.downloadVocabularyBoost() }.calmButton(.secondary)
            case .failed:
                Button("Try again") { appState.downloadVocabularyBoost() }.calmButton(.secondary)
            case .downloading:
                CalmSpinner()
            case .ready:
                Button("Remove") { appState.removeVocabularyBoost() }.calmButton(.secondary)
            }
        }
        .help("A small second model checks the audio for your vocabulary and fixes words Parakeet heard "
              + "far off (“in video” → NVIDIA). It adds a short pass after each dictation.")
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.vocabularyBoostStatus {
        case .notDownloaded:
            CalmRowDescription(text: "Helps Parakeet hear your words, not just spell them.")
        case .downloading:
            CalmRowDescription(text: "Downloading 98 MB…")
        case .ready:
            CalmRowDescription(text: "On. Parakeet listens for your vocabulary. Remove the 98 MB model to turn it off.")
        case .failed(let message):
            CalmInlineNotice("Download failed: \(message)", tone: .warning)
        }
    }
}
