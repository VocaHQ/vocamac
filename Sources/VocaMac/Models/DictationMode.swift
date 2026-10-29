// DictationMode.swift
// VocaMac
//
// Modes: a named way of writing (style, wording, cleanup, language) that a
// dictation can be started in with its own shortcut, or switched to by
// saying the mode's name first ("Formal, dear team…").

import Foundation

// MARK: - DictationMode

/// A named bundle of writing settings for one dictation.
///
/// A mode overrides the app's style rule for that one dictation only. Its
/// shortcut works like the Command Mode shortcut: hold it while speaking, or
/// press it once to start and again to stop. Saying its name at the start
/// of a dictation ("Code, user id equals…") switches to it too, when
/// `listensForName` is on.
struct DictationMode: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: UUID
    /// What it is called, and the word to say to switch to it.
    var name: String
    /// How the text is laid out.
    var style: WritingStyle
    /// Whether the wording is kept, made formal, or made casual.
    var intent: WritingIntent
    /// Whether Smart Cleanup runs, or only formatting, or nothing at all.
    var cleanup: WritingCleanupPolicy
    /// Nil keeps the Smart Cleanup level.
    var cleanupLevel: CleanupLevel?
    /// Nil or blank keeps the Smart Cleanup instructions.
    var cleanupPrompt: String?
    /// A transcription language code ("de"), or nil for the language setting.
    /// Applies only when the mode's shortcut starts the dictation: a spoken
    /// name is heard after the speech was already recognised.
    var language: String?
    /// `HotKeyCombo.storageString`, or empty for no shortcut.
    var shortcut: String
    /// Saying the name first switches to this mode.
    var listensForName: Bool

    init(
        id: UUID = UUID(),
        name: String,
        style: WritingStyle = .plain,
        intent: WritingIntent = .preserve,
        cleanup: WritingCleanupPolicy = .inherit,
        cleanupLevel: CleanupLevel? = nil,
        cleanupPrompt: String? = nil,
        language: String? = nil,
        shortcut: String = "",
        listensForName: Bool = true
    ) {
        self.id = id
        self.name = name
        self.style = style
        self.intent = intent
        self.cleanup = cleanup
        self.cleanupLevel = cleanupLevel
        self.cleanupPrompt = cleanupPrompt
        self.language = language
        self.shortcut = shortcut
        self.listensForName = listensForName
    }

    /// The name as typed, without surrounding spaces.
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The language to transcribe in, or nil to keep the setting.
    var languageOverride: String? {
        guard let language = language?.trimmingCharacters(in: .whitespacesAndNewlines),
              !language.isEmpty, language != "auto" else { return nil }
        return language
    }

    /// The writing profile this mode produces.
    var profile: WritingProfile {
        let prompt = cleanupPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        return WritingProfile(
            format: style,
            rules: style.defaultRules,
            intent: intent,
            cleanup: cleanup,
            cleanupLevel: cleanupLevel,
            cleanupPrompt: (prompt?.isEmpty ?? true) ? nil : prompt
        )
    }

    /// What the overlay and History call it.
    var summaryLabel: String { "\(trimmedName) mode" }

    // Older or hand-edited JSON may leave out the optional fields.
    private enum CodingKeys: String, CodingKey {
        case id, name, style, intent, cleanup, cleanupLevel, cleanupPrompt, language, shortcut, listensForName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        style = (try? container.decode(WritingStyle.self, forKey: .style)) ?? .plain
        intent = (try? container.decode(WritingIntent.self, forKey: .intent)) ?? .preserve
        cleanup = (try? container.decode(WritingCleanupPolicy.self, forKey: .cleanup)) ?? .inherit
        cleanupLevel = try? container.decodeIfPresent(CleanupLevel.self, forKey: .cleanupLevel)
        cleanupPrompt = try? container.decodeIfPresent(String.self, forKey: .cleanupPrompt)
        language = try? container.decodeIfPresent(String.self, forKey: .language)
        shortcut = (try? container.decodeIfPresent(String.self, forKey: .shortcut)) ?? ""
        listensForName = (try? container.decodeIfPresent(Bool.self, forKey: .listensForName)) ?? true
    }

    /// Modes offered the first time the list is opened. None has a
    /// shortcut: a global shortcut takes its keys from every app.
    static let starters: [DictationMode] = [
        DictationMode(name: "Code", style: .code),
        DictationMode(name: "Formal", style: .email, intent: .professional),
        DictationMode(name: "Exact", style: .plain, cleanup: .raw),
    ]
}

// MARK: - Store

enum DictationModeStore {
    static func decode(_ json: String) -> [DictationMode] {
        guard let data = json.data(using: .utf8),
              let modes = try? JSONDecoder().decode([DictationMode].self, from: data) else { return [] }
        return modes
    }

