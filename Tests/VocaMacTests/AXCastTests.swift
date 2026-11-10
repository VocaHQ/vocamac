// AXCastTests.swift
// VocaMac Tests
//
// Type-checked casts of Accessibility return values. No Accessibility
// permission is needed: the values are built locally.

import ApplicationServices
import XCTest
@testable import VocaMac

final class AXCastTests: XCTestCase {
    func testElementAcceptsOnlyAnAXUIElement() {
        XCTAssertNotNil(AXCast.element(AXUIElementCreateSystemWide()))
        XCTAssertNil(AXCast.element(nil))
        XCTAssertNil(AXCast.element("not an element" as CFString))
        var point = CGPoint(x: 1, y: 2)
        XCTAssertNil(AXCast.element(AXValueCreate(.cgPoint, &point)))
    }

    func testValueAcceptsOnlyAnAXValue() {
        var point = CGPoint(x: 1, y: 2)
        XCTAssertNotNil(AXCast.value(AXValueCreate(.cgPoint, &point)))
        XCTAssertNil(AXCast.value(nil))
        XCTAssertNil(AXCast.value(AXUIElementCreateSystemWide()))
        XCTAssertNil(AXCast.value(42 as CFNumber))
    }

    func testTypedReadersReadTheMatchingTypeOnly() {
        var point = CGPoint(x: 3, y: 4)
        let pointValue = AXValueCreate(.cgPoint, &point)
        XCTAssertEqual(AXCast.point(pointValue), CGPoint(x: 3, y: 4))
        XCTAssertNil(AXCast.size(pointValue), "A point is not a size")
        XCTAssertNil(AXCast.range(pointValue), "A point is not a range")

        var size = CGSize(width: 5, height: 6)
        XCTAssertEqual(AXCast.size(AXValueCreate(.cgSize, &size)), CGSize(width: 5, height: 6))

        var range = CFRange(location: 5, length: 2)
        let read = AXCast.range(AXValueCreate(.cfRange, &range))
        XCTAssertEqual(read?.location, 5)
        XCTAssertEqual(read?.length, 2)

        XCTAssertNil(AXCast.point(AXUIElementCreateSystemWide()))
        XCTAssertNil(AXCast.point(nil))
    }
}
