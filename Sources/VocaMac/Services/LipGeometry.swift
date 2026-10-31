// LipGeometry.swift
// VocaMac
//
// The lips as numbers: what the camera tracker reports for each frame, and
// the shape and motion measures Silent Mode builds from it. Pure, so it is
// tested without a camera.
//
// Points arrive in the face box's unit square (Vision's landmark space, origin
// at the lower left). Everything here is made independent of where the face
// sits in the image and how far it is from the camera: points are levelled by
// the head's roll and measured in units of the mouth's own width.

import CoreGraphics
import Foundation

// MARK: - LipShape

/// One face's lips in one camera frame.
struct LipShape: Equatable, Sendable {
    /// The outer lip contour in the face box's unit square, in tracker order.
    var outer: [CGPoint]
    /// The contour around the opening between the lips.
    var inner: [CGPoint]
    /// Head roll in radians (tilt toward a shoulder).
    var roll: Double
    /// Head yaw in radians (turned left or right). Zero when unknown.
    var yaw: Double
    /// The face box in the image's unit square.
    var faceBox: CGRect

    /// A face turned this far from the camera is not talking to the Mac
    /// (a colleague, a second display), and its lips are drawn side-on.
    static let maximumYaw = 0.6

    /// Smaller faces than this, as a share of the image width, give lip
    /// points too coarse to measure motion with.
    static let minimumFaceWidth = 0.08

    /// Whether the frame is good enough to read articulation from.
    var isUsable: Bool {
        outer.count >= 4 && inner.count >= 2 && abs(yaw) <= Self.maximumYaw
            && faceBox.width >= Self.minimumFaceWidth
    }

    /// The outer and inner contours in the image's unit square, for drawing
    /// over the camera picture.
    var imagePoints: (outer: [CGPoint], inner: [CGPoint]) {
        func map(_ point: CGPoint) -> CGPoint {
            CGPoint(x: faceBox.minX + point.x * faceBox.width, y: faceBox.minY + point.y * faceBox.height)
        }
        return (outer.map(map), inner.map(map))
    }
}

// MARK: - LipFrame

/// What the tracker saw at one moment: the lips, or no usable face.
struct LipFrame: Equatable, Sendable {
    /// Seconds on `ProcessInfo.systemUptime`'s clock, like the recording's.
    var time: TimeInterval
    /// Nil when no face was found.
    var shape: LipShape?
    /// The camera image size in pixels.
    var imageSize: CGSize = CGSize(width: 640, height: 480)
    /// The mouth patch for lip reading, while the tracker is asked for it.
    var mouth: MouthPatch?

    /// The lips, when they can be read.
    var usableShape: LipShape? {
        guard let shape, shape.isUsable else { return nil }
        return shape
    }
}

// MARK: - LipFeatures

/// The lips in one frame as a fixed-length list of numbers: how open, how
/// wide, how round, and the contours resampled to a fixed number of points.
/// Comparable across frames, sessions and distances from the camera.
struct LipFeatures: Equatable, Sendable {
    /// Points the outer contour is resampled to.
    static let outerSamples = 10
    /// Points the inner contour is resampled to.
    static let innerSamples = 6

    /// Inner opening height over the mouth's width: 0 closed, about 0.5 wide open.
    var openness: Double
    /// Mouth width over the face width: wider in a smile or "ee", narrower in "oo".
    var spread: Double
    /// Outer height over width: rounder for "oo", flatter for "ee".
    var roundness: Double
    /// Outer contour, levelled, centred on the mouth and scaled by its width.
    var outer: [CGPoint]
    /// Inner contour, in the same frame as `outer`.
    var inner: [CGPoint]

    /// Every measure in one vector, for template matching.
    var vector: [Double] {
        var values = [openness, spread, roundness]
        values.reserveCapacity(3 + 2 * (outer.count + inner.count))
        for point in outer + inner {
            values.append(Double(point.x))
            values.append(Double(point.y))
        }
        return values
    }

    /// Length of `vector`.
    static let dimensions = 3 + 2 * (outerSamples + innerSamples)

    init(openness: Double, spread: Double, roundness: Double, outer: [CGPoint], inner: [CGPoint]) {
        self.openness = openness
        self.spread = spread
        self.roundness = roundness
        self.outer = outer
        self.inner = inner
    }

