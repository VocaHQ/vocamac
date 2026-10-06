// UpdateView.swift
// VocaMac
//
// Update banner and detail sheet for GitHub release updates.

import SwiftUI

/// The menu's note that a new version is waiting: a line in the serif, and
/// one click to see what's new.
struct UpdateBannerView: View {
    let info: UpdateInfo
    @ObservedObject var updateWindowManager: UpdateWindowManager
    @EnvironmentObject var appState: AppState

    var body: some View {
        Button {
            updateWindowManager.open(appState: appState, info: info)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(VocaDesign.accent)
                    .frame(width: 28, height: 28)
                    .background(VocaDesign.accent.opacity(0.13), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("VocaMac \(info.tagName) is ready")
                        .font(VocaDesign.display(16))
                        .foregroundStyle(.primary)
                    Text("See what's new")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("VocaMac \(info.tagName) is ready. See what's new.")
    }
}

/// The update window: the new version on a dawn scene, what changed as
/// readable notes, and the one action to take.
struct UpdateDetailView: View {
    let info: UpdateInfo
    // Closes via the presenting binding rather than @Environment(\.dismiss):
    // inside a MenuBarExtra window, dismiss closes the whole status bar panel.
    @Binding var isPresented: Bool
    @EnvironmentObject var appState: AppState

    @State private var isSceneMoving = true

    private var notes: [ReleaseNotes.Block] { ReleaseNotes.blocks(from: info.releaseNotes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // Notes that open on their own heading don't need ours.
                    if !(notes.first.map(Self.isHeading) ?? false) {
                        Text("WHAT'S NEW")
                            .font(VocaDesign.eyebrow)
                            .tracking(1.4)
                            .foregroundStyle(VocaDesign.accent)
                            .padding(.bottom, 2)
                    }
                    if notes.isEmpty {
                        Text("No release notes were published with this version.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, block in
                        noteView(block)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
            }
            .frame(maxHeight: .infinity)

            Rectangle().fill(VocaDesign.line).frame(height: 1)

            actionArea
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
        }
        .frame(width: 560, height: 580)
        .ignoresSafeArea()
        .vocaPaperBackground()
        .tint(VocaDesign.accentSolid)
        .background {
            // Esc closes without snoozing, as the Close button used to.
            Button("Close") { isPresented = false }
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
        .task {
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            isSceneMoving = false
        }
    }

    private static func isHeading(_ block: ReleaseNotes.Block) -> Bool {
        if case .heading = block { return true }
        return false
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            VocaScene(mood: .dawn, animated: isSceneMoving, framing: .horizon)
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("A NEW VERSION")
                        .font(VocaDesign.eyebrow)
                        .tracking(1.6)
                        .opacity(0.85)
                    Text("VocaMac \(info.tagName)")
                        .font(VocaDesign.display(38))
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(info.dmgSize), countStyle: .file))
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.16), in: Capsule())
            }
            .foregroundStyle(Color(nsColor: VocaPalette.ivory))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 1)
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
            .riseIn(delay: 0.1, distance: 8)
        }
        .frame(height: 176)
        .clipped()
    }

    @ViewBuilder
    private func noteView(_ block: ReleaseNotes.Block) -> some View {
        switch block {
        case .heading(let text):
            Text(ReleaseNotes.attributed(text))
                .font(VocaDesign.display(20))
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(VocaDesign.clay)
                    .frame(width: 5, height: 5)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                Text(ReleaseNotes.attributed(text))
                    .font(.system(size: 13.5))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(VocaDesign.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(VocaDesign.line))
        case .paragraph(let text):
            Text(ReleaseNotes.attributed(text))
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        switch appState.updateChecker.updateState {
        case .updateAvailable:
            HStack(spacing: 14) {
                Button("Skip This Version") {
                    appState.updateChecker.skipVersion(info.version)
                    isPresented = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Later") {
                    appState.updateChecker.dismiss()
                    isPresented = false
                }
                .buttonStyle(VocaOutlineButtonStyle())
                .help("Hide this update for 24 hours")

                Button("Download & Install") {
                    Task { @MainActor in
                        await appState.updateChecker.downloadUpdate(info)
                    }
                }
                .buttonStyle(VocaPrimaryButtonStyle())
            }
        case .updateAvailableViaHomebrew(_, let install):
            VStack(alignment: .leading, spacing: 10) {
                Text("Updates are managed by Homebrew.")
                    .foregroundStyle(.secondary)
                HStack {
                    Text(install.upgradeCommand)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(VocaDesign.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(VocaDesign.line))
                    Spacer()
                    Button("Copy Command") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(install.upgradeCommand, forType: .string)
                    }
                    .buttonStyle(VocaOutlineButtonStyle())
                }
            }
        case .downloading(let progress, let bytesDownloaded, let totalBytes, let eta):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Downloading…")
                        .font(VocaDesign.display(16))
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                VocaProgressBar(value: progress)
                HStack {
                    Text("\(ByteCountFormatter.string(fromByteCount: bytesDownloaded, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if eta > 0 && eta < 3600 {
                        Text(formatETA(eta))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .verifying:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking the download…")
                        .font(VocaDesign.display(16))
                }
            }
        case .readyToInstall(let dmgPath):
            VStack(alignment: .leading, spacing: 10) {
                Label("Ready to install", systemImage: "checkmark.circle.fill")
                    .font(VocaDesign.display(16))
                    .foregroundStyle(VocaDesign.success)
                Text(isBusy
                     ? "Finish the current dictation first. VocaMac quits for a moment to install."
                     : "VocaMac quits, replaces itself, and opens again. Your settings and permissions stay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Install and Relaunch") {
                        Task { @MainActor in
                            await appState.updateChecker.installAndRelaunch(dmgPath: dmgPath)
                        }
                    }
                    .buttonStyle(VocaPrimaryButtonStyle())
                    .disabled(isBusy)
                    Button("Open DMG") {
                        appState.updateChecker.openDMG(at: dmgPath)
                        isPresented = false
                    }
                    .buttonStyle(.vocaLink)
                    .font(.caption)
                }
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Installing…")
                    .font(VocaDesign.display(16))
            }
        case .installFailed(let dmgPath, let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(VocaDesign.warning)
                Text("Open the DMG and drag VocaMac to Applications to install it by hand.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open DMG") {
                    appState.updateChecker.openDMG(at: dmgPath)
                    isPresented = false
                }
                .buttonStyle(VocaPrimaryButtonStyle())
            }
        case .error(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(VocaDesign.warning)

                HStack {
                    Button("View Release") {
                        NSWorkspace.shared.open(info.releasePageURL)
                    }
                    .buttonStyle(VocaOutlineButtonStyle())

                    Button("Retry") {
                        Task { @MainActor in
                            await appState.updateChecker.downloadUpdate(info)
                        }
                    }
                    .buttonStyle(VocaPrimaryButtonStyle())
                }
            }
        default:
            EmptyView()
        }
    }

    /// Quitting mid-dictation would lose it.
    private var isBusy: Bool {
        appState.isRecording || appState.appStatus == .processing
    }

    private func formatETA(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins > 0 {
            return "\(mins)m \(secs)s remaining"
        }
        return "\(secs)s remaining"
    }
}

/// A thin petrol bar on a paper track.
struct VocaProgressBar: View {
    let value: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(VocaDesign.accent)
                    .frame(width: max(6, geometry.size.width * min(max(value, 0), 1)))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: value)
            }
        }
        .frame(height: 5)
        .accessibilityElement()
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}
