// ReleaseNotesTests.swift
// VocaMac

import XCTest
@testable import VocaMac

final class ReleaseNotesTests: XCTestCase {

    func testHeadingsBulletsAndParagraphs() {
        let notes = """
        ## What's new

        Faster cleanup on every Mac.
        It also uses less memory.

        - Command Mode checks its work
        * Paper look
        1. Numbered item
        """
        XCTAssertEqual(ReleaseNotes.blocks(from: notes), [
            .heading("What's new"),
            .paragraph("Faster cleanup on every Mac. It also uses less memory."),
            .bullet("Command Mode checks its work"),
            .bullet("Paper look"),
            .bullet("Numbered item"),
        ])
    }

    func testDropsCommentsImagesRulesAndTables() {
        let notes = """
        <!-- release-drafter: hidden -->
        ![screenshot](https://example.com/a.png)
        ---
        | Model | Size |
        |---|---|
        Kept.
        """
        XCTAssertEqual(ReleaseNotes.blocks(from: notes), [.paragraph("Kept.")])
    }

    func testEmptyNotesHaveNoBlocks() {
        XCTAssertEqual(ReleaseNotes.blocks(from: "  \n\n"), [])
    }

    func testInlineMarkdownFallsBackToPlainText() {
        XCTAssertEqual(String(ReleaseNotes.attributed("**Bold** and `code`").characters), "Bold and code")
    }
}
