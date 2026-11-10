// DictionaryTransfer.swift
// VocaMac
//
// Import and export of the personal dictionary: vocabulary words and
// replacements, as CSV, JSON or a plain list of words. Pure, so the parsing
// and duplicate rules are tested without an `AppState` or a file panel.

import Foundation
import UniformTypeIdentifiers

/// One replacement as it travels in a file: the spoken forms (comma
/// separated, like `WordReplacement.heard`) and what to type.
struct DictionaryTransferReplacement: Equatable, Codable {
    var heard: String
    var replacement: String
}

/// Words and replacements read from, or written to, a file.
struct DictionaryTransferContents: Equatable {
    var words: [String] = []
    var replacements: [DictionaryTransferReplacement] = []
    /// Entries in the file that were left out: longer than
    /// `DictionaryTransfer.maxEntryLength` or past `maxEntries`.
    var skippedCount = 0

    var isEmpty: Bool { words.isEmpty && replacements.isEmpty }
}

/// What an import would change, shown before anything is added.
struct DictionaryImportPlan: Equatable {
    /// Words not already in the dictionary (compared without case).
    var newWords: [String]
    /// Replacements whose spoken forms are not already covered.
    var newReplacements: [DictionaryTransferReplacement]
    /// Entries in the file the dictionary already has.
    var duplicateCount: Int
    /// Entries in the file that can't be imported (too long, or past the
    /// entry limit), so the confirmation can say so.
    var skippedCount = 0

    var isEmpty: Bool { newWords.isEmpty && newReplacements.isEmpty }
}

enum DictionaryTransferFormat: String, CaseIterable, Sendable {
    case csv
    case json
    case plainText

    /// The format a file's extension says it is. Anything that isn't CSV or
    /// JSON is read as a list of words, one per line.
    static func forFile(_ url: URL) -> DictionaryTransferFormat {
        switch url.pathExtension.lowercased() {
        case "csv", "tsv": return .csv
        case "json": return .json
        default: return .plainText
        }
    }

    var contentType: UTType {
        switch self {
        case .csv: return .commaSeparatedText
        case .json: return .json
        case .plainText: return .plainText
        }
    }

    var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .json: return "json"
        case .plainText: return "txt"
        }
    }
}

enum DictionaryTransferError: Error, Equatable {
    case unreadable
    case nothingFound

    var message: String {
        switch self {
        case .unreadable: return "That file isn't a dictionary VocaMac can read."
        case .nothingFound: return "No words or replacements were found in that file."
        }
    }
}

enum DictionaryTransfer {
    /// Longest word or replacement accepted from a file. Longer cells are a
    /// pasted document, not a dictionary entry. Generous enough that a
    /// replacement typed into Settings (which has no limit of its own)
    /// survives an export and re-import; anything longer is counted as
    /// skipped and shown before the import, never dropped silently.
    static let maxEntryLength = 2_000

    /// Most entries one import adds, so a wrong file can't flood the
    /// recognition hints.
    static let maxEntries = 5_000

    // MARK: - Export

