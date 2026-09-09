import Foundation

/// Wording is independent of the destination's punctuation and markup.
enum WritingIntent: String, Codable, CaseIterable, Identifiable {
    case preserve, professional, casual

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .preserve: return "Preserve my wording"
        case .professional: return "Professional"
        case .casual: return "Casual"
        }
    }
}

enum WritingCleanupPolicy: String, Codable, CaseIterable, Identifiable {
    case inherit, off, raw

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .inherit: return "Use local cleanup setting"
        case .off: return "Formatting only"
        case .raw: return "Raw transcription"
        }
    }
}

/// Snapshot once per utterance so asynchronous processing cannot mix settings.
struct WritingProfile: Equatable {
    var format: WritingStyle
    var rules: WritingStyleRules
    var intent: WritingIntent = .preserve
    var cleanup: WritingCleanupPolicy = .inherit

    var allowsRewrite: Bool {
        cleanup == .inherit && format != .code && format != .terminal
    }
}
