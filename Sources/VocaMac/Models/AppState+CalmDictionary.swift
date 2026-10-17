// AppState+CalmDictionary.swift
// VocaMac
//
// What the v3 Dictionary and Snippets pages need from the app's state: one
// list of vocabulary words and replacements to filter and search, checks
// for the add / edit dialogs, and edits that keep an item where it was.
// The pure rules live in `DictionaryEditing` so they can be tested without
// an `AppState`.

import Foundation

// MARK: - List items

/// One row of the Dictionary list: a vocabulary word or a replacement.
enum DictionaryListItem: Identifiable, Equatable {
    case word(String)
    case replacement(WordReplacement)

    var id: String {
        switch self {
        case .word(let term): return "word:\(term)"
        case .replacement(let replacement): return "replacement:\(replacement.id.uuidString)"
        }
    }
}

/// Which items the Dictionary list shows (the page's tabs).
enum DictionaryListFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case words
    case replacements

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .words: return "Words"
        case .replacements: return "Replacements"
        }
    }

    /// The tab a Settings search result points at, if it names one.
    static func forSearchTarget(_ target: String?) -> DictionaryListFilter? {
        switch target {
        case "vocabulary": return .words
        case "word-replacements": return .replacements
        default: return nil
        }
    }
}

/// What the add / edit dialogs make.
enum DictionaryEntryKind: String, Hashable, Sendable {
    case word
    case replacement
}

// MARK: - Checks

/// Whether a dialog's fields can be saved. Empty fields only disable the
/// primary button; a real problem also says why.
enum DictionaryEntryCheck: Equatable {
    case valid
    /// A required field is empty: no message, the button stays disabled.
    case incomplete
    /// Saving would clash with an existing item.
    case problem(String)

    var isValid: Bool { self == .valid }

    var message: String? {
        if case .problem(let message) = self { return message }
        return nil
    }
}

// MARK: - Rules

