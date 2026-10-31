// MeetingCaptureView.swift
// VocaMac

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Audio that exists only in this window: a capture in progress, or one
/// that stopped and hasn't reached Notes yet. Owned by the window manager
/// rather than the view, so closing the window can ask before throwing it
/// away.
@MainActor
final class MeetingCaptureSession: ObservableObject {
    /// What a note records.
    enum Input: String, CaseIterable, Identifiable {
        case systemAudio, microphone, both

        var id: String { rawValue }

        var title: String {
            switch self {
            case .systemAudio: return "This Mac's audio"
            case .microphone: return "Microphone"
            case .both: return "Both"
            }
        }

        var noteSource: VoiceNoteSource {
            switch self {
            case .systemAudio: return .systemAudio
            case .microphone: return .microphone
            case .both: return .meeting
            }
        }
    }

    let capture = SystemAudioCapture()
    let microphone = MicrophoneNoteRecorder()
    @Published var input: Input = .both
    /// Cleared once the audio is saved as a note.
    @Published var capturedSamples: [Float]?
    @Published var isTranscribing = false
    /// The note the last capture became.
    @Published var savedNoteID: UUID?
    /// The running save, so discarding the window can stop it.
    var transcriptionTask: Task<Void, Never>?
    private var systemStartedAt: Date?
    /// Which inputs this recording uses. Kept after a recorder stops by
    /// itself (the 20-minute limit), so its audio is still collected.
    private var recordsSystemAudio = false
    private var recordsMicrophone = false

    var isCapturing: Bool { capture.isCapturing || microphone.isRecording }

    /// Start recording what `input` asks for.
    func start() throws {
        savedNoteID = nil
        capturedSamples = nil
        if input != .microphone {
            try capture.start()
            systemStartedAt = Date()
            recordsSystemAudio = true
        }
        if input != .systemAudio {
            do {
                try microphone.start()
                recordsMicrophone = true
            } catch {
                if capture.isCapturing { _ = capture.stop() }
                recordsSystemAudio = false
                throw error
            }
        }
    }

    /// Test support: act as if `input`'s recorders were started, without
    /// opening any audio device.
    func markRecordingForTesting(system: Bool, microphone: Bool) {
        recordsSystemAudio = system
        recordsMicrophone = microphone
    }

    /// Stop, and return one track: the two inputs lined up and mixed.
    func stop() -> [Float] {
        // A recorder that stopped at the limit still holds its audio: ask
        // every input that took part, not only the ones still running.
        let system = recordsSystemAudio ? capture.stop() : []
        let micStarted = microphone.startedAt
        let mic = recordsMicrophone ? microphone.stop() : []
        var offset = 0.0
        if let systemStartedAt, let micStarted { offset = micStarted.timeIntervalSince(systemStartedAt) }
        systemStartedAt = nil
        recordsSystemAudio = false
        recordsMicrophone = false
        return NoteAudioMixer.mix(system, mic, secondStartsAfter: offset)
    }

    var didReachLimit: Bool { capture.didReachLimit || microphone.didReachLimit }

    /// Throw away everything this window holds: stop capturing and cancel a
    /// save still in flight.
    func discard() {
        if isCapturing { _ = stop() }
        transcriptionTask?.cancel()
        transcriptionTask = nil
        capturedSamples = nil
        isTranscribing = false
    }

    enum PendingAudio: Equatable { case capturing, transcribing, notTranscribed }

    var pendingAudio: PendingAudio? {
        if isCapturing { return .capturing }
        guard capturedSamples != nil else { return nil }
        return isTranscribing ? .transcribing : .notTranscribed
    }
}

