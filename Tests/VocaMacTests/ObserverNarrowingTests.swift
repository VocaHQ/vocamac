// ObserverNarrowingTests.swift
// VocaMac

import Combine
import XCTest
@testable import VocaMac

/// The update checker's changes reach the views that show it, not every
/// view that reads AppState.
@MainActor
final class ObserverNarrowingTests: XCTestCase {

    func testUpdateCheckerChangesAreNotForwardedToAppState() {
        let (appState, _) = AppState.makeTestState()
        var appStateChanges = 0
        var checkerChanges = 0
        let appStateSink = appState.objectWillChange.sink { appStateChanges += 1 }
        let checkerSink = appState.updateChecker.objectWillChange.sink { checkerChanges += 1 }

        appState.updateChecker.updateState = .checking
        appState.updateChecker.updateState = .upToDate

        XCTAssertEqual(checkerChanges, 2)
        XCTAssertEqual(appStateChanges, 0)
        withExtendedLifetime((appStateSink, checkerSink)) {}
    }
}
