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

    func testFencedCodeStaysAsWritten() {
        let notes = """
        Upgrade with:
        ```bash
        brew upgrade --cask vocamac
          --greedy
        ```
        Done.
        """
        XCTAssertEqual(ReleaseNotes.blocks(from: notes), [
            .paragraph("Upgrade with:"),
            .code("brew upgrade --cask vocamac\n  --greedy"),
            .paragraph("Done."),
        ])
    }

    func testWrappedBulletLineContinuesTheBullet() {
        let notes = """
        - Cleanup keeps spoken corrections
          and punctuation intact.
        - Second item

        A paragraph after a blank line.
        """
        XCTAssertEqual(ReleaseNotes.blocks(from: notes), [
            .bullet("Cleanup keeps spoken corrections and punctuation intact."),
            .bullet("Second item"),
            .paragraph("A paragraph after a blank line."),
        ])
    }
}
