// WritingStyleEngine.swift
// VocaMac
//
// Shapes a finished utterance for the app that is about to receive it.
// Pure and deterministic: same input plus same rules always yields the same
// output, so a misformatted result is reproducible from a bug report.

import Foundation

/// Applies a `WritingStyleRules` pipeline to one dictated utterance.
enum WritingStyleEngine {

    // MARK: - Entry point

    /// Format `text` for a style.
    ///
    /// Pipeline order matters. Structural commands run before symbol
    /// substitution so "new line" has already split the text, and the
    /// capitalization / punctuation / spacing polish runs last on the final
    /// shape.
    ///
    /// - Parameters:
    ///   - text: The trimmed utterance from the transcription engine. Spans
    ///     that must not be reshaped (an expanded snippet) may arrive masked
    ///     as `TextPlaceholder` scalars; they pass through untouched.
    ///   - rules: The resolved rules for the target app.
    ///   - globalAutoCapitalize: The Dictation preference, used by `.inherit`.
    ///   - globalTrailingSpace: The Dictation preference, used by `.inherit`.
    static func format(
        _ text: String,
        rules: WritingStyleRules,
        globalAutoCapitalize: Bool,
        globalTrailingSpace: Bool
    ) -> String {
        guard !text.isEmpty else { return text }

        var result = text

        // 1. Leading filler.
        if rules.filler == .trimLeading {
            result = trimLeadingFiller(result)
        }

        // 2. Structural commands.
        if rules.newlineCommands {
            result = applyNewlineCommands(result)
        }
        if rules.listMarkers {
            result = applyListMarkers(result)
        }

        // 3. Symbols, identifiers, and paths. Everything this pass produces
        //    stays masked until the polish below has run, so sentence case
        //    cannot rewrite a filename into a different filename.
        let symbols = SpokenSymbolTransformer.applyMasking(
            result,
            tiers: rules.spokenSymbols,
            pathStitching: rules.pathStitching,
            caseCommandsEnabled: rules.caseCommands
        )
        result = symbols.text

        // 4. Emphasis markup.
        if rules.emphasisDialect != .none {
            result = applyEmphasis(result, dialect: rules.emphasisDialect)
        }

        // 5. Capitalization.
        let shouldCapitalize: Bool
        switch rules.capitalization {
        case .inherit:   shouldCapitalize = globalAutoCapitalize
        case .off:       shouldCapitalize = false
        case .sentences: shouldCapitalize = true
        }
        if shouldCapitalize {
            // Passthrough rules promise the pre-writing-styles pipeline byte
            // for byte — that is both what the master toggle reverts to and
            // what the Plain style is. The style-aware capitalization is an
            // improvement, but it is still a change, so it belongs only to
            // styles that shape their output.
            result = DictationOutputFormatter.capitalizeSentences(
                result,
                scope: rules == .passthrough ? .legacy : .styleAware
            )
        }

        // 6. Terminal punctuation.
        switch rules.terminalPunctuation {
        case .leaveAsIs:
            break
        case .stripTrailingPeriod:
            result = DictationOutputFormatter.stripTrailingPeriod(result)
        case .ensurePeriod:
            result = DictationOutputFormatter.ensureTerminalPeriod(result)
        }

        // 7. Trailing space.
        let shouldAppendSpace: Bool
        switch rules.trailingSpace {
        case .inherit: shouldAppendSpace = globalTrailingSpace
        case .on:      shouldAppendSpace = true
        case .off:     shouldAppendSpace = false
        }
        if shouldAppendSpace {
            result = DictationOutputFormatter.appendTrailingSpace(result)
        }

        // 8. Unmask the spans from step 3. Masks the caller supplied (snippet
        //    expansions) are left in place for the caller to restore.
        return symbols.restore(in: result)
    }

    /// Convenience overload taking a style rather than pre-resolved rules.
    static func format(
        _ text: String,
        style: WritingStyle,
        globalAutoCapitalize: Bool,
        globalTrailingSpace: Bool
    ) -> String {
        format(
            text,
            rules: style.defaultRules,
            globalAutoCapitalize: globalAutoCapitalize,
            globalTrailingSpace: globalTrailingSpace
        )
    }

    // MARK: - Filler

    /// Drop filler words from the start of an utterance only.
    ///
    /// Position-locked on purpose: "so" mid-sentence is almost always real,
    /// while a leading "um, so" is almost always not.
    static func trimLeadingFiller(_ text: String) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var removed = 0

        while words.count > 1 {
            let candidate = words[0]
            if candidate.isEmpty {
                words.removeFirst()
                removed += 1
                continue
            }
            let (core, _) = SpokenSymbolTransformer.splitTrailingPunctuation(candidate)
            guard SpokenSymbolTransformer.leadingFillers.contains(core.lowercased()) else { break }
            words.removeFirst()
            removed += 1
        }

