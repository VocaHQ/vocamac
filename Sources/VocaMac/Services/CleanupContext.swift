import Foundation

/// Token-based planning for bounded cleanup. Split only between complete
/// sentences/paragraphs: a correction or negation inside a sentence stays with
/// the words it qualifies. A single oversized sentence falls back unchanged.
enum CleanupContext {
    static let maximumCharacters = 64_000
    static let maximumChunks = 8

    static func chunks(
        _ text: String, contextTokens: Int, promptTokens: Int,
        allowsSplitting: Bool = true,
        countTokens: (String) async -> Int
    ) async -> [String]? {
        guard text.count <= maximumCharacters else { return nil }
        func fits(_ tokens: Int) -> Bool {
            tokens + max(64, tokens * 5 / 4) + promptTokens + 256 <= contextTokens
        }
        if fits(await countTokens(text)) { return [text] }
        guard allowsSplitting else { return nil }
        var result: [String] = []
        var current = ""
        for sentence in sentences(text) {
            guard !Task.isCancelled else { return nil }
            if fits(await countTokens(current + sentence)) {
                current += sentence
            } else {
                guard !current.isEmpty, fits(await countTokens(sentence)) else { return nil }
                result.append(current)
                guard result.count < maximumChunks else { return nil }
                current = sentence
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.isEmpty ? nil : result
    }

    /// Exact, lossless sentence slices, including their original separators.
    static func sentences(_ text: String) -> [String] {
        let ns = text as NSString
        var ends: [Int] = []
        // Unlike a period regex, sentence segmentation recognizes abbreviations.
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .substringNotRequired]) { _, _, enclosing, _ in
            ends.append(NSMaxRange(NSRange(enclosing, in: text)))
        }
        ends.append(ns.length)
        var start = 0
        var parts: [String] = []
        for end in ends where end > start {
            parts.append(ns.substring(with: NSRange(location: start, length: end - start)))
            start = end
        }
        return parts
    }
}
