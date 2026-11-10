// TestDefaults.swift
// VocaMac
//
// The settings store test AppStates use instead of UserDefaults.standard.

import Foundation
import XCTest

/// One settings store per test process, emptied after every test. Tests
/// used to share `UserDefaults.standard`, so a value one test left behind,
/// or one a test run in another checkout wrote at the same moment, changed
/// what the next test saw.
enum TestDefaults {
    static let suiteName = "com.vocamac.tests.\(ProcessInfo.processInfo.processIdentifier)"

    /// Created on first use, empty, and emptied again when each test ends.
    static let store: UserDefaults = {
        guard let store = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create the test settings store \(suiteName)")
        }
        store.removePersistentDomain(forName: suiteName)
        XCTestObservationCenter.shared.addTestObserver(TestDefaultsReset())
        return store
    }()

    static func reset() {
        store.removePersistentDomain(forName: suiteName)
    }
}

/// Empties the store after each test, and once more when the run ends so
/// no settings file is left behind.
private final class TestDefaultsReset: NSObject, XCTestObservation {
    func testCaseDidFinish(_ testCase: XCTestCase) {
        TestDefaults.reset()
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        TestDefaults.reset()
    }
}
