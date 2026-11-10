// TranscriptScoring.swift
// VocaMac
//
// Accuracy measures beyond the error rate: dropped first and last words,
// punctuation and capitalization, and whether Dictionary terms came through.

import Foundation

/// Scores a transcript against a reference for the accuracy harness
/// (`SpeechAccuracyBenchmarkTests`). Every result is a set of counts that
/// add up across a corpus, like `WordErrorRate`.
enum TranscriptScoring {

    // MARK: - Alignment

    /// One step of a minimum-edit alignment, by word index.
    enum Step: Equatable {
        case match(reference: Int, hypothesis: Int)
        case substitution(reference: Int, hypothesis: Int)
        case deletion(reference: Int)
        case insertion(hypothesis: Int)
    }

    /// The minimum-edit alignment of two word lists, in order. Ties are
    /// broken as `WordErrorRate.align` breaks them, so the steps count the
    /// same substitutions, deletions and insertions.
    static func alignment(reference: [String], hypothesis: [String]) -> [Step] {
        let rows = reference.count
        let columns = hypothesis.count
        // Direction codes: 0 match, 1 substitution, 2 deletion (up), 3 insertion (left).
        var cost = [Int32](repeating: 0, count: (rows + 1) * (columns + 1))
        var direction = [UInt8](repeating: 0, count: (rows + 1) * (columns + 1))
        func at(_ row: Int, _ column: Int) -> Int { row * (columns + 1) + column }
        for row in stride(from: 1, through: rows, by: 1) {
            cost[at(row, 0)] = Int32(row)
            direction[at(row, 0)] = 2
        }
        for column in stride(from: 1, through: columns, by: 1) {
            cost[at(0, column)] = Int32(column)
            direction[at(0, column)] = 3
        }
        if rows > 0, columns > 0 {
            for row in 1...rows {
                for column in 1...columns {
                    if reference[row - 1] == hypothesis[column - 1] {
                        cost[at(row, column)] = cost[at(row - 1, column - 1)]
                        direction[at(row, column)] = 0
                        continue
                    }
                    var best = cost[at(row - 1, column - 1)] + 1
                    var step: UInt8 = 1
                    if cost[at(row - 1, column)] + 1 < best {
                        best = cost[at(row - 1, column)] + 1
                        step = 2
                    }
                    if cost[at(row, column - 1)] + 1 < best {
                        best = cost[at(row, column - 1)] + 1
                        step = 3
                    }
                    cost[at(row, column)] = best
                    direction[at(row, column)] = step
                }
            }
        }
        var steps: [Step] = []
        var row = rows
        var column = columns
        while row > 0 || column > 0 {
            switch direction[at(row, column)] {
            case 0 where row > 0 && column > 0:
                steps.append(.match(reference: row - 1, hypothesis: column - 1))
                row -= 1
                column -= 1
            case 1 where row > 0 && column > 0:
                steps.append(.substitution(reference: row - 1, hypothesis: column - 1))
                row -= 1
                column -= 1
            case 2 where row > 0:
                steps.append(.deletion(reference: row - 1))
                row -= 1
            default:
                steps.append(.insertion(hypothesis: column - 1))
                column -= 1
            }
        }
        return steps.reversed()
    }

    // MARK: - Edge words

    /// Reference words lost at the very start and end of a transcript: what
    /// a late microphone start or an early stop costs. Insertions at an edge
    /// are skipped over; a substituted word is a misheard word, not a drop.
    struct EdgeWords: Equatable, Codable {
        /// Reference words deleted before the first word that came through.
        var leadingDropped: Int
        /// Reference words deleted after the last word that came through.
        var trailingDropped: Int
        var firstWordDropped: Bool { leadingDropped > 0 }
        var lastWordDropped: Bool { trailingDropped > 0 }
    }

    static func edgeWords(reference: String, hypothesis: String) -> EdgeWords {
        let steps = alignment(
            reference: WordErrorRate.normalizedWords(reference),
            hypothesis: WordErrorRate.normalizedWords(hypothesis)
        )
        return EdgeWords(leadingDropped: leadingDeletions(steps), trailingDropped: leadingDeletions(steps.reversed()))
    }

