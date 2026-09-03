// SnippetExpander.swift
// VocaMac
//
// Pure logic for expanding text snippets with regex support.

import Foundation

final class SnippetExpander: SnippetExpanding {
    func expand(in text: String, using snippets: [Snippet]) -> String {
        let hits = matches(in: text, using: snippets)
        guard !hits.isEmpty else { return text }

        // Replace in reverse order to keep ranges valid.
        var result = text
        for hit in hits.reversed() {
            guard let range = Range(hit.range, in: result) else { continue }
            result.replaceSubrange(range, with: hit.expansion)
        }
        return result
    }

    func expandMasked(in text: String, using snippets: [Snippet]) -> MaskedText {
        let hits = matches(in: text, using: snippets)
        guard !hits.isEmpty else { return MaskedText(text: text) }

        // Built left to right, so placeholder indices come out in reading order.
        let nsString = text as NSString
        var result = ""
        var replacements: [String] = []
        var cursor = 0

        for hit in hits {
            guard hit.range.location >= cursor else { continue }
            result += nsString.substring(with: NSRange(location: cursor, length: hit.range.location - cursor))
            if let placeholder = TextPlaceholder.character(at: replacements.count) {
                replacements.append(hit.expansion)
                result.append(placeholder)
            } else {
                // Past the private-use range: insert the expansion literally and
                // accept that formatting may touch it.
                result += hit.expansion
            }
            cursor = hit.range.location + hit.range.length
        }

        result += nsString.substring(from: cursor)
        return MaskedText(text: result, replacements: replacements)
    }

    // MARK: - Matching

    private struct Hit {
        let range: NSRange
        let expansion: String
    }

    /// Every trigger occurrence in `text`, in reading order.
    ///
    /// One combined regex rather than a pass per snippet, so an expansion can
    /// never be re-scanned and expanded again by a later trigger.
    private func matches(in text: String, using snippets: [Snippet]) -> [Hit] {
        guard !snippets.isEmpty, !text.isEmpty else { return [] }

        // Longest triggers first so a longer trigger wins over its own prefix.
        let sortedSnippets = snippets
            .filter { !$0.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.trigger.count > $1.trigger.count }

        guard !sortedSnippets.isEmpty else { return [] }

        var patterns: [String] = []
        for snippet in sortedSnippets {
            let trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            let escapedTrigger = NSRegularExpression.escapedPattern(for: trigger)

            let prefix: String
            if let first = trigger.first, first.isWordCharacter {
                prefix = "\\b"
            } else {
                prefix = "(?<!\\S)"
            }

            let suffix: String
            if let last = trigger.last, last.isWordCharacter {
                suffix = "\\b"
            } else {
                suffix = "(?!\\S)"
            }

            // Capture each trigger in its own group to identify which one matched.
            patterns.append("(\(prefix)\(escapedTrigger)\(suffix))")
        }

        let combinedPattern = patterns.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: combinedPattern, options: [.caseInsensitive]) else {
            return []
        }

        let nsString = text as NSString
        let range = NSRange(location: 0, length: nsString.length)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            for group in 1..<match.numberOfRanges where match.range(at: group).location != NSNotFound {
                return Hit(range: match.range, expansion: sortedSnippets[group - 1].expansion)
            }
            return nil
        }
    }
}

private extension Character {
    var isWordCharacter: Bool {
        return self.isLetter || self.isNumber || self == "_"
    }
}
