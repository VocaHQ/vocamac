// ReleaseNotes.swift
// VocaMac
//
// Turns a GitHub release body (Markdown) into blocks the update window can
// set as headings, bullets and paragraphs.

import Foundation

enum ReleaseNotes {
    enum Block: Equatable {
        case heading(String)
        case bullet(String)
        case paragraph(String)
        /// A fenced command or snippet, kept line for line.
        case code(String)
    }

    /// Blocks in reading order. Blank lines end a paragraph; consecutive
    /// text lines join into one, and a line that follows a bullet without a
    /// blank line continues that bullet. Fenced code stays as written. HTML
    /// comments, images, horizontal rules and table rows are dropped: the
    /// window is for reading, the release page has the rest.
    static func blocks(from markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        /// The fence that opened the code block; only a fence of the same
        /// character, at least as long, closes it.
        var openingFence = ""
        var continuesBullet = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        let withoutComments = markdown.replacingOccurrences(
            of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression
        )
        for rawLine in withoutComments.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let lines = code {
                if isClosingFence(line, opening: openingFence) {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    code?.append(rawLine)
                }
                continue
            }
            if let fence = openingFenceRun(line) {
                flushParagraph()
                openingFence = fence
                code = []
                continuesBullet = false
                continue
            }
            if line.isEmpty {
                flushParagraph()
                continuesBullet = false
                continue
            }
            if line.hasPrefix("!["), line.hasSuffix(")") { continue }
            if line.hasPrefix("|") || line.allSatisfy({ "-*_ ".contains($0) }) {
                flushParagraph()
                continue
            }
            if line.hasPrefix("#") {
                flushParagraph()
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { blocks.append(.heading(title)) }
                continue
            }
            if let marker = ["- ", "* ", "+ "].first(where: { line.hasPrefix($0) }) {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(marker.count))))
                continuesBullet = true
                continue
            }
            if let range = line.range(of: "^[0-9]+[.)] ", options: .regularExpression) {
                flushParagraph()
                blocks.append(.bullet(String(line[range.upperBound...])))
                continuesBullet = true
                continue
            }
            if continuesBullet, case .bullet(let text)? = blocks.last {
                blocks[blocks.count - 1] = .bullet(text + " " + line)
                continue
            }
            paragraph.append(line)
        }
        flushParagraph()
        // An unclosed fence still shows what it held.
        if let lines = code, !lines.isEmpty { blocks.append(.code(lines.joined(separator: "\n"))) }
        return blocks
    }

    /// The run of three or more backticks or tildes that opens a fence.
    private static func openingFenceRun(_ line: String) -> String? {
        guard let marker = line.first, marker == "`" || marker == "~" else { return nil }
        let run = String(line.prefix { $0 == marker })
        return run.count >= 3 ? run : nil
    }

    /// A closing fence: the opening's character, at least as many of it, and
    /// nothing else on the line.
    private static func isClosingFence(_ line: String, opening: String) -> Bool {
        guard let marker = opening.first else { return false }
        return line.count >= opening.count && line.allSatisfy { $0 == marker }
    }

    /// Inline Markdown (bold, code, links) for one block, or the plain text
    /// when it doesn't parse.
    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
