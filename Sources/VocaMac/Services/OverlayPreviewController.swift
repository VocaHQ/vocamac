// OverlayPreviewController.swift
// VocaMac
//
// Plays the recording overlay for a couple of seconds from Settings, so the
// style and position can be judged without starting a dictation.

import Foundation

/// Shows the overlay with a fake waveform and sample words, then hides it.
///
/// A preview never outlives a real dictation: it stops as soon as the app is
/// no longer idle, and leaves the overlay to whoever took over.
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
                // Something else started using the overlay: leave it alone.
                guard isIdle() else {
                    task = nil
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

    /// Cancel a running preview and hide the overlay.
    func stop() {
        guard let running = task else { return }
        running.cancel()
        task = nil
        if isIdle() { overlay.hide() }
    }
}
