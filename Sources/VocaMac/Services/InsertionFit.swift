// InsertionFit.swift
// VocaMac
//
// Fits a finished dictation to the field it is typed into: the kind of
// field, and the text already there. Pure, so every rule is testable
// without Accessibility.

import CoreGraphics
import Foundation

/// What the focused field said about itself just before the text arrives.
/// Read from the focused field only (`AccessibilityTextReader.insertionContext`),
/// so in a chat app it is the user's own draft, never the conversation.
struct InsertionContext: Equatable, Sendable {
    enum Field: Equatable, Sendable {
        /// One line: a search box, an address bar, a subject, a file name.
        case singleLine
        case multiLine
        /// The app didn't say.
        case unknown
    }

    var field: Field
    /// The text before the caret (or the selection being replaced), at most
    /// `contextLength` UTF-16 units. Nil when the field's text can't be read.
    var before: String?
    /// The first few characters after the caret or selection.
    var after: String?
    /// Where the field is on screen, which tells one field from another.
    var frame: CGRect?

    static let contextLength = 400
    static let afterLength = 8

    static let unknown = InsertionContext(field: .unknown, before: nil, after: nil)

    /// Accessibility roles of fields that hold one line.
    static func field(forRole role: String) -> Field {
        switch role {
        case "AXTextField", "AXSearchField", "AXComboBox": return .singleLine
        case "AXTextArea": return .multiLine
        default: return .unknown
        }
    }

    /// The context for a field holding `value` with the caret or selection
    /// at `location` (UTF-16) running `length` units.
    init(field: Field, value: String?, location: Int?, length: Int = 0, frame: CGRect? = nil) {
        self.field = field
        self.frame = frame
        guard let value, let location else {
            before = nil
            after = nil
            return
        }
        let text = value as NSString
        let start = min(max(location, 0), text.length)
        let end = min(max(start + max(length, 0), start), text.length)
        var lead = min(Self.contextLength, start)
        // Never start inside a surrogate pair.
        if lead < start, lead > 0, CFStringIsSurrogateLowCharacter(text.character(at: start - lead)) { lead -= 1 }
        before = text.substring(with: NSRange(location: start - lead, length: lead))
        var trail = min(Self.afterLength, text.length - end)
        if trail > 0, end + trail < text.length, CFStringIsSurrogateHighCharacter(text.character(at: end + trail - 1)) {
            trail -= 1
        }
        after = text.substring(with: NSRange(location: end, length: trail))
    }

    init(field: Field, before: String?, after: String?, frame: CGRect? = nil) {
        self.field = field
        self.before = before
        self.after = after
        self.frame = frame
    }
}

/// Fits dictated text to where it lands. Every rule is one-sided: when the
/// field says nothing, or says something ambiguous, the text is left as the
/// style made it.
enum InsertionFit {

    struct Result: Equatable {
        /// The text, with the field's needs applied.
        let text: String
        /// Type a space before it: the caret sits right after a word.
        let leadingSpace: Bool
    }

