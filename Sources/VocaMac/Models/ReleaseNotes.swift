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
    }

    /// Blocks in reading order. Blank lines end a paragraph; consecutive
    /// text lines join into one. HTML comments, images, horizontal rules and
    /// table rows are dropped: the window is for reading, the release page
    /// has the rest.
    static func blocks(from markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []

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
            if line.isEmpty {
                flushParagraph()
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
                continue
            }
            if let range = line.range(of: "^[0-9]+[.)] ", options: .regularExpression) {
                flushParagraph()
                blocks.append(.bullet(String(line[range.upperBound...])))
                continue
            }
            paragraph.append(line)
        }
        flushParagraph()
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
