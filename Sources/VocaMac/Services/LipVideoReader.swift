// LipVideoReader.swift
// VocaMac
//
// Lip reading from a video file instead of the camera: each frame goes
// through the camera's own per-frame processing (`LipFrameProcessor`) and
// the same crop builder, so a recorded clip shows what Silent Mode would
// read live. Used by the CLI's --read-lips and to check accuracy offline.

import AVFoundation
import CoreMedia
import Foundation

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
        let processor = LipFrameProcessor()
        var frames: [LipFrame] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
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

    /// The whole video read as one stretch (split past 30 seconds).
    static func read(_ url: URL, with reader: any LipReading) async throws -> String {
        let crops = crops(from: try await frames(of: url))
        // Loaded first, so the windows use the lengths this model accepts.
        await reader.prepare()
        guard let first = crops.first?.time, let last = crops.last?.time, first < last else { return "" }
        var texts: [String] = []
        for chunk in LipReadingWindow.chunks([first...last]) {
            let times = LipReadingWindow.frameTimes(for: chunk, available: first...last) { reader.modelLength(for: $0) }
            let window = LipReadingWindow.crops(at: times, from: crops)
            let text = try await reader.read(window)
            if !text.isEmpty { texts.append(text) }
        }
        return texts.joined(separator: " ")
    }
}
