// CameraLipTracker.swift
// VocaMac
//
// Silent Mode's camera: AVFoundation frames, Apple Vision face landmarks,
// one `LipFrame` per processed frame. No picture leaves this file except the
// optional on-screen preview layer; what is passed on is the lip contour.
//
// The camera runs only while something asks for it (a Silent Mode
// recording, the Settings preview, teaching a command) and stops the moment
// the last of them is done, so the camera light means exactly that.

import AVFoundation
import CoreMedia
import Foundation
import QuartzCore
import Vision

// MARK: - Protocol

/// A camera choice in Settings.
struct CameraDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

enum CameraLipTrackerError: LocalizedError, Equatable {
    case accessDenied
    case noCamera
    case configurationFailed(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied: return "Camera access is off. Allow it in Settings › Silent Mode."
        case .noCamera: return "No camera is connected."
        case .configurationFailed(let detail): return "The camera couldn't start: \(detail)"
        }
    }
}

/// Camera access for Silent Mode.
protocol CameraLipTracking: AnyObject, Sendable {
    /// Called on the tracker's own queue for every processed frame.
    func setFrameHandler(_ handler: (@Sendable (LipFrame) -> Void)?)
    /// Also cut the mouth patch lip reading needs (`LipFrame.mouth`). Off,
    /// frames carry only the lip outline.
    func setCapturesMouth(_ captures: Bool)
    /// Start the camera (the chosen one, else the built-in one). Returns once
    /// frames are on their way.
    func start(cameraID: String?) async throws
    /// Stop the camera. The light goes off when this finishes on the tracker's queue.
    func stop()
    /// A layer showing the camera picture, while it runs. Main thread only.
    @MainActor func makePreviewLayer() -> CALayer?
    /// Whether VocaMac may use the camera.
    func authorizationStatus() -> PermissionStatus
    /// Ask for camera access; true when granted.
    func requestAccess() async -> Bool
    /// The cameras attached now.
    func availableCameras() -> [CameraDevice]
}

// MARK: - No camera

/// Stands in where there is no camera to use: tests and headless runs.
final class UnavailableLipTracker: CameraLipTracking {
    func setFrameHandler(_ handler: (@Sendable (LipFrame) -> Void)?) {}
    func setCapturesMouth(_ captures: Bool) {}
    func start(cameraID: String?) async throws { throw CameraLipTrackerError.noCamera }
    func stop() {}
    @MainActor func makePreviewLayer() -> CALayer? { nil }
    func authorizationStatus() -> PermissionStatus { .denied }
    func requestAccess() async -> Bool { false }
    func availableCameras() -> [CameraDevice] { [] }
}

// MARK: - Vision tracker

/// `@unchecked Sendable`: the capture session and the current camera are
/// only touched on `sessionQueue`; the Vision request and frame pacing only
/// on `videoQueue`; the frame handler and the session reference read for the
/// preview are guarded by `lock`.
final class VisionLipTracker: NSObject, CameraLipTracking, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    /// Frames processed per second, at most. Lip movement in speech sits
    /// well under 15 Hz; 30 is enough, and Vision costs less at a steady rate.
    static let maximumFrameRate: Double = 30

    private let sessionQueue = DispatchQueue(label: "com.vocamac.silent.session")
    private let videoQueue = DispatchQueue(label: "com.vocamac.silent.video", qos: .userInitiated)
    private let lock = NSLock()

    // Guarded by `lock`.
    private var handler: (@Sendable (LipFrame) -> Void)?
    private var runningSession: AVCaptureSession?
    private var capturesMouth = false

    // `sessionQueue` only.
    private var session: AVCaptureSession?
    private var currentCameraID: String?

    // `videoQueue` only.
    private let processor = LipFrameProcessor()
    private var lastProcessed: TimeInterval = 0

    func setFrameHandler(_ handler: (@Sendable (LipFrame) -> Void)?) {
        lock.withLock { self.handler = handler }
    }

    func setCapturesMouth(_ captures: Bool) {
        lock.withLock { capturesMouth = captures }
    }

    func authorizationStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func availableCameras() -> [CameraDevice] {
        Self.discovery().devices.map { CameraDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    func start(cameraID: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.startOnQueue(cameraID: cameraID)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        sessionQueue.async { self.stopOnQueue() }
    }

    @MainActor func makePreviewLayer() -> CALayer? {
        guard let session = lock.withLock({ runningSession }) else { return nil }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }

    // MARK: Session

    private static func discovery() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        )
    }

    /// The chosen camera while it is attached, else the built-in one, else any.
    private static func device(id: String?) -> AVCaptureDevice? {
        let devices = discovery().devices
        if let id, let chosen = devices.first(where: { $0.uniqueID == id }) { return chosen }
        return devices.first { $0.deviceType == .builtInWideAngleCamera } ?? devices.first
    }

    private func startOnQueue(cameraID: String?) throws {
        if let session, session.isRunning, currentCameraID == cameraID { return }
        stopOnQueue()
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw CameraLipTrackerError.accessDenied
        }
        guard let device = Self.device(id: cameraID) else { throw CameraLipTrackerError.noCamera }

        let session = AVCaptureSession()
        session.beginConfiguration()
        // Small frames: Vision finds a face in a 640×480 frame as well as in
        // a 1080p one, at a fraction of the cost.
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        } else if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            session.commitConfiguration()
            throw CameraLipTrackerError.configurationFailed(error.localizedDescription)
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraLipTrackerError.configurationFailed("the camera is in use")
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        // Full-range luma is the grayscale picture lip reading trained on.
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CameraLipTrackerError.configurationFailed("no video output")
        }
        session.addOutput(output)
        session.commitConfiguration()
        Self.limitFrameRate(of: device)
        session.startRunning()

        self.session = session
        currentCameraID = cameraID
        lock.withLock { runningSession = session }
        VocaLogger.info(.silentMode, "Camera started: \(device.localizedName)")
    }

    private func stopOnQueue() {
        guard let session else { return }
        lock.withLock { runningSession = nil }
        session.stopRunning()
        for output in session.outputs {
            (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
        }
        self.session = nil
        currentCameraID = nil
        VocaLogger.info(.silentMode, "Camera stopped")
    }

    /// Ask for 30 frames a second where the camera allows it. Best effort:
    /// late frames are dropped anyway.
    private static func limitFrameRate(of device: AVCaptureDevice) {
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        guard ranges.contains(where: { $0.minFrameRate <= maximumFrameRate && $0.maxFrameRate >= maximumFrameRate }) else { return }
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(maximumFrameRate))
            device.unlockForConfiguration()
        } catch {
            VocaLogger.debug(.silentMode, "Couldn't set the camera frame rate: \(error.localizedDescription)")
        }
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastProcessed >= 0.9 / Self.maximumFrameRate,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastProcessed = now
        let frame = processor.process(pixelBuffer, time: now, capturesMouth: lock.withLock { capturesMouth })
        lock.withLock { handler }?(frame)
    }
}

