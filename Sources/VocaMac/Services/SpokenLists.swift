// SpokenLists.swift
// VocaMac
//
// "First, … Second, … Third, …" said as sentences becomes a numbered list.
// A rule, not a model: it needs the whole ordered run at sentence starts,
// so a sentence that merely contains "first" never becomes a list.

import Foundation

enum SpokenLists {
    /// Fewest items that make a list.
    static let minimumItems = 3
    /// Fewest words each item needs after its marker.
    static let minimumWords = 2

    /// The text with a spoken enumeration laid out as "1. …", "2. …".
    ///
    /// Takes the first run of sentences opening with "first", "second",
    /// "third"… (or "one,", "two,", "three,"), in order, at least
    /// `minimumItems` long, each item at least `minimumWords` words. A final
    /// "finally," or "lastly," counts as the next item. Sentences before the
    /// run stay as an introduction; after the last item's own sentence the
    /// rest is a new paragraph. Anything else is left exactly as it is.
    ///
    /// - Parameter restore: Puts masked spans back, to count their words.
    static func numbered(_ text: String, restore: (String) -> String = { $0 }) -> String {
        let spans = sentenceRanges(in: text)
        let sentences = spans.map { String(text[$0]) }
        guard sentences.count >= minimumItems else { return text }

        for start in sentences.indices {
            guard let (family, _) = marker(of: sentences[start], expecting: 1) else { continue }
            var itemStarts = [start]
            var index = start + 1
            while index < sentences.count {
                let next = itemStarts.count + 1
                if marker(of: sentences[index], expecting: next, family: family) != nil {
                    itemStarts.append(index)
                } else if itemStarts.count >= 2, isFinalMarker(sentences[index]) {
                    itemStarts.append(index)
                    break
                }
                index += 1
            }
            guard itemStarts.count >= minimumItems else { continue }

            var items: [String] = []
            for (number, itemStart) in itemStarts.enumerated() {
                let end = number + 1 < itemStarts.count ? itemStarts[number + 1] : itemStart + 1
                let body = sentences[itemStart..<end].joined(separator: " ")
                guard let stripped = strippingMarker(body),
                      words(in: restore(stripped)) >= minimumWords else { return text }
                items.append("\(number + 1). \(stripped)")
            }
            let lastItemEnd = (itemStarts.last ?? start) + 1
            // The introduction and what follows keep their own spacing.
            let intro = text[..<spans[start].lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = lastItemEnd < spans.count
                ? text[spans[lastItemEnd].lowerBound...].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            var result = intro.isEmpty ? "" : intro + "\n"
            result += items.joined(separator: "\n")
            if !rest.isEmpty { result += "\n\n" + rest }
            return result
        }
        return text
    }

    // MARK: - Markers

    private enum Family { case ordinal, cardinal }

    private static let ordinals = [
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
    ]
    private static let adverbs = [
        "firstly", "secondly", "thirdly", "fourthly", "fifthly", "sixthly", "seventhly", "eighthly", "ninthly", "tenthly",
    ]
    private static let cardinals = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]

    /// The family of the marker opening `sentence` when it is the
    /// `expecting`-th item's ("second" for 2), and its length in characters.
    private static func marker(
        of sentence: String, expecting number: Int, family: Family? = nil
    ) -> (Family, Int)? {
        guard number >= 1, number <= ordinals.count else { return nil }
        let lowered = sentence.lowercased()
        if family != .cardinal {
            // "Firstly" is only ever a marker. "First" and "second" also
            // start ordinary sentences ("First impressions matter. Second
            // chances are rare."), so they need a comma or colon, as does
            // "first of all".
            let ordinal = ordinals[number - 1]
            if number == 1, opens(lowered, with: ordinal + " of all", needsMark: true) {
                return (.ordinal, ordinal.count + 7)
            }
            if opens(lowered, with: ordinal, needsMark: true)
                || opens(lowered, with: adverbs[number - 1], needsMark: false) {
                return (.ordinal, ordinal.count)
            }
        }
        // "One, …" or, with numbers written as digits, "1, …": a bare
        // number only counts with a comma or colon.
        if family != .ordinal,
           opens(lowered, with: cardinals[number - 1], needsMark: true)
            || opens(lowered, with: String(number), needsMark: true) {
            return (.cardinal, cardinals[number - 1].count)
        }
        return nil
    }

    private static func isFinalMarker(_ sentence: String) -> Bool {
        let lowered = sentence.lowercased()
        return ["finally", "lastly", "and finally", "and lastly"].contains { opens(lowered, with: $0, needsMark: true) }
    }

    /// `sentence` starts with `word` as a whole word, followed by a comma or
    /// colon (`needsMark`), or by a comma, colon or space.
    private static func opens(_ sentence: String, with word: String, needsMark: Bool) -> Bool {
        guard sentence.hasPrefix(word) else { return false }
        let rest = sentence.dropFirst(word.count)
        guard let next = rest.first else { return false }
        if next == "," || next == ":" { return true }
        return !needsMark && next == " "
    }

    /// The item without its marker and the punctuation after it, its first
    /// letter capitalized when the marker was.
    private static func strippingMarker(_ item: String) -> String? {
        let lowered = item.lowercased()
        let digits = (1...cardinals.count).map(String.init)
        let candidates = (["and finally", "and lastly", "finally", "lastly", "first of all"] + ordinals + adverbs
            + cardinals + digits)
            .sorted { $0.count > $1.count }
        guard let word = candidates.first(where: { lowered.hasPrefix($0) && opens(lowered, with: $0, needsMark: false) }) else {
            return nil
        }
        var body = item.dropFirst(word.count)
        while let first = body.first, first == "," || first == ":" || first == " " { body = body.dropFirst() }
        guard let first = body.first else { return nil }
        if item.first?.isUppercase == true, first.isLowercase {
            return first.uppercased() + body.dropFirst()
        }
        return String(body)
    }

    // MARK: - Sentences

    /// Where each sentence is: split after ".", "!" or "?" and the space or
    /// line break that follows, without the whitespace around it.
    static func sentenceRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var lastNonSpace = text.startIndex
        var afterEnd = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                if afterEnd, let open = start {
                    ranges.append(open..<text.index(after: lastNonSpace))
                    start = nil
                }
                afterEnd = false
            } else {
                if start == nil { start = index }
                lastNonSpace = index
                afterEnd = ".!?".contains(character)
            }
            index = text.index(after: index)
        }
        if let open = start { ranges.append(open..<text.index(after: lastNonSpace)) }
        return ranges
    }

    private static func words(in text: String) -> Int {
        text.split { $0.isWhitespace }.filter { $0.contains { $0.isLetter || $0.isNumber } }.count
    }
}
