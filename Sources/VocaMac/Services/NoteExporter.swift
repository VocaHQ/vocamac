// NoteExporter.swift
// VocaMac
//
// A note as a file: Markdown (with speakers, timestamps and the summary),
// plain text, or JSON. And the export folder (an Obsidian vault, say): pick
// it once, and every finished note is written there as Markdown. The folder
// is remembered as a security-scoped bookmark, which the App Store build's
// sandbox needs to write there after a relaunch.

import Foundation

enum NoteExportFormat: String, CaseIterable, Identifiable {
    case markdown
    case plainText
    case json

    var id: String { rawValue }

    var title: String {
        switch self {
        case .markdown: return "Markdown"
        case .plainText: return "Plain text"
        case .json: return "JSON"
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .plainText: return "txt"
        case .json: return "json"
        }
    }
}

enum NoteExporter {

    static func data(_ note: VoiceNote, format: NoteExportFormat, timeZone: TimeZone = .current) throws -> Data {
        switch format {
        case .markdown: return Data(markdown(note, timeZone: timeZone).utf8)
        case .plainText: return Data(plainText(note).utf8)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(note)
        }
    }

    // MARK: Markdown

    static func markdown(_ note: VoiceNote, timeZone: TimeZone = .current) -> String {
        var lines = ["# \(note.title)", ""]
        lines.append("- Date: \(dateText(note.createdAt, timeZone: timeZone))")
        lines.append("- Source: \(note.source.displayName)")
        if note.durationSeconds > 0 { lines.append("- Length: \(clock(note.durationSeconds))") }
        if !note.speakers.isEmpty {
            lines.append("- Speakers: \(note.speakers.map(note.speakerName).joined(separator: ", "))")
        }

        if let summary = note.summary, !summary.isEmpty {
            lines += ["", "## Summary"]
            if !summary.overview.isEmpty { lines += ["", summary.overview] }
            if !summary.decisions.isEmpty {
                lines += ["", "### Decisions", ""] + summary.decisions.map { "- \($0)" }
            }
            if !summary.actionItems.isEmpty {
                lines += ["", "### Action items", ""] + summary.actionItems.map { "- [ ] \($0)" }
            }
        }

        lines += ["", "## Transcript", ""]
        if note.segments.isEmpty {
            lines.append(note.text)
        } else {
            for segment in note.segments {
                let label = segment.speaker.map { " \(note.speakerName($0)):" } ?? ""
                lines += ["**[\(clock(segment.start))]\(label)** \(segment.text)", ""]
            }
            if lines.last?.isEmpty == true { lines.removeLast() }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Plain text

    static func plainText(_ note: VoiceNote) -> String {
        guard !note.segments.isEmpty else { return note.text + "\n" }
        var paragraphs: [String] = []
        for segment in note.segments {
            let label = segment.speaker.map { "\(note.speakerName($0)): " } ?? ""
            paragraphs.append(label + segment.text)
        }
        return paragraphs.joined(separator: "\n\n") + "\n"
    }

    // MARK: Names

    /// "2026-10-28 14-05 Weekly sync.md": sortable, and safe on every file system.
    /// With `uniquing`, the start of the note's id follows the title
    /// ("… Weekly sync 1A2B3C4D.md"), so two notes from the same minute with
    /// the same opening words never replace each other in a folder.
    static func fileName(
        _ note: VoiceNote, format: NoteExportFormat, uniquing: Bool = false, timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]").union(.newlines).union(.controlCharacters)
        let title = note.title.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        let trimmed = String(title.prefix(80))
        var stem = formatter.string(from: note.createdAt) + (trimmed.isEmpty ? "" : " " + trimmed)
        if uniquing { stem += " " + note.id.uuidString.prefix(8) }
        return stem + "." + format.fileExtension
    }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%02d:%02d", minutes, rest)
    }

    private static func dateText(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Export folder

/// The folder every finished note is also written to, kept as a bookmark.
struct NoteExportFolder {
    static let bookmarkKey = "vocamac.notes.exportFolderBookmark"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The folder, or nil when none is set or it can no longer be found.
    var url: URL? {
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data, options: Self.resolutionOptions, relativeTo: nil, bookmarkDataIsStale: &isStale
        ) else { return nil }
        if isStale { try? remember(url) }
        return url
    }

    func remember(_ folder: URL) throws {
        let data = try folder.bookmarkData(options: Self.creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: Self.bookmarkKey)
    }

    func forget() {
        defaults.removeObject(forKey: Self.bookmarkKey)
    }

    /// Write `note` into the folder as Markdown, replacing an earlier copy
    /// with the same name. Returns where it went.
    @discardableResult
    func write(_ note: VoiceNote) throws -> URL? {
        guard let folder = url else { return nil }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let destination = folder.appendingPathComponent(NoteExporter.fileName(note, format: .markdown, uniquing: true))
        try NoteExporter.data(note, format: .markdown).write(to: destination, options: .atomic)
        return destination
    }

#if APP_STORE
    private static let creationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let resolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
#else
    private static let creationOptions: URL.BookmarkCreationOptions = []
    private static let resolutionOptions: URL.BookmarkResolutionOptions = []
#endif
}
