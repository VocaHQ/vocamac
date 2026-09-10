// SpokenCorrectionResolver.swift
// VocaMac

import Foundation

/// Resolves only explicit, compact self-corrections. Broader rewrites stay in
/// the opt-in model so ordinary uses of “actually” are not deleted.
enum SpokenCorrectionResolver {
    private static let expression = try? NSRegularExpression(
        pattern: #"(?i)\b(\d[\d:./-]*)\s*,?\s+(?:actually|rather|i mean)\s+(\d[\d:./-]*)\b"#
    )

    static func resolve(_ text: String) -> String {
        guard let expression else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: "$2")
    }
}
