// SilentModeController.swift
// VocaMac
//
// Runs the camera for whoever needs it — a Silent Mode recording, the
// Settings preview, teaching a command — and turns it off when the last of
// them is done. Collects the lip frames each of them asked for and keeps
// `live` (what the overlay and Settings draw) up to date.

import Combine
import CoreGraphics
import Foundation
import QuartzCore

/// What the overlay strip and the Settings preview draw. Its own object, so
/// thirty updates a second redraw the strip and nothing else.
@MainActor
final class SilentLiveState: ObservableObject {
    @Published var phase: SilentTrackingPhase = .off
    /// Lip movement against the speaking threshold, 0…1.
    @Published var level: Double = 0
    /// The lips in the latest frame with a face.
    @Published var outline: LipOutline?
    /// Width over height of the camera picture.
    @Published var imageAspect: CGFloat = 4.0 / 3.0
    /// Show the camera picture behind the outline (Settings › Silent Mode).
    @Published var showsVideo = false
    /// A recognised command's chip, shown for a moment before it runs.
    @Published var recognizedCommand: String?
    /// The latest crop the lip reader would read, for the Settings preview.
    @Published var mouthCrop: CGImage?

    /// A layer with the camera picture, while the camera runs.
    var makePreviewLayer: (@MainActor () -> CALayer?)?

    init() {}
}

/// A weak reference the camera's frame handler can carry across queues.
/// Sendable: the reference is only read, and only on the main actor.
private final class WeakController: Sendable {
    nonisolated(unsafe) weak var controller: SilentModeController?

    init(_ controller: SilentModeController) {
        self.controller = controller
    }
}

@MainActor
final class SilentModeController: ObservableObject {

    /// Who has the camera on.
    enum Client: Hashable, Sendable {
        case dictation
        case preview
        case teaching
    }

    let live = SilentLiveState()
    @Published private(set) var cameraPermission: PermissionStatus = .notDetermined
    @Published private(set) var cameras: [CameraDevice] = []

    /// Movement threshold scale, from the Silent Mode page.
    var sensitivity: Double = ArticulationSensitivity.standard {
        didSet { meter.sensitivity = sensitivity }
    }
    /// The camera to use; nil for the built-in one.
    var cameraID: String?
    /// After this long with the lips still (having moved), `onLipsStill` fires
    /// once. Zero turns it off.
    var stillTimeout: TimeInterval = 0
    /// Called when a recording's lips have been still for `stillTimeout`.
    var onLipsStill: (@MainActor () -> Void)?

    private let camera: CameraLipTracking
    private var clients: Set<Client> = []
    private var meter = ArticulationMeter()
    private var dictationFrames: [LipFrame]?
    private var takeFrames: [LipFrame]?
    /// Lip-reading crops for the recording, when it reads lips.
    private var dictationCrops: [MouthCrop]?
    private var cropBuilder = MouthCropBuilder()
    /// The Settings preview shows what the lip reader sees.
    private var previewShowsCrops = false
    private var cropsSinceShown = 0
    /// Bumped on every start and stop, so a start that finishes after a
    /// stop doesn't mark the camera as running.
    private var cameraGeneration = 0
    private var lastSpeaking: TimeInterval?
    private var stillNotified = false