    /// - Parameters:
    ///   - capitalizes: Whether the style starts sentences with a capital. A
    ///     capital is only ever taken back where the style put it.
    ///   - mirrorsRegister: Chat and Slack: follow the draft's own habit of
    ///     lowercase sentence starts and no full stops.
    ///   - protecting: Text that must arrive exactly as saved: snippet
    ///     expansions and Dictionary terms. Masked while fitting, so a
    ///     snippet "That works." after "I think" keeps its capital and stop.
    static func fit(
        _ text: String,
        into context: InsertionContext,
        capitalizes: Bool,
        mirrorsRegister: Bool,
        protecting protected: [String] = []
    ) -> Result {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Result(text: text, leadingSpace: false)
        }
        let masking = mask(text, protecting: protected)
        var result = masking.text
        if context.field == .singleLine {
            result = fittingOneLine(result)
        }
        var leadingSpace = false
        if let before = context.before {
            // Spacing reads the text as it will look; case changes run on
            // the masked text, where a protected span is never a word.
            let join = joining(after: before, text: unmask(result, spans: masking.spans))
            leadingSpace = join.space
            if capitalizes, join.continuesSentence {
                result = lowercasingFirstWord(result)
            }
            if mirrorsRegister {
                result = mirroringRegister(of: before, in: result, capitalizes: capitalizes)
            }
        }
        if let after = context.after {
            result = spacing(result, before: after)
        }
        return Result(text: unmask(result, spans: masking.spans), leadingSpace: leadingSpace)
    }

    /// The context to fit to at delivery: the field read again just before
    /// the text goes in, when it is the field read as recording started.
    /// The user may have moved to another field while speaking; then the
    /// first reading describes the wrong text, and nothing is fitted. Same
    /// field means the same kind at the same place on screen or, when the
    /// app reports no frame, the same text around the caret.
    static func deliveryContext(start: InsertionContext?, now: InsertionContext?) -> InsertionContext? {
        guard let start, let now, start.field == now.field else { return nil }
        if let startFrame = start.frame, let nowFrame = now.frame {
            return startFrame == nowFrame ? now : nil
        }
        guard start.frame == nil, now.frame == nil,
              start.before == now.before, start.after == now.after else { return nil }
        return now
    }

    // MARK: - Protected text

    /// `text` with each protected span replaced by one private-use
    /// character, longest first, and the spans in placeholder order.
    static func mask(_ text: String, protecting protected: [String]) -> (text: String, spans: [String]) {
        var result = text
        var spans: [String] = []
        let candidates = Set(protected.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        for span in candidates where result.contains(span) {
            guard let placeholder = TextPlaceholder.character(at: spans.count) else { break }
            result = result.replacingOccurrences(of: span, with: String(placeholder))
            spans.append(span)
        }
        return (result, spans)
    }

    static func unmask(_ text: String, spans: [String]) -> String {
        guard !spans.isEmpty else { return text }
        var result = ""
        for character in text {
            if let index = TextPlaceholder.index(of: character, base: TextPlaceholder.snippetBase), index < spans.count {
                result += spans[index]
            } else {
                result.append(character)
            }
        }
        return result
    }

    // MARK: - One-line fields

    /// A search box or a subject: one line, no full stop on a single
    /// sentence, nothing trailing. A paragraph break becomes a space; a
    /// pasted line break would split the text or submit the form.
    static func fittingOneLine(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "[ \\t]*\\R+[ \\t]*", with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespaces)
        if isOneSentence(result) {
            result = DictationOutputFormatter.stripTrailingPeriod(result)
        }
        return result
    }

    /// No sentence end before the last character.
    private static func isOneSentence(_ text: String) -> Bool {
        text.range(of: "[.!?][\"'”’)]*\\s+\\S", options: .regularExpression) == nil
    }

    // MARK: - Joining

    /// Whether the text needs a space before it, and whether it continues a
    /// sentence already under way, judged from the characters before the
    /// caret.
    static func joining(after before: String, text: String) -> (space: Bool, continuesSentence: Bool) {
        guard let first = text.first, first.isLetter || first.isNumber else {
            // Punctuation, a line break, or a symbol: it attaches as it is.
            return (false, false)
        }
        guard let last = before.last else { return (false, false) }
        if last.isNewline { return (false, false) }
        if last.isWhitespace {
            return (false, continues(at: before.trimmingCharacters(in: .whitespaces)))
        }
        if openingMarks.contains(last) || isOpeningQuote(at: before) { return (false, false) }
        if last.isLetter || last.isNumber || ",;:".contains(last) || closingMarks.contains(last)
            || sentenceEnds.contains(last) || last == "\"" || last == "'" {
            return (true, continues(at: before))
        }
        // "-", "/", "@", "#" and other symbols: whatever follows belongs to it.
        return (false, false)
    }

    /// Whether text placed after `before` is inside a sentence: the last
    /// mark is a letter, a digit, a comma or a semicolon. Not after a colon
    /// (what follows may start a sentence), a sentence end, or a line break.
    private static func continues(at before: String) -> Bool {
        var trimmed = Substring(before)
        while let last = trimmed.last, closingMarks.contains(last) || last == "\"" || last == "'" {
            trimmed = trimmed.dropLast()
        }
        guard let last = trimmed.last else { return false }
        if last.isNewline { return false }
        return last.isLetter || last.isNumber || last == "," || last == ";"
    }

    /// A straight quote with nothing or a space before it opens a quotation.
    private static func isOpeningQuote(at before: String) -> Bool {
        guard let last = before.last, last == "\"" || last == "'" else { return false }
        let previous = before.dropLast().last
        return previous == nil || previous?.isWhitespace == true || previous.map(openingMarks.contains) == true
    }

    private static let openingMarks: Set<Character> = ["(", "[", "{", "“", "‘", "«", "¿", "¡"]
    private static let closingMarks: Set<Character> = [")", "]", "}", "”", "’", "»"]
    private static let sentenceEnds: Set<Character> = [".", "!", "?", "…"]

    // MARK: - Space after

    /// No trailing space before a space or closing punctuation already in the
    /// field; one before a word the text would otherwise run into.
    static func spacing(_ text: String, before after: String) -> String {
        guard let next = after.first else { return text }
        if next.isWhitespace || ".,;:!?)]}”’»".contains(next) {
            var trimmed = text
            while trimmed.last == " " || trimmed.last == "\t" { trimmed.removeLast() }
            return trimmed
        }
        if next.isLetter || next.isNumber, let last = text.last, !last.isWhitespace {
            return text + " "
        }
        return text
    }

    // MARK: - Case

    /// Lowercase the first word when it is one of the everyday words that
    /// are never names ("That", "And", "We"), so "I think" + "That works"
    /// reads "I think that works". Anything else keeps its capital: a name
    /// mid-sentence keeps it too, and the spell checker can't tell "John"
    /// from "john".
    static func lowercasingFirstWord(_ text: String) -> String {
        guard let range = firstWordRange(in: text) else { return text }
        let word = String(text[range])
        guard let lowered = lowercasedIfCommon(word) else { return text }
        return text.replacingCharacters(in: range, with: lowered)
    }

    private static func firstWordRange(in text: String) -> Range<String.Index>? {
        guard let start = text.firstIndex(where: { !$0.isWhitespace }), text[start].isLetter else { return nil }
        let end = text[start...].firstIndex { !($0.isLetter || $0 == "'" || $0 == "’") } ?? text.endIndex
        return start..<end
    }

    /// The word lowercased when it is a capitalized everyday word, else nil.
    private static func lowercasedIfCommon(_ word: String) -> String? {
        guard let first = word.first, first.isUppercase,
              word.dropFirst().allSatisfy({ !$0.isUppercase }) else { return nil }
        let lowered = word.lowercased()
        let stem = lowered.replacingOccurrences(of: "’", with: "'")
        let base = stem.split(separator: "'").first.map(String.init) ?? stem
        guard base != "i", everydayWords.contains(base) else { return nil }
        return lowered
    }

    // MARK: - Register

    /// In a chat draft that starts its sentences in lowercase, or never ends
    /// one with a full stop, write the same way. Decided from the draft
    /// alone, with enough of it to go on; otherwise nothing changes.
    static func mirroringRegister(of before: String, in text: String, capitalizes: Bool) -> String {
        var result = text
        if capitalizes, prefersLowercaseStarts(before) {
            result = lowercasingSentenceStarts(result)
        }
        if skipsFullStops(before) {
            result = DictationOutputFormatter.stripTrailingPeriod(result)
        }
        return result
    }

    /// At least two sentence starts, and four in five of them lowercase.
    /// "I" and its contractions don't count either way.
    static func prefersLowercaseStarts(_ text: String) -> Bool {
        var lower = 0
        var total = 0
        for word in sentenceStartWords(in: text) {
            let base = word.lowercased().replacingOccurrences(of: "’", with: "'")
                .split(separator: "'").first.map(String.init) ?? ""
            guard base != "i", let first = word.first, first.isLetter else { continue }
            total += 1
            if first.isLowercase { lower += 1 }
        }
        return total >= 2 && lower * 5 >= total * 4
    }

    /// Four or more words and not one full stop.
    static func skipsFullStops(_ text: String) -> Bool {
        let words = text.split { $0.isWhitespace }.filter { $0.contains { $0.isLetter } }
        return words.count >= 4 && !text.contains(".")
    }

    /// The first word of the text and of every sentence or line in it.
    private static func sentenceStartWords(in text: String) -> [String] {
        let pattern = "(?:^|[.!?]\\s+|\\R\\s*)([\\p{L}][\\p{L}'’]*)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }

    private static func lowercasingSentenceStarts(_ text: String) -> String {
        let pattern = "(?:^|[.!?]\\s+|\\R\\s*)([\\p{Lu}][\\p{L}'’]*)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let range = match.range(at: 1)
            let word = ns.substring(with: range)
            if let lowered = lowercasedIfCommon(word) {
                ns.replaceCharacters(in: range, with: lowered)
            }
        }
        return ns as String
    }

    /// Everyday English words that are never a name, so lowering their
    /// capital is safe. Deliberately closed: a word missing here keeps its
    /// capital, which is what happens without this rule. "May" and "Will"
    /// are left out: a month and a name as often as a verb.
    static let everydayWords: Set<String> = [
        // Articles, determiners, pronouns
        "a", "an", "the", "this", "that", "these", "those", "some", "any", "all", "each", "every", "no",
        "both", "either", "neither", "few", "many", "much", "more", "most", "less", "other", "another",
        "such", "what", "which", "who", "whom", "whose", "whatever", "whichever", "whoever",
        "we", "you", "he", "she", "it", "they", "me", "us", "him", "her", "them", "my", "your", "his",
        "its", "our", "their", "mine", "yours", "ours", "theirs", "myself", "yourself", "itself",
        "ourselves", "themselves", "someone", "something", "anyone", "anything", "everyone",
        "everything", "nobody", "nothing", "there", "here", "one",
        // Conjunctions and prepositions
        "and", "but", "or", "nor", "so", "yet", "for", "because", "since", "although", "though",
        "while", "whereas", "unless", "until", "if", "when", "whenever", "where", "wherever", "whether",
        "as", "than", "then", "after", "before", "once", "of", "to", "in", "on", "at", "by", "with",
        "without", "from", "into", "onto", "about", "above", "below", "under", "over", "between",
        "among", "through", "during", "against", "toward", "towards", "upon", "within", "around",
        "like", "plus", "via", "per", "instead", "including", "except", "unlike",
        // Auxiliaries and common verbs
        "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did", "done", "have",
        "has", "had", "having", "would", "shall", "should", "can", "could", "might",
        "must", "need", "needs", "let", "lets", "get", "gets", "got", "make", "makes", "made", "go",
        "goes", "going", "went", "come", "comes", "came", "take", "takes", "took", "see", "saw", "seen",
        "know", "knew", "think", "thought", "say", "said", "says", "tell", "told", "want", "wants",
        "wanted", "look", "looks", "use", "used", "try", "tried", "keep", "kept", "give", "gave",
        "send", "sent", "check", "add", "fix", "put", "run", "start", "stop", "seems", "feel", "feels",
        "works", "work", "worked", "looks", "sounds", "sound", "means", "mean", "meant",
        // Adverbs and fillers people start with
        "also", "just", "only", "even", "still", "already", "again", "maybe", "perhaps", "probably",
        "actually", "really", "basically", "honestly", "anyway", "anyways", "otherwise", "however",
        "therefore", "though", "thus", "hence", "now", "soon", "later", "today", "tomorrow",
        "yesterday", "tonight", "always", "never", "often", "sometimes", "usually", "not", "very",
        "too", "quite", "pretty", "rather", "almost", "especially", "definitely", "hopefully",
        "obviously", "apparently", "yes", "yeah", "yep", "nope", "ok", "okay", "sure", "well", "oh",
        "hey", "hi", "hello", "thanks", "thank", "please", "sorry", "how", "why", "lol", "haha",
        // Common nouns and adjectives a continuation opens with
        "good", "great", "fine", "nice", "cool", "new", "old", "first", "next", "last", "same",
        "different", "better", "best", "little", "lot", "lots", "bit", "time", "way", "thing",
        "things", "people", "day", "week", "both", "half", "whole",
    ]
}
