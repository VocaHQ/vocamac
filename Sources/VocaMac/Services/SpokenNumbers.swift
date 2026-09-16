// SpokenNumbers.swift
// VocaMac
//
// Rewrites dictated English number words as digits. Ported from the VocaPhone
// clients, which are expected to produce the same text for the same transcript;
// the one deliberate difference is `isOrdinalSecond`.

import Foundation

/// Rewrites dictated number words as digits: "six pm at the office" becomes
/// "6 pm at the office".
///
/// Speech models return what was said, and what was said is words. Whether a
/// number belongs in a transcript as "twenty three" or "23" depends on what the
/// text is *for* — a message to a colleague wants digits, prose often does not
/// — which is why this is a preference rather than something the app decides.
///
/// Deliberately conservative. Every rule here exists because the obvious
/// implementation of "replace number words with digits" produces text nobody
/// would send:
///
/// * A run of adjacent number words is converted only when the whole run reads
///   as one number. "twenty three" is 23; "six seven" is left alone rather than
///   becoming "6 7" or, worse, "13".
/// * A lone "one" stays a word unless a unit follows it. "no one", "one of
///   them" and "one day I'll get to it" are the common cases, and all three are
///   ruined by a converter that cannot tell a quantity from a pronoun.
/// * Nothing is invented. Ordinals ("first", "twenty-first") and spoken times
///   ("seven thirty") stay as they were said: this turns number words into
///   digits, it does not reformat English.
///
/// English only. The word lists match nothing in another language, so a Hindi
/// or Spanish transcript passes through untouched rather than being partially
/// mangled.
enum SpokenNumbers {
    /// The largest number this will write out. Past a trillion, a phrase is far
    /// more likely to be a misrecognition than something a person said.
    static let maximum = 999_999_999_999

    /// Units that make a bare "one" a quantity rather than a pronoun.
    ///
    /// Hard units only — "hour", "percent", "pm" — and deliberately not "day",
    /// "week" or "time": "one day I'll get to it" and "one time in Delhi" are
    /// ordinary English, and "1 day I'll get to it" is not.
    static let quantifyingUnits: Set<String> = [
        "am", "pm", "o'clock", "oclock",
        "hour", "hours", "hr", "hrs",
        "minute", "minutes", "min", "mins",
        "second", "seconds", "sec", "secs",
        "percent",
        "dollar", "dollars", "rupee", "rupees", "euro", "euros",
        "pound", "pounds", "cent", "cents",
        "kg", "kilo", "kilos", "kilogram", "kilograms",
        "gram", "grams", "km", "kilometre", "kilometres", "kilometer", "kilometers",
        "mile", "miles", "metre", "metres", "meter", "meters",
        "litre", "litres", "liter", "liters", "ml",
        "degree", "degrees", "star", "stars",
        "kb", "mb", "gb", "tb", "mph", "kmph",
    ]

    /// Words that turn the number before them into an ordinal, which this does
    /// not write: "the twenty first" must not become "the 20 first".
    ///
    /// "second" is deliberately absent. It is an ordinal far less often than it
    /// is a unit of time, so `isOrdinalSecond` decides it from context:
    /// "a five second delay" converts, "the twenty second of June" does not.
    static let ordinalWords: Set<String> = [
        "first", "third", "fourth", "fifth", "sixth", "seventh", "eighth",
        "ninth", "tenth", "eleventh", "twelfth", "thirteenth", "fourteenth",
        "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth",
        "twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth",
        "seventieth", "eightieth", "ninetieth", "hundredth", "thousandth",
        "millionth",
    ]

    // MARK: - Conversion

