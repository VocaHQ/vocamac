// CalmAboutDialogs.swift
// VocaMac
//
// Settings › About › Update available: the new version, what changed, and
// the step the update is on (download, check, install), in the Dialogs
// board's style. Replaces the old update sheet inside the window; the
// menu bar's update window is unchanged.

import AppKit
import SwiftUI

/// “VocaMac 1.1 is available”: release notes in a panel, then the action
/// for where the update is (download, progress, install, or a problem).
struct CalmUpdateDialog: View {
    let info: UpdateInfo

    @EnvironmentObject private var appState: AppState
    @Environment(\.calmDismissDialog) private var dismissDialog

    private var state: UpdateState { appState.updateChecker.updateState }

    var body: some View {
        CalmDialog(
            "\(CalmAdvancedSummary.displayVersion(info)) is available",
            description: "You have \(CalmSettingsMenu.appVersion).",
            width: 460
        ) {
            notes
            progress
        } footer: {
            footer
        }
    }

    // MARK: Content

    private var notes: some View {
        let lines = CalmAdvancedSummary.releaseNoteLines(info.releaseNotes)
        return ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                if lines.isEmpty {
                    Text("No release notes were published with this version.")
                } else {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(ReleaseNotes.attributed(line)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(CalmFont.description)
            .lineSpacing(3)
            .foregroundStyle(CalmColor.ink2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
        }
        .frame(maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
        .calmPanelBackground()
    }

    @ViewBuilder
    private var progress: some View {
        switch state {
        case .updateAvailableViaHomebrew(_, let install):
            CalmInlineNotice("Updates come from Homebrew. Run: \(install.upgradeCommand)", tone: .info)
        case .downloading(let value, let done, let total, let eta):
            CalmProgressBar(
                value: value,
                title: "Downloading · \(bytes(done)) of \(bytes(total))",
                detail: eta > 0 && eta < 3600 ? Self.remaining(eta) : "\(Int(value * 100))%"
            )
        case .verifying:
            busyLine("Checking the download…")
        case .installing:
            busyLine("Installing…")
        case .readyToInstall:
            CalmInlineNotice(
                isBusy
                    ? "Finish the current dictation first. VocaMac quits for a moment to install."
                    : "Ready. VocaMac quits, replaces itself and opens again. Your settings and permissions stay.",
                tone: isBusy ? .warning : .success
            )
        case .installFailed(_, let message):
            CalmInlineNotice("\(message) Open the DMG and drag VocaMac to Applications to install it by hand.")
        case .error(let message):
            CalmInlineNotice(message)
        default:
            EmptyView()
        }
    }

    private func busyLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            CalmSpinner(size: 16)
            Text(text).font(CalmFont.note).foregroundStyle(CalmColor.ink)
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        switch state {
        case .updateAvailable:
            CalmDialogFooter(
                primaryTitle: "Download and install", cancelTitle: "Later",
                onCancel: later, dismissesOnPrimary: false, onPrimary: download
            ) {
                Button("Skip this version", action: skip).calmButton(.quiet)
            }
        case .updateAvailableViaHomebrew(_, let install):
            CalmDialogFooter(primaryTitle: "Copy command", cancelTitle: "Close", dismissesOnPrimary: false) {
                copy(install.upgradeCommand)
            }
        case .readyToInstall(let dmgPath):
            CalmDialogFooter(
                primaryTitle: "Install and relaunch", isPrimaryEnabled: !isBusy, cancelTitle: "Later",
                dismissesOnPrimary: false, onPrimary: { install(dmgPath) },
                leading: { Button("Open DMG") { openDMG(dmgPath) }.calmButton(.quiet) }
            )
        case .installFailed(let dmgPath, _):
            CalmDialogFooter(primaryTitle: "Open DMG", cancelTitle: "Close") { openDMG(dmgPath) }
        case .error:
            CalmDialogFooter(primaryTitle: "Retry", cancelTitle: "Close", dismissesOnPrimary: false, onPrimary: download) {
                Button("View release") { NSWorkspace.shared.open(info.releasePageURL) }.calmButton(.quiet)
            }
        default:
            // Downloading, checking, installing: it carries on with the dialog closed.
            CalmDialogFooter(primaryTitle: "Close", primaryKind: .secondary, cancelTitle: nil) {}
        }
    }

    // MARK: Actions

    private func download() {
        Task { @MainActor in await appState.updateChecker.downloadUpdate(info) }
    }

    private func install(_ dmgPath: URL) {
        Task { @MainActor in await appState.updateChecker.installAndRelaunch(dmgPath: dmgPath) }
    }

    /// Hides this update for 24 hours.
    private func later() {
        appState.updateChecker.dismiss()
        dismissDialog?()
    }

    private func skip() {
        appState.updateChecker.skipVersion(info.version)
        dismissDialog?()
    }

    private func openDMG(_ path: URL) {
        appState.updateChecker.openDMG(at: path)
        dismissDialog?()
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Quitting mid-dictation would lose it.
    private var isBusy: Bool {
        appState.isRecording || appState.appStatus == .processing
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// “2m 10s left”, “40s left”.
    static func remaining(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let rest = Int(seconds) % 60
        return minutes > 0 ? "\(minutes)m \(rest)s left" : "\(rest)s left"
    }
}
