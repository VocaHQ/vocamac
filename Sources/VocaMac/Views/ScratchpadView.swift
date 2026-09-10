// ScratchpadView.swift
// VocaMac

import AppKit
import SwiftUI

@MainActor
final class ScratchpadWindowManager: ObservableObject {
    private var panel: NSPanel?
    private var closeObserver: NSObjectProtocol?

    func open(appState: AppState) {
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = "VocaMac Scratchpad"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ScratchpadView().environmentObject(appState))
        panel.center()
        panel.isReleasedWhenClosed = false
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        DockVisibilityCoordinator.shared.windowDidOpen()
        NSApp.activate(ignoringOtherApps: true)
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel = nil
                if let closeObserver = self.closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
                self.closeObserver = nil
                DockVisibilityCoordinator.shared.windowDidClose()
            }
        }
    }
}

struct ScratchpadView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scratchpad").font(.title2.bold())
                    Text("Dictate here when no text field is ready.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(appState.scratchpadText, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                .disabled(appState.scratchpadText.isEmpty)
                Button("Clear", role: .destructive) { appState.scratchpadText = "" }
                    .disabled(appState.scratchpadText.isEmpty)
            }
            TextEditor(text: $appState.scratchpadText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(VocaDesign.canvas, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(VocaDesign.line))
            HStack {
                Button {
                    Task { await appState.toggleScratchpadRecording() }
                } label: {
                    Label(
                        appState.isRecording ? "Stop and Add" : "Dictate into Scratchpad",
                        systemImage: appState.isRecording ? "stop.fill" : "mic.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.appStatus == .processing)
                if appState.isRecording {
                    ObservedAudioLevelView(meter: appState.audioMeter, tint: VocaDesign.accent)
                        .frame(width: 120, height: 6)
                }
                Spacer()
                Text("Saved automatically on this Mac")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(VocaDesign.canvas)
        .tint(VocaDesign.accent)
    }
}