    private static func leadingDeletions<S: Sequence>(_ steps: S) -> Int where S.Element == Step {
        var count = 0
        for step in steps {
            switch step {
            case .deletion: count += 1
            case .insertion: continue
            case .match, .substitution: return count
            }
        }
        // Nothing came through at all. That is an empty transcript, which
        // the harness counts on its own, not a clipped edge.
        return 0
    }

    // MARK: - Punctuation and capitalization

    /// Precision and recall of one kind of mark over the words both texts
    /// share.
    struct MarkAgreement: Equatable, Codable {
        /// Shared words the reference marks.
        var referenceMarks = 0
        /// Shared words the hypothesis marks.
        var hypothesisMarks = 0
        /// Shared words both mark the same way.
        var agreements = 0

        var precision: Double? { hypothesisMarks == 0 ? nil : Double(agreements) / Double(hypothesisMarks) }
        var recall: Double? { referenceMarks == 0 ? nil : Double(agreements) / Double(referenceMarks) }
        /// `nil` only when neither text marks a shared word, so there is
        /// nothing to score. Marks on one side with no agreement score 0, so
        /// a transcript that misses every mark is not hidden as "n/a".
        var f1: Double? {
            guard referenceMarks > 0 || hypothesisMarks > 0 else { return nil }
            guard agreements > 0, let precision, let recall else { return 0 }
            return 2 * precision * recall / (precision + recall)
        }

        static func + (lhs: MarkAgreement, rhs: MarkAgreement) -> MarkAgreement {
            MarkAgreement(
                referenceMarks: lhs.referenceMarks + rhs.referenceMarks,
                hypothesisMarks: lhs.hypothesisMarks + rhs.hypothesisMarks,
                agreements: lhs.agreements + rhs.agreements
            )
        }
    }

    /// How the hypothesis punctuates and capitalizes the words it shares with
    /// the reference. Only words the alignment matches count, so a misheard
    /// word is not also a punctuation error. Meaningful only when the
    /// reference itself is punctuated (an `.intended.txt` written as text).
    struct Formatting: Equatable, Codable {
        /// The mark after a word (`.`, `,`, `?`, `!`, `:`, `;`): a hypothesis
        /// mark agrees only when it is the same mark.
        var punctuation = MarkAgreement()
        /// A capital first letter.
        var capitalization = MarkAgreement()

        static func + (lhs: Formatting, rhs: Formatting) -> Formatting {
            Formatting(
                punctuation: lhs.punctuation + rhs.punctuation,
                capitalization: lhs.capitalization + rhs.capitalization
            )
        }
    }

    static func formatting(reference: String, hypothesis: String) -> Formatting {
        let referenceWords = WordErrorRate.surfaceWords(reference)
        let hypothesisWords = WordErrorRate.surfaceWords(hypothesis)
        let steps = alignment(
            reference: referenceWords.map { $0.text.lowercased() },
            hypothesis: hypothesisWords.map { $0.text.lowercased() }
        )
        var result = Formatting()
        for case let .match(referenceIndex, hypothesisIndex) in steps {
            let expected = referenceWords[referenceIndex]
            let actual = hypothesisWords[hypothesisIndex]
            if expected.trailingMark != nil { result.punctuation.referenceMarks += 1 }
            if actual.trailingMark != nil { result.punctuation.hypothesisMarks += 1 }
            if let mark = expected.trailingMark, mark == actual.trailingMark { result.punctuation.agreements += 1 }
            if expected.isCapitalized { result.capitalization.referenceMarks += 1 }
            if actual.isCapitalized { result.capitalization.hypothesisMarks += 1 }
            if expected.isCapitalized, actual.isCapitalized { result.capitalization.agreements += 1 }
        }
        return result
    }

    // MARK: - Terms

