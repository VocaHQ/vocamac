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

    func testPayloadReadsTheMatchingTypeOnly() {
        var point = CGPoint(x: 3, y: 4)
        let pointValue = AXValueCreate(.cgPoint, &point)
        XCTAssertEqual(AXCast.payload(pointValue, as: .cgPoint, default: CGPoint.zero), CGPoint(x: 3, y: 4))
        XCTAssertNil(AXCast.payload(pointValue, as: .cgSize, default: CGSize.zero), "A point is not a size")

        var range = CFRange(location: 5, length: 2)
        let rangeValue = AXValueCreate(.cfRange, &range)
        let read = AXCast.payload(rangeValue, as: .cfRange, default: CFRange())
        XCTAssertEqual(read?.location, 5)
        XCTAssertEqual(read?.length, 2)

        XCTAssertNil(AXCast.payload(AXUIElementCreateSystemWide(), as: .cgPoint, default: CGPoint.zero))
        XCTAssertNil(AXCast.payload(nil, as: .cgPoint, default: CGPoint.zero))
    }
}
