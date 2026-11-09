// WordErrorRate.swift
// VocaMac
//
// Word error rate (WER) for comparing a transcript against a reference.

import Foundation

/// Word-level edit distance between a reference transcript and a hypothesis.
///
/// Used by the speech accuracy benchmark to catch regressions in decoding
/// options, silence trimming, or audio conversion. Text is normalized first
/// (see `normalizedWords(_:)`), so punctuation, capitalization and how a
/// number is written, which cleanup and formatting change anyway, never
/// count as errors. For scripts written without spaces the same counts are
/// taken over characters instead (`measureCharacters`, CER).
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
    /// slashes split words ("Wi-Fi" → "wi fi"); a comma between digits is a
    /// thousands separator ("1,000" → "1000"); "%" reads as "percent"; every
    /// other character that is not a letter, digit, or apostrophe ends a word
    /// ("3.5" → "3 5"). Apostrophes stay inside a word ("don't") but not
    /// around one (a quoted 'word' loses its quotes).
    ///
    /// With `foldsNumbers` (the default), English number words become digits
    /// (`NumberFolding`), so "three" and "3", "twenty one" and "21", and
    /// "three point five" and "3.5" score as the same words: engines and
    /// cleanup differ in how they write numbers, and that is not a
    /// recognition error.
    static func normalizedWords(_ text: String, foldsNumbers: Bool = true) -> [String] {
        let words = surfaceWords(text).map { $0.text.lowercased() }
        return foldsNumbers ? NumberFolding.fold(words) : words
    }

    /// One word of a text as written: its spelling (case kept), whether it
    /// starts with a capital, and the sentence punctuation right after it.
    struct SurfaceWord: Equatable {
        var text: String
        /// The first `.`, `,`, `?`, `!`, `:` or `;` between this word and the
        /// next, if any.
        var trailingMark: Character?
        var isCapitalized: Bool {
            text.first.map { $0.isUppercase } ?? false
        }
    }

    /// The marks `SurfaceWord.trailingMark` records.
    static let sentenceMarks: Set<Character> = [".", ",", "?", "!", ":", ";"]

    /// The words of `text` split exactly as `normalizedWords` splits them,
    /// with case and trailing punctuation kept for formatting metrics.
    static func surfaceWords(_ text: String) -> [SurfaceWord] {
        let characters = Array(text)
        var words: [SurfaceWord] = []
        var current = ""
        func finish() {
            let trimmed = current.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            if !trimmed.isEmpty { words.append(SurfaceWord(text: trimmed, trailingMark: nil)) }
            current = ""
        }
        for (index, character) in characters.enumerated() {
            switch character {
            case "\u{2018}", "\u{2019}", "\u{02BC}", "`", "'":
                current.append("'")
            case "-", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "/":
                finish()
            case "%":
                finish()
                words.append(SurfaceWord(text: "percent", trailingMark: nil))
            case ",":
                // "1,000": a thousands separator, not a break.
                let between = index > 0 && index + 1 < characters.count
                    && characters[index - 1].isNumber && characters[index + 1].isNumber
                if between, !current.isEmpty { continue }
                finish()
                markLast(&words, character)
            default:
                if character.isLetter || character.isNumber {
                    current.append(character)
                } else {
                    finish()
                    if sentenceMarks.contains(character) { markLast(&words, character) }
                }
            }
        }
        finish()
        return words
    }

    private static func markLast(_ words: inout [SurfaceWord], _ mark: Character) {
        guard let last = words.indices.last, words[last].trailingMark == nil else { return }
        words[last].trailingMark = mark
    }

    // MARK: - Characters

    /// What an error rate counts: words, or characters for scripts written
    /// without spaces between words.
    enum Unit: String, Codable {
        case words
        case characters
    }

    /// Characters for text mostly in a script written without spaces (Chinese,
    /// Japanese, Thai, Lao, Khmer, Burmese), where a "word" split on spaces is
    /// a whole sentence and WER says nothing. Words otherwise.
    static func unit(for text: String) -> Unit {
        var letters = 0
        var unspaced = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if isUnspacedScript(scalar) { unspaced += 1 }
        }
        return letters > 0 && unspaced * 2 > letters ? .characters : .words
    }

    /// Measure in `unit`, or in the unit the reference calls for.
    static func measure(reference: String, hypothesis: String, unit: Unit) -> WordErrorRate {
        switch unit {
        case .words: return measure(reference: reference, hypothesis: hypothesis)
        case .characters: return measureCharacters(reference: reference, hypothesis: hypothesis)
        }
    }

    /// Character error rate (CER): the same edit distance over characters.
    /// `referenceWords` then counts reference characters. Case, spaces and
    /// punctuation are ignored, as they are for words.
    static func measureCharacters(reference: String, hypothesis: String) -> WordErrorRate {
        align(reference: characterUnits(reference), hypothesis: characterUnits(hypothesis))
    }

    /// The letters and digits of `text`, lowercased, one per element.
    static func characterUnits(_ text: String) -> [String] {
        text.lowercased().compactMap { character in
            character.isLetter || character.isNumber ? String(character) : nil
        }
    }

    private static func isUnspacedScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return true // kana
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F: return true // Han
        case 0x0E00...0x0EFF: return true // Thai, Lao
        case 0x1000...0x109F, 0x1780...0x17FF: return true // Burmese, Khmer
        default: return false
        }
    }
}
