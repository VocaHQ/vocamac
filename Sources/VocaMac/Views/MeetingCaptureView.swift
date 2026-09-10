// MeetingCaptureView.swift
// VocaMac

import AppKit
import SwiftUI

@MainActor
final class MeetingCaptureWindowManager: ObservableObject {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    func open(appState: AppState) {
        if let window, window.isVisible { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "System Audio Transcription"
        window.contentView = NSHostingView(rootView: MeetingCaptureView().environmentObject(appState))
        window.center(); window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil)
        self.window = window
        DockVisibilityCoordinator.shared.windowDidOpen(); NSApp.activate(ignoringOtherApps: true)
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.window = nil
                if let closeObserver = self.closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
                self.closeObserver = nil
                DockVisibilityCoordinator.shared.windowDidClose()
            }
        }
    }
}

struct MeetingCaptureView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var capture = SystemAudioCapture()
    @State private var result: VocaTranscription?
    @State private var error: String?
    @State private var isTranscribing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VocaPageHeader(title: "System Audio", subtitle: "Capture what this Mac is playing, then transcribe it locally.", horizontalPadding: 0)
            HStack(spacing: 12) {
                Circle().fill(capture.isCapturing ? Color.red : Color.secondary).frame(width: 10, height: 10)
                Text(capture.isCapturing ? "Capturing system audio" : "Ready")
                Spacer()
                Button(capture.isCapturing ? "Stop and Transcribe" : "Start Capture") {
                    capture.isCapturing ? stop() : start()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isTranscribing || appState.isRecording)
                if isTranscribing { ProgressView().controlSize(.small) }
            }
            .vocaCard()
            Text("Playback is not muted. VocaMac uses a private Core Audio process tap and does not install a virtual audio driver. Capture is limited to 20 minutes; stop before changing speech models.")
                .font(.caption).foregroundStyle(.secondary)
            if let result {
                HStack { Text("Transcript").font(.headline); Spacer(); Button("Copy") { copy(result.text) } }
                ScrollView { Text(result.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .vocaCard()
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption) }
            Spacer()
        }
        .padding(24).background(VocaDesign.canvas).tint(VocaDesign.accent)
        .onDisappear { if capture.isCapturing { _ = capture.stop() } }
    }

    private func start() {
        error = nil; result = nil
        do { try capture.start() } catch { self.error = error.localizedDescription }
    }

    private func stop() {
        let samples = capture.stop()
        guard !samples.isEmpty else { error = "No system audio was captured."; return }
        if capture.didReachLimit {
            error = "The 20-minute capture limit was reached. The first 20 minutes will be transcribed."
        }
        isTranscribing = true
        Task { @MainActor in
            do { result = try await appState.transcribeCapturedAudio(samples) }
            catch { self.error = error.localizedDescription }
            isTranscribing = false
        }
    }

    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}
