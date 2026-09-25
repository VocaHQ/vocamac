// TranscriptRepetition.swift
// VocaMac
//
// Finds the runaway loops Whisper falls into on short clips ("Chalo. Chalo.
// Chalo. …" until the token limit, "ктттттт…" inside one word, or a tail of
// "::::::::") and collapses them to one copy.

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

    /// Copies a phrase of `unitLength` words needs before it can be a loop.
    ///
    /// People repeat themselves on purpose ("no no no", "thank you, thank
    /// you", "please leave now" four times), so a count alone is weak
    /// evidence. A run this long is only a loop when the audio is too short
    /// to have said it (see `maximumWordsPerSecond`), or when it has twice
    /// as many copies. Loops run to the token limit, usually a dozen copies
    /// or more.
    static func minimumCopies(unitLength: Int) -> Int {
        switch unitLength {
        case 1:  return 8
        case 2:  return 5
        default: return 4
        }
    }

    /// Faster than anyone speaks: fast speech is about 4 words a second. The
    /// loop that prompted this came to 75 words from 1.8 seconds of audio.
    static let maximumWordsPerSecond = 6.0

    /// The first loop in `text`, if any.
    ///
    /// - Parameter audioSeconds: How long the recording was, when known.
    ///   Text with more words than that audio could hold is runaway
    ///   generation, so a shorter run of copies is enough to call it a loop.
    static func loop(in text: String, audioSeconds: Double? = nil) -> Loop? {
        let words = tokens(in: text).map(\.normalized)
        guard words.count >= 4 else { return nil }
        let isImplausiblyLong = audioSeconds.map { seconds in
            seconds > 0 && Double(words.count) / seconds > maximumWordsPerSecond
        } ?? false

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
                let required = minimumCopies(unitLength: unitLength) * (isImplausiblyLong ? 1 : 2)
                guard copies >= required else { continue }
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

    /// Whether `text` holds a loop of words, of letters inside a word, or of
    /// punctuation.
    static func containsLoop(_ text: String, audioSeconds: Double? = nil) -> Bool {
        loop(in: text, audioSeconds: audioSeconds) != nil
            || characterLoop(in: text, audioSeconds: audioSeconds) != nil
            || symbolLoop(in: text) != nil
    }

    /// `text` with every loop cut down to its first copy, keeping that copy's
    /// punctuation and anything said after the loop.
    static func collapsingLoops(in text: String, audioSeconds: Double? = nil) -> String {
        var text = text
        // Each pass replaces at least six characters with at most three.
        while let loop = symbolLoop(in: text) {
            text = collapsing(loop, in: text)
        }
        // Letters first: once "Hiiiiiiiiiiii Hiiiiiiiiiiii …" is "Hi Hi …",
        // the word pass sees the repeated word. Each pass shortens the text,
        // so this ends even when every word looped.
        while let loop = characterLoop(in: text, audioSeconds: audioSeconds) {
            let firstCopyEnd = text.index(loop.range.lowerBound, offsetBy: loop.unitLength)
            let firstCopy = String(text[loop.range.lowerBound..<firstCopyEnd])
            text.replaceSubrange(loop.range, with: firstCopy)
        }
        // Each pass removes one loop; a transcript rarely holds more than one.
        for _ in 0..<8 {
            guard let loop = loop(in: text, audioSeconds: audioSeconds) else { break }
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

    // MARK: - Letters

    /// A letter, or a few letters, repeated back to back inside one word.
    ///
    /// Whisper can also loop on a single token with no space between copies:
    /// Voca Hinglish ended an 11.5 second dictation with "в к" and about 170
    /// "т". The word check reads that as one long word and never fires.
    struct CharacterLoop: Equatable {
        /// The characters the loop covers, from its first copy through any
        /// copy the token limit cut off.
        let range: Range<String.Index>
        /// Characters in one copy.
        let unitLength: Int
        /// Complete copies, including the first.
        let copies: Int
    }

    /// The longest run of letters, in characters, that is checked for
    /// repetition inside a word.
    static let maximumCharacterUnitLength = 4

    /// Copies a run of `unitLength` letters needs before it can be a loop.
    ///
    /// Like `minimumCopies(unitLength:)`, this is only enough when the audio
    /// is too short for the copies (see `maximumCharacterCopiesPerSecond`);
    /// otherwise a loop needs twice as many. Stretched words and laughter stay
    /// under that: "Sooooo", "Hmmmm", "hahahahahahahaha". A decoder loop runs
    /// to the token limit, usually well past a hundred copies.
    static func minimumCharacterCopies(unitLength: Int) -> Int {
        unitLength == 1 ? 12 : 8
    }

    /// More copies a second than anyone voices: each copy of "ha" is a
    /// syllable, and even fast laughter stays under 8 a second.
    static let maximumCharacterCopiesPerSecond = 8.0

    /// The first loop of letters inside a word in `text`, if any.
    ///
    /// Only letters count, so a spoken number such as "1000000000000" is
    /// never cut down.
    ///
    /// - Parameter audioSeconds: How long the recording was, when known. A
    ///   run with more copies than that audio could hold is runaway
    ///   generation, so fewer copies are enough to call it a loop.
    static func characterLoop(in text: String, audioSeconds: Double? = nil) -> CharacterLoop? {
        for token in tokens(in: text) {
            let word = text[token.range]
            let indices = Array(word.indices)
            let characters = word.map { $0.lowercased() }
            let isLetter = word.map(\.isLetter)
            for start in characters.indices where isLetter[start] {
                let longestUnit = min(maximumCharacterUnitLength, (characters.count - start) / 2)
                guard longestUnit >= 1 else { break }
                for unitLength in 1...longestUnit {
                    let unitRange = start..<(start + unitLength)
                    guard isLetter[unitRange].allSatisfy({ $0 }) else { break }
                    let unit = characters[unitRange]
                    var copies = 1
                    var next = start + unitLength
                    while next + unitLength <= characters.count,
                          characters[next..<(next + unitLength)].elementsEqual(unit) {
                        copies += 1
                        next += unitLength
                    }
                    let isImplausiblyLong = audioSeconds.map { seconds in
                        seconds > 0 && Double(copies) / seconds > maximumCharacterCopiesPerSecond
                    } ?? false
                    let required = minimumCharacterCopies(unitLength: unitLength) * (isImplausiblyLong ? 1 : 2)
                    guard copies >= required else { continue }
                    // A copy the decoder cut off mid-run belongs to the loop.
                    var partial = 0
                    while next + partial < characters.count, partial < unitLength - 1,
                          characters[next + partial] == unit[unit.startIndex + partial] {
                        partial += 1
                    }
                    let end = next + partial
                    let upperBound = end < indices.count ? indices[end] : token.range.upperBound
                    return CharacterLoop(range: indices[start]..<upperBound, unitLength: unitLength, copies: copies)
                }
            }
        }
        return nil
    }

    // MARK: - Punctuation

    /// Punctuation or symbols repeated far past any written use.
    ///
    /// Voca Hinglish ended an 11.4 second dictation with "please?" and sixteen
    /// colons, and another with a full stop and twenty. The word check skips
    /// punctuation and the letter check only reads letters, so both went
    /// through. Punctuation is never spoken, so the length of the audio says
    /// nothing about how many copies are plausible.
    struct SymbolLoop: Equatable {
        /// From the first copy through any copy cut off at the end.
        let range: Range<String.Index>
        /// One copy.
        let unit: String
        /// Complete copies, including the first.
        let copies: Int
    }

    /// The longest run of symbols, in characters, that is checked.
    static let maximumSymbolUnitLength = 3

    /// Copies before repeated punctuation is a loop. Writing stops well short
    /// of this: an ellipsis is three dots, emphasis a few "!". None of 1,015
    /// real dictations came close, and both loops ran past fifteen.
    static let minimumSymbolCopies = 6

    /// Characters whose long runs are written on purpose: Markdown rules and
    /// headings ("------", "***", "======", "###"), and plain-text dividers.
    /// A repeated unit made only of these is never a loop; one that mixes in
    /// anything else ("-:-:-:") still is.
    static let dividerCharacters: Set<Character> = ["-", "_", "=", "*", "~", "#"]

    /// The first loop of punctuation or symbols in `text`, if any.
    ///
    /// Only symbols written back to back form a run. A space, a line break or
    /// anything else ends it, so separate tokens ("-> -> ->", ":-) :-) :-)"),
    /// the separators in "1,000,000,000,000" and symbols on separate lines
    /// never add up. Both loops seen so far were unbroken.
    static func symbolLoop(in text: String) -> SymbolLoop? {
        var run: [String.Index] = []
        for index in text.indices {
            if isSymbol(text[index]) {
                run.append(index)
            } else {
                if let loop = symbolLoop(in: run, of: text) { return loop }
                run.removeAll()
            }
        }
        return symbolLoop(in: run, of: text)
    }

    private static func isSymbol(_ character: Character) -> Bool {
        character.isPunctuation || character.isSymbol
    }

    /// A loop inside one run of symbols, given as their positions in `text`.
    private static func symbolLoop(in run: [String.Index], of text: String) -> SymbolLoop? {
        guard run.count >= minimumSymbolCopies else { return nil }
        let characters = run.map { text[$0] }
        // A divider can be long, and nothing in it is a loop; don't scan it
        // from every position.
        guard !characters.allSatisfy(dividerCharacters.contains) else { return nil }
        for start in characters.indices {
            let longestUnit = min(maximumSymbolUnitLength, (characters.count - start) / 2)
            guard longestUnit >= 1 else { break }
            for unitLength in 1...longestUnit {
                let unit = characters[start..<(start + unitLength)]
                var copies = 1
                var next = start + unitLength
                while next + unitLength <= characters.count,
                      characters[next..<(next + unitLength)].elementsEqual(unit) {
                    copies += 1
                    next += unitLength
                }
                guard copies >= minimumSymbolCopies,
                      !unit.allSatisfy(dividerCharacters.contains) else { continue }
                // A copy cut off at the end belongs to the loop.
                var partial = 0
                while next + partial < characters.count, partial < unitLength - 1,
                      characters[next + partial] == unit[unit.startIndex + partial] {
                    partial += 1
                }
                let last = run[next + partial - 1]
                return SymbolLoop(
                    range: run[start]..<text.index(after: last),
                    unit: String(unit),
                    copies: copies
                )
            }
        }
        return nil
    }

    /// `text` with `loop` cut down to what the sentence needs from it.
    ///
    /// Dots become an ellipsis. A run that follows other punctuation, or
    /// starts the text, is dropped: "please?::::::::" is "please?", not
    /// "please?:". Otherwise one copy is kept, so "Wait!!!!!!!!" is "Wait!".
    static func collapsing(_ loop: SymbolLoop, in text: String) -> String {
        var prefix = String(text[..<loop.range.lowerBound])
        var suffix = String(text[loop.range.upperBound...])
        let previous = prefix.last(where: { !$0.isWhitespace })
        let replacement: String
        if loop.unit.allSatisfy({ $0 == "." }) {
            replacement = "..."
        } else if previous.map(isSymbol) ?? true {
            replacement = ""
        } else {
            replacement = loop.unit
        }
        if replacement.isEmpty {
            // Leave one space where the run sat between words, none at an end.
            if suffix.first?.isWhitespace == true || suffix.isEmpty {
                while prefix.last?.isWhitespace == true { prefix.removeLast() }
            }
            if prefix.isEmpty {
                while suffix.first?.isWhitespace == true { suffix.removeFirst() }
            }
        }
        return prefix + replacement + suffix
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
