// LiveTranscriptStateTests.swift
// VocaMac Tests

import Combine
import XCTest
@testable import VocaMac

@MainActor
final class LiveTranscriptStateTests: XCTestCase {
    func testRepeatedPartialDoesNotRedraw() {
        let state = LiveTranscriptState()
        var changes = 0
        let subscription = state.objectWillChange.sink { changes += 1 }
        state.update("hello")
        state.update("hello")
        state.update("hello world")
        XCTAssertEqual(state.text, "hello world")
        XCTAssertEqual(changes, 2)
        subscription.cancel()
    }

    func testPartialsDoNotInvalidateAppState() async {
        let (app, _) = AppState.makeTestState()
        var appChanges = 0
        let subscription = app.objectWillChange.sink { appChanges += 1 }
        app.liveTranscriptState.update("words so far")
        XCTAssertEqual(app.liveTranscript, "words so far")
        XCTAssertEqual(appChanges, 0)
        subscription.cancel()
    }
}