    init(camera: CameraLipTracking) {
        self.camera = camera
        live.makePreviewLayer = { [weak camera] in camera?.makePreviewLayer() }
        let owner = WeakController(self)
        camera.setFrameHandler { frame in
            // Main queue, in order: a frame's motion is measured against the one before.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { owner.controller?.ingest(frame) }
            }
        }
    }

    // MARK: Permission and cameras

    /// Read the camera permission and the attached cameras again.
    func refresh() {
        cameraPermission = camera.authorizationStatus()
        cameras = camera.availableCameras()
    }

    /// Ask for camera access when it hasn't been decided. True when granted.
    @discardableResult
    func requestPermission() async -> Bool {
        let status = camera.authorizationStatus()
        if status == .notDetermined {
            let granted = await camera.requestAccess()
            cameraPermission = granted ? .granted : .denied
            return granted
        }
        cameraPermission = status
        return status == .granted
    }

    // MARK: Clients

    var isCameraRequested: Bool { !clients.isEmpty }

    /// Turn the camera on for `client`, asking for access the first time.
    func begin(_ client: Client) async {
        let wasEmpty = clients.isEmpty
        clients.insert(client)
        guard wasEmpty else { return }
        cameraGeneration += 1
        let generation = cameraGeneration
        meter = ArticulationMeter(sensitivity: sensitivity)
        live.outline = nil
        live.level = 0
        live.phase = .starting
        guard await requestPermission() else {
            guard generation == cameraGeneration else { return }
            live.phase = .unavailable(CameraLipTrackerError.accessDenied.errorDescription ?? "")
            return
        }
        guard generation == cameraGeneration, !clients.isEmpty else { return }
        do {
            try await camera.start(cameraID: cameraID)
            guard generation == cameraGeneration else { return }
            if clients.isEmpty {
                camera.stop()
            } else if live.phase == .starting {
                live.phase = .searching
            }
        } catch {
            guard generation == cameraGeneration else { return }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            VocaLogger.warning(.silentMode, "Camera unavailable: \(message)")
            live.phase = .unavailable(message)
        }
    }

    /// `client` is done with the camera; the last one turns it off.
    func end(_ client: Client) {
        if client == .preview { previewShowsCrops = false }
        syncMouthCapture()
        guard clients.remove(client) != nil, clients.isEmpty else { return }
        cameraGeneration += 1
        camera.stop()
        live.phase = .off
        live.level = 0
        live.outline = nil
        live.mouthCrop = nil
    }

    /// Show the lip reader's crop in the Settings preview.
    func setPreviewShowsCrops(_ shows: Bool) {
        previewShowsCrops = shows
        if !shows { live.mouthCrop = nil }
        syncMouthCapture()
    }

    /// The tracker cuts mouth patches only while someone wants crops.
    private func syncMouthCapture() {
        camera.setCapturesMouth(dictationCrops != nil || previewShowsCrops)
    }

    // MARK: Dictation

    /// Start keeping frames for a recording, and lip-reading crops when
    /// `readsLips`. The camera starts alongside; the recording doesn't wait.
    func beginDictation(readsLips: Bool = false) {
        dictationFrames = []
        dictationCrops = readsLips ? [] : nil
        cropBuilder = MouthCropBuilder()
        syncMouthCapture()
        lastSpeaking = nil
        stillNotified = false
        live.recognizedCommand = nil
        Task {
            // A recording that ended before this ran must not turn the
            // camera on with nobody left to turn it off.
            guard isDictating else { return }
            await begin(.dictation)
        }
    }

    /// The frames kept since `beginDictation`, with the camera off for the recording.
    func finishDictation() -> [LipFrame] {
        finishDictationCapture().frames
    }

    /// The frames and lip-reading crops kept since `beginDictation`, with
    /// the camera off for the recording.
    func finishDictationCapture() -> (frames: [LipFrame], crops: [MouthCrop]) {
        let frames = dictationFrames ?? []
        var crops = dictationCrops ?? []
        if dictationCrops != nil { crops += cropBuilder.finish() }
        dictationFrames = nil
        dictationCrops = nil
        cropBuilder = MouthCropBuilder()
        end(.dictation)
        return (frames, crops)
    }

    var isDictating: Bool { dictationFrames != nil }

    // MARK: Teaching

    func beginTake() {
        takeFrames = []
    }

    func finishTake() -> [LipFrame] {
        let frames = takeFrames ?? []
        takeFrames = nil
        return frames
    }

    var isRecordingTake: Bool { takeFrames != nil }

    // MARK: Frames

    /// One frame from the camera. Internal so tests can feed frames.
    func ingest(_ frame: LipFrame) {
        guard !clients.isEmpty else { return }
        // Frames are kept without their patch: only the crops need it.
        var outline = frame
        outline.mouth = nil
        dictationFrames?.append(outline)
        takeFrames?.append(outline)
        if let patch = frame.mouth, dictationCrops != nil || previewShowsCrops {
            let crops = cropBuilder.ingest(time: frame.time, patch: patch)
            if dictationCrops != nil { dictationCrops?.append(contentsOf: crops) }
            if previewShowsCrops, let latest = crops.last {
                cropsSinceShown += 1
                // A few times a second is enough to check framing.
                if cropsSinceShown >= 3 {
                    cropsSinceShown = 0
                    live.mouthCrop = Self.image(latest)
                }
            }
        }
        meter.ingest(frame)

        let phase: SilentTrackingPhase
        switch meter.reading {
        case .noFace: phase = .searching
        case .still: phase = .tracking
        case .speaking: phase = .speaking
        }
        // Frames arriving means the camera works, whatever was shown before.
        if live.phase != phase { live.phase = phase }
        let level = (meter.level * 50).rounded() / 50
        if live.level != level { live.level = level }
        if let shape = frame.shape, let outline = LipOutline(shape) {
            live.outline = outline
        } else if meter.reading == .noFace {
            live.outline = nil
        }
        if frame.imageSize.height > 0 {
            let aspect = frame.imageSize.width / frame.imageSize.height
            if live.imageAspect != aspect { live.imageAspect = aspect }
        }
        noteStillness(at: frame.time)
    }

    private func noteStillness(at time: TimeInterval) {
        guard isDictating, stillTimeout > 0 else { return }
        if meter.reading == .speaking {
            lastSpeaking = time
            stillNotified = false
            return
        }
        guard let lastSpeaking, !stillNotified, time - lastSpeaking >= stillTimeout else { return }
        stillNotified = true
        onLipsStill?()
    }

    /// A crop as a grayscale image.
    static func image(_ crop: MouthCrop) -> CGImage? {
        let size = MouthCropGeometry.cropSize
        guard crop.pixels.count == size * size,
              let provider = CGDataProvider(data: Data(crop.pixels) as CFData) else { return nil }
        return CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
