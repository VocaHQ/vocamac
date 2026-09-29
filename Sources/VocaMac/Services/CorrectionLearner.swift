// CorrectionLearner.swift
// VocaMac
//
// Works out which words a user corrected in text VocaMac typed, by comparing
// the field's contents right after the dictation with its contents later.
//
// Only spelling fixes count: a name spelled differently, a casing change, or
// words joined into one term. Rewording a sentence is the user writing, not a
// transcription mistake, and is ignored.

import Foundation

enum CorrectionLearner {

    struct Correction: Equatable {
        let heard: String
        let corrected: String
    }

    /// Longest edited region, in words, that is still treated as a fix
    /// rather than a rewrite.
    static let maximumEditedWords = 12

    /// Corrections the user made inside the dictated text.
    ///
    /// - Parameters:
    ///   - inserted: The text VocaMac typed.
    ///   - before: The field's text just after typing it.
    ///   - after: The field's text now.
    ///   - caretLocation: Caret position in `before`, used to find the right
    ///     copy of `inserted` when it appears more than once.
    ///   - isKnownWord: Whether a lowercase word is ordinary vocabulary.
    static func corrections(
        inserted: String,
        before: String,
        after: String,
        caretLocation: Int? = nil,
        isKnownWord: (String) -> Bool
    ) -> [Correction] {
        let dictated = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dictated.isEmpty, before != after else { return [] }
        let old = Array(before)
        let new = Array(after)
        guard let insertedRange = locate(Array(dictated), in: old, caretLocation: caretLocation) else { return [] }

        // The single region where the two texts differ.
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }

        // Widen to whole words so "Namratha" → "Namrata" compares whole names.
        while prefix > 0, isWordCharacter(old[prefix - 1]) { prefix -= 1 }
        while suffix > 0, isWordCharacter(old[old.count - suffix]) { suffix -= 1 }

        let oldChanged = prefix..<(old.count - suffix)
        let newChanged = prefix..<(new.count - suffix)
        guard oldChanged.overlaps(insertedRange) || (oldChanged.isEmpty && insertedRange.contains(prefix)) else {
            return []
        }
        // An edit reaching well outside the dictation is the user writing.
        guard oldChanged.lowerBound >= insertedRange.lowerBound - 1,
              oldChanged.upperBound <= insertedRange.upperBound + 1 else {
            return []
        }

        let oldWords = words(in: String(old[oldChanged]))
        let newWords = words(in: String(new[newChanged]))
        guard !oldWords.isEmpty, !newWords.isEmpty,
              oldWords.count <= maximumEditedWords, newWords.count <= maximumEditedWords else {
            return []
        }

        var found: [Correction] = []
        for block in substitutions(from: oldWords, to: newWords)
        where (1...3).contains(block.old.count) && (1...2).contains(block.new.count) {
            let heard = block.old.joined(separator: " ")
            let corrected = block.new.joined(separator: " ")
            if isLikelyCorrection(heard: heard, corrected: corrected, isKnownWord: isKnownWord) {
                found.append(Correction(heard: heard, corrected: corrected))
            }
        }
        return Array(found.prefix(3))
    }

    /// Whether changing `heard` to `corrected` looks like fixing a
    /// transcription (spelling, casing, joining) rather than rewording.
    static func isLikelyCorrection(heard: String, corrected: String, isKnownWord: (String) -> Bool) -> Bool {
        guard heard != corrected,
              corrected.count <= 40,
              corrected.contains(where: \.isLetter) else { return false }
        let heardKey = DictionaryCorrector.normalized(heard)
        let correctedKey = DictionaryCorrector.normalized(corrected)
        guard correctedKey.count >= 2, !heardKey.isEmpty else { return false }

        if heardKey == correctedKey {
            // Same letters: a casing or joining fix. Capitalizing an ordinary
            // word ("hello" → "Hello") is sentence case, not a new term.
            let isPlainCapitalization = corrected == corrected.prefix(1).uppercased() + corrected.dropFirst().lowercased()
                && !corrected.contains(" ")
            if isPlainCapitalization, isKnownWord(corrected.lowercased()) { return false }
            return true
        }

        // Swapping one ordinary word for another ("their" → "there") is a
        // grammar fix the dictionary can't help with.
        let correctedIsPlainLowercase = corrected == corrected.lowercased()
        if correctedIsPlainLowercase, corrected.split(separator: " ").allSatisfy({ isKnownWord(String($0)) }) {
            return false
        }

        guard DictionaryCorrector.firstSound(heardKey) == DictionaryCorrector.firstSound(correctedKey) else {
            return false
        }
        let distance = DictionaryCorrector.levenshtein(heardKey, correctedKey)
        let ratio = Double(distance) / Double(max(heardKey.count, correctedKey.count))
        return ratio <= 0.4
    }

    // MARK: - Private

    /// Where `needle` sits in `haystack`, preferring the copy ending nearest
    /// the caret (the one just typed).
    private static func locate(_ needle: [Character], in haystack: [Character], caretLocation: Int?) -> Range<Int>? {
        guard needle.count <= haystack.count else { return nil }
        var ranges: [Range<Int>] = []
        var start = 0
        while start + needle.count <= haystack.count {
            if haystack[start] == needle[0], Array(haystack[start..<(start + needle.count)]) == needle {
                ranges.append(start..<(start + needle.count))
                start += needle.count
            } else {
                start += 1
            }
        }
        guard let caretLocation else { return ranges.last }
        return ranges.min { abs($0.upperBound - caretLocation) < abs($1.upperBound - caretLocation) }
    }

    private static func words(in text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'’-_."))) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
    }

    /// Runs of words that were replaced, from a longest-common-subsequence
    /// alignment of the two word lists.
    private static func substitutions(from old: [String], to new: [String]) -> [(old: [String], new: [String])] {
        var table = [[Int]](repeating: [Int](repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var blocks: [(old: [String], new: [String])] = []
        var pendingOld: [String] = []
        var pendingNew: [String] = []
        func flush() {
            if !pendingOld.isEmpty && !pendingNew.isEmpty {
                blocks.append((pendingOld, pendingNew))
            }
            pendingOld = []
            pendingNew = []
        }

        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, j < new.count, old[i] == new[j] {
                flush()
                i += 1
                j += 1
            } else if j < new.count, i == old.count || table[i][j + 1] >= table[i + 1][j] {
                pendingNew.append(new[j])
                j += 1
            } else {
                pendingOld.append(old[i])
                i += 1
            }
        }
        flush()
        return blocks
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "'" || character == "’"
    }
}
