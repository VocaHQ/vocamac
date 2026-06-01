// SnippetTests.swift
// VocaMac
//
// Tests for custom text snippets and expansion logic.

import XCTest
@testable import VocaMac

final class SnippetTests: XCTestCase {
    
    var appState: AppState!
    
    @MainActor
    override func setUp() async throws {
        // Use makeTestState to avoid real hardware access in CI
        let (testState, _) = AppState.makeTestState()
        appState = testState
        
        // Clear snippets for testing
        appState.snippets = []
    }
    
    @MainActor
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
    
    @MainActor
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
    
    @MainActor
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
    
    @MainActor
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

    @MainActor
    func testRegexExpansionSafety() {
        // Given
        appState.snippets = [
            Snippet(trigger: "price", expansion: "$100")
        ]
        
        // When
        let input = "The price is right"
        let output = appState.expandSnippets(in: input)
        
        // Then
        // If expansion is not escaped, $1 would be treated as a capture group reference.
        XCTAssertEqual(output, "The $100 is right")
    }
}
