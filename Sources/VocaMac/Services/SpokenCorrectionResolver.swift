// SpokenCorrectionResolver.swift
// VocaMac
//
// Keeps only the corrected value when a speaker fixes themselves mid-sentence:
// "let's do it tomorrow, oh, no, Wednesday" → "let's do it Wednesday".

import Foundation

/// Resolves explicit, compact self-corrections without a model.
///
/// A correction is three parts: the value said first, an explicit cue ("no",
/// "or no", "wait", "sorry", "I mean", "actually", "make that", …), and the
/// replacement. Both values must be the same kind of thing — a day ("tomorrow",
/// "Wednesday", "next Friday"), a month, or a number or time ("5", "6 pm",
/// "3:30", "fifteen minutes") — so an ordinary "no" is never taken for a
/// correction: in "Monday no problem" the word after "no" isn't a day.
///
/// Cues and day and month names cover English, Spanish, French, German,
/// Portuguese, Italian, and romanized Hindi, and can mix ("kal, nahi,
/// Wednesday"). A question before the cue ("tomorrow? No, Wednesday") is an
/// answer, not a correction, and a negative clause ("I can't do Monday, no,
/// Tuesday works") is left alone — there "no" agrees, it doesn't correct.
/// Looser corrections ("John, no, Mary") are left to the model at the High
/// level; see `EditMerge`.
enum SpokenCorrectionResolver {

    static func resolve(_ text: String) -> String {
        resolveCounting(text).text
    }

    /// The text with corrections resolved, and how many were.
    static func resolveCounting(_ text: String) -> (text: String, count: Int) {
        guard let expression else { return (text, 0) }
        var result = text
        var count = 0
        // Repeatedly, since one sentence can correct itself twice, and each
        // replacement shifts everything after it.
        for _ in 0..<8 {
            let ns = result as NSString
            let matches = expression.matches(in: result, range: NSRange(location: 0, length: ns.length))
            guard let match = matches.first(where: { isCorrection($0, in: ns) }) else { break }
            let first = ns.substring(with: match.range(withName: "first"))
            let replacement = carryingLeadingWords(from: first, to: ns.substring(with: match.range(withName: "replacement")))
            result = ns.replacingCharacters(in: match.range(withName: "correction"), with: replacement)
            count += 1
        }
        return (result, count)
    }

    /// "at 5, no, 6" → "at 6"; "next Monday, no, Tuesday" → "next Tuesday".
    /// A replacement that brings its own "at" / "the" / "next" keeps it.
    private static func carryingLeadingWords(from first: String, to replacement: String) -> String {
        let leading = { (value: String) -> [String] in
            Array(value.split(separator: " ").map(String.init)
                .prefix { articles.contains($0.lowercased()) || dayModifiers.contains($0.lowercased()) })
        }
        guard leading(replacement).isEmpty else { return replacement }
        let carried = leading(first)
        return carried.isEmpty ? replacement : (carried + [replacement]).joined(separator: " ")
    }

    // MARK: - Checks

