// DictationEditLearning.swift
// VocaMac
//
// What the user's edits to a dictation teach beyond spellings: the dictation
// as it reads once they're done (kept in History), words they delete every
// time, and an app where they always start in lowercase. Pure functions of
// the two readings `CorrectionObserver` takes; the decisions live here so
// they can be tested without a field to read.

import Foundation

/// A dictation read back from the field it was typed into.
struct DictationEditObservation {
    /// The dictated text as typed, trimmed.
    let inserted: String
    /// The dictated text as it reads now: `inserted` when the user left it
    /// alone, nil when an edit reached outside it, so it can't be told apart
    /// from the user's own writing.
    let editedText: String?
    /// The character before the dictation in the field, spaces skipped; nil
    /// at the start of the field.
    let precedingCharacter: Character?
    /// The History entry for this dictation, when History keeps it.
    var historyID: UUID?
    /// The app the dictation was typed into.
    var app: RunningAppSnapshot?

    /// Whether the user changed the dictation, beyond surrounding spaces.
    var wasEdited: Bool {
        guard let editedText else { return false }
        return editedText != inserted
    }
}

/// Works out the dictation as it now reads from two readings of a field.
enum DictationEditReader {

    /// The dictated text after the user's edits, and the character before it.
    ///
    /// Typing before or after the dictation (the user carrying on writing)
    /// leaves it as dictated. An edit that starts inside it and spills more
    /// than a character past either end can't be pinned to the dictation, so
    /// its edited text is unknown (nil). So is a dictation that is gone: the
    /// field was cleared (a chat message sent with Return) or what is left
    /// shares too little with it to be an edit of it (`isStillDictation`).
    ///
    /// - Returns: Nil when the dictation isn't in `before` at all.
    static func read(
        inserted: String, before: String, after: String, caretLocation: Int? = nil
    ) -> (editedText: String?, precedingCharacter: Character?)? {
        let dictated = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dictated.isEmpty else { return nil }
        let old = Array(before)
        let new = Array(after)
        guard let range = CorrectionLearner.locate(Array(dictated), in: old, caretLocation: caretLocation) else {
            return nil
        }
        let preceding = old[..<range.lowerBound].last { $0 != " " && $0 != "\t" }
        guard before != after else { return (dictated, preceding) }
        guard !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (nil, preceding) }

        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        let changed = prefix..<(old.count - suffix)
        // A pure insertion counts only strictly inside the dictation: at
        // either end it is the user writing next to it.
        let touches = changed.isEmpty
            ? prefix > range.lowerBound && prefix < range.upperBound
            : changed.overlaps(range)
        guard touches else { return (dictated, preceding) }
        guard changed.lowerBound >= range.lowerBound - 1, changed.upperBound <= range.upperBound + 1 else {
            return (nil, preceding)
        }
        let start = min(range.lowerBound, changed.lowerBound)
        let end = max(range.upperBound, changed.upperBound) + (new.count - old.count)
        guard start <= end, end <= new.count else { return (nil, preceding) }
        let edited = String(new[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (isStillDictation(edited, of: dictated) ? edited : nil, preceding)
    }

    /// Whether `edited` is still the dictation, edited, rather than what
    /// replaced it after it was sent or deleted: half of a longer
    /// dictation's words are still there, or a short one is still spelled
    /// mostly the same ("Pria" → "Priya", not "hello there" → "ok").
    static func isStillDictation(_ edited: String, of dictated: String) -> Bool {
        let words = { (text: String) in
            text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }.map(String.init)
        }
        let dictatedWords = words(dictated)
        let editedWords = words(edited)
        guard !editedWords.isEmpty else { return false }
        if dictatedWords.count >= 4 {
            var remaining = Dictionary(editedWords.map { ($0, 1) }, uniquingKeysWith: +)
            var kept = 0
            for word in dictatedWords where remaining[word, default: 0] > 0 {
                remaining[word, default: 0] -= 1
                kept += 1
            }
            return kept * 2 >= dictatedWords.count
        }
        let a = dictatedWords.joined(separator: " ")
        let b = editedWords.joined(separator: " ")
        let distance = DictionaryCorrector.levenshtein(a, b)
        return Double(distance) <= Double(max(a.count, b.count)) * 0.5
    }
}

// MARK: - Personal fillers

/// Words a user keeps deleting from their dictations, removed for them once
/// they have done it often enough (`AppState.personalFillerDeletionsToLearn`).
///
/// Only discourse markers can be learned. Deleting "the" three times while
/// rewording must not make every "the" vanish, so a closed list decides what
/// is a filler at all; the user's deletions only decide which of them they
/// don't want.
enum PersonalFillers {

    /// Removed wherever they stand alone: they rarely carry the meaning.
    static let anywhere: Set<String> = [
        "basically", "actually", "literally", "honestly", "totally", "essentially",
        "obviously", "seriously", "definitely", "anyway", "anyways", "apparently",
    ]

    /// Real words as often as fillers ("I like it", "it works well, thanks",
    /// "turn right, then left"), so only removed where they open a sentence
    /// and a comma follows: "So, we ship Friday", "Like, it was huge".
    static let commaBound: Set<String> = [
        "like", "right", "well", "so", "okay", "ok", "yeah", "just", "really", "alright",
        "you know", "i mean", "kind of", "sort of",
    ]

    static var learnable: Set<String> { anywhere.union(commaBound) }

