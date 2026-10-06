// LiveTranscriptStateTests.swift
// VocaMac Tests

import Combine
import Observation
import XCTest
@testable import VocaMac

@MainActor
final class LiveTranscriptStateTests: XCTestCase {
    /// Whether reading `text` and then running `change` notifies observers.
    private func notifies(_ state: LiveTranscriptState, _ change: () -> Void) -> Bool {
        var notified = false
        withObservationTracking { _ = state.text } onChange: { notified = true }
        change()
        return notified
    }

    func testRepeatedPartialDoesNotRedraw() {
        let state = LiveTranscriptState()
        XCTAssertTrue(notifies(state) { state.update("hello") })
        XCTAssertFalse(notifies(state) { state.update("hello") })
        XCTAssertTrue(notifies(state) { state.update("hello world") })
        XCTAssertEqual(state.text, "hello world")
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
