// FileTranscriptionView.swift
// VocaMac

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class FileTranscriptionWindowManager: ObservableObject {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func open(appState: AppState, initialURL: URL? = nil) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = FileTranscriptionView(initialURL: initialURL).environmentObject(appState)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.contentMinSize = NSSize(width: 500, height: 320)
        window.title = "Transcribe a File"
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        self.window = window
        DockVisibilityCoordinator.shared.windowDidOpen()
        NSApp.activate(ignoringOtherApps: true)
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
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

struct FileTranscriptionView: View {
    @EnvironmentObject var appState: AppState
    let initialURL: URL?
    @State private var fileURL: URL?
    @State private var result: VocaTranscription?
    @State private var error: String?
    @State private var isRunning = false
    @State private var isTargeted = false

    init(initialURL: URL? = nil) {
        self.initialURL = initialURL
        _fileURL = State(initialValue: initialURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TranscriptionWorkflowHeader(
                title: "Transcribe a File",
                subtitle: "Audio and video stay on this Mac and use your selected speech model.",
                systemImage: "waveform.badge.plus"
            )
            dropZone
            if let result {
                WorkflowTranscriptCard(
                    text: result.text,
                    detail: "\(String(format: "%.1f", result.audioLengthSeconds))s audio · \(String(format: "%.1f", result.duration))s processing · \(result.detectedLanguage)",
                    copy: { copy(result.text) }
                )
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VocaDesign.canvas)
        .tint(VocaDesign.accent)
    }

    private var dropZone: some View {
        HStack(spacing: 12) {
            Image(systemName: fileURL == nil ? "arrow.down.doc" : "waveform")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(fileURL == nil ? .secondary : VocaDesign.accent)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(fileURL?.lastPathComponent ?? "Drop audio or video here")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Up to 500 MB · 30 minutes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Choose…", action: chooseFile)
                .controlSize(.small)
            Button(isRunning ? "Transcribing…" : "Transcribe") { run() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(fileURL == nil || isRunning)
            if isRunning { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background((isTargeted ? VocaDesign.accent.opacity(0.14) : Color.primary.opacity(0.04)), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isTargeted ? VocaDesign.accent : VocaDesign.line))
        .onDrop(of: [UTType.fileURL.identifier, UTType.audio.identifier, UTType.movie.identifier], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else { url = item as? URL }
                if let url { Task { @MainActor in select(url) } }
            }
            return true
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose Audio or Video"
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        select(url)
    }

    private func select(_ url: URL) {
        fileURL = url
        result = nil
        error = nil
    }

    private func run() {
        guard let fileURL else { return }
        isRunning = true
        result = nil
        error = nil
        Task { @MainActor in
            do { result = try await appState.transcribeFile(at: fileURL) }
            catch { self.error = error.localizedDescription }
            isRunning = false
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
