import XCTest
@testable import VocaMac

final class SettingsWindowGeometryTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1050)

    func testCollapsedSavedFrameIsRejected() {
        XCTAssertTrue(SettingsWindowGeometry.needsReset(CGRect(x: 959, y: 766, width: 1, height: 28), screens: [screen]))
    }

    func testUsableFrameIsPreserved() {
        XCTAssertFalse(SettingsWindowGeometry.needsReset(CGRect(x: 300, y: 200, width: 860, height: 658), screens: [screen]))
    }

    func testDisconnectedDisplayIsRejected() {
        XCTAssertTrue(SettingsWindowGeometry.needsReset(CGRect(x: 2400, y: 200, width: 860, height: 658), screens: [screen]))
    }

    func testWindowOnSecondaryDisplayIsPreserved() {
        let second = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        XCTAssertFalse(SettingsWindowGeometry.needsReset(CGRect(x: 2400, y: 200, width: 860, height: 658), screens: [screen, second]))
    }
}
