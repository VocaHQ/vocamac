// StatsShareDestination.swift
// VocaMac
//
// Social destinations for sharing the stats card, plus the post text
// and composer URL each one gets.

import Foundation

/// A place the user can post their stats card to.
///
/// Web share intents cannot carry an attachment, so the flow copies the
/// rendered card to the clipboard and opens the destination's composer
/// with prefilled text for the user to paste the image into.
enum StatsShareDestination: String, CaseIterable, Identifiable {
    case x
    case linkedIn

    var id: String { rawValue }

    /// Menu label. X is X, not Twitter.
    var displayName: String {
        switch self {
        case .x: return "X"
        case .linkedIn: return "LinkedIn"
        }
    }

    /// How VocaMac refers to itself on this network, or `nil` where it has no
    /// account to point at. VocaMac has no LinkedIn page, so a LinkedIn post
    /// signs off with the site alone rather than a handle that resolves to 404.
    var handle: String? {
        switch self {
        case .x: return "@vocahq"
        case .linkedIn: return nil
        }
    }
}

/// Builds the post text and composer URL for a stats share.
enum StatsShareComposer {
    static let siteURL = "https://vocamac.com"

    /// The post body is hardcoded English, so its numbers and units are pinned
    /// to English too. Without this a German user posts "2.500 Stunden of
    /// talking", and the grouping separator varies by locale ("12,500" vs
    /// "12.500" vs "12 500"). `en_US` rather than `en_US_POSIX`, which drops
    /// grouping separators entirely ("12500").
    private static let postLocale = Locale(identifier: "en_US")

    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = postLocale
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .full
        formatter.zeroFormattingBehavior = .dropAll
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = postLocale
        formatter.calendar = calendar
        return formatter
    }()

    /// Shortest duration the post will mention. `.dropAll` does not blank a
    /// zero duration — it falls back to the smallest allowed unit — so anything
    /// under a minute has to be filtered out here instead.
    private static let minimumReportedDuration: Double = 60

    /// The post body. Kept short enough for X's 280-character limit.
    static func message(for snapshot: StatsShareSnapshot, destination: StatsShareDestination) -> String {
        message(for: snapshot, handle: destination.handle)
    }

    /// The post body for the system share picker. The destination app is
    /// unknown there, so it signs off with the site alone.
    static func message(for snapshot: StatsShareSnapshot, handle: String? = nil) -> String {
        var lines = [
            "🎤 \(pluralized(snapshot.totalWords, "word")) talked into my Mac with VocaMac.",
            statLine(for: snapshot),
            "Every model runs on my Mac. Works fully offline, no audio ever leaves it. 🔒",
            [handle, siteURL].compactMap { $0 }.joined(separator: " · ")
        ]
        lines.removeAll { $0.isEmpty }
        return lines.joined(separator: "\n\n")
    }

    /// Composer URL with the message prefilled, or `nil` if it cannot be encoded.
    static func composerURL(for snapshot: StatsShareSnapshot, destination: StatsShareDestination) -> URL? {
        let text = message(for: snapshot, destination: destination)
        switch destination {
        case .x:
            return url("https://x.com/intent/post", query: [("text", text)])
        case .linkedIn:
            // `share-offsite` only accepts a URL; the feed composer is the one
            // LinkedIn surface that still prefills body text.
            return url(
                "https://www.linkedin.com/feed/",
                query: [("shareActive", "true"), ("text", text)]
            )
        }
    }

    /// Unreserved set from RFC 3986. Everything else in a value is escaped so
    /// `&`, `+` and `;` inside the post text cannot act as query separators.
    private static let valueAllowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func url(_ base: String, query: [(name: String, value: String)]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        let encoded = query.compactMap { item -> String? in
            guard let value = item.value.addingPercentEncoding(withAllowedCharacters: valueAllowed) else {
                return nil
            }
            return "\(item.name)=\(value)"
        }
        guard encoded.count == query.count else { return nil }
        components.percentEncodedQuery = encoded.joined(separator: "&")
        return components.url
    }

    /// The middle line: whichever secondary stats the user actually has.
    private static func statLine(for snapshot: StatsShareSnapshot) -> String {
        var parts: [String] = []
        if snapshot.totalTranscriptions > 0 {
            parts.append("📊 \(pluralized(snapshot.totalTranscriptions, "session"))")
        }
        if snapshot.totalAudioDurationSeconds >= minimumReportedDuration,
           let duration = durationFormatter.string(from: snapshot.totalAudioDurationSeconds),
           !duration.isEmpty {
            parts.append("⏱️ \(duration) of talking")
        }
        if snapshot.averageWPM > 0 {
            parts.append(String(format: "⚡️ %.0f WPM", snapshot.averageWPM))
        }
        if snapshot.currentStreak > 0 {
            parts.append("🔥 \(snapshot.currentStreak)-day streak")
        }
        return parts.isEmpty ? "" : parts.joined(separator: " · ")
    }

    /// "1 session", not "1 sessions" — the post is public.
    static func pluralized(_ count: Int, _ noun: String) -> String {
        "\(formatCount(count)) \(count == 1 ? noun : noun + "s")"
    }

    /// Grouped count, shared with the card image so the pasted picture and the
    /// post text never disagree ("12,500" next to "12500").
    static func formatCount(_ value: Int) -> String {
        countFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
