// CalmCommandsPage.swift
// VocaMac
//
// Commands: Command Mode (edit selected text, or write new text, by voice).
// The header carries the on/off switch and the shortcut pill; then the one
// problem worth fixing, the hero with examples, saved commands, and the
// rows: preview before replacing, copying a hidden selection, voice
// actions and their Shortcuts allow-list, and the model (picked in
// Settings › Models › Writing AI).

import SwiftUI

/// Which dialog the Commands page is showing.
enum CalmCommandsDialog: Identifiable {
    case shortcut
    case command(CalmSavedCommandDraft)
    case voiceShortcuts
    case howItWorks
    case tryIt

    var id: String {
        switch self {
        case .shortcut: return "shortcut"
        case .command(let draft): return "command-\(draft.id)"
        case .voiceShortcuts: return "voice-shortcuts"
        case .howItWorks: return "how-it-works"
        case .tryIt: return "try-it"
        }
    }
}

/// Commands: Command Mode, saved commands and voice actions.
struct CalmCommandsPage: View {
    @EnvironmentObject private var appState: AppState
    @Environment(CalmNavigator.self) private var navigator
    @State private var dialog: CalmCommandsDialog?

    var body: some View {
        let status = appState.calmCommandsStatus
        CalmPage(.list, spacing: 22) {
            header
                .settingsTarget("command-mode-shortcut")
            CalmCommandsStatusPanel(status: status, onSetShortcut: { dialog = .shortcut }, onOpenModels: openWritingAI)
            hero
            CalmSavedCommandsSection(
                onCreate: { dialog = .command(CalmSavedCommandDraft()) },
                onEdit: { dialog = .command(CalmSavedCommandDraft(editing: $0)) }
            )
            .settingsTarget("command-mode-saved")
            rows(status: status)
        }
        .calmDialog(item: $dialog) { dialog in
            switch dialog {
            case .shortcut: CalmShortcutRecorderDialog(target: .commandMode, current: appState.shortcut(for: .commandMode))
            case .command(let draft): CalmSavedCommandDialog(draft: draft)
            case .voiceShortcuts: CalmVoiceShortcutsDialog(text: appState.voiceActionShortcuts)
            case .howItWorks: CalmCommandsHowItWorksDialog()
            case .tryIt: CalmCommandsTryDialog { self.dialog = .shortcut }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        let isOn = appState.isCommandModeOn
        let caps = appState.shortcut(for: .commandMode).map(CalmKeyCaps.labels(for:)) ?? []
        return CalmFeatureHeader(
            "Commands",
            isOn: Binding(
                get: { appState.isCommandModeOn },
                set: { isOn in
                    // No free keys to turn on with: let the person pick some.
                    if !appState.setCommandModeOn(isOn) { dialog = .shortcut }
                }
            ),
            shortcut: caps,
            shortcutCaption: isOn ? "to edit by voice" : "Set a shortcut",
            onShortcutTap: { dialog = .shortcut }
        )
    }

    // MARK: Hero

    private var hero: some View {
        CalmFeatureCard(
            dismissKey: nil,
            title: Text("Select text. Say what to change."),
            message: CalmCommandsText.heroMessage(review: appState.commandModeReview),
            waveHeights: [60, 100, 150, 90, 120, 44]
        ) {
            VStack(alignment: .leading, spacing: 18) {
                FlowLayout(spacing: 8) {
                    ForEach(CalmCommandsText.heroExamples, id: \.self) { example in
                        CalmCommandExampleChip(text: example)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Examples: " + CalmCommandsText.heroExamples.joined(separator: ", "))
                HStack(spacing: 8) {
                    Button("Try it out") { dialog = .tryIt }
                        .calmButton(.heroPrimary)
                    Button { dialog = .howItWorks } label: {
                        Text("How it works")
                            .font(CalmFont.button)
                            .foregroundStyle(CalmColor.heroText)
                            .padding(.horizontal, 14)
                            .frame(height: CalmMetrics.buttonHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(CalmPlainFocusStyle(radius: CalmMetrics.Radius.button))
                    .focusEffectDisabled()
                }
            }
        }
    }

    // MARK: Rows

    private func rows(status: CalmCommandsStatus) -> some View {
        CalmPanel {
            CalmRow("Preview before replacing") {
                CalmDropdown(
                    selection: $appState.commandModeReview,
                    options: CommandReviewMode.allCases.map { CalmOption($0, CalmCommandsText.reviewTitle($0)) }
                )
                .accessibilityLabel("Preview before replacing")
            }
            .help("Shows what changed and waits. Press the Command Mode shortcut to replace, or Esc to discard.")
            .settingsTarget("command-mode-review")

            CalmToggleRow(
                "Copy the selection when an app hides it",
                description: "For terminals and editors that don’t share selected text",
                isOn: $appState.commandModeClipboardFallback
            )
            .help("VocaMac copies the selection with ⌘C and puts your clipboard back right away. Clipboard managers may briefly see the selected text.")
            .settingsTarget("command-mode-clipboard")

            CalmToggleRow(
                "Voice actions",
                description: "Say “open Safari”, “search the web for…”, “remind me to…” or “run the shortcut…”. Only what you say starts an action, never the selected text.",
                isOn: $appState.voiceActionsEnabled
            )
            .settingsTarget("command-mode-actions")

            if appState.voiceActionsEnabled {
                CalmValueRow(
                    "Shortcuts VocaMac may run",
                    value: CalmCommandsText.shortcutsSummary(appState.voiceActionShortcuts)
                ) { dialog = .voiceShortcuts }
            }

            modelRow(status: status)
        }
    }

    private func modelRow(status: CalmCommandsStatus) -> some View {
        CalmRow("Model") {
            VStack(alignment: .leading, spacing: 8) {
                CalmRowDescription(text: appState.calmCommandsModelLine)
                if case .downloading(let kind, let progress) = status {
                    CalmProgressBar(
                        value: progress,
                        title: "Downloading \(CalmModelText.name(kind))",
                        detail: "\(Int((progress * 100).rounded()))%"
                    )
                    .frame(maxWidth: 360)
                    .padding(.top, 2)
                }
            }
        } trailing: {
            Button("Change", action: openWritingAI).calmButton(.secondary)
        }
    }

    private func openWritingAI() {
        navigator.modelsTab = .writing
        // The Command Mode row, not the cleanup cards above it.
        navigator.openSettings(.models, target: "command-mode-share")
    }
}

// MARK: - Status

/// The one problem that stops Command Mode, with its fix. Nothing when ready
/// (and nothing while the model downloads: the Model row shows that).
private struct CalmCommandsStatusPanel: View {
    let status: CalmCommandsStatus
    let onSetShortcut: () -> Void
    let onOpenModels: () -> Void

    @EnvironmentObject private var appState: AppState

    var body: some View {
        switch status {
        case .off(let suggestion):
            CalmPanel {
                CalmStatusRow(
                    "Command Mode is off",
                    description: "It starts with a shortcut. Pick one, then select text in any app, press it and say what to change.",
                    tone: .info
                ) {
                    if let suggestion {
                        Button("Use \(CalmCommandsText.keys(suggestion))") {
                            appState.setShortcut(suggestion, for: .commandMode)
                        }
                        .calmButton(.secondary)
                        .help("Three modifiers, which other apps rarely use")
                    } else {
                        Button("Set shortcut", action: onSetShortcut).calmButton(.secondary)
                    }
                }
            }
        case .needsDownload(let kind):
            CalmPanel {
                CalmStatusRow(
                    "\(CalmModelText.name(kind)) isn’t downloaded yet",
                    description: "Command Mode needs it to edit text. It’s \(kind.descriptor.sizeDescription.replacingOccurrences(of: "~", with: "about ")) and runs on this Mac.",
                    tone: .warning
                ) {
                    Button("Go to Models", action: onOpenModels).calmButton(.secondary)
                }
            }
        case .problem(let message):
            CalmPanel {
                CalmStatusRow("Command Mode can’t edit right now", description: message, tone: .warning) {
                    Button("Change model", action: onOpenModels).calmButton(.secondary)
                }
            }
        case .downloading, .ready:
            EmptyView()
        }
    }
}

// MARK: - Hero pieces

/// An example instruction in the hero: an italic quote on a hero chip.
/// Not a button; it shows what to say.
private struct CalmCommandExampleChip: View {
    let text: String

    var body: some View {
        Text("“\(text)”")
            .font(CalmFont.button.italic())
            .foregroundStyle(CalmColor.heroText)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 14)
            .frame(height: CalmMetrics.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: CalmMetrics.Radius.button, style: .continuous)
                    .fill(CalmColor.heroText.opacity(0.14))
            )
    }
}