    /// Whether the words the speaker needs spelled a certain way (their
    /// Dictionary terms) came through spelled that way.
    struct TermRecall: Equatable, Codable {
        /// Term occurrences in the reference.
        var expected = 0
        /// Of those, how many the hypothesis has with the term's exact
        /// spelling and case ("GitHub", not "github" or "get hub").
        var recalled = 0
        /// Term occurrences in the hypothesis beyond the reference's, in any
        /// case: a hint pulling a term in where it was not said.
        var falseInsertions = 0

        var recall: Double? { expected == 0 ? nil : Double(recalled) / Double(expected) }

        static func + (lhs: TermRecall, rhs: TermRecall) -> TermRecall {
            TermRecall(
                expected: lhs.expected + rhs.expected,
                recalled: lhs.recalled + rhs.recalled,
                falseInsertions: lhs.falseInsertions + rhs.falseInsertions
            )
        }
    }

    static func termRecall(terms: [String], reference: String, hypothesis: String) -> TermRecall {
        let plainReference = WordErrorRate.surfaceWords(reference).map { $0.text.lowercased() }
        let plainHypothesis = WordErrorRate.surfaceWords(hypothesis).map(\.text)
        var result = TermRecall()
        var seen = Set<String>()
        for term in terms {
            // "C++", "C#" and ".NET" are told apart by their symbols, which
            // the word tokenizer drops; such terms match whole tokens instead.
            let keepsSymbols = hasMeaningfulSymbols(term)
            let exact = keepsSymbols ? symbolTokens(term, keeping: term) : WordErrorRate.surfaceWords(term).map(\.text)
            let lowered = exact.map { $0.lowercased() }
            guard !lowered.isEmpty, seen.insert(lowered.joined(separator: " ")).inserted else { continue }
            let referenceWords = keepsSymbols
                ? symbolTokens(reference, keeping: term).map { $0.lowercased() } : plainReference
            let hypothesisSurface = keepsSymbols ? symbolTokens(hypothesis, keeping: term) : plainHypothesis
            let said = occurrences(of: lowered, in: referenceWords)
            let heardExactly = occurrences(of: exact, in: hypothesisSurface)
            let heardAny = occurrences(of: lowered, in: hypothesisSurface.map { $0.lowercased() })
            result.expected += said
            result.recalled += min(said, heardExactly)
            result.falseInsertions += max(0, heardAny - said)
        }
        return result
    }

    /// Whether a term holds a character other than letters, digits, spaces,
    /// apostrophes and hyphens ("C++", "C#", "Node.js", ".NET").
    static func hasMeaningfulSymbols(_ term: String) -> Bool {
        term.contains { character in
            !(character.isLetter || character.isNumber || character.isWhitespace
                || "'\u{2019}-".contains(character))
        }
    }

    /// Tokens split at whitespace and at separators ("/", "|", dashes) the
    /// term itself does not use, with the sentence punctuation, quotes and
    /// brackets around them removed, keeping symbols inside or ending a term:
    /// "use C++." → ["use", "C++"], "(.NET)" → [".NET"],
    /// "Node.js/TypeScript" → ["Node.js", "TypeScript"].
    static func symbolTokens(_ text: String, keeping term: String) -> [String] {
        let leading = CharacterSet(charactersIn: "\"'\u{2018}\u{201C}([{")
        let trailing = CharacterSet(charactersIn: ".,;:!?\"'\u{2019}\u{201D})]}")
        let separators = Set("/|\u{2013}\u{2014}").subtracting(term)
        return text.split { $0.isWhitespace || separators.contains($0) }.compactMap { raw in
            var token = Substring(raw)
            while let first = token.unicodeScalars.first, leading.contains(first) { token = token.dropFirst() }
            while let last = token.unicodeScalars.last, trailing.contains(last) { token = token.dropLast() }
            return token.isEmpty ? nil : String(token)
        }
    }

    /// Non-overlapping occurrences of `phrase` in `words`.
    static func occurrences(of phrase: [String], in words: [String]) -> Int {
        guard !phrase.isEmpty, words.count >= phrase.count else { return 0 }
        var count = 0
        var index = 0
        while index + phrase.count <= words.count {
            if Array(words[index..<index + phrase.count]) == phrase {
                count += 1
                index += phrase.count
            } else {
                index += 1
            }
        }
        return count
    }
}