/// The Dictionary and Snippets rules, free of `AppState`.
enum DictionaryEditing {
    /// The list for a tab and a search: words first, then replacements, the
    /// newest of each on top. The search matches any part of a word, a
    /// spoken form or a replacement, ignoring case.
    static func items(
        terms: [String], replacements: [WordReplacement],
        filter: DictionaryListFilter, query: String
    ) -> [DictionaryListItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ text: String) -> Bool {
            query.isEmpty || text.localizedCaseInsensitiveContains(query)
        }
        var items: [DictionaryListItem] = []
        if filter != .replacements {
            items += terms.reversed().filter(matches).map(DictionaryListItem.word)
        }
        if filter != .words {
            items += replacements.reversed()
                .filter { matches($0.heard) || matches($0.replacement) }
                .map(DictionaryListItem.replacement)
        }
        return items
    }

    /// Checks a vocabulary word. `editing` is the word being changed, which
    /// may keep its spelling or change only its case. Commas and new lines
    /// separate words in the stored list, so “B, C” is two words and each
    /// is checked.
    static func checkWord(_ word: String, terms: [String], editing: String? = nil) -> DictionaryEntryCheck {
        let words = RecognitionHints.terms(from: word)
        guard !words.isEmpty else { return .incomplete }
        let clash = words.first { candidate in
            terms.contains { $0 != editing && $0.lowercased() == candidate.lowercased() }
        }
        return clash.map { .problem("“\($0)” is already in your dictionary.") } ?? .valid
    }

    /// Checks a replacement. A spoken form another replacement already
    /// answers to is a clash, since only one of them could win.
    static func checkReplacement(
        heard: String, replacement: String, existing: [WordReplacement], editing: UUID? = nil
    ) -> DictionaryEntryCheck {
        let candidate = WordReplacement(heard: heard, replacement: replacement)
        guard candidate.isValid else { return .incomplete }
        let others = existing.filter { $0.id != editing }
        // A new spoken form for text that already has a replacement is fine:
        // adding merges it in. Only a form that is already taken clashes.
        guard let clash = others.first(where: { WordReplacement.overlaps(candidate, $0) }) else { return .valid }
        let shared = candidate.heardForms.first { form in
            clash.heardForms.contains { $0.lowercased() == form.lowercased() }
        } ?? clash.heard
        return .problem("“\(shared)” already becomes “\(clash.replacement)”.")
    }

    /// Checks a snippet. Two snippets can't answer to the same trigger.
    static func checkSnippet(
        trigger: String, expansion: String, existing: [Snippet], editing: UUID? = nil
    ) -> DictionaryEntryCheck {
        let trimmedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTrigger.isEmpty,
              !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .incomplete }
        let candidate = Snippet(trigger: trimmedTrigger, expansion: expansion)
        let clashes = existing.contains { $0.id != editing && Snippet.sharesTrigger($0, candidate) }
        return clashes ? .problem("You already have a snippet called “\(trimmedTrigger)”.") : .valid
    }

    /// `terms` with `old` changed to `new` in the same place. A different
    /// copy of `new` elsewhere is dropped so the list stays unique.
    static func renaming(_ old: String, to new: String, in terms: [String]) -> [String] {
        // “B, C” becomes two words in the old one's place.
        let words = RecognitionHints.terms(from: new)
        guard !words.isEmpty, let index = terms.firstIndex(of: old) else { return terms }
        let lowered = Set(words.map { $0.lowercased() })
        var result = terms
        result.replaceSubrange(index...index, with: words)
        let placed = index..<(index + words.count)
        return result.enumerated()
            .filter { placed.contains($0.offset) || !lowered.contains($0.element.lowercased()) }
            .map(\.element)
    }

    /// A snippet's text on one line, for the list.
    static func oneLine(_ expansion: String) -> String {
        expansion
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: - AppState

extension AppState {
    /// The Dictionary list for a tab and a search.
    func dictionaryItems(filter: DictionaryListFilter, query: String) -> [DictionaryListItem] {
        DictionaryEditing.items(terms: vocabularyTerms, replacements: wordReplacements, filter: filter, query: query)
    }

    /// Whether the Dictionary shows the Parakeet vocabulary boost row: only
    /// with Parakeet selected, and once there is vocabulary (or the model is
    /// already on this Mac, so it can be removed).
    var showsVocabularyBoostOption: Bool {
        ModelSize(rawValue: selectedModelSize)?.engine == .parakeet
            && (!vocabularyTerms.isEmpty || vocabularyBoostStatus == .ready)
    }

    func checkVocabularyTerm(_ word: String, editing: String? = nil) -> DictionaryEntryCheck {
        DictionaryEditing.checkWord(word, terms: vocabularyTerms, editing: editing)
    }

    func checkWordReplacement(heard: String, replacement: String, editing: UUID? = nil) -> DictionaryEntryCheck {
        DictionaryEditing.checkReplacement(
            heard: heard, replacement: replacement, existing: wordReplacements, editing: editing
        )
    }

    func checkSnippet(trigger: String, expansion: String, editing: UUID? = nil) -> DictionaryEntryCheck {
        DictionaryEditing.checkSnippet(trigger: trigger, expansion: expansion, existing: snippets, editing: editing)
    }

    /// Change a vocabulary term in place, so the recognition hints (which
    /// keep the last terms) don't lose a different one.
    func renameVocabularyTerm(_ old: String, to new: String) {
        setVocabularyTerms(DictionaryEditing.renaming(old, to: new, in: vocabularyTerms))
    }

    /// Change a replacement's spoken forms and text, keeping its place.
    func updateWordReplacement(id: UUID, heard: String, replacement: String) {
        guard let index = wordReplacements.firstIndex(where: { $0.id == id }) else { return }
        let forms = WordReplacement(heard: heard, replacement: replacement).heardForms
        let text = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !forms.isEmpty, !text.isEmpty else { return }
        wordReplacements[index].heard = forms.joined(separator: ", ")
        wordReplacements[index].replacement = text
    }

    /// Add a snippet (`id` nil) or change one. The trigger is trimmed for
    /// matching; the text is kept as typed, since leading or trailing
    /// whitespace can be intentional formatting.
    func saveSnippet(id: UUID?, trigger: String, expansion: String) {
        let trimmedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTrigger.isEmpty, !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let id, let index = snippets.firstIndex(where: { $0.id == id }) {
            snippets[index].trigger = trimmedTrigger
            snippets[index].expansion = expansion
        } else {
            snippets.append(Snippet(trigger: trimmedTrigger, expansion: expansion))
        }
    }
}
