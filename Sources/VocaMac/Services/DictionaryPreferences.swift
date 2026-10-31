// DictionaryPreferences.swift
// VocaMac
//
// The Dictionary as stored in VocaMac's preferences, readable and writable
// from outside the app (the MCP server runs in its own process). The app
// keeps the same keys in `AppState`; a write from here posts a distributed
// notification so a running app reloads them.

import Foundation

/// Reads and writes the vocabulary terms and replacements in one
/// preferences domain. Value type: every call goes to `defaults`.
struct DictionaryPreferences {
    /// Posted (distributed) after another process changed the Dictionary.
    static let externalChangeNotification = Notification.Name("com.vocamac.dictionary.externalChange")

    /// The same keys `AppState` stores under.
    static let vocabularyKey = "vocamac.customVocabulary"
    static let replacementsKey = PreferenceKey.wordReplacements

    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: - Reading

    /// Vocabulary terms in the order the user gave them, first spelling wins.
    var vocabularyTerms: [String] {
        RecognitionHints.terms(from: defaults.string(forKey: Self.vocabularyKey) ?? "")
    }

    var replacements: [WordReplacement] {
        guard let data = defaults.data(forKey: Self.replacementsKey),
              let decoded = try? JSONDecoder().decode([WordReplacement].self, from: data) else { return [] }
        return decoded
    }

    // MARK: - Writing

    /// What adding a term changed, for the caller to report.
    struct AddResult: Equatable {
        var addedTerm: Bool
        var addedReplacement: Bool
    }

    /// Add `term` to the vocabulary (replacing a differently-cased copy), and
    /// when `heard` is given and differs from `term` in more than case and
    /// spacing, a replacement from `heard` to `term` — the same thing
    /// accepting a suggestion does in the app.
    @discardableResult
    func add(term rawTerm: String, heard rawHeard: String?) throws -> AddResult {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { throw DictionaryPreferencesError.emptyTerm }
        guard !term.contains(where: { $0 == "\n" || $0 == "," }) else {
            throw DictionaryPreferencesError.termHasSeparator
        }

        var result = AddResult(addedTerm: false, addedReplacement: false)
        var terms = vocabularyTerms
        if !terms.contains(term) {
            terms.removeAll { $0.lowercased() == term.lowercased() }
            terms.append(term)
            defaults.set(terms.joined(separator: "\n"), forKey: Self.vocabularyKey)
            result.addedTerm = true
        }

        let heard = rawHeard?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !heard.isEmpty, Self.spellingKey(heard) != Self.spellingKey(term) {
            var replacements = self.replacements
            if let index = replacements.firstIndex(where: { $0.replacement == term }) {
                let forms = replacements[index].heardForms
                if !forms.contains(where: { $0.lowercased() == heard.lowercased() }) {
                    replacements[index].heard = (forms + [heard]).joined(separator: ", ")
                    result.addedReplacement = true
                }
            } else {
                replacements.append(WordReplacement(heard: heard, replacement: term))
                result.addedReplacement = true
            }
            if result.addedReplacement {
                defaults.set(try JSONEncoder().encode(replacements), forKey: Self.replacementsKey)
            }
        }
        return result
    }

    /// Letters only, lowercased: "voca mac" and "VocaMac" spell the same.
    static func spellingKey(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Tell a running VocaMac that the Dictionary changed under it.
    static func postExternalChange() {
        DistributedNotificationCenter.default().postNotificationName(
            externalChangeNotification, object: nil, userInfo: nil, deliverImmediately: true
        )
    }
}

enum DictionaryPreferencesError: LocalizedError, Equatable {
    case emptyTerm
    case termHasSeparator

    var errorDescription: String? {
        switch self {
        case .emptyTerm: return "The term is empty."
        case .termHasSeparator: return "A term can't contain a comma or a new line; add each term on its own."
        }
    }
}
