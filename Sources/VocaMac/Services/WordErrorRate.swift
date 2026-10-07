// WordErrorRate.swift
// VocaMac
//
// Word error rate (WER) for comparing a transcript against a reference.

import Foundation

/// Word-level edit distance between a reference transcript and a hypothesis.
///
/// Used by the speech accuracy benchmark to catch regressions in decoding
/// options, silence trimming, or audio conversion. Text is normalized first
/// (see `normalizedWords(_:)`), so punctuation and capitalization, which
/// cleanup and formatting change anyway, never count as errors.
struct WordErrorRate: Equatable, Codable {
    /// Reference words replaced by a different word.
    var substitutions: Int
    /// Reference words missing from the hypothesis.
    var deletions: Int
    /// Hypothesis words with no reference word.
    var insertions: Int
    /// Words in the normalized reference.
    var referenceWords: Int

    /// Total edits needed to turn the hypothesis into the reference.
    var errors: Int { substitutions + deletions + insertions }

    /// Errors per reference word. An empty reference scores 0 when the
    /// hypothesis is empty too, and 1 per inserted word otherwise.
    var rate: Double {
        guard referenceWords > 0 else { return Double(insertions) }
        return Double(errors) / Double(referenceWords)
    }

    static let zero = WordErrorRate(substitutions: 0, deletions: 0, insertions: 0, referenceWords: 0)

    /// Sum of two measurements. Corpus WER is total errors over total
    /// reference words, not the mean of per-utterance rates, so long
    /// utterances weigh more than short ones.
    static func + (lhs: WordErrorRate, rhs: WordErrorRate) -> WordErrorRate {
        WordErrorRate(
            substitutions: lhs.substitutions + rhs.substitutions,
            deletions: lhs.deletions + rhs.deletions,
            insertions: lhs.insertions + rhs.insertions,
            referenceWords: lhs.referenceWords + rhs.referenceWords
        )
    }

    /// Measure `hypothesis` against `reference` after normalizing both.
    static func measure(reference: String, hypothesis: String) -> WordErrorRate {
        align(reference: normalizedWords(reference), hypothesis: normalizedWords(hypothesis))
    }

    /// Minimum-edit alignment of two word lists (Levenshtein over words).
    /// Ties prefer a substitution, then a deletion, then an insertion.
    static func align(reference: [String], hypothesis: [String]) -> WordErrorRate {
        let rows = reference.count
        let columns = hypothesis.count
        guard rows > 0 else {
            return WordErrorRate(substitutions: 0, deletions: 0, insertions: columns, referenceWords: 0)
        }
        guard columns > 0 else {
            return WordErrorRate(substitutions: 0, deletions: rows, insertions: 0, referenceWords: rows)
        }

        struct Cell { var cost: Int; var substitutions: Int; var deletions: Int; var insertions: Int }
        var previous = (0...columns).map { Cell(cost: $0, substitutions: 0, deletions: 0, insertions: $0) }
        var current = previous
        for row in 1...rows {
            current[0] = Cell(cost: row, substitutions: 0, deletions: row, insertions: 0)
            for column in 1...columns {
                let diagonal = previous[column - 1]
                if reference[row - 1] == hypothesis[column - 1] {
                    current[column] = diagonal
                    continue
                }
                var best = diagonal
                best.cost += 1
                best.substitutions += 1
                let up = previous[column]
                if up.cost + 1 < best.cost {
                    best = up
                    best.cost += 1
                    best.deletions += 1
                }
                let left = current[column - 1]
                if left.cost + 1 < best.cost {
                    best = left
                    best.cost += 1
                    best.insertions += 1
                }
                current[column] = best
            }
            swap(&previous, &current)
        }
        let result = previous[columns]
        return WordErrorRate(
            substitutions: result.substitutions,
            deletions: result.deletions,
            insertions: result.insertions,
            referenceWords: rows
        )
    }

    /// The words of `text` as compared for WER.
    ///
    /// Lowercased; curly quotes and apostrophes straightened; hyphens and
    /// slashes split words ("Wi-Fi" → "wi fi"); every other character that
    /// is not a letter, digit, or apostrophe ends a word ("3.5" → "3 5").
    /// Apostrophes stay inside a word ("don't") but not around one (a quoted
    /// 'word' loses its quotes). Numbers
    /// are not spelled out: "3" and "three" differ, so a corpus should
    /// write numbers the way the models are expected to.
    static func normalizedWords(_ text: String) -> [String] {
        var cleaned = ""
        cleaned.reserveCapacity(text.count)
        for character in text.lowercased() {
            switch character {
            case "\u{2018}", "\u{2019}", "\u{02BC}", "`":
                cleaned.append("'")
            case "-", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "/":
                cleaned.append(" ")
            default:
                // Everything else (punctuation, symbols, whitespace) ends a
                // word, so "end.Next" still reads as two words.
                let keeps = character.isLetter || character.isNumber || character == "'"
                cleaned.append(keeps ? character : " ")
            }
        }
        return cleaned
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }
}
