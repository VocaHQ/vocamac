// NoteSummarizer.swift
// VocaMac
//
// Summarizes a voice note with the local Writing AI model: an overview,
// decisions, and action items with owners. A transcript longer than the
// model reads at once is summarized part by part, and the parts' summaries
// are then merged. The prompts are fixed text, byte for byte, so llama.cpp
// reuses what it has already read of them.

import Foundation

enum NoteSummarizer {

    // MARK: Prompts

    /// Asks for a summary of one stretch of a transcript.
    static let partPrompt = """
    You summarize a transcript of a meeting, call, or voice memo. Write in the transcript's own language. \
    Use only what the transcript says; never invent names, dates, numbers, or decisions. \
    Answer in exactly this format and nothing else:
    SUMMARY:
    Two or three sentences on what was discussed.
    DECISIONS:
    - One line per decision that was made. Write "- None" if there were none.
    ACTION ITEMS:
    - Owner: task, one line each, using the speaker's name or label as owner, or "Someone" when nobody took it. \
    Write "- None" if there were none.
    """

    /// Asks for one summary from the summaries of a transcript's parts.
    static let mergePrompt = """
    You combine summaries of consecutive parts of one meeting, call, or voice memo into a single summary. \
    Write in the same language as the summaries. Keep every decision and action item, merging only exact repeats; \
    add nothing that is not in them. Answer in exactly this format and nothing else:
    SUMMARY:
    Two or three sentences on what was discussed overall.
    DECISIONS:
    - One line per decision. Write "- None" if there were none.
    ACTION ITEMS:
    - Owner: task, one line each. Write "- None" if there were none.
    """

    // MARK: Input

    /// The transcript as the model reads it: one line per speaker turn.
    static func transcriptText(for note: VoiceNote) -> String {
        guard !note.segments.isEmpty else { return note.text }
        return note.segments.map { segment in
            guard let speaker = segment.speaker else { return segment.text }
            return "\(note.speakerName(speaker)): \(segment.text)"
        }.joined(separator: "\n")
    }

    /// `text` cut into parts of at most `budget` characters, at line breaks
    /// where possible, then at sentence ends, then at spaces.
    static func chunks(_ text: String, budget: Int) -> [String] {
        let budget = max(budget, 200)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > budget else { return trimmed.isEmpty ? [] : [trimmed] }

        var units: [String] = []
        for line in trimmed.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if line.count <= budget {
                units.append(line)
            } else {
                units += split(line, budget: budget)
            }
        }

        var parts: [String] = []
        var current = ""
        for unit in units {
            let joined = current.isEmpty ? unit : current + "\n" + unit
            if joined.count <= budget {
                current = joined
            } else {
                if !current.isEmpty { parts.append(current) }
                current = unit
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// A line too long for one part, cut at sentence ends, then spaces.
    private static func split(_ line: String, budget: Int) -> [String] {
        var sentences: [String] = []
        line.enumerateSubstrings(in: line.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence { sentences.append(sentence.trimmingCharacters(in: .whitespaces)) }
        }
        var pieces: [String] = []
        var current = ""
        for sentence in sentences.flatMap({ $0.count <= budget ? [$0] : words(of: $0, budget: budget) }) {
            let joined = current.isEmpty ? sentence : current + " " + sentence
            if joined.count <= budget {
                current = joined
            } else {
                if !current.isEmpty { pieces.append(current) }
                current = sentence
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    private static func words(of sentence: String, budget: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        for word in sentence.split(separator: " ") {
            let joined = current.isEmpty ? String(word) : current + " " + word
            if joined.count <= budget {
                current = joined
            } else {
                if !current.isEmpty { pieces.append(current) }
                current = String(word.prefix(budget))
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    // MARK: Running

    enum Failure: Error, Equatable {
        case empty
        case model(String)
        case unreadable
    }

    /// Asks the model; returns its answer, or why there is none.
    typealias Ask = @MainActor (_ text: String, _ prompt: String) async -> Result<String, Failure>

    /// Summarize `transcript`, part by part when it is longer than `budget`
    /// characters. `ask` runs the model once.
    @MainActor
    static func summarize(
        _ transcript: String, budget: Int, model: String?, now: Date = Date(), ask: Ask
    ) async -> Result<VoiceNoteSummary, Failure> {
        let parts = chunks(transcript, budget: budget)
        guard !parts.isEmpty else { return .failure(.empty) }

        var summaries: [String] = []
        for part in parts {
            switch await ask(part, partPrompt) {
            case .success(let answer): summaries.append(answer)
            case .failure(let failure): return .failure(failure)
            }
        }
        // Merge until one summary is left, a budget's worth at a time.
        while summaries.count > 1 {
            var merged: [String] = []
            for group in chunks(summaries.joined(separator: "\n\n"), budget: budget) {
                switch await ask(group, mergePrompt) {
                case .success(let answer): merged.append(answer)
                case .failure(let failure): return .failure(failure)
                }
            }
            // A merge that can't shrink the list would loop forever.
            if merged.count >= summaries.count { summaries = [merged.joined(separator: "\n\n")]; break }
            summaries = merged
        }
        guard let summary = parse(summaries[0], model: model, now: now) else { return .failure(.unreadable) }
        return .success(summary)
    }

    // MARK: Parsing

    /// Read the model's answer. Section headings are matched loosely (case,
    /// Markdown `#` and `**`); text before any heading counts as the
    /// overview. Nil when nothing usable came back.
    static func parse(_ answer: String, model: String?, now: Date = Date()) -> VoiceNoteSummary? {
        enum Section { case summary, decisions, actions }
        var section = Section.summary
        var overview: [String] = []
        var decisions: [String] = []
        var actions: [String] = []

        let inlineHeadings: [(String, Section)] = [
            ("summary:", .summary), ("overview:", .summary), ("decisions:", .decisions),
            ("action items:", .actions), ("next steps:", .actions),
        ]
        for rawLine in answer.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // "SUMMARY: We agreed…" — a heading with its text on the same line.
            let bare = line.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "#* "))
            if let (prefix, heading) = inlineHeadings.first(where: { bare.hasPrefix($0.0) }), bare.count > prefix.count {
                section = heading
                line = String(bare.dropFirst(prefix.count)).isEmpty ? "" : String(
                    line.drop { "#* ".contains($0) }.dropFirst(prefix.count)
                ).trimmingCharacters(in: CharacterSet(charactersIn: "* ").union(.whitespaces))
                if line.isEmpty { continue }
            }
            let heading = line.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "#*: ").union(.whitespaces))
            switch heading {
            case "summary", "overview": section = .summary; continue
            case "decisions", "decisions made": section = .decisions; continue
            case "action items", "actions", "next steps": section = .actions; continue
            default: break
            }
            var item = String(line.drop { "-*•· ".contains($0) })
            if let number = item.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                item.removeSubrange(number)
            }
            item = item.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty, !isNone(item) else { continue }
            switch section {
            case .summary: overview.append(item)
            case .decisions: decisions.append(item)
            case .actions: actions.append(item)
            }
        }
        let summary = VoiceNoteSummary(
            overview: overview.joined(separator: " "), decisions: decisions, actionItems: actions,
            model: model, createdAt: now
        )
        return summary.isEmpty ? nil : summary
    }

    private static func isNone(_ item: String) -> Bool {
        let lowered = item.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        return ["none", "n/a", "none.", "no decisions", "no action items", "nothing"].contains(lowered)
    }
}
