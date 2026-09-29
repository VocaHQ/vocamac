// Snippet.swift
// VocaMac
//
// Model representing a custom text snippet with a trigger phrase and expansion text.

import Foundation

struct Snippet: Identifiable, Codable, Equatable {
    var id: UUID
    var trigger: String
    var expansion: String

    init(id: UUID = UUID(), trigger: String = "", expansion: String = "") {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
    }
}

extension Snippet {
    /// Two snippets answer to the same spoken trigger.
    static func sharesTrigger(_ a: Snippet, _ b: Snippet) -> Bool {
        a.trigger.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == b.trigger.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
