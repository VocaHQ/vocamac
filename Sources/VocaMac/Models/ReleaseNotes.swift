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
            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    code = []
                }
                continuesBullet = false
                continue
            }
            if code != nil {
                code?.append(rawLine)
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

    /// Inline Markdown (bold, code, links) for one block, or the plain text
    /// when it doesn't parse.
    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
