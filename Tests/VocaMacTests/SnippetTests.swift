// SnippetTests.swift
// VocaMac
//
// Tests for custom text snippets and expansion logic.

import XCTest
@testable import VocaMac

@MainActor
final class SnippetTests: XCTestCase {
    
    var appState: AppState!
    
    override func setUp() async throws {
        // Use a fresh AppState for each test
        // We need to mock some dependencies to avoid side effects
        appState = AppState(
            cursorOverlay: MockCursorOverlayManager(),
            skipSystemIntegration: true
        )
        // Clear snippets for testing
        appState.snippets = []
    }
    
    func testSnippetExpansion() {
        // Given
        appState.snippets = [
            Snippet(trigger: "My Mail", expansion: "kanishk@example.com"),
            Snippet(trigger: "vmac", expansion: "VocaMac")
        ]
        
        // When
        let input1 = "Please send it to My Mail"
        let output1 = appState.expandSnippets(in: input1)
        
        let input2 = "I love vmac"
        let output2 = appState.expandSnippets(in: input2)
        
        // Then
        XCTAssertEqual(output1, "Please send it to kanishk@example.com")
        XCTAssertEqual(output2, "I love VocaMac")
    }
    
    func testCaseInsensitiveExpansion() {
        // Given
        appState.snippets = [
            Snippet(trigger: "My Mail", expansion: "kanishk@example.com")
        ]
        
        // When
        let input = "please send it to my mail"
        let output = appState.expandSnippets(in: input)
        
        // Then
        XCTAssertEqual(output, "please send it to kanishk@example.com")
    }
    
    func testWordBoundaries() {
        // Given
        appState.snippets = [
            Snippet(trigger: "mail", expansion: "kanishk@example.com")
        ]
        
        // When
        let input = "Check the mailbox for mail"
        let output = appState.expandSnippets(in: input)
        
        // Then
        // "mailbox" should NOT be replaced, but "mail" should.
        XCTAssertEqual(output, "Check the mailbox for kanishk@example.com")
    }
    
    func testOverlappingSnippets() {
        // Given
        // Snippets should be matched longest-trigger-first
        appState.snippets = [
            Snippet(trigger: "mail", expansion: "SHORT"),
            Snippet(trigger: "mail address", expansion: "LONG")
        ]
        
        // When
        let input = "my mail address"
        let output = appState.expandSnippets(in: input)
        
        // Then
        XCTAssertEqual(output, "my LONG")
    }
}

// Minimal mock for AppState dependency
class MockCursorOverlayManager: CursorOverlayManaging {
    func show() {}
    func hide() {}
    func updateAudioLevel(_ level: Float) {}
    func transitionToProcessing() {}
}
