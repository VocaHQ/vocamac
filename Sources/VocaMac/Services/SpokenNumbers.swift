// SpokenNumbers.swift
// VocaMac
//
// Rewrites dictated English number words as digits. Ported from the VocaPhone
// clients; the shared cases in `Tests/VocaMacTests/Fixtures/spoken-numbers.tsv`
// are the contract both are expected to meet.

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
/// * A lone "one" stays a word unless a unit follows it or another number is
///   paired with it ("one or two"). "no one", "one of them" and "one day I'll
///   get to it" are ruined by a converter that cannot tell a quantity from a
///   pronoun.
/// * Idioms keep their words: "high five", "cloud nine", "forty winks".
/// * Shapes that are only numbers in context need that context. Digit strings
///   ("nine eight seven…") convert after a cue such as "number is" or "code";
///   years ("nineteen ninety nine") after "in", "since" or "year"; spoken
///   times ("seven thirty") before "am" or "pm".
///
/// With `symbols`, the stage also writes what digits usually travel with:
/// "50%", "$5.50", "-5", "21st" and "June 22". Off, those words stay words.
///
/// English only. The word lists match nothing in another language, so a Hindi
/// or Spanish transcript passes through untouched rather than being partially
/// mangled.
enum SpokenNumbers {
    /// The largest number this will write out in full. Past a trillion, a
    /// phrase is far more likely to be a misrecognition than something a
    /// person said. "three trillion" still converts, as "3 trillion".
    static let maximum = 999_999_999_999

