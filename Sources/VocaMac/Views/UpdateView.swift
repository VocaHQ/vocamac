// UpdateView.swift
// VocaMac
//
// Update banner and detail sheet for GitHub release updates.

import SwiftUI

struct UpdateBannerView: View {
    let info: UpdateInfo
    @ObservedObject var updateWindowManager: UpdateWindowManager
    @EnvironmentObject var appState: AppState

    var body: some View {
        Button {
            updateWindowManager.open(appState: appState, info: info)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(VocaDesign.accent)
                Text("Update \(info.tagName) available")
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(VocaDesign.accent.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
    }
}

struct UpdateDetailView: View {
    let info: UpdateInfo
    // Closes via the presenting binding rather than @Environment(\.dismiss):
    // inside a MenuBarExtra window, dismiss closes the whole status bar panel.
    @Binding var isPresented: Bool
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("VocaMac \(info.tagName) Available")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(info.dmgSize), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Later (24h)") {
                    appState.updateChecker.dismiss()
                    isPresented = false
                }
                .buttonStyle(.bordered)
                .help("Hide this update for 24 hours")

                Button("Close") {
                    isPresented = false
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .help("Close without snoozing")
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                Text(info.releaseNotes.isEmpty ? "No release notes provided." : info.releaseNotes)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .frame(maxHeight: 280)

            Divider()

            actionArea
                .padding(20)
        }
        .frame(width: 520)
        .background(VocaDesign.canvas)
        .tint(VocaDesign.accent)
    }

    @ViewBuilder
    private var actionArea: some View {
        switch appState.updateChecker.updateState {
        case .updateAvailable:
            HStack {
                Button("Skip This Version") {
                    appState.updateChecker.skipVersion(info.version)
                    isPresented = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Download & Install") {
                    Task { @MainActor in
                        await appState.updateChecker.downloadUpdate(info)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        case .updateAvailableViaHomebrew(_, let install):
            VStack(alignment: .leading, spacing: 10) {
                Text("Updates are managed by Homebrew.")
                    .foregroundStyle(.secondary)
                HStack {
                    Text(install.upgradeCommand)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy Command") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(install.upgradeCommand, forType: .string)
                    }
                    .buttonStyle(.bordered)
                }
            }
        case .downloading(let progress, let bytesDownloaded, let totalBytes, let eta):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Downloading update...")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(VocaDesign.accent)
                HStack {
                    Text("\(ByteCountFormatter.string(fromByteCount: bytesDownloaded, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if eta > 0 && eta < 3600 {
                        Text(formatETA(eta))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        case .verifying:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Verifying download integrity...")
                        .foregroundStyle(.secondary)
                }
            }
        case .readyToInstall(let dmgPath):
            VStack(alignment: .leading, spacing: 10) {
                Label("Download complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(VocaDesign.success)
                Text("Open the DMG and drag VocaMac to Applications to replace the existing app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open DMG") {
                    appState.updateChecker.openDMG(at: dmgPath)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
        case .error(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                HStack {
                    Button("View Release") {
                        NSWorkspace.shared.open(info.releasePageURL)
                    }
                    .buttonStyle(.bordered)

                    Button("Retry") {
                        Task { @MainActor in
                            await appState.updateChecker.downloadUpdate(info)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        default:
            EmptyView()
        }
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
