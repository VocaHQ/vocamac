// MouthCrop.swift
// VocaMac
//
// The picture the lip-reading model reads: an 88×88 grayscale crop of the
// mouth, 25 times a second, made the way the model's training data was
// (Auto-AVSR's `preparation/` and Chaplin's `video_process.py`):
//
// 1. Four face points (eyes, nose base, mouth centre) are smoothed over
//    ±6 frames and mapped onto a mean face in a 256×256 square by a
//    similarity transform.
// 2. A 96×96 square around the mapped mouth centre is cut, and its centre
//    88×88 kept.
//
// The camera tracker cuts a larger 128×128 patch in the same mean-face
// space as each frame arrives, with that frame's own (unsmoothed)
// transform. `MouthCropBuilder` then waits six frames, smooths, and cuts
// the final crop from the patch. So only small patches are held, never
// whole frames. Pure apart from the pixel buffer read in the tracker.

import CoreGraphics
import Foundation

// MARK: - Points and transforms

/// The four face points the crop is aligned by, in image pixels with a
/// top-left origin.
struct MouthKeypoints: Equatable, Sendable {
    /// The eye on the image's left (the person's right eye, unmirrored).
    var rightEye: CGPoint
    var leftEye: CGPoint
    /// The base of the nose.
    var nose: CGPoint
    /// The centre of the lips.
    var mouth: CGPoint

    var points: [CGPoint] { [rightEye, leftEye, nose, mouth] }

    init(rightEye: CGPoint, leftEye: CGPoint, nose: CGPoint, mouth: CGPoint) {
        self.rightEye = rightEye
        self.leftEye = leftEye
        self.nose = nose
        self.mouth = mouth
    }

    init(points: [CGPoint]) {
        self.init(rightEye: points[0], leftEye: points[1], nose: points[2], mouth: points[3])
    }
}

/// x' = a·x − b·y + tx, y' = b·x + a·y + ty: rotation, uniform scale, shift.
struct SimilarityTransform: Equatable, Sendable {
    var a: Double
    var b: Double
    var tx: Double
    var ty: Double

    static let identity = SimilarityTransform(a: 1, b: 0, tx: 0, ty: 0)

    func apply(_ point: CGPoint) -> CGPoint {
        let x = Double(point.x), y = Double(point.y)
        return CGPoint(x: a * x - b * y + tx, y: b * x + a * y + ty)
    }

    var inverse: SimilarityTransform? {
        let scale = a * a + b * b
        guard scale > 1e-12 else { return nil }
        let ia = a / scale, ib = -b / scale
        return SimilarityTransform(a: ia, b: ib, tx: -(ia * tx - ib * ty), ty: -(ib * tx + ia * ty))
    }

    /// The least-squares similarity taking `source` onto `target` (Umeyama,
    /// without reflection). Nil for fewer than two points or degenerate input.
    static func estimate(from source: [CGPoint], to target: [CGPoint]) -> SimilarityTransform? {
        let count = min(source.count, target.count)
        guard count >= 2 else { return nil }
        var sx = 0.0, sy = 0.0, dx = 0.0, dy = 0.0
        for index in 0..<count {
            sx += Double(source[index].x); sy += Double(source[index].y)
            dx += Double(target[index].x); dy += Double(target[index].y)
        }
        let n = Double(count)
        sx /= n; sy /= n; dx /= n; dy /= n
        var dot = 0.0, cross = 0.0, norm = 0.0
        for index in 0..<count {
            let px = Double(source[index].x) - sx, py = Double(source[index].y) - sy
            let qx = Double(target[index].x) - dx, qy = Double(target[index].y) - dy
            dot += px * qx + py * qy
            cross += px * qy - py * qx
            norm += px * px + py * py
        }
        guard norm > 1e-12 else { return nil }
        let a = dot / norm, b = cross / norm
        return SimilarityTransform(a: a, b: b, tx: dx - (a * sx - b * sy), ty: dy - (b * sx + a * sy))
    }
}

// MARK: - Geometry

enum MouthCropGeometry {
    /// The mean face's eyes, nose base and mouth centre in its 256×256 square
    /// (Auto-AVSR's `20words_mean_face.npy`, averaged as `get_stable_reference` does).
    static let reference: [CGPoint] = [
        CGPoint(x: 102.0739, y: 94.2723),
        CGPoint(x: 156.3613, y: 93.5782),
        CGPoint(x: 129.0037, y: 135.9034),
        CGPoint(x: 129.3134, y: 157.8230),
    ]

    /// The patch the tracker keeps per frame, in mean-face pixels.
    static let patchSize = 128
    /// The crop the model reads.
    static let cropSize = 88
    /// The square cut around the mouth before its centre is kept.
    static let cutSize = 96

    /// The patch's top-left corner in mean-face space: centred on the mean
    /// face's mouth.
    static var patchOrigin: CGPoint {
        CGPoint(x: (reference[3].x - CGFloat(patchSize) / 2).rounded(), y: (reference[3].y - CGFloat(patchSize) / 2).rounded())
    }

    /// Bilinear sample of an 8-bit image at (x, y); zero outside, as
    /// OpenCV's constant border is.
    @inline(__always)
    static func sample(_ pixels: UnsafeBufferPointer<UInt8>, width: Int, height: Int, rowBytes: Int, x: Double, y: Double) -> UInt8 {
        guard x > -1, y > -1, x < Double(width), y < Double(height) else { return 0 }
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let fx = x - Double(x0), fy = y - Double(y0)
        @inline(__always) func pixel(_ px: Int, _ py: Int) -> Double {
            guard px >= 0, py >= 0, px < width, py < height else { return 0 }
            return Double(pixels[py * rowBytes + px])
        }
        let top = pixel(x0, y0) * (1 - fx) + pixel(x0 + 1, y0) * fx
        let bottom = pixel(x0, y0 + 1) * (1 - fx) + pixel(x0 + 1, y0 + 1) * fx
        return UInt8(max(0, min(255, (top * (1 - fy) + bottom * fy).rounded())))
    }