    static func digits(in text: String) -> String {
        guard !text.isEmpty, let wordPattern else { return text }
        let string = text as NSString
        let words = wordPattern.matches(
            in: text,
            range: NSRange(location: 0, length: string.length)
        )
        guard !words.isEmpty else { return text }

        var result = ""
        var copied = 0
        var index = 0
        while index < words.count {
            // A number opens with a value, never with "hundred", "and" or
            // "point" — those are "hundreds of people", "you and I", "to the
            // point", and starting a run on one would swallow the number that
            // follows it.
            let opensWithA = isArticleBeforeAMultiplier(at: index, in: words, text: string)
            guard let first = opensWithA ? .unit(1) : word(for: string.substring(with: words[index].range)),
                  first.opensANumber
            else {
                index += 1
                continue
            }

            var tokens = [first]
            var last = index
            // Grow while the next word continues this number and only a space
            // or a hyphen separates them. A line break or a comma ends the run:
            // "twenty,\nthree" is two numbers, whatever it would parse as.
            while last + 1 < words.count,
                  isJoiner(gapAfter: last, in: words, text: string),
                  let next = word(for: string.substring(with: words[last + 1].range)),
                  next.mayExtend(tokens),
                  !startsASecondHundreds(next, after: tokens, at: last + 1, in: words, text: string)
            {
                tokens.append(next)
                last += 1
            }
            // "two hundred and the rest" and "five point Nemo" ran into the next
            // clause; the connector goes back to being a word.
            while let trailing = tokens.last, trailing.isConnector {
                tokens.removeLast()
                last -= 1
            }
            // "a hundred times" and "a million reasons" are idioms, not
            // quantities; "a" only counts when more of the number follows.
            if opensWithA, tokens.count <= 2 {
                index += 1
                continue
            }

            guard !tokens.isEmpty,
                  let phrase = parse(tokens),
                  isWorthConverting(tokens: tokens, startingAt: index, endingAt: last, in: words, text: string)
            else {
                // Left exactly as dictated — including a run that did not parse,
                // which stays whole rather than being picked apart into the
                // numbers it happens to contain.
                index = last + 1
                continue
            }

            let start = words[index].range.location
            result += string.substring(with: NSRange(
                location: copied,
                length: start - copied
            ))
            result += phrase.formatted
            copied = words[last].range.upperBound
            index = last + 1
        }
        result += string.substring(from: copied)
        return result
    }

    /// The two judgement calls, once the words have been shown to add up: an
    /// ordinal after the number, and a lone "one".
    private static func isWorthConverting(
        tokens: [Token],
        startingAt first: Int,
        endingAt last: Int,
        in words: [NSTextCheckingResult],
        text: NSString
    ) -> Bool {
        let following: (word: String, gap: String)? = last + 1 < words.count
            ? (
                text.substring(with: words[last + 1].range).lowercased(),
                text.substring(with: NSRange(
                    location: words[last].range.upperBound,
                    length: words[last + 1].range.location - words[last].range.upperBound
                ))
            )
            : nil

        // "twenty first" and "twenty-first" are one ordinal, not a number with a
        // word after it.
        if let following,
           following.gap == " " || following.gap == "-" || following.gap == "‑",
           ordinalWords.contains(following.word)
        {
            return false
        }
        if isOrdinalSecond(tokens: tokens, startingAt: first, endingAt: last, in: words, text: text) {
            return false
        }

        // A lone "one" needs a unit after it to read as a quantity. Everything
        // else that parsed is a number the user said out loud.
        guard tokens == [.unit(1)] else { return true }
        // "one, pm" is not a time; only a plain space keeps the unit attached.
        guard let following, following.gap == " " else { return false }
        return quantifyingUnits.contains(following.word)
    }

    /// Whether the "second" after this number makes it an ordinal ("the twenty
    /// second of June") rather than a duration ("a twenty second delay").
    ///
    /// Only a number ending in "twenty"–"ninety", "hundred", or a scale can
    /// form an ordinal with "second", so "a five second delay" never gets
    /// here. For those, a duration is an adjective: it follows "a" and needs a
    /// noun after it, perhaps past a comma ("a twenty second, high-quality
    /// clip"). An ordinal follows a month or a possessive, ends the sentence,
    /// or runs into a preposition, conjunction, or pronoun. "the forty second
    /// floor" stays ambiguous and converts, as a duration would.
    ///
    /// VocaPhone treats every "second" as a unit, so this is the one place the
    /// Mac keeps more words than the phone does.
    private static func isOrdinalSecond(
        tokens: [Token],
        startingAt first: Int,
        endingAt last: Int,
        in words: [NSTextCheckingResult],
        text: NSString
    ) -> Bool {
        switch tokens.last {
        case .tens, .hundred, .scale: break
        default: return false
        }
        let second = last + 1
        guard second < words.count,
              text.substring(with: words[second].range).lowercased() == "second",
              isJoiner(gapAfter: last, in: words, text: text)
        else { return false }

        if first > 0, gap(after: first - 1, in: words, text: text) == " " {
            let before = text.substring(with: words[first - 1].range).lowercased()
            if before == "a" || before == "an" { return false }
            if ordinalLeaders.contains(before) { return true }
        }
        // A duration adjective can't end the text or a sentence: "on the
        // twenty second." Past a comma, the next word still decides.
        guard second + 1 < words.count else { return true }
        let separator = gap(after: second, in: words, text: text)
        if separator.contains(where: { ".!?;:".contains($0) || $0.isNewline }) { return true }
        return ordinalFollowers.contains(text.substring(with: words[second + 1].range).lowercased())
    }