    /// Numbers at or above this are written with thousands separators:
    /// "12,500". Four-digit numbers are not, because most of them that people
    /// dictate are years ("2005") or codes.
    static let groupingThreshold = 10_000

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
        "gram", "grams", "mg", "km", "kilometre", "kilometres", "kilometer", "kilometers",
        "mile", "miles", "metre", "metres", "meter", "meters",
        "litre", "litres", "liter", "liters", "ml",
        "degree", "degrees", "star", "stars",
        "kb", "mb", "gb", "tb", "mph", "kmph",
    ]

    /// Words that turn the number before them into an ordinal: "the twenty
    /// first" must not become "the 20 first".
    ///
    /// "second" is deliberately absent. It is an ordinal far less often than it
    /// is a unit of time, so `isOrdinalSecond` decides it from context:
    /// "a five second delay" converts, "the twenty second of June" does not.
    static let ordinalWords: Set<String> = Set(ordinalValues.keys).subtracting(["second"])

    /// What each ordinal word is worth, for `symbols`: "twenty first" is 21st.
    private static let ordinalValues: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
        "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11,
        "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
        "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50,
        "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90,
        "hundredth": 100, "thousandth": 1_000, "millionth": 1_000_000,
    ]

    // MARK: - Conversion

    /// Rewrites every number phrase in `text` as digits.
    ///
    /// - Parameter symbols: Also write "%", currency signs, a minus sign,
    ///   ordinal suffixes and dates: "fifty percent" becomes "50%", "June
    ///   twenty second" becomes "June 22".
    static func digits(in text: String, symbols: Bool = false) -> String {
        guard !text.isEmpty, let words = Words(text), !words.isEmpty else { return text }
        let protected = idiomWords(in: words)

        var result = ""
        var copied = 0
        var index = 0
        while index < words.count {
            let match = fixedPhrase(at: index, in: words)
                ?? time(at: index, in: words, protected: protected)
                ?? digitString(at: index, in: words)
                ?? year(at: index, in: words, protected: protected)
                ?? (symbols ? dayOfMonth(at: index, in: words) : nil)
                ?? number(at: index, in: words, protected: protected, symbols: symbols)
            guard let match else {
                index += 1
                continue
            }
            if let replacement = match.replacement {
                let start = words.ranges[match.first].location
                result += words.text.substring(with: NSRange(location: copied, length: start - copied))
                result += replacement
                copied = words.ranges[match.last].upperBound
            }
            // A run that did not convert is skipped whole, rather than being
            // picked apart into the numbers it happens to contain.
            index = match.last + 1
        }
        guard copied > 0 else { return text }
        result += words.text.substring(from: copied)
        return result
    }

    /// Words `first...last` and what to write for them. A nil replacement
    /// leaves the words as spoken and moves past them.
    private struct Match {
        var first: Int
        var last: Int
        var replacement: String?
    }

    // MARK: - Number phrases

    /// A run of number words starting at `index`: "twenty three", "two
    /// hundred and fifty", "three point five", "a thousand".
    private static func number(
        at index: Int, in words: Words, protected: Set<Int>, symbols: Bool
    ) -> Match? {
        guard !protected.contains(index) else { return nil }
        // "oh seven" is "oh, seven" as often as it is 07; "four oh four" is
        // taken as a digit string before this.
        if index > 0, zeroWords.contains(words.lower[index - 1]), words.isJoiner(after: index - 1) {
            return nil
        }

        // A number opens with a value, never with "hundred", "and" or "point"
        // — those are "hundreds of people", "you and I", "to the point", and
        // starting a run on one would swallow the number that follows it.
        // Three openers stand in for a value: "a hundred" (1), "nought point
        // five" (0), and "point five percent" (0).
        var tokens: [Token]
        let opensWithA = isArticleBeforeAMultiplier(at: index, in: words)
        let opensWithPoint = words.lower[index] == "point"
        if opensWithA {
            tokens = [.unit(1)]
        } else if opensWithPoint {
            guard index + 1 < words.count, words.isJoiner(after: index),
                  case .unit = words.token(index + 1)
            else { return nil }
            tokens = [.unit(0), .point]
        } else if words.lower[index] == "nought", index + 1 < words.count,
                  words.isJoiner(after: index), words.lower[index + 1] == "point" {
            tokens = [.unit(0)]
        } else if let first = words.token(index), first.opensANumber {
            tokens = [first]
        } else {
            return nil
        }

        var last = index
        // Grow while the next word continues this number and only a space or
        // a hyphen separates them. A line break or a comma ends the run:
        // "twenty,\nthree" is two numbers, whatever it would parse as.
        while last + 1 < words.count,
              !protected.contains(last + 1),
              words.isJoiner(after: last),
              let next = words.token(last + 1, isDecimal: tokens.contains(.point)),
              next.mayExtend(tokens),
              !startsASecondHundreds(next, after: tokens, at: last + 1, in: words) {
            tokens.append(next)
            last += 1
        }
        // "two hundred and the rest" and "five point Nemo" ran into the next
        // clause; the connector goes back to being a word.
        while let trailing = tokens.last, trailing.isConnector, last > index {
            tokens.removeLast()
            last -= 1
        }
        if opensWithPoint {
            // A bare "point five" is "0.5" only as a quantity: "point five
            // percent". "At some point five people came" is a sentence.
            guard tokens.count >= 3, isFollowedByQuantifyingUnit(last, in: words) else { return nil }
        }
        // "a hundred times" and "a million reasons" are idioms, not
        // quantities; "a" only counts when more of the number follows, or a
        // unit does: "a hundred dollars".
        if opensWithA, tokens.count <= 2, !isFollowedByQuantifyingUnit(last, in: words) {
            return nil
        }
        guard tokens.count > (opensWithPoint ? 2 : 0), var phrase = parse(tokens) else {
            return Match(first: index, last: last, replacement: nil)
        }

        let skip = Match(first: index, last: last, replacement: nil)
        let next = last + 1 < words.count ? last + 1 : nil
        let nextWord = next.map { words.lower[$0] }
        let spaceAfter = next != nil && words.gap(after: last) == " "

        // "three quarters" and "eighteen hundreds" are not quantities of a
        // unit; the number is part of the phrase.
        if spaceAfter, let nextWord, fractionNouns.contains(nextWord) || pluralScales.contains(nextWord) {
            return skip
        }

        // "twenty first" and "twenty-first" are one ordinal, not a number with
        // a word after it.
        let isOrdinal = next.map { next in
            words.isJoiner(after: last)
                && (ordinalWords.contains(words.lower[next])
                    || isOrdinalSecond(tokens: tokens, startingAt: index, endingAt: last, in: words))
        } ?? false
        if isOrdinal, let next {
            guard symbols, let value = compoundOrdinal(tokens, phrase, words.lower[next]) else { return skip }
            // "June twenty second" is a date: "June 22", not "June 22nd".
            let date = index > 0 && isMonth(before: index, in: words)
            return Match(first: index, last: next, replacement: date ? String(value) : ordinal(value))
        }

        // "two and a half hours" is 2.5 hours.
        if phrase.decimals.isEmpty, phrase.scaleWord == nil,
           let fraction = fraction(after: last, in: words) {
            phrase.decimals = fraction.decimals
            last = fraction.last
        } else if tokens == [.unit(1)], !isQuantity(one: index, in: words) {
            return nil
        }

        var first = index
        var formatted = phrase.formatted
        if symbols {
            var sign = ""
            if let minus = negativeSign(before: index, in: words) {
                first = minus
                sign = "-"
            }
            if let percent = percentSign(after: last, in: words) {
                last = percent
                formatted += "%"
            } else if let money = currency(after: last, in: words) {
                last = money.last
                if let cents = money.cents, phrase.decimals.isEmpty, phrase.scaleWord == nil {
                    formatted += "." + cents
                }
                formatted = money.symbol + formatted
            } else if let shared = rangeSymbol(after: last, in: words) {
                // "twenty to thirty dollars" is "$20 to $30", not "20 to $30".
                formatted = shared == "%" ? formatted + "%" : shared + formatted
            }
            formatted = sign + formatted
        }
        return Match(first: first, last: last, replacement: formatted)
    }

    /// Whether a lone "one" is a quantity: a unit follows it ("one pm"), or it
    /// is paired with another number ("one or two", "between one and five").
    ///
    /// Only a plain space keeps a unit attached: "one, pm" is not a time.
    private static func isQuantity(one index: Int, in words: Words) -> Bool {
        let last = index
        if last + 1 < words.count, words.gap(after: last) == " ",
           quantifyingUnits.contains(words.lower[last + 1]) {
            return true
        }
        if last + 2 < words.count, words.gap(after: last) == " ", words.gap(after: last + 1) == " ",
           pairingWords.contains(words.lower[last + 1]), isPartner(words.lower[last + 2]) {
            return true
        }
        if index >= 2, words.gap(after: index - 1) == " ", words.gap(after: index - 2) == " ",
           pairingWords.contains(words.lower[index - 1]), isPartner(words.lower[index - 2]) {
            return true
        }
        return false
    }

    /// Words that join two numbers into a pair or a range.
    private static let pairingWords: Set<String> = ["or", "to", "and"]

    /// A number word that can pair with a lone "one". Another "one" cannot:
    /// "one to one" and "one or the other" stay words.
    private static func isPartner(_ word: String) -> Bool {
        word != "one" && (units[word] != nil || teens[word] != nil || tens[word] != nil)
    }

    /// "and a half" or "and a quarter" right after a number.
    private static func fraction(after last: Int, in words: Words) -> (decimals: String, last: Int)? {
        guard last + 3 < words.count,
              words.gap(after: last) == " ", words.gap(after: last + 1) == " ", words.gap(after: last + 2) == " ",
              words.lower[last + 1] == "and", words.lower[last + 2] == "a"
        else { return nil }
        switch words.lower[last + 3] {
        case "half": return ("5", last + 3)
        case "quarter": return ("25", last + 3)
        default: return nil
        }
    }

    /// Nouns a number is part of rather than a count of.
    private static let fractionNouns: Set<String> = [
        "half", "halves", "quarter", "quarters", "thirds", "fourths", "fifths",
        "sixths", "sevenths", "eighths", "ninths", "tenths",
    ]

    /// "eighteen hundreds", "two millions": scale words that are nouns.
    private static let pluralScales: Set<String> = [
        "hundreds", "thousands", "millions", "billions", "trillions", "dozens",
    ]

    // MARK: - Ordinals and dates

    /// The value of a number run followed by an ordinal word, when the two
    /// compose: "twenty first" is 21, "one hundred second" is 102. "two
    /// first" and "one hundredth" do not.
    private static func compoundOrdinal(_ tokens: [Token], _ phrase: Phrase, _ word: String) -> Int? {
        guard phrase.decimals.isEmpty, phrase.scaleWord == nil,
              let value = ordinalValues[word], value < 100
        else { return nil }
        switch tokens.last {
        case .tens: return value < 10 ? phrase.value + value : nil
        case .hundred, .scale: return phrase.value + value
        default: return nil
        }
    }

    /// "21st", "22nd", "23rd", "11th".
    private static func ordinal(_ value: Int) -> String {
        let suffix: String
        switch (value % 10, value % 100) {
        case (_, 11...13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(value)\(suffix)"
    }

    /// A lone ordinal as a day of the month: "May fifth" is "May 5", "the
    /// fifth of May" is "the 5th of May". Only with `symbols`, and only next
    /// to a month: "first of all" and "the fifth element" stay words.
    private static func dayOfMonth(at index: Int, in words: Words) -> Match? {
        guard let value = ordinalValues[words.lower[index]], value <= 31 else { return nil }
        if index > 0, isMonth(before: index, in: words) {
            return Match(first: index, last: index, replacement: String(value))
        }
        if index + 2 < words.count, words.gap(after: index) == " ", words.gap(after: index + 1) == " ",
           words.lower[index + 1] == "of", isMonth(words.original(index + 2)) {
            return Match(first: index, last: index, replacement: ordinal(value))
        }
        return nil
    }

    /// Whether the word before `index`, past one space, names a month.
    private static func isMonth(before index: Int, in words: Words) -> Bool {
        words.gap(after: index - 1) == " " && isMonth(words.original(index - 1))
    }

    /// "May" and "March" are also ordinary words ("you may", "march on"), so
    /// they count only when capitalized.
    private static func isMonth(_ word: String) -> Bool {
        let lower = word.lowercased()
        guard months.contains(lower) else { return false }
        if lower == "may" || lower == "march" { return word.first?.isUppercase == true }
        return true
    }

    private static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
    ]

    // MARK: - Symbols

    /// "minus five" and "negative ten", unless a number comes before the
    /// sign: "ten minus five" is arithmetic, not "10 -5".
    private static func negativeSign(before index: Int, in words: Words) -> Int? {
        let sign = index - 1
        guard sign >= 0, words.gap(after: sign) == " ",
              words.lower[sign] == "minus" || words.lower[sign] == "negative"
        else { return nil }
        if sign > 0, words.isJoiner(after: sign - 1), let token = words.token(sign - 1),
           token != .and, token != .point {
            return nil
        }
        return sign
    }

    /// "percent" or "per cent" after the number.
    private static func percentSign(after last: Int, in words: Words) -> Int? {
        guard last + 1 < words.count, words.gap(after: last) == " " else { return nil }
        if words.lower[last + 1] == "percent" { return last + 1 }
        if last + 2 < words.count, words.lower[last + 1] == "per",
           words.gap(after: last + 1) == " ", words.lower[last + 2] == "cent" {
            return last + 2
        }
        return nil
    }

    /// A currency after the number, and the cents after that: "five dollars
    /// and fifty cents" is $5.50.
    ///
    /// Pounds are left out on purpose: "five pounds" is a weight as often as
    /// it is money.
    private static func currency(after last: Int, in words: Words) -> (symbol: String, last: Int, cents: String?)? {
        guard last + 1 < words.count, words.gap(after: last) == " ",
              let symbol = currencySymbols[words.lower[last + 1]]
        else { return nil }
        let unit = last + 1
        let plain = (symbol: symbol, last: unit, cents: String?.none)
        // "and fifty cents", "and five cents", "and twenty-five cents".
        var index = unit + 2
        guard index < words.count, words.gap(after: unit) == " ", words.lower[unit + 1] == "and",
              words.gap(after: unit + 1) == " "
        else { return plain }
        var cents: Int
        switch words.token(index) {
        case let .unit(value) where value > 0: cents = value
        case let .teen(value): cents = value
        case let .tens(value):
            cents = value
            if index + 1 < words.count, words.isJoiner(after: index),
               case let .unit(unit) = words.token(index + 1), unit > 0 {
                cents += unit
                index += 1
            }
        default: return plain
        }
        guard index + 1 < words.count, words.gap(after: index) == " ",
              words.lower[index + 1] == "cent" || words.lower[index + 1] == "cents"
        else { return plain }
        return (symbol, index + 1, String(format: "%02d", cents))
    }

    /// The symbol the second number of a range takes, for the first to share:
    /// "twenty to thirty dollars", "five or ten percent".
    ///
    /// Not when only the second has a scale: "between two and three hundred
    /// dollars" may be $200 to $300, and "$2" would be a guess.
    private static func rangeSymbol(after last: Int, in words: Words) -> String? {
        guard last + 2 < words.count, words.gap(after: last) == " ",
              pairingWords.contains(words.lower[last + 1]), words.gap(after: last + 1) == " ",
              let opener = words.token(last + 2), opener.opensANumber
        else { return nil }
        var end = last + 2
        while end + 1 < words.count, end - last < 8, words.isJoiner(after: end), let token = words.token(end + 1),
              token != .and {
            end += 1
        }
        if (last + 2...end).contains(where: { words.token($0) == .hundred || isScale(words.token($0)) }) {
            return nil
        }
        if percentSign(after: end, in: words) != nil { return "%" }
        return currency(after: end, in: words)?.symbol
    }

    private static func isScale(_ token: Token?) -> Bool {
        if case .scale = token { return true }
        return false
    }

    private static let currencySymbols: [String: String] = [
        "dollar": "$", "dollars": "$", "euro": "€", "euros": "€", "rupee": "₹", "rupees": "₹",
    ]

    // MARK: - Times, digit strings and years

    /// "seven thirty pm" → "7:30 pm", "twelve oh five am" → "12:05 am".
    ///
    /// Only before "am" or "pm". Without one, "seven thirty" is as likely to be
    /// two numbers, a score, or a price as it is a time, and stays words.
    private static func time(at index: Int, in words: Words, protected: Set<Int>) -> Match? {
        guard !protected.contains(index), index + 1 < words.count, words.gap(after: index) == " " else { return nil }
        let hour: Int
        switch words.token(index) {
        case let .unit(value) where value > 0: hour = value
        case let .teen(value) where value <= 12: hour = value
        default: return nil
        }
        var last = index + 1
        let minutes: Int
        switch words.token(last) {
        case let .teen(value):
            minutes = value
        case let .tens(value) where value <= 50:
            minutes = value
            if last + 1 < words.count, words.isJoiner(after: last),
               case let .unit(unit) = words.token(last + 1), unit > 0 {
                last += 1
                return timeMatch(index, last, hour, value + unit, in: words)
            }
        default:
            guard zeroWords.contains(words.lower[last]) || words.lower[last] == "zero",
                  last + 1 < words.count, words.gap(after: last) == " ",
                  case let .unit(unit) = words.token(last + 1), unit > 0
            else { return nil }
            last += 1
            minutes = unit
        }
        return timeMatch(index, last, hour, minutes, in: words)
    }

    private static func timeMatch(_ first: Int, _ last: Int, _ hour: Int, _ minutes: Int, in words: Words) -> Match? {
        guard let meridiem, last + 1 < words.count else { return nil }
        let rest = words.text.substring(from: words.ranges[last].upperBound)
        guard meridiem.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) != nil
        else { return nil }
        return Match(first: first, last: last, replacement: String(format: "%d:%02d", hour, minutes))
    }

    /// " am", " pm", " a.m.", " P.M." right after the minutes.
    private static let meridiem = try? NSRegularExpression(pattern: "^ (?:[AaPp]\\.?[Mm]\\.?)(?![A-Za-z])")

    /// A string of single digits, written as one: "my number is nine eight
    /// seven…" → "my number is 987…", "room four oh four" → "room 404".
    ///
    /// Three digits or more, and either a cue word just before it ("number",
    /// "code", "PIN") or an "oh" inside it, which only a digit string has.
    /// "one two three four" on its own is a count, and stays words.
    private static func digitString(at index: Int, in words: Words) -> Match? {
        var digits = ""
        var last = index - 1
        var hasInnerZero = false
        var hasRepeat = false
        var next = index
        while next < words.count {
            if next > index, !words.isJoiner(after: next - 1) { break }
            let word = words.lower[next]
            if let repeatCount = repeats[word], next + 1 < words.count, words.gap(after: next) == " ",
               case let .unit(value) = words.token(next + 1) {
                digits += String(repeating: String(value), count: repeatCount)
                hasRepeat = true
                last = next + 1
                next += 2
            } else if case let .unit(value) = words.token(next) {
                digits += String(value)
                last = next
                next += 1
            } else if next > index, zeroWords.contains(word) {
                digits += "0"
                hasInnerZero = true
                last = next
                next += 1
            } else {
                break
            }
        }
        guard digits.count >= 3, last >= index else { return nil }
        // An "oh" that ends the string is "four five oh" said to someone, not
        // a digit.
        if zeroWords.contains(words.lower[last]), !hasCue(before: index, in: words) { return nil }
        guard hasCue(before: index, in: words) || (hasInnerZero && !hasRepeat) else { return nil }
        return Match(first: index, last: last, replacement: digits)
    }

    /// Words that read as the digit 0 inside a number: "four oh four", "three
    /// point oh".
    private static let zeroWords: Set<String> = ["oh", "o", "nought"]

    /// "double seven" is 77 inside a phone number, and two words outside one.
    private static let repeats: [String: Int] = ["double": 2, "triple": 3]

    /// Whether a digit string at `index` is introduced as one: "my number is",
    /// "code", "PIN:", "room".
    private static func hasCue(before index: Int, in words: Words) -> Bool {
        var word = index - 1
        var fillers = 0
        while word >= 0, fillers <= 2 {
            let gap = words.gap(after: word)
            guard gap == " " || gap == ": " || gap == " #" || gap == " # " else { return false }
            if digitCues.contains(words.lower[word]) { return true }
            guard cueFillers.contains(words.lower[word]) else { return false }
            fillers += 1
            word -= 1
        }
        return false
    }

    private static let digitCues: Set<String> = [
        "number", "phone", "mobile", "cell", "code", "pin", "otp", "extension", "ext",
        "room", "zip", "zipcode", "postcode", "flight", "account", "card", "id",
        "passcode", "ticket", "order", "reference", "ref", "gate", "apartment", "apt",
        "suite", "invoice", "tracking", "serial",
    ]

    /// Words that may sit between a cue and its digits: "number is", "code
    /// was", "PIN is".
    private static let cueFillers: Set<String> = ["is", "was", "it's", "its", "at", "number", "code"]

    /// A year said as two pairs: "in nineteen ninety nine" → "in 1999",
    /// "since twenty twenty" → "since 2020", "nineteen oh five" → "1905".
    ///
    /// Needs "in", "since", "year" or "circa" in front, or an "oh" in the
    /// middle. "nineteen eighty four" on its own is a title as often as a
    /// year, and "twenty twenty five" is a score.
    private static func year(at index: Int, in words: Words, protected: Set<Int>) -> Match? {
        guard !protected.contains(index), index + 1 < words.count, words.gap(after: index) == " " else { return nil }
        let century: Int
        switch words.token(index) {
        case let .teen(value) where value >= 11: century = value
        case .tens(20): century = 20
        default: return nil
        }
        var last = index + 1
        var rest: Int
        var saidOh = false
        switch words.token(last) {
        case let .teen(value):
            rest = value
        case let .tens(value):
            rest = value
            if last + 1 < words.count, words.isJoiner(after: last), case let .unit(unit) = words.token(last + 1), unit > 0 {
                rest += unit
                last += 1
            }
        default:
            guard zeroWords.contains(words.lower[last]), last + 1 < words.count, words.gap(after: last) == " ",
                  case let .unit(unit) = words.token(last + 1), unit > 0
            else { return nil }
            rest = unit
            saidOh = true
            last += 1
        }
        let cued = index > 0 && words.gap(after: index - 1) == " " && yearCues.contains(words.lower[index - 1])
        guard cued || saidOh else { return nil }
        // "in fifteen twenty minutes" is two numbers.
        if last + 1 < words.count, words.gap(after: last) == " ",
           quantifyingUnits.contains(words.lower[last + 1]) || countNouns.contains(words.lower[last + 1]) {
            return nil
        }
        return Match(first: index, last: last, replacement: String(century * 100 + rest))
    }

    private static let yearCues: Set<String> = ["in", "since", "year", "circa"]

    /// Nouns that make a pair of numbers a count rather than a year.
    private static let countNouns: Set<String> = [
        "day", "days", "week", "weeks", "month", "months", "year", "years",
        "time", "times", "people", "things", "items", "copies", "points",
    ]

    /// Phrases whose digit form is not the digits of their words:
    /// "twenty four seven" is 24/7.
    private static func fixedPhrase(at index: Int, in words: Words) -> Match? {
        for (phrase, written) in fixedPhrases where words.matches(phrase, at: index) {
            return Match(first: index, last: index + phrase.count - 1, replacement: written)
        }
        return nil
    }

    private static let fixedPhrases: [([String], String)] = [
        (["twenty", "four", "seven"], "24/7"),
        (["twenty", "four", "by", "seven"], "24/7"),
    ]

    // MARK: - Idioms

    /// Indices of the number words inside idioms, which stay words: "high
    /// five", "cloud nine", "forty winks", "one sec".
    private static func idiomWords(in words: Words) -> Set<Int> {
        var protected: Set<Int> = []
        for index in 0..<words.count {
            for idiom in idioms where words.matches(idiom, at: index) {
                protected.formUnion(index..<(index + idiom.count))
            }
            // "double seven" outside a digit string.
            if repeats[words.lower[index]] != nil, index + 1 < words.count,
               words.gap(after: index) == " ", case .unit = words.token(index + 1) {
                protected.insert(index + 1)
            }
        }
        return protected
    }

    private static let idioms: [[String]] = [
        ["high", "five"], ["high", "fives"], ["take", "five"], ["cloud", "nine"],
        ["forty", "winks"], ["zero", "dark", "thirty"], ["zero", "sum"], ["one", "sec"],
        ["ocean's", "eleven"], ["ocean’s", "eleven"], ["big", "three"], ["big", "four"],
        ["three", "musketeers"], ["seven", "seas"], ["four", "by", "four"],
        ["nine", "lives"], ["hang", "ten"], ["magnificent", "seven"], ["famous", "five"],
        ["deep", "six"], ["six", "feet", "under"], ["seven", "deadly", "sins"],
    ]

    // MARK: - Context

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
        tokens: [Token], startingAt first: Int, endingAt last: Int, in words: Words
    ) -> Bool {
        switch tokens.last {
        case .tens, .hundred, .scale: break
        default: return false
        }
        let second = last + 1
        guard second < words.count, words.lower[second] == "second", words.isJoiner(after: last) else { return false }

        if first > 0, words.gap(after: first - 1) == " " {
            let before = words.lower[first - 1]
            if before == "a" || before == "an" { return false }
            if ordinalLeaders.contains(before) { return true }
        }
        // A duration adjective can't end the text or a sentence: "on the
        // twenty second." Past a comma, the next word still decides.
        guard second + 1 < words.count else { return true }
        let separator = words.gap(after: second)
        if separator.contains(where: { ".!?;:".contains($0) || $0.isNewline }) { return true }
        return ordinalFollowers.contains(words.lower[second + 1])
    }

    /// Words before a number that make a following "second" an ordinal:
    /// "June twenty second", "his thirty second birthday".
    private static let ordinalLeaders: Set<String> = months.union([
        "my", "your", "his", "her", "its", "our", "their",
    ])

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
    private static func isArticleBeforeAMultiplier(at index: Int, in words: Words) -> Bool {
        guard index + 1 < words.count, words.lower[index] == "a", words.isJoiner(after: index) else { return false }
        switch words.token(index + 1) {
        case .hundred, .scale: return true
        default: return false
        }
    }

    /// Whether the word after `index`, past a single space, is a unit such as
    /// "dollars" or "hours".
    private static func isFollowedByQuantifyingUnit(_ index: Int, in words: Words) -> Bool {
        guard index + 1 < words.count, words.gap(after: index) == " " else { return false }
        return quantifyingUnits.contains(words.lower[index + 1])
    }

    /// Whether `next` opens another hundreds group in a segment that already
    /// has one: in "two hundred three hundred" the "three" starts a second
    /// number, where taking it would read as 20300.
    private static func startsASecondHundreds(
        _ next: Token, after tokens: [Token], at position: Int, in words: Words
    ) -> Bool {
        switch next {
        case .unit, .teen: break
        default: return false
        }
        let segment = tokens.reversed().prefix { if case .scale = $0 { false } else { true } }
        guard segment.contains(.hundred), position + 1 < words.count, words.isJoiner(after: position) else {
            return false
        }
        return words.token(position + 1) == .hundred
    }

    // MARK: - Words

    /// The words of a transcript, lower-cased once, with the text between them.
    private struct Words {
        let text: NSString
        let ranges: [NSRange]
        let lower: [String]

        init?(_ source: String) {
            guard let wordPattern else { return nil }
            text = source as NSString
            ranges = wordPattern.matches(in: source, range: NSRange(location: 0, length: text.length)).map(\.range)
            lower = ranges.map { (source as NSString).substring(with: $0).lowercased() }
        }

        var count: Int { ranges.count }
        var isEmpty: Bool { ranges.isEmpty }

        func original(_ index: Int) -> String { text.substring(with: ranges[index]) }

        /// The text between word `index` and the next one.
        func gap(after index: Int) -> String {
            text.substring(with: NSRange(
                location: ranges[index].upperBound,
                length: ranges[index + 1].location - ranges[index].upperBound
            ))
        }

        /// What may sit between two words of one number: a single space, or
        /// the hyphen of "twenty-three".
        func isJoiner(after index: Int) -> Bool {
            let separator = gap(after: index)
            return separator == " " || separator == "-" || separator == "‑"
        }

        func token(_ index: Int, isDecimal: Bool = false) -> Token? {
            if let token = SpokenNumbers.word(for: lower[index]) { return token }
            // Past the decimal point "oh" is a zero: "three point oh".
            return isDecimal && zeroWords.contains(lower[index]) ? .unit(0) : nil
        }

        /// Whether `phrase` is said at `index`, joined by spaces or hyphens.
        func matches(_ phrase: [String], at index: Int) -> Bool {
            guard index + phrase.count <= count else { return false }
            for (offset, word) in phrase.enumerated() {
                guard lower[index + offset] == word else { return false }
                if offset > 0, !isJoiner(after: index + offset - 1) { return false }
            }
            return true
        }
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
            // "2.5 million" ends at its scale.
            if case .scale = tokens.last, tokens.contains(.point) { return false }
            switch self {
            case .and:
                // "two hundred and fifty" is one number; "five and ten" is not.
                switch tokens.last {
                case .hundred, .scale: return true
                default: return false
                }
            case .point:
                return tokens.last?.isConnector == false && !tokens.contains(.point)
            default:
                return true
            }
        }
    }

    private struct Phrase {
        var value: Int
        var decimals: String
        /// "million" in "2.5 million": a round number past a million keeps
        /// its scale word, as people write it.
        var scaleWord: String?

        var formatted: String {
            let whole = scaleWord == nil && value >= groupingThreshold ? grouped(value) : String(value)
            let number = decimals.isEmpty ? whole : "\(whole).\(decimals)"
            return scaleWord.map { "\(number) \($0)" } ?? number
        }

        private func grouped(_ value: Int) -> String {
            let digits = Array(String(value))
            var result = ""
            for (index, digit) in digits.enumerated() {
                if index > 0, (digits.count - index) % 3 == 0 { result.append(",") }
                result.append(digit)
            }
            return result
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
        "trillion": 1_000_000_000_000,
    ]
    private static let scaleNames: [Int: String] = [
        1_000_000: "million", 1_000_000_000: "billion", 1_000_000_000_000: "trillion",
    ]

    private static func word(for key: String) -> Token? {
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

        for (position, token) in tokens.enumerated() {
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
                // A round number past a million, said last, keeps its word:
                // "1 million", "2.5 billion", "3 trillion".
                if position == tokens.count - 1, total == 0, let name = scaleNames[value] {
                    guard group > 0 || !decimals.isEmpty else { return nil }
                    return Phrase(value: group, decimals: decimals, scaleWord: name)
                }
                // Scales descend: "two million three thousand", never "three
                // thousand two million".
                guard !isDecimal, group > 0, value < smallestScale else { return nil }
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
        // Past the decimal point a number is read out digit by digit, and may
        // end on a scale: "two point five million".
        if isDecimal {
            switch token {
            case .unit: return true
            case let .scale(value): return value >= 1_000_000 && previous != .point
            default: return false
            }
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