    /// The features of `shape`, or nil when its contours are degenerate.
    init?(_ shape: LipShape) {
        guard shape.outer.count >= 3, shape.inner.count >= 2 else { return nil }
        let centre = LipGeometry.centroid(shape.outer)
        // Vision's points are in the face box's unit square, which is not
        // square in pixels; the box's aspect makes x and y comparable.
        let aspect = shape.faceBox.width > 0 ? Double(shape.faceBox.height / shape.faceBox.width) : 1
        func level(_ point: CGPoint) -> CGPoint {
            let x = Double(point.x - centre.x)
            let y = Double(point.y - centre.y) * aspect
            let cosine = cos(-shape.roll), sine = sin(-shape.roll)
            return CGPoint(x: x * cosine - y * sine, y: x * sine + y * cosine)
        }
        let levelledOuter = shape.outer.map(level)
        let levelledInner = shape.inner.map(level)
        let outerBounds = LipGeometry.bounds(levelledOuter)
        let innerBounds = LipGeometry.bounds(levelledInner)
        let width = Double(outerBounds.width)
        guard width > 1e-4 else { return nil }
        func scaled(_ point: CGPoint) -> CGPoint {
            CGPoint(x: Double(point.x) / width, y: Double(point.y) / width)
        }
        self.init(
            openness: Double(innerBounds.height) / width,
            // In face-box units the face is 1 wide.
            spread: width,
            roundness: Double(outerBounds.height) / width,
            outer: LipGeometry.resampledLoop(levelledOuter, count: Self.outerSamples).map(scaled),
            inner: LipGeometry.resampledLoop(levelledInner, count: Self.innerSamples).map(scaled)
        )
    }

    /// How far the lips moved from `previous` to this frame: the mean point
    /// distance in mouth widths, plus the change in opening.
    func motion(from previous: LipFeatures) -> Double {
        let points = zip(outer + inner, previous.outer + previous.inner)
        var total = 0.0
        var count = 0
        for (now, before) in points {
            total += hypot(Double(now.x - before.x), Double(now.y - before.y))
            count += 1
        }
        let shapeChange = count > 0 ? total / Double(count) : 0
        return shapeChange + abs(openness - previous.openness)
    }
}

// MARK: - Geometry helpers

enum LipGeometry {
    static func centroid(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(into: CGPoint.zero) { result, point in
            result.x += point.x
            result.y += point.y
        }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    static func bounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Twice the signed area: positive when the loop runs counterclockwise.
    static func signedArea(_ points: [CGPoint]) -> Double {
        guard points.count >= 3 else { return 0 }
        var sum = 0.0
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            sum += Double(current.x * next.y - next.x * current.y)
        }
        return sum
    }

    /// `points` as a closed loop resampled to `count` points evenly spaced
    /// along it, starting at the leftmost point and running counterclockwise,
    /// so the same mouth gives the same list whatever order the tracker used.
    static func resampledLoop(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard count > 0 else { return [] }
        guard points.count >= 2 else { return Array(repeating: points.first ?? .zero, count: count) }
        var loop = points
        if signedArea(loop) < 0 { loop.reverse() }
        if let start = loop.indices.min(by: { loop[$0].x < loop[$1].x }) {
            loop = Array(loop[start...] + loop[..<start])
        }
        let closed = loop + [loop[0]]
        var lengths: [Double] = [0]
        for index in 1..<closed.count {
            let step = hypot(Double(closed[index].x - closed[index - 1].x), Double(closed[index].y - closed[index - 1].y))
            lengths.append(lengths[index - 1] + step)
        }
        guard let total = lengths.last, total > 0 else { return Array(repeating: loop[0], count: count) }
        var result: [CGPoint] = []
        result.reserveCapacity(count)
        var segment = 1
        for sample in 0..<count {
            let target = total * Double(sample) / Double(count)
            while segment < lengths.count - 1, lengths[segment] < target { segment += 1 }
            let start = closed[segment - 1], end = closed[segment]
            let span = lengths[segment] - lengths[segment - 1]
            let fraction = span > 0 ? (target - lengths[segment - 1]) / span : 0
            result.append(CGPoint(
                x: Double(start.x) + Double(end.x - start.x) * fraction,
                y: Double(start.y) + Double(end.y - start.y) * fraction
            ))
        }
        return result
    }
}