// MARK: - Per-frame processing

/// Face landmarks for one picture: the lip outline and, when asked, the
/// mouth patch lip reading needs. The camera and video files (the CLI's
/// `--read-lips`) go through this same code. One queue at a time.
final class LipFrameProcessor {
    private let request: VNDetectFaceLandmarksRequest = {
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        if VNDetectFaceLandmarksRequest.revision(
            VNDetectFaceLandmarksRequestRevision3, supportsConstellation: .constellation76Points
        ) {
            request.constellation = .constellation76Points
        }
        return request
    }()

    func process(_ pixelBuffer: CVPixelBuffer, time: TimeInterval, capturesMouth: Bool) -> LipFrame {
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            VocaLogger.debug(.silentMode, "Face landmarks failed: \(error.localizedDescription)")
        }
        let face = (request.results ?? []).max { $0.boundingBox.width < $1.boundingBox.width }
        let shape = face.flatMap(Self.lipShape)
        var frame = LipFrame(time: time, shape: shape, imageSize: size)
        if capturesMouth, shape?.isUsable == true, let face, let keypoints = Self.keypoints(face, imageSize: size) {
            frame.mouth = Self.mouthPatch(pixelBuffer, keypoints: keypoints)
        }
        return frame
    }

    // MARK: Lip-reading patch

    /// Eyes, nose base and mouth centre in image pixels (top-left origin).
    private static func keypoints(_ face: VNFaceObservation, imageSize: CGSize) -> MouthKeypoints? {
        guard let landmarks = face.landmarks,
              let leftEye = landmarks.leftEye?.normalizedPoints, !leftEye.isEmpty,
              let rightEye = landmarks.rightEye?.normalizedPoints, !rightEye.isEmpty,
              let nose = landmarks.nose?.normalizedPoints, nose.count >= 3,
              let outer = landmarks.outerLips?.normalizedPoints, let inner = landmarks.innerLips?.normalizedPoints else { return nil }
        let box = face.boundingBox
        func image(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: (box.minX + point.x * box.width) * imageSize.width,
                y: (1 - (box.minY + point.y * box.height)) * imageSize.height
            )
        }
        let eyes = [LipGeometry.centroid(leftEye.map(image)), LipGeometry.centroid(rightEye.map(image))]
            .sorted { $0.x < $1.x }
        // The nose base: the three lowest nose points (dlib's 31–35 are the nostrils).
        let noseBase = LipGeometry.centroid(Array(nose.map(image).sorted { $0.y > $1.y }.prefix(3)))
        let mouth = LipGeometry.centroid((outer + inner).map(image))
        return MouthKeypoints(rightEye: eyes[0], leftEye: eyes[1], nose: noseBase, mouth: mouth)
    }

    /// The mean-face patch around the mouth, cut from the frame's luma.
    private static func mouthPatch(_ pixelBuffer: CVPixelBuffer, keypoints: MouthKeypoints) -> MouthPatch? {
        guard let transform = SimilarityTransform.estimate(from: keypoints.points, to: MouthCropGeometry.reference),
              CVPixelBufferGetPlaneCount(pixelBuffer) >= 1 else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let luma = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: rowBytes * height)
        guard let pixels = MouthCropGeometry.patch(
            from: luma, width: width, height: height, rowBytes: rowBytes, toReference: transform
        ) else { return nil }
        return MouthPatch(keypoints: keypoints, transform: transform, pixels: pixels)
    }

    private static func lipShape(_ face: VNFaceObservation) -> LipShape? {
        guard let landmarks = face.landmarks,
              let outer = landmarks.outerLips?.normalizedPoints, outer.count >= 4,
              let inner = landmarks.innerLips?.normalizedPoints, inner.count >= 2 else { return nil }
        return LipShape(
            outer: outer, inner: inner,
            roll: face.roll?.doubleValue ?? 0,
            yaw: face.yaw?.doubleValue ?? 0,
            faceBox: face.boundingBox
        )
    }
}
