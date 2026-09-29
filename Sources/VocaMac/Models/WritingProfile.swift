import Foundation

/// Wording is independent of the destination's punctuation and markup.
enum WritingIntent: String, Codable, CaseIterable, Identifiable {
    case preserve, professional, casual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .preserve: return "As spoken"
        case .professional: return "Formal"
        case .casual: return "Casual"
        }
    }

    var description: String {
        switch self {
        case .preserve:
            return "Keep your own words. Smart Cleanup can still remove “um” and “uh” when it is on."
        case .professional:
            return "Reword English dictation to sound clear and professional, for work and email."
        case .casual:
            return "Reword English dictation to sound relaxed and friendly, for chatting."
        }
    }
}

enum WritingCleanupPolicy: String, Codable, CaseIterable, Identifiable {
    case inherit, off, raw

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .inherit: return "Use Smart Cleanup settings"
        case .off: return "Formatting only, no AI"
        case .raw: return "Exactly as transcribed"
        }
    }
}

/// Snapshot once per utterance so asynchronous processing cannot mix settings.
struct WritingProfile: Equatable {
    var format: WritingStyle
    var rules: WritingStyleRules
    var intent: WritingIntent = .preserve
    var cleanup: WritingCleanupPolicy = .inherit
    /// Nil inherits the global cleanup level.
    var cleanupLevel: CleanupLevel?
    /// Nil or blank inherits the global cleanup prompt.
    var cleanupPrompt: String?

    var allowsRewrite: Bool {
        cleanup == .inherit && format.supportsWording
    }
}