    /// Words before a number that make a following "second" an ordinal:
    /// "June twenty second", "his thirty second birthday".
    private static let ordinalLeaders: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
        "my", "your", "his", "her", "its", "our", "their",
    ]

    /// Words a duration adjective can't describe, so "second" before one is
    /// an ordinal: "the twenty second of June", "on the thirty second we
    /// launch".
    private static let ordinalFollowers: Set<String> = [
        "of", "at", "in", "on", "by", "for", "from", "to", "through", "until",
        "and", "or", "but", "so", "then",
        "i", "we", "you", "he", "she", "they", "it", "is", "was", "will",
    ]

    /// Whether word `index` is an "a" that stands for one before "hundred" or a
    /// scale: "a hundred and fifty", "a thousand five hundred".
    private static func isArticleBeforeAMultiplier(
        at index: Int,
        in words: [NSTextCheckingResult],
        text: NSString
    ) -> Bool {
        guard index + 1 < words.count,
              text.substring(with: words[index].range).lowercased() == "a",
              isJoiner(gapAfter: index, in: words, text: text)
        else { return false }
        switch word(for: text.substring(with: words[index + 1].range)) {
        case .hundred, .scale: return true
        default: return false
        }
    }

    /// Whether `next` opens another hundreds group in a segment that already
    /// has one: in "two hundred three hundred" the "three" starts a second
    /// number, where taking it would read as 20300.
    private static func startsASecondHundreds(
        _ next: Token,
        after tokens: [Token],
        at position: Int,
        in words: [NSTextCheckingResult],
        text: NSString
    ) -> Bool {
        switch next {
        case .unit, .teen: break
        default: return false
        }
        let segment = tokens.reversed().prefix { if case .scale = $0 { false } else { true } }
        guard segment.contains(.hundred),
              position + 1 < words.count,
              isJoiner(gapAfter: position, in: words, text: text)
        else { return false }
        return word(for: text.substring(with: words[position + 1].range)) == .hundred
    }

    /// The text between word `index` and the next one.
    private static func gap(after index: Int, in words: [NSTextCheckingResult], text: NSString) -> String {
        text.substring(with: NSRange(
            location: words[index].range.upperBound,
            length: words[index + 1].range.location - words[index].range.upperBound
        ))
    }

    /// What may sit between two words of one number: a single space, or the
    /// hyphen of "twenty-three".
    private static func isJoiner(
        gapAfter index: Int,
        in words: [NSTextCheckingResult],
        text: NSString
    ) -> Bool {
        let separator = gap(after: index, in: words, text: text)
        return separator == " " || separator == "-" || separator == "‑"
    }

    // MARK: - Grammar

    private enum Token: Equatable {
        case unit(Int)
        case teen(Int)
        case tens(Int)
        case hundred
        case scale(Int)
        case and
        case point

        var opensANumber: Bool {
            switch self {
            case .unit, .teen, .tens: true
            case .hundred, .scale, .and, .point: false
            }
        }

        /// "and" and "point" join two halves of a number and are worth nothing
        /// on their own, so a run that ends on one has run past its number.
        var isConnector: Bool {
            switch self {
            case .and, .point: true
            default: false
            }
        }

        /// Whether this word can be taken as part of the run so far.
        ///
        /// Only the connectors are checked here, and only to stop them being
        /// swallowed from the sentence around the number — "between five and
        /// ten" is two numbers with a conjunction, not one number. Everything
        /// else is left to `parse`, which rejects the whole run if the words
        /// do not add up.
        func mayExtend(_ tokens: [Token]) -> Bool {
            switch self {
            case .and:
                // "two hundred and fifty" is one number; "five and ten" is not.
                switch tokens.last {
                case .hundred, .scale: return true
                default: return false
                }
            case .point:
                return tokens.last?.isConnector == false
            default:
                return true
            }
        }
    }

    private struct Phrase {
        var value: Int
        var decimals: String

        var formatted: String {
            decimals.isEmpty ? String(value) : "\(value).\(decimals)"
        }
    }

    private static let wordPattern = try? NSRegularExpression(
        pattern: "[A-Za-z]+(?:['’][A-Za-z]+)*"
    )

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        // "fourty" is a common misspelling, and a speech model that emits it is
        // still saying forty.
        "twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = [
        "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
    ]

    private static func word(for text: String) -> Token? {
        let key = text.lowercased()
        if let value = units[key] { return .unit(value) }
        if let value = teens[key] { return .teen(value) }
        if let value = tens[key] { return .tens(value) }
        if let value = scales[key] { return .scale(value) }
        switch key {
        case "hundred": return .hundred
        case "and": return .and
        case "point": return .point
        default: return nil
        }
    }

    /// The value of a run, or `nil` when the words are adjacent numbers rather
    /// than one number.
    private static func parse(_ tokens: [Token]) -> Phrase? {
        var total = 0
        var group = 0
        var decimals = ""
        var isDecimal = false
        var smallestScale = Int.max
        var previous: Token?

        for token in tokens {
            guard mayFollow(previous, token: token, isDecimal: isDecimal) else { return nil }
            switch token {
            case let .unit(value):
                if isDecimal { decimals.append(String(value)) } else { group += value }
            case let .teen(value):
                group += value
            case let .tens(value):
                group += value
            case .hundred:
                // A group takes one "hundred": "two hundred three hundred" is
                // two numbers, not 20300.
                guard group < 100 else { return nil }
                group *= 100
            case let .scale(value):
                // Scales descend: "two million three thousand", never "three
                // thousand two million".
                guard group > 0, value < smallestScale else { return nil }
                smallestScale = value
                total += group * value
                group = 0
            case .and:
                break
            case .point:
                isDecimal = true
            }
            previous = token
        }

        if isDecimal, decimals.isEmpty { return nil }
        let value = total + group
        guard value <= maximum else { return nil }
        return Phrase(value: value, decimals: decimals)
    }

    /// The whole grammar, as the one question that matters at each word: can
    /// this follow that? Anything rejected here leaves the run as words.
    private static func mayFollow(_ previous: Token?, token: Token, isDecimal: Bool) -> Bool {
        // Past the decimal point a number is read out digit by digit.
        if isDecimal {
            if case .unit = token { return true }
            return false
        }
        switch previous {
        case .none:
            return token.opensANumber
        case let .unit(value):
            switch token {
            // "zero hundred" and "zero thousand" are not numbers anyone says.
            case .hundred, .scale: return value > 0
            case .point: return true
            default: return false
            }
        case .teen:
            switch token {
            // "nineteen hundred" and "nineteen thousand" both work.
            case .hundred, .scale, .point: return true
            default: return false
            }
        case .tens:
            switch token {
            // "twenty three", never "twenty zero" or "twenty hundred".
            case let .unit(value): return value > 0
            case .scale, .point: return true
            default: return false
            }
        case .hundred:
            switch token {
            case let .unit(value): return value > 0
            case .teen, .tens, .scale, .and, .point: return true
            default: return false
            }
        case .scale:
            switch token {
            case let .unit(value): return value > 0
            // "two thousand five hundred" opens a new group with "five";
            // "two thousand hundred" is not English, so "hundred" cannot
            // follow a scale directly.
            case .teen, .tens, .scale, .and, .point: return true
            default: return false
            }
        case .and:
            switch token {
            case let .unit(value): return value > 0
            case .teen, .tens: return true
            default: return false
            }
        case .point:
            if case .unit = token { return true }
            return false
        }
    }
}
