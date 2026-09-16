// OverlapDeduplication.swift
// VocaMac
//
// Removes the words a piece's decode repeats from the audio it was given as
// context, so each piece can be decoded with some of the speech before it.

import Foundation

enum OverlapDeduplication {
    /// The part of `decoded` that is new: `decoded` transcribes context audio
    /// (the end of the previous piece, whose text is `previous`) followed by
    /// the piece itself. Nil when the context can't be found with confidence.
    ///
    /// Semi-global alignment of normalized words: the suffix of `previous`
    /// may start anywhere, the start of `decoded` is anchored (a skipped
    /// leading word, such as a word cut in half by the context start, costs a
    /// point), and whatever follows the aligned span is the new text.
    static func newText(decoded: String, previous: String, contextSeconds: Double) -> String? {
        let decodedTokens = decoded.split(whereSeparator: \.isWhitespace).map(String.init)
        let out = decodedTokens.map(normalized)
        let prev = previous.split(whereSeparator: \.isWhitespace).map { normalized(String($0)) }.filter { !$0.isEmpty }
        guard !out.isEmpty, !prev.isEmpty else { return nil }

        let expected = max(2, Int((contextSeconds * 3).rounded()))
        let p = Array(prev.suffix(min(prev.count, expected * 2 + 4)))
        let o = Array(out.prefix(min(out.count, max(p.count, expected) * 2 + 6)))

        let match = 2, penalty = -1
        var score = Array(repeating: Array(repeating: 0, count: o.count + 1), count: p.count + 1)
        var matches = Array(repeating: Array(repeating: 0, count: o.count + 1), count: p.count + 1)
        for j in 0...o.count { score[0][j] = j * penalty }
        for i in 1...p.count {
            for j in 1...o.count {
                let same = !o[j - 1].isEmpty && p[i - 1] == o[j - 1]
                let diagonal = score[i - 1][j - 1] + (same ? match : penalty)
                let up = score[i - 1][j] + penalty
                let left = score[i][j - 1] + penalty
                if diagonal >= up, diagonal >= left {
                    score[i][j] = diagonal
                    matches[i][j] = matches[i - 1][j - 1] + (same ? 1 : 0)
                } else if up >= left {
                    score[i][j] = up
                    matches[i][j] = matches[i - 1][j]
                } else {
                    score[i][j] = left
                    matches[i][j] = matches[i][j - 1]
                }
            }
        }
        var bestEnd = -1, bestScore = Int.min
        for j in 0...o.count where score[p.count][j] > bestScore {
            bestScore = score[p.count][j]
            bestEnd = j
        }
        // The context must actually be there: most of the previous words, not
        // two that happen to recur in the new speech ("on Friday").
        let matched = matches[p.count][bestEnd]
        guard bestEnd > 0, matched >= 2, Double(matched) >= minimumMatchedShare * Double(p.count) else { return nil }
        return decodedTokens.dropFirst(bestEnd).joined(separator: " ")
    }

    /// Share of the previous piece's (compared) words that must be found.
    static let minimumMatchedShare = 0.6

    static func normalized(_ token: String) -> String {
        String(token.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "'" })
    }
}
