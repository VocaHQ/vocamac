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