        // Never strip the whole utterance — "ok" on its own is a real answer.
        guard removed > 0, !words.isEmpty else { return text }
        return words.joined(separator: " ")
    }

    // MARK: - Structural commands

    /// Words that turn a following "new line" / "new paragraph" into a noun
    /// phrase rather than a command.
    ///
    /// A determiner in front is the clearest evidence prose offers: nobody
    /// dictating a break says "the new line". Same shape of guard the symbol
    /// transformer uses — decide from the immediate neighbours, never from
    /// evidence elsewhere in the utterance.
    private static let structuralDeterminers: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "each", "every",
        "another", "my", "your", "our", "their", "its", "his", "her",
        "some", "any", "per", "no", "same", "whole", "entire", "single",
        "blank", "empty"
    ]

    // Ordinals ("one", "first", "second") are deliberately absent: "line one
    // new line line two" is numbering, not "one new line".


    /// Words that, immediately after the phrase, make it the sentence's
    /// subject rather than a break in one.
    ///
    /// Deliberately small: only words that essentially cannot open the content
    /// dictated *after* a line break. "in", "at" and "for" are excluded on
    /// purpose — "new line in the config" is a real command with real content.
    private static let structuralContinuations: Set<String> = [
        "of", "between", "across", "through", "versus", "vs",
        "is", "was", "are", "were", "has", "have", "had",
        "reads", "read", "looks", "seems", "means", "works", "counts"
    ]

    /// "new line" → a line break, "new paragraph" → a blank line.
    ///
    /// Both phrases are ordinary English as well as commands, so every match
    /// is checked against its immediate neighbours before it fires.
    static func applyNewlineCommands(_ text: String) -> String {
        var result = text
        // Longest phrase first so "new paragraph" is not eaten by "new line".
        let replacements: [(pattern: String, replacement: String)] = [
            (#"(?i)\s*\bnew paragraph\b[,.]?\s*"#, "\n\n"),
            (#"(?i)\s*\bnext paragraph\b[,.]?\s*"#, "\n\n"),
            (#"(?i)\s*\bnew line\b[,.]?\s*"#, "\n"),
            (#"(?i)\s*\bnewline\b[,.]?\s*"#, "\n"),
            (#"(?i)\s*\bnext line\b[,.]?\s*"#, "\n")
        ]
        for (pattern, replacement) in replacements {
            result = regexReplace(result, pattern: pattern) { match, source in
                isStructuralCommand(match, in: source) ? replacement : nil
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " "))
    }

    /// Whether a "new line" / "new paragraph" match is a command.
    ///
    /// Rejects a match introduced by a determiner ("draw a new line") or
    /// followed by a word that makes the phrase the subject ("new line of
    /// thinking"). Anything else fires, so a bare "new line" between two
    /// clauses still works.
    private static func isStructuralCommand(_ match: NSTextCheckingResult, in source: NSString) -> Bool {
        if let previous = wordBefore(match.range, in: source),
           structuralDeterminers.contains(previous) {
            return false
        }
        if let following = wordAfter(match.range, in: source),
           structuralContinuations.contains(following) {
            return false
        }
        return true
    }

    /// Keywords that open a spoken list item, longest first so "bullet point"
    /// is not matched as a bare "bullet".
    private static let listMarkerKeywords = ["bullet point", "new bullet", "list item", "bullet"]

    /// A line starting with a list keyword becomes a `- ` list item.
    ///
    /// Gated on structure, not on the keyword alone. "bullet proof vest" and
    /// "list item pricing was wrong" are ordinary sentences, and a single
    /// keyword at the start of a single-line utterance is not evidence that
    /// the user is dictating a list. Two or more marked lines, on the other
    /// hand, cannot be a coincidence — and dictating a list is exactly how
    /// they arise, via "bullet buy milk new line bullet buy eggs".
    static func applyListMarkers(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let candidates = lines.filter { listMarkerKeyword(for: $0) != nil }
        guard candidates.count > 1 else { return text }

        let marked = lines.map { line -> String in
            guard let keyword = listMarkerKeyword(for: line) else { return line }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return "- " + String(trimmed.dropFirst(keyword.count)).trimmingCharacters(in: .whitespaces)
        }
        return marked.joined(separator: "\n")
    }

    /// The list keyword this line opens with, if it opens with one and has a
    /// body after it.
    private static func listMarkerKeyword(for line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        for keyword in listMarkerKeywords where lowered.hasPrefix(keyword + " ") {
            let body = String(trimmed.dropFirst(keyword.count)).trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : keyword
        }
        return nil
    }

    // MARK: - Emphasis

    /// Words that make an opening "bold" / "italic" / "strikethrough" part of
    /// the sentence rather than a command.
    ///
    /// Two groups, both keyed off the word immediately after the command:
    ///
    /// - a copula or conjunction means the command word is the subject —
    ///   "strikethrough is a formatting option";
    /// - a noun these adjectives habitually modify means it is a modifier —
    ///   "bold move by the team", "italic text is hard to read".
    ///
    /// A denylist is the honest tool here: the distinction is "adjective or
    /// imperative", which grammar alone cannot settle. Same trade-off, and the
    /// same failure mode, as `SpokenSymbolTransformer.gluedSplitDenylist` —
    /// when it is unsure it leaves the words spoken, which is recoverable.
    private static let emphasisBlockers: Set<String> = [
        // Command word as subject.
        "is", "was", "are", "were", "means", "looks", "seems", "works",
        "and", "or", "but", "so", "because", "which", "that",
        // Command word as adjective.
        "move", "moves", "claim", "claims", "statement", "statements",
        "choice", "choices", "decision", "decisions", "strategy", "prediction",
        "predictions", "stance", "guess", "bet", "step", "play", "call",
        "text", "font", "fonts", "type", "typeface", "style", "styles",
        "formatting", "markup", "letters", "letter", "words", "word",
        "colours", "colors", "flavour", "flavor", "print", "face"
    ]

    /// Wrap the words after "bold" / "italic" / "strikethrough" in the
    /// dialect's markers.
    ///
    /// The span runs to an explicit "end bold" or the end of the line,
    /// whichever comes first. No state is carried between utterances.
    static func applyEmphasis(_ text: String, dialect: EmphasisDialect) -> String {
        guard dialect != .none else { return text }

        let markers: [(command: String, marker: String)]
        switch dialect {
        case .markdown:
            markers = [("bold", "**"), ("italic", "*"), ("italics", "*"), ("strikethrough", "~~")]
        case .slackMrkdwn:
            markers = [("bold", "*"), ("italic", "_"), ("italics", "_"), ("strikethrough", "~")]
        case .none:
            return text
        }

        var result = text
        for (command, marker) in markers {
            // Explicit span: "start bold … end bold". Safe anywhere in a line
            // because the closing command proves the user meant markup, so it
            // needs no denylist.
            let explicitStart = #"(?i)\bstart (?:a |an )?\#(command)\b[,:]?\s+(.+?)\s*\bend \#(command)\b[,.]?"#
            result = regexReplace(result, pattern: explicitStart, with: "\(marker)$1\(marker)")

            let bounded = #"(?i)\b\#(command)\b[,:]?\s+(.+?)\s*\bend \#(command)\b[,.]?"#
            result = regexReplace(result, pattern: bounded, with: "\(marker)$1\(marker)")

            // Implicit span to end of line, and only when the command opens
            // the line — without that anchor "that was a bold move" would
            // become "that was a **move**". The anchor alone is not enough,
            // though: an opening "bold move by the team" is still prose, so
            // the word after the command has to clear the denylist too.
            let toEnd = #"(?i)^\s*\#(command)\b[,:]?\s+(\S.*?)([.!?]?)\s*$"#
            result = regexReplace(result, pattern: toEnd, multiline: true) { match, source in
                guard let following = firstWord(of: match.range(at: 1), in: source),
                      !emphasisBlockers.contains(following) else { return nil }
                return "\(marker)$1\(marker)$2"
            }
        }
        return result
    }

    // MARK: - Neighbour lookup

    /// The bare word immediately before `range`, lowercased and stripped of
    /// punctuation, or `nil` when `range` starts the text.
    private static func wordBefore(_ range: NSRange, in source: NSString) -> String? {
        let prefix = source.substring(to: range.location)
        return prefix.split(whereSeparator: { $0.isWhitespace }).last.map { normalizedWord(String($0)) }
    }

    /// The bare word immediately after `range`, lowercased and stripped of
    /// punctuation, or `nil` when `range` ends the text.
    private static func wordAfter(_ range: NSRange, in source: NSString) -> String? {
        let end = range.location + range.length
        guard end < source.length else { return nil }
        let suffix = source.substring(from: end)
        return suffix.split(whereSeparator: { $0.isWhitespace }).first.map { normalizedWord(String($0)) }
    }

    /// The first bare word inside `range`.
    private static func firstWord(of range: NSRange, in source: NSString) -> String? {
        guard range.location != NSNotFound else { return nil }
        return source.substring(with: range)
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map { normalizedWord(String($0)) }
    }

    private static func normalizedWord(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    // MARK: - Regex helper

    private static func regexReplace(
        _ text: String,
        pattern: String,
        with template: String,
        multiline: Bool = false
    ) -> String {
        regexReplace(text, pattern: pattern, multiline: multiline) { _, _ in template }
    }

    /// Replace only the matches `template` accepts.
    ///
    /// The closure receives each match and the string it was found in, and
    /// returns a template or `nil` to leave that match alone — which is how a
    /// command phrase is checked against its neighbours before it fires.
    /// Matches are applied last-first so earlier ranges stay valid.
    private static func regexReplace(
        _ text: String,
        pattern: String,
        multiline: Bool = false,
        template: (NSTextCheckingResult, NSString) -> String?
    ) -> String {
        var options: NSRegularExpression.Options = []
        if multiline { options.insert(.anchorsMatchLines) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            VocaLogger.warning(.general, "Writing style regex failed to compile: \(pattern)")
            return text
        }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }

        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            guard let template = template(match, source) else { continue }
            let replacement = regex.replacementString(for: match, in: text, offset: 0, template: template)
            result.replaceCharacters(in: match.range, with: replacement)
        }
        return result as String
    }
}
