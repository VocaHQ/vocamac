// TranscriptRepetition.swift
// VocaMac
//
// Finds the runaway loops Whisper falls into on short clips ("Chalo. Chalo.
// Chalo. …" until the token limit) and collapses them to one copy.

import Foundation

/// Detects and removes a phrase that a speech model repeated back to back
/// far more often than anyone says it.
///
/// Whisper can lock onto a phrase and repeat it until the decoder runs out of
/// tokens: a 2 second "Nahin main puchh raha hoon" came back as 420
/// characters of the same sentence. WhisperKit's own guard (a compression
/// ratio check that re-decodes at a higher temperature) is off for dictation
/// latency, so the loop has to be caught here.
enum TranscriptRepetition {

    /// A run of back-to-back copies of the same words.
    struct Loop: Equatable {
        /// Index of the first word of the first copy.
        let start: Int
        /// Words in one copy.
        let unitLength: Int
        /// Complete copies, including the first.
        let copies: Int
        /// Words after the last complete copy that begin another copy, cut
        /// off by the decoder's token limit.
        let trailingPartial: Int

        /// Index one past the last word the loop covers.
        var end: Int { start + unitLength * copies + trailingPartial }
    }

    /// The longest phrase, in words, that is checked for repetition.
    static let maximumUnitLength = 16

    /// Copies a phrase of `unitLength` words needs before it counts as a loop.
    ///
    /// People repeat themselves on purpose ("no no no", "thank you, thank
    /// you"), so short phrases need many copies. Loops run to the token
    /// limit, usually a dozen copies or more, so the bar can sit well above
    /// anything spoken.
    static func minimumCopies(unitLength: Int) -> Int {
        switch unitLength {
        case 1:  return 8
        case 2:  return 5
        default: return 4
        }
    }

    /// The first loop in `text`, if any.
    static func loop(in text: String) -> Loop? {
        let words = tokens(in: text).map(\.normalized)
        guard words.count >= 4 else { return nil }

        for start in words.indices {
            let longestUnit = min(maximumUnitLength, (words.count - start) / 2)
            guard longestUnit >= 1 else { break }
            for unitLength in 1...longestUnit {
                let unit = words[start..<(start + unitLength)]
                var copies = 1
                var next = start + unitLength
                while next + unitLength <= words.count,
                      words[next..<(next + unitLength)].elementsEqual(unit) {
                    copies += 1
                    next += unitLength
                }
                guard copies >= minimumCopies(unitLength: unitLength) else { continue }
                // A copy the decoder cut off mid-phrase belongs to the loop.
                var partial = 0
                while next + partial < words.count, partial < unitLength - 1,
                      words[next + partial] == unit[unit.startIndex + partial] {
                    partial += 1
                }
                // The limit can also land mid-word: "…hoon. Nahin main puch".
                if next + partial == words.count - 1, partial < unitLength,
                   unit[unit.startIndex + partial].hasPrefix(words[next + partial]) {
                    partial += 1
                }
                return Loop(start: start, unitLength: unitLength, copies: copies, trailingPartial: partial)
            }
        }
        return nil
    }

    static func containsLoop(_ text: String) -> Bool {
        loop(in: text) != nil
    }

    /// `text` with every loop cut down to its first copy, keeping that copy's
    /// punctuation and anything said after the loop.
    static func collapsingLoops(in text: String) -> String {
        var text = text
        // Each pass removes one loop; a transcript rarely holds more than one.
        for _ in 0..<8 {
            guard let loop = loop(in: text) else { break }
            let words = tokens(in: text)
            let keepUntil = words[loop.start + loop.unitLength].range.lowerBound
            var kept = String(text[..<keepUntil])
            while kept.last?.isWhitespace == true { kept.removeLast() }
            if loop.end < words.count {
                let rest = text[words[loop.end].range.lowerBound...]
                kept += " " + rest
            }
            text = kept
        }
        return text
    }

    // MARK: - Words

    private struct Token {
        let range: Range<String.Index>
        let normalized: String
    }

    /// Words as runs of letters, marks, and digits. Punctuation is ignored,
    /// and so is a missing space: loops often glue copies together
    /// ("hoon.Nahin").
    private static func tokens(in text: String) -> [Token] {
        var result: [Token] = []
        var start: String.Index?
        var index = text.startIndex
        func isWordCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character.unicodeScalars.contains {
                CharacterSet.nonBaseCharacters.contains($0)
            } || character == "'" || character == "’"
        }
        while index < text.endIndex {
            if isWordCharacter(text[index]) {
                if start == nil { start = index }
            } else if let wordStart = start {
                result.append(Token(range: wordStart..<index, normalized: text[wordStart..<index].lowercased()))
                start = nil
            }
            index = text.index(after: index)
        }
        if let wordStart = start {
            result.append(Token(range: wordStart..<text.endIndex, normalized: text[wordStart...].lowercased()))
        }
        return result
    }
}
