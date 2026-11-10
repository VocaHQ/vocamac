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

    /// Most records kept for terms no longer listed; the least recently
    /// used go first. A listed term's record is never dropped, since
    /// "not said in a while" reads it (`unused`).
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
            let listed = Set(terms.map { $0.lowercased() })
            let oldest = updated.filter { !listed.contains($0.key) }
                .sorted { $0.value.lastUsed < $1.value.lastUsed }
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

    // MARK: - Unused terms

    /// Days without a term turning up before the Dictionary offers to
    /// remove it.
    static let unusedAfterDays = 60

    /// `firstSeen` with today's date for each of `terms` it doesn't have
    /// yet, and without terms no longer listed. Keys are lowercased, like
    /// usage keys.
    ///
    /// When a term was added isn't stored, so its age counts from the first
    /// time VocaMac saw it listed. That is never earlier than when it was
    /// added, so a term is never called unused too soon.
    static func noting(
        _ terms: [String], in firstSeen: [String: Date], now: Date = Date()
    ) -> [String: Date] {
        let keys = Set(terms.map { $0.lowercased() }.filter { !$0.isEmpty })
        var updated = firstSeen.filter { keys.contains($0.key) }
        for key in keys where updated[key] == nil {
            updated[key] = now
        }
        return updated
    }

    /// The terms of `terms` neither dictated nor listed in the last `days`:
    /// the later of its last use and when it was (last) first seen listed is
    /// that long ago. A word removed and added again counts from its return,
    /// not its old use. A term with no record either way is left out.
    static func unused(
        _ terms: [String],
        usage: [String: TermUsage],
        firstSeen: [String: Date],
        now: Date = Date(),
        days: Int = unusedAfterDays
    ) -> [String] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var seen = Set<String>()
        return terms.filter { term in
            let key = term.lowercased()
            guard seen.insert(key).inserted,
                  let reference = [usage[key]?.lastUsed, firstSeen[key]].compactMap({ $0 }).max()
            else { return false }
            return reference <= cutoff
        }
    }

    static func decodeDates(_ stored: [String: Any]?) -> [String: Date] {
        guard let stored else { return [:] }
        var dates: [String: Date] = [:]
        for (key, value) in stored {
            if let seconds = value as? Double, seconds.isFinite {
                dates[key] = Date(timeIntervalSince1970: seconds)
            }
        }
        return dates
    }

    static func encodeDates(_ dates: [String: Date]) -> [String: Double] {
        dates.mapValues(\.timeIntervalSince1970)
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