    /// CSV with a header: `type,heard,text`. Words have an empty `heard`.
    static func csv(_ contents: DictionaryTransferContents) -> String {
        var lines = ["type,heard,text"]
        lines += contents.words.map { "word,,\(csvField($0))" }
        lines += contents.replacements.map { "replacement,\(csvField($0.heard)),\(csvField($0.replacement))" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// JSON: `{"version": 1, "words": [...], "replacements": [{"heard", "replacement"}]}`.
    static func json(_ contents: DictionaryTransferContents) -> String {
        let file = JSONFile(version: 1, words: contents.words, replacements: contents.replacements)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(file), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text + "\n"
    }

    private struct JSONFile: Codable {
        var version: Int
        var words: [String]
        var replacements: [DictionaryTransferReplacement]
    }

    // MARK: - Import

    /// Read a dictionary file.
    ///
    /// - CSV: `type,heard,text` as exported; or two columns, what was heard
    ///   and what to type; or one column of words. A header row is skipped.
    /// - JSON: the exported shape; or an array of words; or an array of
    ///   `{heard|from|original, replacement|to|text}` objects.
    /// - Plain text: one word per line, or `heard -> text` / `heard → text`
    ///   for a replacement. `#` starts a comment line.
    static func parse(_ text: String, format: DictionaryTransferFormat) throws -> DictionaryTransferContents {
        var contents: DictionaryTransferContents
        switch format {
        case .csv: contents = parseCSV(text)
        case .json: contents = try parseJSON(text)
        case .plainText: contents = parsePlainText(text)
        }
        contents = sanitized(contents)
        guard !contents.isEmpty else { throw DictionaryTransferError.nothingFound }
        return contents
    }

    /// What importing `contents` would add to a dictionary that already has
    /// `existingWords` and `existingReplacements`.
    ///
    /// A word already listed (ignoring case) is a duplicate. A replacement
    /// is a duplicate when every spoken form it has already maps to the same
    /// text; forms that map somewhere else are left to the existing entry,
    /// since only one replacement can win for a spoken form.
    static func plan(
        importing contents: DictionaryTransferContents,
        existingWords: [String],
        existingReplacements: [WordReplacement]
    ) -> DictionaryImportPlan {
        var knownWords = Set(existingWords.map { $0.lowercased() })
        var claimedForms: [String: String] = [:]
        for replacement in existingReplacements {
            for form in replacement.heardForms { claimedForms[form.lowercased()] = replacement.replacement }
        }

        var newWords: [String] = []
        var newReplacements: [DictionaryTransferReplacement] = []
        var duplicates = 0

        for word in contents.words {
            if knownWords.insert(word.lowercased()).inserted {
                newWords.append(word)
            } else {
                duplicates += 1
            }
        }
        for replacement in contents.replacements {
            let forms = WordReplacement(heard: replacement.heard, replacement: replacement.replacement).heardForms
            let free = forms.filter { claimedForms[$0.lowercased()] == nil }
            guard !free.isEmpty else {
                duplicates += 1
                continue
            }
            for form in free { claimedForms[form.lowercased()] = replacement.replacement }
            newReplacements.append(DictionaryTransferReplacement(
                heard: free.joined(separator: ", "), replacement: replacement.replacement
            ))
        }
        return DictionaryImportPlan(
            newWords: newWords, newReplacements: newReplacements,
            duplicateCount: duplicates, skippedCount: contents.skippedCount
        )
    }

    // MARK: - CSV

    private static let headerCells: Set<String> = [
        "type", "kind", "heard", "text", "word", "words", "term", "terms", "replacement", "replace",
        "from", "to", "original", "spoken", "written", "with", "find", "vocabulary",
    ]

    private static func parseCSV(_ text: String) -> DictionaryTransferContents {
        let separator = csvSeparator(for: text)
        var rows = csvRows(text, separator: separator)
        guard let first = rows.first else { return DictionaryTransferContents() }
        let isHeader = !first.isEmpty && first.allSatisfy {
            let cell = $0.trimmingCharacters(in: .whitespaces).lowercased()
            return cell.isEmpty || headerCells.contains(cell)
        }
        let hasTypeColumn = isHeader && ["type", "kind"].contains(first.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? "")
        if isHeader { rows.removeFirst() }

        var contents = DictionaryTransferContents()
        for row in rows {
            let cells = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard cells.contains(where: { !$0.isEmpty }) else { continue }
            if hasTypeColumn || (cells.count >= 3 && ["word", "replacement"].contains(cells[0].lowercased())) {
                let kind = cells[0].lowercased()
                let heard = cells.count > 1 ? cells[1] : ""
                let written = cells.count > 2 ? cells[2] : ""
                if kind == "replacement" || (!heard.isEmpty && !written.isEmpty) {
                    contents.replacements.append(DictionaryTransferReplacement(heard: heard, replacement: written))
                } else {
                    contents.words.append(written.isEmpty ? heard : written)
                }
            } else if cells.count >= 2, !cells[0].isEmpty, !cells[1].isEmpty {
                contents.replacements.append(DictionaryTransferReplacement(heard: cells[0], replacement: cells[1]))
            } else if let word = cells.first(where: { !$0.isEmpty }) {
                contents.words.append(word)
            }
        }
        return contents
    }

    /// Tab when the first row has a tab outside quotes, else comma.
    /// Decided from the header (or first row) only: cells of a
    /// tab-separated file may hold commas, such as several spoken forms of
    /// one replacement, and a quoted CSV cell may hold a tab.
    static func csvSeparator(for text: String) -> Character {
        var inQuotes = false
        var sawContent = false
        for character in text {
            if character == "\"" {
                inQuotes.toggle()
            } else if !inQuotes {
                if character == "\t" { return "\t" }
                if character.isNewline {
                    if sawContent { break }
                    continue
                }
            }
            if !character.isWhitespace { sawContent = true }
        }
        return ","
    }

    /// RFC 4180 rows: quoted fields may hold the separator, quotes ("") and
    /// line breaks.
    static func csvRows(_ text: String, separator: Character = ",") -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        func endField() { row.append(field); field = "" }
        func endRow() {
            endField()
            rows.append(row)
            row = []
        }

        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    let next = iterator.next()
                    if next == "\"" {
                        field.append("\"")
                    } else {
                        inQuotes = false
                        pending = next
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty:
                inQuotes = true
            case separator:
                endField()
            case "\n", "\r\n", "\r":
                endRow()
            default:
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) || value != value.trimmingCharacters(in: .whitespaces) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - JSON

    private static func parseJSON(_ text: String) throws -> DictionaryTransferContents {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            throw DictionaryTransferError.unreadable
        }
        var contents = DictionaryTransferContents()
        func take(_ items: [Any]) {
            for item in items {
                if let word = item as? String {
                    contents.words.append(word)
                } else if let entry = item as? [String: Any] {
                    let heard = firstString(in: entry, keys: ["heard", "from", "original", "spoken", "find"])
                    let written = firstString(in: entry, keys: ["replacement", "to", "text", "written", "replace", "with"])
                    if let heard, let written, !heard.isEmpty, !written.isEmpty {
                        contents.replacements.append(DictionaryTransferReplacement(heard: heard, replacement: written))
                    } else if let word = written ?? heard ?? firstString(in: entry, keys: ["word", "term"]) {
                        contents.words.append(word)
                    }
                }
            }
        }
        if let array = object as? [Any] {
            take(array)
        } else if let dictionary = object as? [String: Any] {
            for key in ["words", "vocabulary", "terms"] {
                if let words = dictionary[key] as? [Any] { take(words) }
            }
            for key in ["replacements", "corrections"] {
                if let replacements = dictionary[key] as? [Any] { take(replacements) }
            }
        } else {
            throw DictionaryTransferError.unreadable
        }
        return contents
    }

    private static func firstString(in entry: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = entry[key] as? String { return value }
        }
        return nil
    }

