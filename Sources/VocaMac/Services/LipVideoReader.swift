// LipVideoReader.swift
// VocaMac
//
// Lip reading from a video file instead of the camera: each frame goes
// through the camera's own per-frame processing (`LipFrameProcessor`) and
// the same crop builder, so a recorded clip shows what Silent Mode would
// read live. Used by the CLI's --read-lips and to check accuracy offline.

import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import ImageIO

enum LipVideoReaderError: LocalizedError {
    case noVideoTrack
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The file has no video."
        case .unreadable(let detail): return "The video couldn't be read: \(detail)"
        }
    }
}

enum LipVideoReader {
    /// Every frame of the video's first track, with lip outline and mouth patch.
    static func frames(of url: URL) async throws -> [LipFrame] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw LipVideoReaderError.noVideoTrack
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw LipVideoReaderError.unreadable("no readable video output") }
        reader.add(output)
        guard reader.startReading() else {
            throw LipVideoReaderError.unreadable(reader.error?.localizedDescription ?? "reading didn't start")
        }
        // Phones store portrait video sideways with a rotation to apply;
        // Vision and the crop need the picture upright.
        let orientation = Self.orientation(of: try await track.load(.preferredTransform))
        let rotator = orientation == .up ? nil : UprightFrames(orientation: orientation)
        let processor = LipFrameProcessor()
        var frames: [LipFrame] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let stored = CMSampleBufferGetImageBuffer(sample) else { continue }
            guard let pixelBuffer = rotator.map({ $0.upright(stored) }) ?? stored else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            frames.append(processor.process(pixelBuffer, time: time, capturesMouth: true))
        }
        if reader.status == .failed {
            throw LipVideoReaderError.unreadable(reader.error?.localizedDescription ?? "decoding failed")
        }
        return frames
    }

    /// The lip-reading crops for `frames`, in time order.
    static func crops(from frames: [LipFrame]) -> [MouthCrop] {
        var builder = MouthCropBuilder()
        var crops: [MouthCrop] = []
        for frame in frames {
            guard let patch = frame.mouth else { continue }
            crops += builder.ingest(time: frame.time, patch: patch)
        }
        return crops + builder.finish()
    }

    /// The whole video read as one stretch (split when long).
    static func read(_ url: URL, with reader: any LipReading) async throws -> String {
        try await read(crops(from: try await frames(of: url)), with: reader)
    }

    /// `crops` read as one stretch (split when long).
    static func read(_ crops: [MouthCrop], with reader: any LipReading) async throws -> String {
        // Loaded first, so the windows use the lengths this model accepts.
        await reader.prepare()
        guard let first = crops.first?.time, let last = crops.last?.time, first < last else { return "" }
        var pieces: [SilentTextPiece] = []
        for chunk in LipReadingWindow.chunks([first...last]) {
            pieces += try await LipReadingWindow.read(chunk, available: first...last, from: crops, with: reader)
        }
        return SilentTextPiece.joined(pieces)
    }

    /// The rotation a track's transform asks for, as an image orientation.
    /// Only right-angle turns are recognised; anything else reads as upright.
    static func orientation(of transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a.rounded(), transform.b.rounded(), transform.c.rounded(), transform.d.rounded()) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        default: return .up
        }
    }
}

/// Turns stored video frames upright, into full-range 4:2:0 buffers like
/// the camera's.
private final class UprightFrames {
    private let orientation: CGImagePropertyOrientation
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    init(orientation: CGImagePropertyOrientation) {
        self.orientation = orientation
    }

    func upright(_ stored: CVPixelBuffer) -> CVPixelBuffer? {
        var image = CIImage(cvPixelBuffer: stored).oriented(orientation)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, Int(image.extent.width), Int(image.extent.height),
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes as CFDictionary, &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }
        context.render(image, to: buffer)
        return buffer
    }
}