    private static func isCorrection(_ match: NSTextCheckingResult, in text: NSString) -> Bool {
        let first = text.substring(with: match.range(withName: "first"))
        let replacement = text.substring(with: match.range(withName: "replacement"))
        guard let firstKind = kind(of: first), firstKind == kind(of: replacement),
              first.lowercased() != replacement.lowercased() else { return false }
        // Only the clause the first value sits in: from the last sentence end.
        let before = text.substring(to: match.range(withName: "correction").location)
        let clause = before.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).last ?? before
        return !containsNegation(clause)
    }

    private enum Kind { case day, month, number }

    private static func kind(of value: String) -> Kind? {
        let words = value.lowercased().split(whereSeparator: { $0 == " " }).map(String.init)
        guard let core = words.last(where: { !articles.contains($0) && !dayModifiers.contains($0) }) else { return nil }
        if days.contains(core) || days.contains(core.replacingOccurrences(of: "-feira", with: "")) { return .day }
        if months.contains(core) { return .month }
        if words.contains(where: { $0.first?.isNumber == true || numberWords.contains($0) }) { return .number }
        return nil
    }

    private static func containsNegation(_ clause: String) -> Bool {
        let words = clause.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
        return words.contains { negations.contains($0) || $0.hasSuffix("n't") }
    }

    // MARK: - Vocabulary

    private static let days: Set<String> = [
        // English
        "today", "tomorrow", "yesterday", "tonight", "monday", "tuesday", "wednesday", "thursday",
        "friday", "saturday", "sunday", "weekend",
        // Spanish
        "hoy", "mañana", "manana", "ayer", "lunes", "martes", "miércoles", "miercoles", "jueves",
        "viernes", "sábado", "sabado", "domingo",
        // French
        "aujourd'hui", "demain", "hier", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche",
        // German
        "heute", "morgen", "übermorgen", "gestern", "montag", "dienstag", "mittwoch", "donnerstag",
        "freitag", "samstag", "sonntag",
        // Portuguese
        "hoje", "amanhã", "amanha", "ontem", "segunda", "terça", "terca", "quarta", "quinta", "sexta",
        // Italian
        "oggi", "domani", "ieri", "lunedì", "lunedi", "martedì", "martedi", "mercoledì", "mercoledi",
        "giovedì", "giovedi", "venerdì", "venerdi", "sabato", "domenica",
        // Hindi (romanized)
        "aaj", "kal", "parso", "parson", "somvar", "somwar", "mangalvar", "mangalwar", "budhvar", "budhwar",
        "guruvar", "guruwar", "shukravar", "shukrawar", "shanivar", "shaniwar", "ravivar", "raviwar", "itvaar",
    ]

    private static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september",
        "october", "november", "december",
        "enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre",
        "octubre", "noviembre", "diciembre",
        "janvier", "février", "fevrier", "mars", "avril", "mai", "juin", "juillet", "août", "aout",
        "septembre", "octobre", "novembre", "décembre", "decembre",
        "januar", "februar", "märz", "maerz", "juni", "juli", "oktober", "dezember",
        "janeiro", "fevereiro", "março", "marco", "maio", "junho", "julho", "setembro", "outubro",
        "novembro", "dezembro",
        "gennaio", "febbraio", "aprile", "maggio", "giugno", "luglio", "settembre", "ottobre",
        "dicembre",
    ]

    private static let numberWords: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
        "twelve", "fifteen", "twenty", "thirty", "forty", "fifty", "hundred", "noon", "midnight",
        "uno", "dos", "tres", "cuatro", "cinco", "seis", "siete", "ocho", "nueve", "diez",
        "deux", "trois", "quatre", "cinq", "sept", "huit", "neuf", "dix",
        "eins", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun", "zehn",
        "ek", "paanch", "chhe", "saat", "aath", "nau",
    ]

    /// Allowed before a value and carried into the replacement: "the", "el",
    /// "am", "on", "at", …
    private static let articles: Set<String> = [
        "the", "on", "at", "in", "by", "el", "la", "los", "las", "le", "der", "die", "das", "am", "um",
        "à", "il", "lo",
    ]

    private static let dayModifiers: Set<String> = ["next", "this", "last", "coming", "próximo", "prochain", "nächsten"]

    static let negations: Set<String> = [
        "not", "no", "never", "cannot", "can't", "won't", "don't", "doesn't", "didn't", "isn't", "aren't",
        "nicht", "kein", "keine", "nie", "pas", "jamais", "nunca", "não", "nao", "non", "nahi", "nahin", "mat",
    ]

    /// Cue phrases, longest first so "or no" wins over "no".
    static let cues: [String] = [
        "no no", "oh no", "no wait", "or no", "oh sorry", "or rather", "i mean", "make that", "scratch that",
        "no sorry", "sorry", "wait", "actually", "rather", "correction", "no",
        "perdón", "perdon", "mejor dicho", "digo", "o sea",
        "non", "pardon", "je veux dire", "plutôt", "plutot", "enfin",
        "nein", "ich meine", "besser gesagt", "quatsch",
        "não", "nao", "desculpa", "quer dizer", "aliás", "alias",
        "scusa", "cioè", "cioe", "anzi",
        "nahi nahi", "nahi", "nahin", "mera matlab", "matlab",
    ]

    // MARK: - Pattern

    /// Spaces and tabs only. A line break is structure — "deploy Monday" on
    /// one line and "no, Tuesday" on the next are two lines, not a
    /// correction — so no part of the pattern may cross one.
    private static let space = "[ \\t]"

    private static func value(_ group: String) -> String {
        let alternation = { (words: Set<String>) in
            words.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        }
        let day = "(?:(?:" + alternation(dayModifiers) + ")" + space + "+)?(?:" + alternation(days) + ")(?:-feira)?"
        let month = alternation(months)
        let number = "(?:\\d+(?:[:.]\\d+)?|" + alternation(numberWords) + ")"
            + "(?:" + space + "*(?:a\\.?m\\.?|p\\.?m\\.?|o'clock|minutes?|mins?|hours?|days?|weeks?|percent|%|uhr|heures?|horas?|ore|baje))?"
        return "(?<\(group)>(?:(?:" + alternation(articles) + ")" + space + "+)?(?:" + day + "|" + month + "|" + number + "))"
    }

    /// "<first value> [oh,] <cue> <replacement>", with the cue set off by
    /// commas, periods, dashes, or spaces — never a question mark. The whole
    /// span is replaced by the replacement value.
    private static let expression: NSRegularExpression? = {
        let cue = cues.map { phrase in
            phrase.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "[," + space + "]+")
        }.joined(separator: "|")
        let separators = "[,.;…—–\\-" + space + "]"
        let pattern = "(?i)(?<![\\p{L}\\p{N}])(?<correction>" + value("first")
            + separators + "*(?:oh[," + space + "]+)?(?:" + cue + ")(?![\\p{L}])" + separators + "+"
            + value("replacement") + ")(?![\\p{L}\\p{N}])"
        return try? NSRegularExpression(pattern: pattern)
    }()
}