    // MARK: - Plain text

    private static func parsePlainText(_ text: String) -> DictionaryTransferContents {
        var contents = DictionaryTransferContents()
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if let arrow = ["→", "->", "=>"].lazy.compactMap({ line.range(of: $0) }).first {
                let heard = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                let written = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                if !heard.isEmpty, !written.isEmpty {
                    contents.replacements.append(DictionaryTransferReplacement(heard: heard, replacement: written))
                    continue
                }
            }
            contents.words.append(line)
        }
        return contents
    }

    // MARK: - Cleanup

    /// Trimmed, length-checked entries with duplicates inside the file
    /// itself dropped, capped at `maxEntries`.
    private static func sanitized(_ contents: DictionaryTransferContents) -> DictionaryTransferContents {
        func normalized(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines).joined(separator: " ")
        }
        func fits(_ value: String) -> Bool { value.count <= maxEntryLength }

        var skipped = 0
        var seenWords = Set<String>()
        var seenReplacements = Set<String>()
        var result = DictionaryTransferContents()
        for word in contents.words {
            // A word file may separate words with commas on one line.
            for part in RecognitionHints.vocabularyTerms(from: word) {
                let cleaned = normalized(part)
                guard !cleaned.isEmpty else { continue }
                guard fits(cleaned) else {
                    skipped += 1
                    continue
                }
                guard seenWords.insert(cleaned.lowercased()).inserted else { continue }
                result.words.append(cleaned)
            }
        }
        for replacement in contents.replacements {
            let heard = normalized(replacement.heard)
            // Replacement text may hold line breaks (a signature, an
            // address); only the ends are trimmed so a move between Macs
            // keeps it exactly.
            let written = replacement.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !heard.isEmpty, !written.isEmpty else { continue }
            guard fits(heard), fits(written) else {
                skipped += 1
                continue
            }
            let key = heard.lowercased() + "\u{1F}" + written
            guard seenReplacements.insert(key).inserted else { continue }
            result.replacements.append(DictionaryTransferReplacement(heard: heard, replacement: written))
        }
        let wordBudget = min(result.words.count, maxEntries)
        let replacementBudget = max(0, maxEntries - wordBudget)
        skipped += (result.words.count - wordBudget) + max(0, result.replacements.count - replacementBudget)
        result.words = Array(result.words.prefix(wordBudget))
        result.replacements = Array(result.replacements.prefix(replacementBudget))
        result.skippedCount = skipped
        return result
    }
}
