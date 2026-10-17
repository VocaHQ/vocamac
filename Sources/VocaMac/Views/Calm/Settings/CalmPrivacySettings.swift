// CalmPrivacySettings.swift
// VocaMac
//
// Settings › Privacy and History: what leaves this Mac, how history is
// kept (audio, how long, apps it never saves from, what's saved now),
// spelling names from the screen, and backing up settings to a file.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Privacy and History.
struct CalmPrivacySettings: View {
    @EnvironmentObject private var appState: AppState
    @Environment(CalmNavigator.self) private var navigator: CalmNavigator?

    @State private var showsExcludedApps = false
    @State private var confirmsClearHistory = false
    @State private var confirmsDeleteAudio = false
    @State private var backupNotice: CalmBackupNotice?

    var body: some View {
        CalmPage(.sheet) {
            CalmPageHeader("Privacy and History")

            CalmPrivacyStatementPanel(statement: appState.calmPrivacyStatement) { tab in
                navigator?.modelsTab = tab
                navigator?.select(.models)
            }

            CalmGroup("History") {
                VStack(alignment: .leading, spacing: 10) {
                    if appState.historyStore.hasUnsavedChanges {
                        CalmInlineNotice(
                            "Recent changes couldn’t be saved to disk. VocaMac keeps trying; check that your disk has free space."
                        )
                        .padding(.leading, 2)
                    }
                    historyPanel
                }
            }
            .settingsTarget("history-retention")

            CalmGroup("Screen") {
                CalmPanel {
                    CalmToggleRow(
                        "Spell names from the screen",
                        description: "Matches names in the field you’re typing into. Read once, never saved. Never reads password fields.",
                        isOn: $appState.useScreenContext
                    )
                    .help("When you start dictating, VocaMac reads the visible text in the focused field and spells matching names and code identifiers the same way (“user id” → userId). Needs Accessibility permission.")
                }
            }
            .settingsTarget("screen-context")

            CalmGroup("Backup") {
                VStack(alignment: .leading, spacing: 10) {
                    CalmPanel {
                        CalmRow(
                            "Settings, dictionary and snippets",
                            description: "Save them to a file to move to another Mac. History, stats, models, endpoints and API keys stay here."
                        ) {
                            HStack(spacing: 8) {
                                Button("Import", action: importSettings).calmButton(.secondary)
                                Button("Export", action: exportSettings).calmButton(.secondary)
                            }
                        }
                    }
                    if let backupNotice {
                        CalmInlineNotice(backupNotice.text, tone: backupNotice.isError ? .warning : .success)
                            .padding(.leading, 2)
                    }
                }
            }
            .settingsTarget("settings-backup")
        }
        .calmDialog(isPresented: $showsExcludedApps) { CalmExcludedAppsDialog() }
        .calmDialog(isPresented: $confirmsClearHistory) {
            CalmDialog(
                "Clear all history?",
                description: CalmAdvancedSummary.clearHistoryMessage(count: appState.historyStore.entries.count)
            ) {
                CalmDialogFooter(primaryTitle: "Clear history", primaryKind: .destructive) {
                    HistoryAudioPlayer.shared.stop()
                    appState.clearHistory()
                }
            }
        }
        .calmDialog(isPresented: $confirmsDeleteAudio) {
            CalmDialog(
                "Delete all recordings?",
                description: CalmAdvancedSummary.deleteAudioMessage(count: appState.calmHistoryAudioCount)
            ) {
                CalmDialogFooter(primaryTitle: "Delete audio", primaryKind: .destructive) {
                    HistoryAudioPlayer.shared.stop()
                    appState.deleteAllHistoryAudio()
                }
            }
        }
    }

    // MARK: History

