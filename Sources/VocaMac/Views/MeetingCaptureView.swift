// MeetingCaptureView.swift
// VocaMac

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Audio that exists only in this window: a capture in progress, or one
/// that stopped and hasn't been transcribed yet (still running, or failed and
/// waiting for Try Again). Owned by the window manager rather than the view,
/// so closing the window can ask before throwing it away.
@MainActor
final class MeetingCaptureSession: ObservableObject {
    let capture = SystemAudioCapture()
    /// Cleared only once transcription succeeds.
    @Published var capturedSamples: [Float]?
    @Published var isTranscribing = false
    /// The running transcription, so discarding the window can stop the
    /// decode instead of leaving it to hold the speech model unseen.
    var transcriptionTask: Task<Void, Never>?

    /// Throw away everything this window holds: stop capturing and cancel a
    /// transcription still in flight.
    func discard() {
        if capture.isCapturing { _ = capture.stop() }
        transcriptionTask?.cancel()
        transcriptionTask = nil
        capturedSamples = nil
        isTranscribing = false
    }

    enum PendingAudio: Equatable { case capturing, transcribing, notTranscribed }

    var pendingAudio: PendingAudio? {
        if capture.isCapturing { return .capturing }
        guard capturedSamples != nil else { return nil }
        return isTranscribing ? .transcribing : .notTranscribed
    }
}

@MainActor
final class MeetingCaptureWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var session: MeetingCaptureSession?

    func open(appState: AppState) {
        if let window, window.isVisible { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 350),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.contentMinSize = NSSize(width: 500, height: 310)
        window.title = "System Audio Transcription"
        let session = MeetingCaptureSession()
        window.contentView = NSHostingView(
            rootView: MeetingCaptureView(session: session, capture: session.capture).environmentObject(appState)
        )
        window.delegate = self
        window.center(); window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil)
        self.window = window
        self.session = session
        DockVisibilityCoordinator.shared.windowDidOpen(); NSApp.activate(ignoringOtherApps: true)
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.window = nil
                self.session?.discard()
                self.session = nil
                if let closeObserver = self.closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
                self.closeObserver = nil
                DockVisibilityCoordinator.shared.windowDidClose()
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let pending = session?.pendingAudio else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard the system-audio capture?"
        switch pending {
        case .capturing:
            alert.informativeText = "Closing this window stops the capture and throws away the audio recorded so far. Use Stop and Transcribe to keep it."
            alert.addButton(withTitle: "Keep Capturing")
        case .transcribing:
            alert.informativeText = "The capture is still being transcribed. Closing this window throws away the audio and its transcript."
            alert.addButton(withTitle: "Keep Window Open")
        case .notTranscribed:
            alert.informativeText = "This capture hasn't been transcribed. Closing this window throws the audio away; use Try Again to transcribe it."
            alert.addButton(withTitle: "Keep Window Open")
        }
        alert.addButton(withTitle: "Discard and Close")
        return alert.runModal() == .alertSecondButtonReturn
    }
}

struct MeetingCaptureView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var session: MeetingCaptureSession
    @ObservedObject var capture: SystemAudioCapture
    @State private var result: VocaTranscription?
    @State private var error: String?
    @State private var notice: String?
    @State private var startedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TranscriptionWorkflowHeader(
                title: "System Audio",
                subtitle: "Capture what this Mac is playing, then transcribe it locally.",
                systemImage: "speaker.wave.2"
            )
            HStack(spacing: 12) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.subheadline.weight(.medium))
                    if capture.isCapturing, let startedAt {
                        TimelineView(.periodic(from: startedAt, by: 1)) { context in
                            Text(elapsedDescription(since: startedAt, now: context.date))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(statusDetail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(capture.isCapturing ? "Stop and Transcribe" : "Start Capture") {
                    capture.isCapturing ? stop() : start()
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.isTranscribing || appState.isRecording)
                if session.isTranscribing { ProgressView().controlSize(.small) }
            }
            .vocaCard()
            Label("Private capture · no virtual driver · 20-minute limit", systemImage: "lock.shield")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let result {
                WorkflowTranscriptCard(
                    text: result.text,
                    detail: "\(String(format: "%.1f", result.audioLengthSeconds))s audio · \(String(format: "%.1f", result.duration))s processing · \(result.detectedLanguage)",
                    copy: { copy(result.text) },
                    save: { save(result.text) }
                )
            }
            if let error {
                HStack(spacing: 10) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(VocaDesign.warning)
                        .font(.caption)
                    if session.capturedSamples != nil, !session.isTranscribing, !capture.isCapturing {
                        Button("Try Again") { transcribeCapture() }
                            .controlSize(.small)
                    }
                }
            }
            if let notice {
                Label(notice, systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VocaDesign.canvas)
        .tint(VocaDesign.accent)
        .onChange(of: capture.didReachLimit) {
            if capture.didReachLimit, !session.isTranscribing { stop() }
        }
    }

    private func start() {
        error = nil
        notice = nil
        result = nil
        session.capturedSamples = nil
        do {
            try capture.start()
            startedAt = Date()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func elapsedDescription(since start: Date, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(start)))
        let limit = SystemAudioAccumulator.maximumDurationSeconds
        return String(format: "%d:%02d of %d:00 · playback continues normally", elapsed / 60, elapsed % 60, limit / 60)
    }

    private func stop() {
        startedAt = nil
        let samples = capture.stop()
        guard !samples.isEmpty else { error = "No system audio was captured."; return }
        guard !SystemAudioAccumulator.isSilent(samples) else {
            error = "Only silence was captured. Play audio while capturing, and allow VocaMac under System Settings → Privacy & Security → Screen & System Audio Recording."
            return
        }
        if capture.didReachLimit {
            notice = "The 20-minute limit was reached; the retained audio is being transcribed."
        }
        session.capturedSamples = samples
        transcribeCapture()
    }

    private func transcribeCapture() {
        guard let samples = session.capturedSamples else { return }
        error = nil
        session.isTranscribing = true
        session.transcriptionTask = Task { @MainActor in
            do {
                result = try await appState.transcribeCapturedAudio(samples)
                session.capturedSamples = nil
            } catch {
                // A cancelled task belongs to a window the user closed.
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            session.isTranscribing = false
            session.transcriptionTask = nil
        }
    }

    private var statusTitle: String {
        if capture.isCapturing { return "Capturing system audio" }
        if session.isTranscribing { return "Transcribing capture" }
        if session.capturedSamples != nil { return "Capture not transcribed yet" }
        return "Ready to capture"
    }

    private var statusDetail: String {
        if capture.isCapturing { return "Playback continues normally" }
        if session.isTranscribing { return "Processing locally with the selected speech model" }
        return "Uses the currently selected speech model"
    }

    private var statusColor: Color {
        if capture.isCapturing { return .red }
        if session.isTranscribing { return VocaDesign.accent }
        return VocaDesign.success
    }

    private func save(_ text: String) {
        let panel = NSSavePanel()
        panel.title = "Save Transcript"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "System Audio Transcript.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = "Could not save the transcript: \(error.localizedDescription)" }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
