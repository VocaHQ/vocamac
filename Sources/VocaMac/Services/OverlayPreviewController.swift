// OverlayPreviewController.swift
// VocaMac
//
// Plays the recording overlay for a couple of seconds from Settings, so the
// style and position can be judged without starting a dictation.

import Foundation

/// Shows the overlay with a fake waveform and sample words, then hides it.
///
/// A preview never outlives the idle state: `AppState` ends it before a
/// dictation starts, and it hides itself if the app becomes busy any other
/// way. Either way the fake "listening" overlay is gone before the speech
/// model loads or a recording begins.
@MainActor
final class OverlayPreviewController {
    static let sampleTranscript = "This is how your words will appear."

    private let overlay: CursorOverlayManaging
    private let isIdle: () -> Bool
    private let duration: Duration
    private let tick: Duration
    private var task: Task<Void, Never>?

    init(
        overlay: CursorOverlayManaging,
        isIdle: @escaping () -> Bool,
        duration: Duration = .seconds(3),
        tick: Duration = .milliseconds(60)
    ) {
        self.overlay = overlay
        self.isIdle = isIdle
        self.duration = duration
        self.tick = tick
    }

    /// Whether a preview is on screen.
    var isRunning: Bool { task != nil }

    /// Start a preview, replacing one already running. Does nothing while a
    /// dictation is in progress or when the overlay is switched off.
    func start(style: OverlayStyle, position: OverlayPosition) {
        stop()
        guard style != .off, isIdle() else { return }

        overlay.recordingLimit = nil
        overlay.show(style: style, position: position)
        overlay.transitionToRecording()
        overlay.setLiveWordsAvailable(style == .live)
        if style == .live { overlay.updateTranscript(Self.sampleTranscript) }

        task = Task { [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            let start = clock.now
            var step = 0.0
            while clock.now - start < duration {
                guard !Task.isCancelled else { return }
                // The app got busy without going through `stop()`. A real
                // dictation always calls `stop()` first, so nothing else owns
                // the overlay yet and the fake one must not linger.
                guard isIdle() else {
                    task = nil
                    overlay.hide()
                    return
                }
                step += 1
                overlay.updateAudioLevel(Float(0.35 + 0.3 * sin(step / 3)))
                try? await Task.sleep(for: tick)
            }
            guard !Task.isCancelled else { return }
            task = nil
            overlay.hide()
        }
    }

    /// Cancel a running preview and hide the overlay. Does nothing when no
    /// preview is running, so it never touches an overlay it does not own.
    func stop() {
        guard let running = task else { return }
        running.cancel()
        task = nil
        overlay.hide()
    }
}