    private var historyPanel: some View {
        CalmPanel {
            CalmToggleRow(
                "Keep a history of dictations",
                description: "Shown on Home, to copy, play back or retry. Stays on this Mac.",
                isOn: $appState.historyEnabled
            )
            CalmToggleRow(
                "Keep audio recordings",
                description: "Needed to play back or retry. Failed dictations always keep theirs.",
                isOn: $appState.historyKeepsAudio
            )
            .calmDisabledByParent(!appState.historyEnabled)
            CalmRow("Delete dictations older than") {
                CalmDropdown(
                    selection: $appState.historyRetention,
                    options: HistoryRetention.allCases.map { CalmOption($0, CalmAdvancedSummary.retentionTitle($0)) }
                )
            }
            .calmDisabledByParent(!appState.historyEnabled)
            .onChange(of: appState.historyRetention) { appState.applyHistoryRetention() }
            CalmValueRow(
                "Never save from these apps",
                value: CalmAdvancedSummary.excludedApps(appState.historyExcludedApps.map(\.displayName))
            ) {
                showsExcludedApps = true
            }
            .calmDisabledByParent(!appState.historyEnabled)
            .settingsTarget("history-excluded-apps")
            savedNowRow
        }
    }

    private var savedNowRow: some View {
        let entries = appState.historyStore.entries
        return CalmRow(
            "Saved now",
            description: CalmAdvancedSummary.savedNow(count: entries.count, audioBytes: appState.calmHistoryAudioBytes)
        ) {
            HStack(spacing: 8) {
                Button("Delete audio") { confirmsDeleteAudio = true }
                    .calmButton(.secondary)
                    .disabled(appState.calmHistoryAudioCount == 0)
                Button("Clear history") { confirmsClearHistory = true }
                    .calmButton(.quietDestructive)
                    .disabled(entries.isEmpty)
            }
        }
    }

    // MARK: Backup

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.title = "Export VocaMac Settings"
        panel.nameFieldStringValue = "vocamac-settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SettingsArchiveService.encode().write(to: url, options: .atomic)
            backupNotice = CalmBackupNotice(
                text: "Settings exported. Cleanup endpoints, custom endpoint settings and API keys were left out.",
                isError: false
            )
        } catch {
            backupNotice = CalmBackupNotice(text: "Couldn’t export settings: \(error.localizedDescription)", isError: true)
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.title = "Import VocaMac Settings"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let devices = Set(appState.availableInputDevices().map(\.id))
            try SettingsArchiveService.restore(Data(contentsOf: url), isAvailableInputDevice: devices.contains)
            appState.reloadImportedSettings()
            backupNotice = CalmBackupNotice(
                text: "Settings imported. Your cleanup endpoint and API key were left as they were, and Your own server wasn’t selected from the file.",
                isError: false
            )
        } catch {
            backupNotice = CalmBackupNotice(text: "Couldn’t import settings: \(error.localizedDescription)", isError: true)
        }
    }
}

/// The line under Backup after an import or export.
private struct CalmBackupNotice: Equatable {
    let text: String
    let isError: Bool
}

// MARK: - Statement panel

/// “Everything stays on this Mac”, or the amber variant naming what
/// leaves when a remote speech or AI endpoint is in use.
struct CalmPrivacyStatementPanel: View {
    let statement: CalmPrivacyStatement
    /// Opens Models on the tab that changes it (remote variant only).
    var onReview: ((CalmModelsTab) -> Void)?

    var body: some View {
        HStack(spacing: 16) {
            CalmIcon(statement.isRemote ? .warning : .lock, size: 20, weight: statement.isRemote ? 1.8 : 1.6)
                .foregroundStyle(statement.isRemote ? CalmColor.amber : CalmColor.accent)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(statement.isRemote ? CalmColor.amberSoft : CalmColor.accentSoft)
                )
                .accessibilityHidden(true)
            CalmRowLabel(title: statement.title) { CalmRowDescription(text: statement.message) }
            if statement.isRemote, let onReview {
                Button("Review") { onReview(statement.modelsTab) }
                    .calmButton(.secondary)
                    .accessibilityLabel("Review where your words go")
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .calmPanelBackground()
        .accessibilityElement(children: .contain)
    }
}