@MainActor
final class MeetingCaptureWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    /// Shared, so the Notes page and the menu bar open the same window.
    static let shared = MeetingCaptureWindowManager()

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
        window.title = "New Note"
        let session = MeetingCaptureSession()
        window.contentView = NSHostingView(
            rootView: MeetingCaptureView(
                session: session, capture: session.capture, microphone: session.microphone
            ).environmentObject(appState)
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
        alert.messageText = "Discard this recording?"
        switch pending {
        case .capturing:
            alert.informativeText = "Closing this window stops the recording and throws away the audio recorded so far. Use Stop and Save to keep it."
            alert.addButton(withTitle: "Keep Recording")
        case .transcribing:
            alert.informativeText = "The recording is still being saved to Notes. Closing this window now throws it away."
            alert.addButton(withTitle: "Keep Window Open")
        case .notTranscribed:
            alert.informativeText = "This recording hasn't been saved. Closing this window throws the audio away; use Try Again to save it."
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
    @ObservedObject var microphone: MicrophoneNoteRecorder
    @State private var error: String?
    @State private var notice: String?
    @State private var startedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TranscriptionWorkflowHeader(
                title: "New Note",
                subtitle: "Record a meeting, a call or a memo, saved to Notes. "
                    + appState.speechProcessingDescription + ".",
                systemImage: "note.text"
            )
            Picker("Record", selection: $session.input) {
                ForEach(MeetingCaptureSession.Input.allCases) { input in
                    Text(input.title).tag(input)
                }
            }
            .pickerStyle(.segmented)
            .disabled(session.isCapturing || session.isTranscribing)
            HStack(spacing: 12) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.subheadline.weight(.medium))
                    if session.isCapturing, let startedAt {
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
                Button(session.isCapturing ? "Stop and Save" : "Start Recording") {
                    session.isCapturing ? stop() : start()
                }
                .buttonStyle(VocaPrimaryButtonStyle())
                .disabled(session.isTranscribing || appState.isRecording)
                if session.isTranscribing { ProgressView().controlSize(.small) }
            }
            .vocaCard()
            Label(inputHint, systemImage: session.input == .microphone ? "mic" : "speaker.wave.2")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if session.savedNoteID != nil {
                HStack(spacing: 10) {
                    Label("Saved to Notes. The transcript and summary appear there when ready.", systemImage: "checkmark.circle")
                        .font(.caption)
                    Spacer()
                    Button("Open in Notes") { openNotes() }
                        .controlSize(.small)
                }
            }
            if let error {
                HStack(spacing: 10) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(VocaDesign.warning)
                        .font(.caption)
                    if session.capturedSamples != nil, !session.isTranscribing, !session.isCapturing {
                        Button("Try Again") { saveCapture() }
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
        .vocaPaperBackground()
        .buttonStyle(VocaOutlineButtonStyle())
        .tint(VocaDesign.accent)
        .onChange(of: session.didReachLimit) {
            if session.didReachLimit, !session.isTranscribing { stop() }
        }
    }

    private var inputHint: String {
        switch session.input {
        case .systemAudio: return "No virtual driver · 20-minute limit"
        case .microphone: return "Uses the system's default microphone · 20-minute limit"
        case .both: return "Your microphone and this Mac's audio · use headphones so the call isn't heard twice · 20-minute limit"
        }
    }

    private func start() {
        error = nil
        notice = nil
        do {
            try session.start()
            startedAt = Date()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func elapsedDescription(since start: Date, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(start)))
        let limit = SystemAudioAccumulator.maximumDurationSeconds
        return String(format: "%d:%02d of %d:00", elapsed / 60, elapsed % 60, limit / 60)
    }

    private func stop() {
        startedAt = nil
        let samples = session.stop()
        guard !samples.isEmpty else { error = "Nothing was recorded."; return }
        guard !SystemAudioAccumulator.isSilent(samples) else {
            error = session.input == .microphone
                ? "Only silence was recorded. Check the microphone in System Settings → Sound."
                : "Only silence was captured. Play audio while recording, and allow VocaMac under System Settings → Privacy & Security → Screen & System Audio Recording."
            return
        }
        if session.didReachLimit {
            notice = "The 20-minute limit was reached; what was recorded is being saved."
        }
        session.capturedSamples = samples
        saveCapture()
    }

    private func saveCapture() {
        guard let samples = session.capturedSamples else { return }
        error = nil
        session.isTranscribing = true
        let source = session.input.noteSource
        session.transcriptionTask = Task { @MainActor in
            do {
                let id = try await appState.saveNote(samples: samples, source: source)
                guard !Task.isCancelled else { return }
                session.savedNoteID = id
                session.capturedSamples = nil
            } catch {
                guard !Task.isCancelled else { return }
                // The samples stay here, so Try Again can save them.
                self.error = "The recording could not be saved: \(error.localizedDescription)"
            }
            session.isTranscribing = false
            session.transcriptionTask = nil
        }
    }

    private func openNotes() {
        appState.requestSettingsPage(.notes)
        SettingsWindowManager.shared.open(appState: appState)
    }

    private var statusTitle: String {
        if session.isCapturing { return "Recording" }
        if session.isTranscribing { return "Saving the recording" }
        if session.capturedSamples != nil { return "Recording not saved yet" }
        return "Ready to record"
    }

    private var statusDetail: String {
        if session.isTranscribing { return "Writing the audio to Notes" }
        return "Uses the currently selected speech model"
    }

    private var statusColor: Color {
        if session.isCapturing { return VocaDesign.clay }
        if session.isTranscribing { return VocaDesign.accent }
        return VocaDesign.success
    }
}
