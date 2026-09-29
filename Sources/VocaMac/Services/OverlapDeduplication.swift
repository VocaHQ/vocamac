// OverlapDeduplication.swift
// VocaMac
//
// Removes the words a piece's decode repeats from the audio it was given as
// context, so each piece can be decoded with some of the speech before it.

import Foundation

enum OverlapDeduplication {
    /// Where the context ends in a decode of context audio followed by a new
    /// piece. Indices are into the whitespace-separated words of each text.
    struct Alignment: Equatable {
        /// First word of the previous text the decode matched.
        let previousStart: Int
        /// The decode's word for it; words before it (a word cut in half by
        /// the context start) belong to neither text.
        let decodedStart: Int
        /// First word of the decode that is new.
        let decodedEnd: Int
    }

    /// The part of `decoded` that is new: `decoded` transcribes context audio
    /// (the end of the previous piece, whose text is `previous`) followed by
    /// the piece itself. Nil when the context can't be found with confidence.
    static func newText(
        decoded: String, previous: String, contextSeconds: Double, contextShare: Double = 1
    ) -> String? {
        guard let alignment = align(
            decoded: decoded, previous: previous, contextSeconds: contextSeconds, contextShare: contextShare
        ) else { return nil }
        return words(decoded).dropFirst(alignment.decodedEnd).joined(separator: " ")
    }

    /// Semi-global alignment of normalized words: the suffix of `previous`
    /// may start anywhere, the start of `decoded` is anchored (a skipped
    /// leading word, such as a word cut in half by the context start, costs a
    /// point), and whatever follows the aligned span is the new text.
    ///
    /// - Parameter contextShare: How much of the previous piece's audio the
    ///   context covered, 1 for all of it. Only about that share of its words
    ///   can be found in `decoded`.
    static func align(
        decoded: String, previous: String, contextSeconds: Double, contextShare: Double = 1
    ) -> Alignment? {
        let out = words(decoded).map(normalized)
        let previousWords = words(previous)
        // Normalized previous words that are words at all, and where each
        // came from, so an alignment maps back to the text.
        var prev: [String] = []
        var prevSource: [Int] = []
        for (index, word) in previousWords.enumerated() {
            let token = normalized(word)
            guard !token.isEmpty else { continue }
            prev.append(token)
            prevSource.append(index)
        }
        guard !out.isEmpty, !prev.isEmpty else { return nil }

        let share = min(1, max(0, contextShare))
        // Words the context audio should hold. Overestimating is harmless:
        // previous words before the aligned span are skipped for free.
        let inContext = max(1, Int((Double(prev.count) * share).rounded(.up)))
        let searched = share < 1 ? min(prev.count, Int((Double(inContext) * 1.5).rounded(.up)) + 2) : prev.count
        let expected = max(2, Int((contextSeconds * 3).rounded()))
        let p = Array(prev.suffix(min(searched, expected * 2 + 4)))
        let pOffset = prev.count - p.count
        let o = Array(out.prefix(min(out.count, max(p.count, expected) * 2 + 6)))

        enum Step: UInt8 { case diagonal, up, left }
        let match = 2, penalty = -1
        var score = Array(repeating: Array(repeating: 0, count: o.count + 1), count: p.count + 1)
        var matches = Array(repeating: Array(repeating: 0, count: o.count + 1), count: p.count + 1)
        var steps = Array(repeating: Array(repeating: Step.up, count: o.count + 1), count: p.count + 1)
        for j in 0...o.count {
            score[0][j] = j * penalty
            steps[0][j] = .left
        }
        for i in 1...p.count {
            for j in 1...o.count {
                let same = !o[j - 1].isEmpty && p[i - 1] == o[j - 1]
                // A word heard differently ("flower" then "flour") is the
                // same word, not a deletion followed by a new word: scored
                // as a deletion, it would be kept twice.
                let step = same ? match : (areLookAlikes(p[i - 1], o[j - 1]) ? 0 : penalty)
                let diagonal = score[i - 1][j - 1] + step
                let up = score[i - 1][j] + penalty
                let left = score[i][j - 1] + penalty
                if diagonal >= up, diagonal >= left {
                    score[i][j] = diagonal
                    matches[i][j] = matches[i - 1][j - 1] + (same ? 1 : 0)
                    steps[i][j] = .diagonal
                } else if up >= left {
                    score[i][j] = up
                    matches[i][j] = matches[i - 1][j]
                    steps[i][j] = .up
                } else {
                    score[i][j] = left
                    matches[i][j] = matches[i][j - 1]
                    steps[i][j] = .left
                }
            }
        }
        var bestEnd = -1, bestScore = Int.min
        for j in 0...o.count where score[p.count][j] > bestScore {
            bestScore = score[p.count][j]
            bestEnd = j
        }
        // The context must actually be there: most of the previous words it
        // covers, not two that happen to recur in the new speech ("on Friday").
        let matched = matches[p.count][bestEnd]
        guard bestEnd > 0, matched >= 2,
              Double(matched) >= minimumMatchedShare * Double(min(p.count, inContext)) else { return nil }

        // Walk back to the first matching word of the aligned span. A
        // mismatch before it is most likely a word cut in half by the
        // context start, not a word of either text.
        var i = p.count, j = bestEnd
        var firstI = i, firstJ = j
        while i > 0, j > 0 {
            switch steps[i][j] {
            case .diagonal:
                if p[i - 1] == o[j - 1] {
                    firstI = i - 1
                    firstJ = j - 1
                }
                i -= 1
                j -= 1
            case .up:
                i -= 1
            case .left:
                j -= 1
            }
        }
        return Alignment(
            previousStart: prevSource[pOffset + firstI],
            decodedStart: firstJ,
            decodedEnd: bestEnd
        )
    }

    /// Share of the previous piece's (compared) words that must be found.
    static let minimumMatchedShare = 0.6

    /// Two spellings close enough to be one spoken word heard two ways:
    /// "flower"/"flour", "their"/"there", "weather"/"whether". Short words
    /// are left out, because "it" and "in" are different words far more
    /// often than one misheard.
    static func areLookAlikes(_ a: String, _ b: String) -> Bool {
        let longer = max(a.count, b.count)
        guard longer >= 4, a != b else { return false }
        return editDistance(Array(a).map(String.init), Array(b).map(String.init)) * 2 < longer
    }

    /// Word-level edit distance between two word lists.
    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty else { return b.count }
        var previous = Array(0...b.count)
        for (i, word) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, other) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (word == other ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func normalized(_ token: String) -> String {
        String(token.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "'" })
    }
}
