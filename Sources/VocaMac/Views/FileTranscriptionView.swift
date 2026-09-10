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
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
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
        VStack(alignment: .leading, spacing: 16) {
            VocaPageHeader(
                title: "Transcribe a File",
                subtitle: "Audio and video stay on this Mac and use your selected speech model.",
                horizontalPadding: 0
            )
            dropZone
            if let result {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Transcript").font(.headline)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(result.text, forType: .string)
                        }
                    }
                    ScrollView {
                        Text(result.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("\(String(format: "%.1f", result.audioLengthSeconds))s audio · \(String(format: "%.1f", result.duration))s processing · \(result.detectedLanguage)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .vocaCard()
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .background(VocaDesign.canvas)
        .tint(VocaDesign.accent)
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.badge.plus").font(.system(size: 32)).foregroundStyle(VocaDesign.accent)
            Text(fileURL?.lastPathComponent ?? "Drop audio or video here")
                .font(.headline).lineLimit(1)
            Text("Up to 500 MB and 30 minutes")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Choose File…", action: chooseFile)
                Button(isRunning ? "Transcribing…" : "Transcribe") { run() }
                    .buttonStyle(.borderedProminent)
                    .disabled(fileURL == nil || isRunning)
                if isRunning { ProgressView().controlSize(.small) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background((isTargeted ? VocaDesign.accent.opacity(0.14) : Color.secondary.opacity(0.08)), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(isTargeted ? VocaDesign.accent : VocaDesign.line))
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
}