    /// The 128×128 mean-face patch around the mouth, cut from a grayscale
    /// image with `toReference` (image pixels → mean-face pixels).
    static func patch(
        from pixels: UnsafeBufferPointer<UInt8>, width: Int, height: Int, rowBytes: Int,
        toReference: SimilarityTransform
    ) -> [UInt8]? {
        guard let fromReference = toReference.inverse else { return nil }
        let origin = patchOrigin
        var output = [UInt8](repeating: 0, count: patchSize * patchSize)
        for row in 0..<patchSize {
            for column in 0..<patchSize {
                let source = fromReference.apply(CGPoint(x: Double(origin.x) + Double(column), y: Double(origin.y) + Double(row)))
                output[row * patchSize + column] = sample(
                    pixels, width: width, height: height, rowBytes: rowBytes, x: Double(source.x), y: Double(source.y)
                )
            }
        }
        return output
    }
}

// MARK: - Samples

/// What the tracker keeps for one frame: the face points, the transform it
/// cut with, and the patch.
struct MouthPatch: Equatable, Sendable {
    var keypoints: MouthKeypoints
    /// Image pixels → mean-face pixels, from this frame's own points.
    var transform: SimilarityTransform
    /// `MouthCropGeometry.patchSize`² grayscale pixels.
    var pixels: [UInt8]
}

/// One crop for the model.
struct MouthCrop: Equatable, Sendable {
    var time: TimeInterval
    /// `MouthCropGeometry.cropSize`² grayscale pixels.
    var pixels: [UInt8]
}

// MARK: - Builder

/// Turns patches into crops with the training data's ±6-frame smoothing:
/// each crop waits for the six frames after it.
struct MouthCropBuilder {
    static let halfWindow = 6

    private var pending: [(time: TimeInterval, patch: MouthPatch)] = []
    /// Index in `pending` of the next frame to finish.
    private var next = 0

    /// Add a frame; returns the crops that are now complete.
    mutating func ingest(time: TimeInterval, patch: MouthPatch) -> [MouthCrop] {
        pending.append((time, patch))
        var done: [MouthCrop] = []
        while next + Self.halfWindow < pending.count {
            if let crop = crop(at: next) { done.append(crop) }
            next += 1
        }
        // Keep only what later frames still need.
        let drop = max(0, next - Self.halfWindow)
        if drop > 0 {
            pending.removeFirst(drop)
            next -= drop
        }
        return done
    }

    /// The crops still waiting, with the window cut short at the end.
    mutating func finish() -> [MouthCrop] {
        var done: [MouthCrop] = []
        while next < pending.count {
            if let crop = crop(at: next) { done.append(crop) }
            next += 1
        }
        pending.removeAll()
        next = 0
        return done
    }

    private func crop(at index: Int) -> MouthCrop? {
        let margin = min(Self.halfWindow, index, pending.count - 1 - index)
        let window = pending[(index - margin)...(index + margin)].map(\.patch.keypoints.points)
        let current = pending[index].patch
        // Average each point over the window, then move the average back
        // onto this frame's own centre, as `crop_patch` does.
        var smoothed = (0..<4).map { point in
            let xs = window.map { Double($0[point].x) }, ys = window.map { Double($0[point].y) }
            return CGPoint(x: xs.reduce(0, +) / Double(xs.count), y: ys.reduce(0, +) / Double(ys.count))
        }
        let currentCentre = LipGeometry.centroid(current.keypoints.points)
        let smoothedCentre = LipGeometry.centroid(smoothed)
        smoothed = smoothed.map { CGPoint(x: $0.x + currentCentre.x - smoothedCentre.x, y: $0.y + currentCentre.y - smoothedCentre.y) }
        guard let toReference = SimilarityTransform.estimate(from: smoothed, to: MouthCropGeometry.reference),
              let fromReference = toReference.inverse else { return nil }
        let pixels = Self.cut(patch: current, smoothedFromReference: fromReference, mouth: toReference.apply(smoothed[3]))
        return MouthCrop(time: pending[index].time, pixels: pixels)
    }

    /// Cut the 96×96 square around `mouth` (mean-face space, smoothed) and
    /// keep its centre 88×88, reading pixels from the frame's patch.
    static func cut(patch: MouthPatch, smoothedFromReference: SimilarityTransform, mouth: CGPoint) -> [UInt8] {
        let size = MouthCropGeometry.cropSize
        let patchSize = MouthCropGeometry.patchSize
        let origin = MouthCropGeometry.patchOrigin
        // `cut_patch` rounds the 96 square's corner; the 88 crop starts 4 in.
        let left = (Double(mouth.x) - Double(MouthCropGeometry.cutSize) / 2).rounded() + 4
        let top = (Double(mouth.y) - Double(MouthCropGeometry.cutSize) / 2).rounded() + 4
        var output = [UInt8](repeating: 0, count: size * size)
        patch.pixels.withUnsafeBufferPointer { pixels in
            for row in 0..<size {
                for column in 0..<size {
                    // Smoothed mean-face point → image → this frame's patch.
                    let image = smoothedFromReference.apply(CGPoint(x: left + Double(column), y: top + Double(row)))
                    let raw = patch.transform.apply(image)
                    output[row * size + column] = MouthCropGeometry.sample(
                        pixels, width: patchSize, height: patchSize, rowBytes: patchSize,
                        x: Double(raw.x - origin.x), y: Double(raw.y - origin.y)
                    )
                }
            }
        }
        return output
    }
}
