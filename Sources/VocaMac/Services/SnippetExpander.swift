// SnippetExpander.swift
// VocaMac
//
// Pure logic for expanding text snippets with regex support.

import Foundation

class SnippetExpander: SnippetExpanding {
    func expand(in text: String, using snippets: [Snippet]) -> String {
        guard !snippets.isEmpty else { return text }
        
        // Sort snippets by trigger length descending to prioritize longer triggers
        let sortedSnippets = snippets
            .filter { !$0.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.trigger.count > $1.trigger.count }
        
        guard !sortedSnippets.isEmpty else { return text }
        
        // Build a single combined regex to avoid cascading expansions
        // and handle different boundary requirements for word/non-word triggers.
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
            
            // Capture each trigger in its own group to identify which one matched
            patterns.append("(\(prefix)\(escapedTrigger)\(suffix))")
        }
        
        let combinedPattern = patterns.joined(separator: "|")
        
        guard let regex = try? NSRegularExpression(pattern: combinedPattern, options: [.caseInsensitive]) else {
            return text
        }
        
        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
        
        // Replace matches in reverse order to keep ranges valid
        var result = text
        for match in matches.reversed() {
            // Find which group matched (group 0 is the whole match, groups 1..N are our snippets)
            for i in 1...match.numberOfRanges - 1 {
                let range = match.range(at: i)
                if range.location != NSNotFound {
                    let snippet = sortedSnippets[i - 1]
                    
                    // Since we are going in reverse, we can just use string replacement on the range.
                    if let resultRange = Range(match.range, in: result) {
                        result.replaceSubrange(resultRange, with: snippet.expansion)
                    }
                    break
                }
            }
        }
        
        return result
    }
}

private extension Character {
    var isWordCharacter: Bool {
        return self.isLetter || self.isNumber || self == "_"
    }
}