    static func encode(_ modes: [DictationMode]) -> String {
        guard let data = try? JSONEncoder().encode(modes),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    /// Why `name` can't name a mode, or nil. Names are compared the way they
    /// are heard: without case, accents or punctuation.
    static func nameProblem(_ name: String, id: UUID, in modes: [DictationMode]) -> String? {
        let key = ModePrefix.normalized(name)
        guard !key.isEmpty else { return "Give the mode a name." }
        if modes.contains(where: { $0.id != id && ModePrefix.normalized($0.name) == key }) {
            return "Another mode already has this name."
        }
        if ModePrefix.nameTokens(name).count > ModePrefix.maximumNameWords {
            return "Use at most \(ModePrefix.maximumNameWords) words, so it is quick to say."
        }
        return nil
    }
}

// MARK: - Spoken prefix

/// Finds a mode named at the very start of a transcript.
///
/// One-sided on purpose: a dictation that merely begins with the same word
/// ("Formal dress is required") must not switch. So the name has to be
/// followed by a pause mark (",", ":", ".", "—", "!", "?") or by the word
/// "mode" ("code mode user id…"), and something has to follow it. A name on
/// its own is a dictation of that word, not a switch.
enum ModePrefix {
    /// Longer names are hard to say as a quick prefix, and costlier to match.
    static let maximumNameWords = 3

    /// The mode named first, and the transcript without the name.
    struct Match: Equatable {
        let mode: DictationMode
        let remainder: String
    }

    static func match(_ transcript: String, modes: [DictationMode]) -> Match? {
        let candidates = modes.filter { $0.listensForName && !nameTokens($0.name).isEmpty }
        guard !candidates.isEmpty else { return nil }
        let leading = transcript.prefix { $0.isWhitespace }
        let text = transcript.dropFirst(leading.count)
        let words = leadingWords(text, count: maximumNameWords + 1)
        // The longest name wins, so "Formal email" beats "Formal".
        let ordered = candidates.sorted { nameTokens($0.name).count > nameTokens($1.name).count }
        for mode in ordered {
            // Split the name the way the transcript is split, so "E-mail"
            // is one word on both sides and "Formal" never matches the
            // first half of "Formal-wear".
            let nameWords = nameTokens(mode.name)
            guard !nameWords.isEmpty, words.count >= nameWords.count,
                  zip(words, nameWords).allSatisfy({ normalized($0.text) == $1 }) else { continue }
            let nameEnd = words[nameWords.count - 1]
            guard let remainder = remainder(after: nameEnd, in: text, words: words, nameCount: nameWords.count)
            else { continue }
            return Match(mode: mode, remainder: recased(remainder, like: text))
        }
        return nil
    }

    /// Lowercased, accent-free, punctuation as spaces, spaces collapsed.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    // MARK: Helpers

    private struct Word {
        let text: String
        /// Where the word ends in the transcript.
        let end: String.Index
    }

    /// A name's words, normalized, split where a transcript's words are.
    static func nameTokens(_ name: String) -> [String] {
        leadingWords(Substring(name), count: maximumNameWords + 1).map { normalized($0.text) }
    }

    /// The first `count` words, each with where it ends. A word is a run of
    /// letters and digits; apostrophes and hyphens inside it stay with it.
    private static func leadingWords(_ text: Substring, count: Int) -> [Word] {
        var words: [Word] = []
        var index = text.startIndex
        while words.count < count, index < text.endIndex {
            while index < text.endIndex, !isWordCharacter(text[index]) { index = text.index(after: index) }
            guard index < text.endIndex else { break }
            let start = index
            while index < text.endIndex, isWordCharacter(text[index]) || isJoiner(text, at: index) {
                index = text.index(after: index)
            }
            words.append(Word(text: String(text[start..<index]), end: index))
        }
        return words
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// An apostrophe or hyphen between two letters ("don't", "e-mail").
    private static func isJoiner(_ text: Substring, at index: String.Index) -> Bool {
        guard "'’-".contains(text[index]) else { return false }
        let next = text.index(after: index)
        return next < text.endIndex && isWordCharacter(text[next])
    }

    private static let pauseMarks: Set<Character> = [",", ":", ".", "!", "?", ";", "—", "–", "…"]

    /// The text after the name and its pause mark (or "mode"), or nil when
    /// the name isn't set off as a prefix or nothing follows it.
    private static func remainder(after nameEnd: Word, in text: Substring, words: [Word], nameCount: Int) -> String? {
        var index = nameEnd.end
        var sawMark = false
        // "Formal, " "Formal: " "Formal — " "Formal. "
        while index < text.endIndex, text[index].isWhitespace || pauseMarks.contains(text[index]) || text[index] == "-" {
            if pauseMarks.contains(text[index]) || text[index] == "-" { sawMark = true }
            index = text.index(after: index)
        }
        if !sawMark {
            // "code mode user id…": the word "mode" sets the name off instead.
            guard words.count > nameCount, normalized(words[nameCount].text) == "mode" else { return nil }
            index = words[nameCount].end
            while index < text.endIndex, text[index].isWhitespace || pauseMarks.contains(text[index]) {
                index = text.index(after: index)
            }
        }
        let rest = String(text[index...])
        return rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : rest
    }

    /// Start the remainder with a capital when the transcript started with
    /// one: the name took the sentence's first word, not its capital.
    private static func recased(_ remainder: String, like text: Substring) -> String {
        guard let first = text.first(where: isWordCharacter), first.isUppercase,
              let head = remainder.first, head.isLowercase else { return remainder }
        return head.uppercased() + remainder.dropFirst()
    }
}