    /// Fillers the user deleted from `dictated` to get `edited`.
    ///
    /// Counts only an edit that deletes and does nothing else (beyond the
    /// case of the next word), and deletes at most four words: rewording a
    /// sentence also deletes words, and those say nothing about fillers.
    ///
    /// - Parameter isExcluded: Words never learned, such as Dictionary terms.
    static func deletions(dictated: String, edited: String, isExcluded: (String) -> Bool = { _ in false }) -> [String] {
        let old = words(in: dictated)
        let new = words(in: edited)
        guard !old.isEmpty, old.count > new.count, old.count - new.count <= 4 else { return [] }
        // Every remaining word must line up, in order: nothing was added.
        var deleted: [[String]] = []
        var run: [String] = []
        var j = 0
        for word in old {
            if j < new.count, new[j] == word {
                if !run.isEmpty { deleted.append(run); run = [] }
                j += 1
            } else {
                run.append(word)
            }
        }
        if !run.isEmpty { deleted.append(run) }
        guard j == new.count else { return [] }

        var found: [String] = []
        for block in deleted {
            let phrase = block.joined(separator: " ")
            guard learnable.contains(phrase), !isExcluded(phrase), !found.contains(phrase) else { continue }
            found.append(phrase)
        }
        return found
    }

    /// `text` without the learned fillers, with the punctuation they leave
    /// behind repaired (see `WritingStyleEngine.removeWordRuns`).
    static func remove(_ fillers: [String], from text: String) -> (text: String, removed: Int) {
        let wanted = fillers.map { $0.lowercased() }.filter { learnable.contains($0) }
        guard !wanted.isEmpty, !text.isEmpty else { return (text, 0) }
        let alternatives = wanted.sorted { $0.count > $1.count }
            .map { $0.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[ \\t]+") }
            .joined(separator: "|")
        guard let expression = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}'’])("# + alternatives + #")(?![\p{L}\p{N}'’])([,.!?;:…]*)"#,
            options: [.caseInsensitive]
        ) else { return (text, 0) }
        let ns = text as NSString
        let ranges = expression.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match -> NSRange? in
            let word = ns.substring(with: match.range(at: 1)).lowercased()
                .split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            if anywhere.contains(word) { return match.range }
            // Opening a sentence, a comma right after it: "So, we".
            guard ns.substring(with: match.range(at: 2)).hasPrefix(",") else { return nil }
            var before = match.range.location - 1
            while before >= 0, let scalar = UnicodeScalar(ns.character(at: before)),
                  scalar == " " || scalar == "\t" || scalar == "\"" || scalar == "“" {
                before -= 1
            }
            guard before >= 0, let scalar = UnicodeScalar(ns.character(at: before)) else { return match.range }
            return ".!?…\n\r".unicodeScalars.contains(scalar) ? match.range : nil
        }
        guard !ranges.isEmpty else { return (text, 0) }
        let result = WritingStyleEngine.removeWordRuns(ranges, from: text)
        return (result.trimmingCharacters(in: .whitespaces), ranges.count)
    }

    /// Lowercased words, punctuation trimmed, apostrophes kept.
    static func words(in text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'"))) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { words, word in
                // "you know" and the like are compared as one phrase.
                if let last = words.last, PersonalFillers.commaBound.contains("\(last) \(word)") {
                    words[words.count - 1] = "\(last) \(word)"
                } else {
                    words.append(word)
                }
            }
    }
}

// MARK: - Lowercase starts

/// An app where the user lowercases the first letter of what VocaMac types.
enum LearnedCasing {

    /// Whether the user's edit only lowercased the dictation's first letter,
    /// where it started a message rather than continued a sentence.
    ///
    /// A dictation that follows a word or a comma starts mid-sentence: a
    /// capital there is a joining mistake, not the app's style, so it isn't
    /// counted.
    static func lowercasedStart(dictated: String, edited: String?, precedingCharacter: Character?) -> Bool {
        guard let edited, let first = dictated.first, first.isUppercase,
              let editedFirst = edited.first, editedFirst.isLowercase,
              String(first).lowercased() == String(editedFirst),
              dictated.dropFirst() == edited.dropFirst() else { return false }
        if let precedingCharacter, !".!?\n\r".contains(precedingCharacter) { return false }
        return true
    }

    /// `text` with its first letter lowercased, when that is safe: the first
    /// word is an ordinary word (`isKnownWord`, lowercased) with no other
    /// capitals. "I", names, and acronyms keep their capitals.
    static func lowercasingStart(_ text: String, isKnownWord: (String) -> Bool) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        let word = String(text.prefix { $0.isLetter || $0 == "'" || $0 == "’" })
        let core = word.split(whereSeparator: { $0 == "'" || $0 == "’" }).first.map(String.init) ?? word
        guard core.count >= 2, core.dropFirst().allSatisfy(\.isLowercase),
              isKnownWord(core.lowercased()) else { return text }
        return String(first).lowercased() + text.dropFirst()
    }
}

/// One app the user starts in lowercase, learned from their edits.
struct LearnedLowercaseApp: Codable, Identifiable, Hashable {
    var id: String
    var displayName: String
    var bundleIdentifier: String?
    var processName: String?

    init(snapshot: RunningAppSnapshot) {
        id = snapshot.bundleIdentifier ?? snapshot.processName ?? snapshot.displayName
        displayName = snapshot.displayName
        bundleIdentifier = snapshot.bundleIdentifier
        processName = snapshot.processName
    }

    func matches(_ snapshot: RunningAppSnapshot) -> Bool {
        AppIdentityMatching.matches(
            configuredBundleIdentifier: bundleIdentifier, configuredProcessName: processName,
            configuredID: id, snapshot: snapshot
        )
    }
}

extension ResolvedWritingStyle {
    /// The same style, its rules untouched, starting in lowercase.
    func startingInLowercase() -> ResolvedWritingStyle {
        var copy = self
        copy.startsInLowercase = true
        return copy
    }
}
