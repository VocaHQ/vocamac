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
            result = DictationOutputFormatter.capitalizeSentences(result)
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

    /// "new line" → a line break, "new paragraph" → a blank line.
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
            result = regexReplace(result, pattern: pattern, with: replacement)
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " "))
    }

    /// A line starting with "bullet" or "dash" becomes a `- ` list item.
    static func applyListMarkers(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let marked = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return line }
            for keyword in ["bullet point", "bullet", "new bullet", "list item"] {
                if trimmed.lowercased().hasPrefix(keyword + " ") {
                    let body = String(trimmed.dropFirst(keyword.count)).trimmingCharacters(in: .whitespaces)
                    guard !body.isEmpty else { return line }
                    return "- " + body
                }
            }
            return line
        }
        return marked.joined(separator: "\n")
    }

    // MARK: - Emphasis

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
            // because the closing command proves the user meant markup.
            let explicitStart = #"(?i)\bstart (?:a |an )?\#(command)\b[,:]?\s+(.+?)\s*\bend \#(command)\b[,.]?"#
            result = regexReplace(result, pattern: explicitStart, with: "\(marker)$1\(marker)")

            let bounded = #"(?i)\b\#(command)\b[,:]?\s+(.+?)\s*\bend \#(command)\b[,.]?"#
            result = regexReplace(result, pattern: bounded, with: "\(marker)$1\(marker)")

            // Implicit span to end of line, but only when the command opens the
            // line. Without that anchor "that was a bold move" would become
            // "that was a **move**".
            let toEnd = #"(?i)^\s*\#(command)\b[,:]?\s+(\S.*?)([.!?]?)\s*$"#
            result = regexReplace(result, pattern: toEnd, with: "\(marker)$1\(marker)$2", multiline: true)
        }
        return result
    }

    // MARK: - Regex helper

    private static func regexReplace(
        _ text: String,
        pattern: String,
        with template: String,
        multiline: Bool = false
    ) -> String {
        var options: NSRegularExpression.Options = []
        if multiline { options.insert(.anchorsMatchLines) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            VocaLogger.warning(.general, "Writing style regex failed to compile: \(pattern)")
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
