// DMGBackgroundTests.swift
// VocaMac Tests

import AppKit
import ImageIO
import XCTest
@testable import VocaMac

final class DMGBackgroundTests: XCTestCase {

    func testInstallerBackgroundsKeepFinderDensityMetadata() throws {
        try assertBackground(name: "dmg-background", width: 1320, height: 1040)
        try assertBackground(name: "dmg-background@2x", width: 2640, height: 2080)
    }

    func testFinderBackgroundHasExpectedLogicalWindowSize() throws {
        let url = try resourceURL(named: "dmg-background")
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        XCTAssertEqual(image.size.width, 660, accuracy: 0.01)
        XCTAssertEqual(image.size.height, 520, accuracy: 0.01)
    }

    private func assertBackground(name: String, width: Int, height: Int) throws {
        let url = try resourceURL(named: name)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )

        let pixelWidth = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? NSNumber)
        let pixelHeight = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? NSNumber)
        let dpiWidth = try XCTUnwrap(properties[kCGImagePropertyDPIWidth] as? NSNumber)
        let dpiHeight = try XCTUnwrap(properties[kCGImagePropertyDPIHeight] as? NSNumber)

        XCTAssertEqual(pixelWidth.intValue, width, name)
        XCTAssertEqual(pixelHeight.intValue, height, name)
        XCTAssertEqual(dpiWidth.doubleValue, 144, accuracy: 0.01, name)
        XCTAssertEqual(dpiHeight.doubleValue, 144, accuracy: 0.01, name)
    }

    private func resourceURL(named name: String) throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(
                forResource: name,
                withExtension: "png",
                subdirectory: "Resources"
            ) ?? Bundle.module.url(forResource: name, withExtension: "png")
        )
    }
}
