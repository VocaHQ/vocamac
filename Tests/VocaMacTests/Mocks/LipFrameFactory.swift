// LipFrameFactory.swift
// VocaMacTests
//
// Synthetic lip frames for Silent Mode tests: an elliptical mouth whose
// opening, width and roundness follow a function of time, sampled at 30
// frames a second, the way the camera tracker reports them.

import CoreGraphics
import Foundation
@testable import VocaMac

enum LipFrameFactory {
    static let faceBox = CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.5)
    static let fps = 30.0

    /// Lips in the face box's unit square.
    static func shape(
        openness: Double, width: Double = 0.4, roundness: Double = 0.35,
        roll: Double = 0, yaw: Double = 0, faceBox: CGRect = faceBox
    ) -> LipShape {
        let centre = CGPoint(x: 0.5, y: 0.25)
        let outer = ellipse(centre: centre, radiusX: width / 2, radiusY: width * roundness / 2, count: 12)
        let inner = ellipse(centre: centre, radiusX: width * 0.35, radiusY: max(openness * width / 2, 0.0005), count: 8)
        func rotated(_ point: CGPoint) -> CGPoint {
            guard roll != 0 else { return point }
            let x = Double(point.x - centre.x), y = Double(point.y - centre.y)
            return CGPoint(x: Double(centre.x) + x * cos(roll) - y * sin(roll), y: Double(centre.y) + x * sin(roll) + y * cos(roll))
        }
        return LipShape(outer: outer.map(rotated), inner: inner.map(rotated), roll: roll, yaw: yaw, faceBox: faceBox)
    }

    static func ellipse(centre: CGPoint, radiusX: Double, radiusY: Double, count: Int) -> [CGPoint] {
        (0..<count).map { index in
            let angle = 2 * Double.pi * Double(index) / Double(count)
            return CGPoint(x: Double(centre.x) + radiusX * cos(angle), y: Double(centre.y) + radiusY * sin(angle))
        }
    }

    /// Frames from `start` for `seconds`, the mouth following `openness`
    /// (and optionally `width`) as functions of seconds since `start`.
    static func frames(
        from start: TimeInterval, seconds: Double,
        openness: (Double) -> Double,
        width: (Double) -> Double = { _ in 0.4 },
        roundness: (Double) -> Double = { _ in 0.35 }
    ) -> [LipFrame] {
        let count = Int((seconds * fps).rounded())
        return (0..<count).map { index in
            let elapsed = Double(index) / fps
            return LipFrame(
                time: start + elapsed,
                shape: shape(openness: openness(elapsed), width: width(elapsed), roundness: roundness(elapsed))
            )
        }
    }

    /// Lips at rest.
    static func still(from start: TimeInterval, seconds: Double) -> [LipFrame] {
        frames(from: start, seconds: seconds, openness: { _ in 0.02 })
    }

    /// Lips mouthing syllables: the opening swings `amplitude` at `rate` Hz.
    static func speaking(from start: TimeInterval, seconds: Double, amplitude: Double = 0.25, rate: Double = 4) -> [LipFrame] {
        frames(from: start, seconds: seconds, openness: { elapsed in
            0.02 + amplitude * (1 - cos(2 * Double.pi * rate * elapsed)) / 2
        })
    }

    /// No face in view.
    static func noFace(from start: TimeInterval, seconds: Double) -> [LipFrame] {
        let count = Int((seconds * fps).rounded())
        return (0..<count).map { LipFrame(time: start + Double($0) / fps, shape: nil) }
    }
}
