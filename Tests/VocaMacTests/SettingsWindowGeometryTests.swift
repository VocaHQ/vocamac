import XCTest
@testable import VocaMac

final class SettingsWindowGeometryTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1050)

    func testCollapsedSavedFrameIsRejected() {
        XCTAssertTrue(SettingsWindowGeometry.needsReset(CGRect(x: 959, y: 766, width: 1, height: 28), screens: [screen]))
    }

    func testUsableFrameIsPreserved() {
        XCTAssertFalse(SettingsWindowGeometry.needsReset(CGRect(x: 300, y: 200, width: 1240, height: 800), screens: [screen]))
    }

    func testMinimumSizeFrameIsPreserved() {
        let size = SettingsWindowGeometry.minimumContentSize
        XCTAssertFalse(SettingsWindowGeometry.needsReset(CGRect(origin: CGPoint(x: 300, y: 200), size: size), screens: [screen]))
    }

    /// The old Settings window (860 × 620) is too small for the v3 window
    /// and its Settings sheet, so a remembered frame of that size resets.
    func testOldSettingsWindowFrameIsRejected() {
        XCTAssertTrue(SettingsWindowGeometry.needsReset(CGRect(x: 300, y: 200, width: 860, height: 658), screens: [screen]))
    }

    func testSettingsSheetFitsTheSmallestWindowOnARoomyScreen() {
        let minimum = SettingsWindowGeometry.minimumContentSize
        XCTAssertGreaterThanOrEqual(minimum.width, CalmMetrics.sheetSize.width + 2 * CalmMetrics.Space.s40)
        XCTAssertGreaterThanOrEqual(minimum.height, CalmMetrics.sheetSize.height + 2 * 30)
        XCTAssertEqual(SettingsWindowGeometry.sheetSize(in: minimum), CalmMetrics.sheetSize)
        XCTAssertGreaterThanOrEqual(SettingsWindowGeometry.defaultContentSize.width, minimum.width)
        XCTAssertGreaterThanOrEqual(SettingsWindowGeometry.defaultContentSize.height, minimum.height)
    }

    /// A 13" laptop at a larger-text scaling has about 1024 × 640 visible:
    /// the minimum and the opening size fit the screen, and the sheet
    /// shrinks to keep its margin inside the smaller window.
    func testSmallScreenClampsTheMinimumAndShrinksTheSheet() {
        let laptop = CGRect(x: 0, y: 0, width: 1024, height: 640)
        let minimum = SettingsWindowGeometry.minimumContentSize(forVisibleFrame: laptop)
        XCTAssertLessThanOrEqual(minimum.width, laptop.width)
        XCTAssertLessThanOrEqual(minimum.height, laptop.height)
        let opening = SettingsWindowGeometry.openingContentSize(forVisibleFrame: laptop)
        XCTAssertLessThanOrEqual(opening.width, laptop.width)
        XCTAssertLessThanOrEqual(opening.height, laptop.height)
        XCTAssertFalse(SettingsWindowGeometry.needsReset(CGRect(origin: laptop.origin, size: opening), screens: [laptop]))

        let sheet = SettingsWindowGeometry.sheetSize(in: minimum)
        XCTAssertLessThan(sheet.height, CalmMetrics.sheetSize.height)
        XCTAssertEqual(sheet.width, minimum.width - 2 * SettingsWindowGeometry.sheetMargin.width)
        XCTAssertEqual(sheet.height, minimum.height - 2 * SettingsWindowGeometry.sheetMargin.height)
        // On a roomy screen the minimum is the full one.
        XCTAssertEqual(SettingsWindowGeometry.minimumContentSize(forVisibleFrame: screen), SettingsWindowGeometry.minimumContentSize)
        // Never below what the layout supports, however small the screen.
        let tiny = SettingsWindowGeometry.minimumContentSize(forVisibleFrame: CGRect(x: 0, y: 0, width: 640, height: 400))
        XCTAssertEqual(tiny, SettingsWindowGeometry.smallestContentSize)
    }

    func testDisconnectedDisplayIsRejected() {
        XCTAssertTrue(SettingsWindowGeometry.needsReset(CGRect(x: 2400, y: 200, width: 1240, height: 800), screens: [screen]))
    }

    func testWindowOnSecondaryDisplayIsPreserved() {
        let second = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        XCTAssertFalse(SettingsWindowGeometry.needsReset(CGRect(x: 2400, y: 200, width: 1240, height: 800), screens: [screen, second]))
    }

    func testV3WindowDoesNotReuseTheOldSettingsFrame() {
        // The old window saved 1080 × 740 under this name; the v3 window
        // must start fresh at the default size.
        XCTAssertNotEqual(SettingsWindowGeometry.frameAutosaveName, "VocaMac.Settings")
        XCTAssertTrue(SettingsWindowGeometry.retiredFrameAutosaveNames.contains("VocaMac.Settings"))
        XCTAssertFalse(SettingsWindowGeometry.retiredFrameAutosaveNames.contains(SettingsWindowGeometry.frameAutosaveName))
    }

    func testOpensAtTheDefaultSizeOnARoomyScreen() {
        XCTAssertEqual(
            SettingsWindowGeometry.openingContentSize(forVisibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1079)),
            SettingsWindowGeometry.defaultContentSize
        )
        XCTAssertEqual(SettingsWindowGeometry.openingContentSize(forVisibleFrame: nil), SettingsWindowGeometry.defaultContentSize)
    }

    func testOpeningSizeShrinksToFitASmallScreenButNotBelowTheMinimum() {
        let small = SettingsWindowGeometry.openingContentSize(forVisibleFrame: CGRect(x: 0, y: 0, width: 1280, height: 775))
        XCTAssertEqual(small.width, 1200)
        XCTAssertEqual(small.height, 740)
        let tiny = SettingsWindowGeometry.openingContentSize(forVisibleFrame: CGRect(x: 0, y: 0, width: 1024, height: 640))
        XCTAssertEqual(tiny, CGSize(width: 1024, height: 640))
        // A size it opens at is never one the frame check would reset.
        let frame = CGRect(origin: CGPoint(x: 40, y: 0), size: small)
        XCTAssertFalse(SettingsWindowGeometry.needsReset(frame, screens: [CGRect(x: 0, y: 0, width: 1280, height: 775)]))
    }
}
