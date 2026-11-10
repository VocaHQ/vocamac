// TermUsage.swift
// VocaMac
//
// How often, and how recently, each dictionary term turns up in what the
// user dictates.
//
// Engines take only so many hints: Whisper's prompt holds about 40 terms
// and drops from the front, Qwen3-ASR takes 20, an endpoint's glossary 600
// characters. With automatic learning on, the list grows by itself, and in
// the order terms were added the oldest fall out first even when they are
// the ones the user says every day. Ordering by use keeps the words the
// user actually says at the end, where every engine keeps them.

import Foundation

struct TermUsage: Equatable, Sendable {
    /// Dictations the term appeared in.
    var count: Int
    /// The latest of them.
    var lastUsed: Date

    /// As stored: [count, seconds since 1970].
    var stored: [Double] { [Double(count), lastUsed.timeIntervalSince1970] }

    init(count: Int, lastUsed: Date) {
        self.count = count
        self.lastUsed = lastUsed
    }

    init?(stored: [Double]) {
        guard stored.count == 2, stored[0] >= 1, stored[1].isFinite else { return nil }
        self.init(count: Int(stored[0]), lastUsed: Date(timeIntervalSince1970: stored[1]))
    }

    static func decode(_ stored: [String: Any]?) -> [String: TermUsage] {
        guard let stored else { return [:] }
        var usage: [String: TermUsage] = [:]
        for (key, value) in stored {
            if let numbers = value as? [Double], let entry = TermUsage(stored: numbers) {
                usage[key] = entry
            }
        }
        return usage
    }

    static func encode(_ usage: [String: TermUsage]) -> [String: [Double]] {
        usage.mapValues(\.stored)
    }

    /// Most terms remembered; the least recently used go first.
    static let maximumEntries = 500

    /// `usage` with every term of `terms` found in `text` counted once more.
    static func recording(
        _ text: String, terms: [String], in usage: [String: TermUsage], now: Date = Date()
    ) -> [String: TermUsage] {
        guard !text.isEmpty else { return usage }
        var updated = usage
        var seen = Set<String>()
        for term in terms {
            let key = term.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted, contains(term, in: text) else { continue }
            let count = (updated[key]?.count ?? 0) + 1
            updated[key] = TermUsage(count: count, lastUsed: now)
        }
        if updated.count > maximumEntries {
            let oldest = updated.sorted { $0.value.lastUsed < $1.value.lastUsed }
                .prefix(updated.count - maximumEntries).map(\.key)
            for key in oldest { updated.removeValue(forKey: key) }
        }
        return updated
    }

    /// Whether `term` appears in `text` as a whole word, ignoring case.
    static func contains(_ term: String, in text: String) -> Bool {
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: term, options: [.caseInsensitive], range: searchRange) {
            let before = found.lowerBound == text.startIndex ? nil : text[text.index(before: found.lowerBound)]
            let after = found.upperBound == text.endIndex ? nil : text[found.upperBound]
            if !isWordCharacter(before), !isWordCharacter(after) { return true }
            searchRange = text.index(after: found.lowerBound)..<text.endIndex
        }
        return false
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }

    /// `terms` reordered for hints that keep their end: never-used terms
    /// first in their listed order, then used ones from least to most
    /// recently used, so the words said lately are the last to be dropped.
    static func ordered(_ terms: [String], by usage: [String: TermUsage]) -> [String] {
        guard !usage.isEmpty else { return terms }
        let indexed = Array(terms.enumerated())
        let unused = indexed.filter { usage[$0.element.lowercased()] == nil }.map(\.element)
        let used = indexed.compactMap { entry -> (Int, String, Date)? in
            guard let record = usage[entry.element.lowercased()] else { return nil }
            return (entry.offset, entry.element, record.lastUsed)
        }
        .sorted { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 < $1.2 }
        .map(\.1)
        return unused + used
    }
}
