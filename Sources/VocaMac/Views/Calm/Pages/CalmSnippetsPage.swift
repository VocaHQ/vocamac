// CalmSnippetsPage.swift
// VocaMac
//
// Snippets: the feature card with examples, a search behind the header's
// search button, the list of triggers and what they type, and the add /
// edit dialogs (`CalmSnippetEditor`).

import SwiftUI

/// Snippets: say a word, get the whole text.
struct CalmSnippetsPage: View {
    @EnvironmentObject private var appState: AppState

    @State private var isSearching = false
    @AppStorage(CalmFeatureCard<EmptyView>.storageKey("snippets")) private var isHeroDismissed = false
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool
    @State private var editor: CalmSnippetEditorRequest?

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var filteredSnippets: [Snippet] {
        let query = trimmedQuery
        guard !query.isEmpty else { return appState.snippets }
        return appState.snippets.filter {
            $0.trigger.localizedCaseInsensitiveContains(query) || $0.expansion.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        CalmPage(.list, spacing: 22) {
            CalmPageHeader("Snippets") {
                HStack(spacing: 8) {
                    if !appState.snippets.isEmpty { searchControl }
                    Button {
                        editor = .add
                    } label: {
                        CalmButtonLabel("Add new", icon: .plus)
                    }
                    .calmButton(.primary)
                }
            }
            if !isSearching {
                hero
            }
            list
                .settingsTarget("snippets")
        }
        .calmDialog(item: $editor) { request in
            CalmSnippetEditor(request: request)
        }
        // Deleting the last snippet hides the search button; leave search
        // too, or the page stays without its card and with no way back.
        .onChange(of: appState.snippets.isEmpty) { _, isEmpty in
            if isEmpty, isSearching { closeSearch() }
        }
    }

    // MARK: Search

    @ViewBuilder
    private var searchControl: some View {
        if isSearching {
            CalmSearchField(text: $query, prompt: "Search snippets", focus: $isSearchFocused, onEscapeWhenEmpty: closeSearch)
                .frame(width: 260)
                .onChange(of: isSearchFocused) { _, focused in
                    if !focused, query.isEmpty { closeSearch() }
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
        } else {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { isSearching = true }
                DispatchQueue.main.async { isSearchFocused = true }
            } label: {
                CalmIcon(.search, size: 17)
            }
            .calmIconButton()
            .help("Search snippets")
            .accessibilityLabel("Search snippets")
        }
    }

    private func closeSearch() {
        query = ""
        withAnimation(.easeOut(duration: 0.18)) { isSearching = false }
    }

    // MARK: Feature card

    private var hero: some View {
        CalmFeatureCard(
            dismissKey: "snippets",
            title: Text("Say a word, get the whole thing."),
            message: "Save text you type often, like an address, an intro or a standup template. "
                + "Say its name while dictating and VocaMac types the full text.",
            waveHeights: [50, 120, 80, 160, 70, 110, 40]
        ) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(CalmSnippetExample.all) { example in
                        CalmSnippetExampleRow(example: example)
                    }
                }
                .padding(.top, 2)
                Button("Add a snippet") { editor = .add }
                    .calmButton(.heroPrimary)
                    .padding(.top, 20)
            }
        }
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        let snippets = filteredSnippets
        if appState.snippets.isEmpty {
            // The feature card above says the same, with its own Add button.
            if isHeroDismissed {
                CalmEmptyState(
                    icon: .snippets, title: "No snippets yet",
                    message: "Save an email address, a sign-off or a link, and say its name to type it."
                )
            }
        } else if snippets.isEmpty {
            CalmNoResults(message: "No snippets match “\(trimmedQuery)”.") { query = "" }
        } else {
            CalmPagedList(snippets, resetKey: trimmedQuery) { snippet in
                CalmSnippetRow(snippet: snippet) { editor = .edit(snippet) }
            }
        }
    }
}

// MARK: - Examples

/// One example on the feature card: what you say and what VocaMac types.
private struct CalmSnippetExample: Identifiable {
    let say: String
    let types: String
    var id: String { say }

    static let all = [
        CalmSnippetExample(say: "my address", types: "221B Baker Street, London"),
        CalmSnippetExample(say: "standup", types: "Yesterday: … Today: … Blockers: …"),
        CalmSnippetExample(say: "intro email", types: "Hi, thanks for reaching out…"),
    ]
}

/// “my address” → 221B Baker Street, London as two hero pills.
private struct CalmSnippetExampleRow: View {
    let example: CalmSnippetExample

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CalmMetrics.Radius.button, style: .continuous)
        HStack(spacing: 10) {
            Text("“\(example.say)”")
                .font(CalmFont.sf(13.5, weight: 550).italic())
                .padding(.horizontal, 14)
                .frame(height: CalmMetrics.buttonHeight)
                .background(shape.fill(CalmColor.heroText.opacity(0.14)))
            CalmIcon(.arrowRight, size: 14)
                .opacity(0.7)
            Text(example.types)
                .font(.system(size: 13.5))
                .padding(.horizontal, 14)
                .frame(height: CalmMetrics.buttonHeight)
                .background(shape.fill(CalmColor.heroText.opacity(0.22)))
        }
        .lineLimit(1)
        .foregroundStyle(CalmColor.heroText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example: say “\(example.say)” to type \(example.types)")
    }
}

// MARK: - Row

/// A snippet: trigger (14/560), arrow, its text on one line in ink2, and
/// the edit button. Clicking the row also edits it.
private struct CalmSnippetRow: View {
    let snippet: Snippet
    let onEdit: () -> Void

    var body: some View {
        CalmListRow(padding: .compact, alignment: .center, alwaysShowsActions: true) {
            HStack(spacing: 16) {
                Text(snippet.trigger)
                    .font(CalmFont.rowTitle)
                    .foregroundStyle(CalmColor.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                CalmIcon(.arrowRight, size: 14)
                    .foregroundStyle(CalmColor.muted)
                    .accessibilityHidden(true)
                Text(DictionaryEditing.oneLine(snippet.expansion))
                    .font(CalmFont.body)
                    .foregroundStyle(CalmColor.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        } actions: {
            Button(action: onEdit) {
                CalmIcon(.edit, size: 15)
            }
            .calmIconButton()
            .help("Edit")
            .accessibilityLabel("Edit \(snippet.trigger)")
        }
        .onTapGesture(perform: onEdit)
    }
}
