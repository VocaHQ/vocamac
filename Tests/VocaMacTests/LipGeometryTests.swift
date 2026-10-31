// LipGeometryTests.swift
// VocaMacTests
//
// Lip features are the same whatever the face's place in the picture, its
// tilt, and the order the tracker lists points in; they change when the
// mouth does.

import CoreGraphics
import XCTest
@testable import VocaMac

final class LipGeometryTests: XCTestCase {

    func testOpennessIsTheOpeningOverTheMouthWidth() throws {
        // A square face box: the face box's aspect is otherwise part of the measure.
        let square = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let features = try XCTUnwrap(LipFeatures(LipFrameFactory.shape(openness: 0.3, width: 0.4, faceBox: square)))
        // Inner height is openness × width (2 × radius); over the outer width.
        XCTAssertEqual(features.openness, 0.3, accuracy: 0.01)
        XCTAssertEqual(features.spread, 0.4, accuracy: 0.001)
        XCTAssertEqual(features.roundness, 0.35, accuracy: 0.01)
        XCTAssertEqual(features.vector.count, LipFeatures.dimensions)
    }

    func testFeaturesDoNotDependOnWhereTheFaceIs() throws {
        let left = LipFrameFactory.shape(openness: 0.2, faceBox: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.5))
        let right = LipFrameFactory.shape(openness: 0.2, faceBox: CGRect(x: 0.5, y: 0.3, width: 0.4, height: 0.5))
        let a = try XCTUnwrap(LipFeatures(left)).vector
        let b = try XCTUnwrap(LipFeatures(right)).vector
        for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: 1e-9) }
    }

    func testATiltedHeadIsLevelled() throws {
        let level = try XCTUnwrap(LipFeatures(LipFrameFactory.shape(openness: 0.2)))
        let tilted = try XCTUnwrap(LipFeatures(LipFrameFactory.shape(openness: 0.2, roll: 0.3)))
        XCTAssertEqual(level.openness, tilted.openness, accuracy: 0.02)
        XCTAssertEqual(level.roundness, tilted.roundness, accuracy: 0.02)
    }

    func testTheContourIsTheSameWhicheverWayTheTrackerListsIt() {
        let points = LipFrameFactory.ellipse(centre: CGPoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.1, count: 12)
        let forward = LipGeometry.resampledLoop(points, count: 8)
        let backward = LipGeometry.resampledLoop(Array(points.reversed()), count: 8)
        let rotated = LipGeometry.resampledLoop(Array(points[5...] + points[..<5]), count: 8)
        for (a, b) in zip(forward, backward) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-9)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-9)
        }
        for (a, b) in zip(forward, rotated) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-9)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-9)
        }
        // Starts at the left corner.
        XCTAssertEqual(forward[0].x, 0.3, accuracy: 1e-9)
    }

    func testMotionIsZeroForAStillMouthAndGrowsWithMovement() throws {
        let closed = try XCTUnwrap(LipFeatures(LipFrameFactory.shape(openness: 0.02)))
        let ajar = try XCTUnwrap(LipFeatures(LipFrameFactory.shape(openness: 0.1)))
        let open = try XCTUnwrap(LipFeatures(LipFrameFactory.shape(openness: 0.4)))
        XCTAssertEqual(closed.motion(from: closed), 0, accuracy: 1e-12)
        XCTAssertGreaterThan(ajar.motion(from: closed), 0)
        XCTAssertGreaterThan(open.motion(from: closed), ajar.motion(from: closed))
    }

    func testAFaceTurnedAwayOrTooSmallIsNotRead() {
        XCTAssertTrue(LipFrameFactory.shape(openness: 0.1).isUsable)
        XCTAssertFalse(LipFrameFactory.shape(openness: 0.1, yaw: 0.9).isUsable)
        XCTAssertFalse(LipFrameFactory.shape(openness: 0.1, faceBox: CGRect(x: 0.4, y: 0.4, width: 0.05, height: 0.06)).isUsable)
        XCTAssertNil(LipFrame(time: 0, shape: nil).usableShape)
    }

    func testTheOutlineIsMirroredLikeAMirror() throws {
        var shape = LipFrameFactory.shape(openness: 0.2)
        // Move the mouth to the left of the face box: in the mirror it is on the right.
        shape.outer = shape.outer.map { CGPoint(x: $0.x - 0.2, y: $0.y) }
        shape.inner = shape.inner.map { CGPoint(x: $0.x - 0.2, y: $0.y) }
        let outline = try XCTUnwrap(LipOutline(shape))
        let centreX = outline.outerInImage.map(\.x).reduce(0, +) / CGFloat(outline.outerInImage.count)
        let unmirrored = shape.imagePoints.outer.map(\.x).reduce(0, +) / CGFloat(shape.outer.count)
        XCTAssertEqual(centreX, 1 - unmirrored, accuracy: 1e-9)
        // The badge outline is centred whatever the mouth's place.
        let badgeCentre = outline.outer.map(\.x).reduce(0, +) / CGFloat(outline.outer.count)
        XCTAssertEqual(badgeCentre, 0.5, accuracy: 0.02)
    }
}
