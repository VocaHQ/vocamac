// CalmModesSection.swift
// VocaMac
//
// The Styles page's Modes section: a serif title with Create new, then a
// grid of mode cards (keys, name, what it does). With none yet, a card
// offers the starter set. Clicking a card opens the mode's editor.

import SwiftUI

/// Modes: title, Create new, and the card grid.
struct CalmModesSection: View {
    @EnvironmentObject private var appState: AppState

    @State private var editing: DictationMode?
    @State private var isCreating = false

    private static let columns = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    CalmSectionTitle("Modes")
                    Text("Dictate in a mode with its own shortcut, or say its name first: “Formal, dear team…”.")
                        .calmType(.description)
                        .foregroundStyle(CalmColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button { isCreating = true } label: { CalmButtonLabel("Create new", icon: .plus) }
                    .calmButton(.primary)
            }
            grid
        }
        .calmDialog(item: $editing) { mode in
            CalmModeDialog(mode: mode, isNew: false)
        }
        .calmDialog(isPresented: $isCreating) {
            CalmModeDialog(mode: DictationMode(name: ""), isNew: true)
        }
    }

    private var cells: [Cell] {
        let modes = appState.dictationModes
        return modes.isEmpty ? [Cell.starters] : modes.map(Cell.mode)
    }

    private var grid: some View {
        let rows = stride(from: 0, to: cells.count, by: Self.columns).map { start in
            Array(cells[start..<min(start + Self.columns, cells.count)])
        }
        return Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row) { cell in
                        view(for: cell)
                            .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity, alignment: .topLeading)
                    }
                    ForEach(0..<(Self.columns - row.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity).frame(height: 1).gridCellUnsizedAxes(.vertical)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func view(for cell: Cell) -> some View {
        switch cell {
        case .mode(let mode):
            CalmModeCard(mode: mode) { editing = mode }
        case .starters:
            CalmStarterModesCard { appState.addStarterModes() }
        }
    }

    private enum Cell: Identifiable {
        case mode(DictationMode)
        case starters

        var id: String {
            switch self {
            case .mode(let mode): return mode.id.uuidString
            case .starters: return "starters"
            }
        }
    }
}

// MARK: - Text

/// How a mode is described on its card and for VoiceOver.
enum CalmModeText {
    /// "Code style", "Email style · Formal", "Plain style · exactly as heard · German".
    static func summary(_ mode: DictationMode) -> String {
        var parts = ["\(mode.style.displayName) style"]
        switch mode.cleanup {
        case .raw: parts.append("exactly as heard")
        case .off: parts.append("no AI cleanup")
        case .inherit:
            if mode.style.supportsWording { parts.append(mode.intent.displayName) }
            if let level = mode.cleanupLevel { parts.append("\(level.displayName) cleanup") }
        }
        if let language = mode.languageOverride {
            parts.append(SpokenLanguages.displayName(for: language))
        }
        return parts.joined(separator: " · ")
    }

    static func name(_ mode: DictationMode) -> String {
        mode.trimmedName.isEmpty ? "Untitled mode" : mode.trimmedName
    }
}

// MARK: - Cards

/// One mode: its keys (or how to use it without), name and what it does.
private struct CalmModeCard: View {
    let mode: DictationMode
    let onEdit: () -> Void

    @State private var isHovered = false

    private var combo: HotKeyCombo? { HotKeyCombo(storageString: mode.shortcut) }

    var body: some View {
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 10) {
                keys
                VStack(alignment: .leading, spacing: 10) {
                    Text(CalmModeText.name(mode))
                        .font(CalmFont.sf(14.5, weight: 600))
                        .foregroundStyle(CalmColor.ink)
                        .lineLimit(1)
                    Text(CalmModeText.summary(mode))
                        .calmType(.description)
                        .foregroundStyle(CalmColor.muted)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .calmCard()
            .overlay(alignment: .topTrailing) {
                if isHovered {
                    CalmIcon(.edit, size: 15)
                        .foregroundStyle(CalmColor.muted)
                        .padding(16)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: CalmMetrics.Radius.panel, style: .continuous))
        }
        .buttonStyle(CalmPlainFocusStyle(radius: CalmMetrics.Radius.panel))
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Edit")
    }

    @ViewBuilder
    private var keys: some View {
        if let combo {
            CalmKeyCombo(combo: combo)
        } else {
            Text(mode.listensForName ? "No shortcut · say its name" : "No shortcut")
                .font(CalmFont.note)
                .foregroundStyle(CalmColor.muted)
                .frame(height: CalmMetrics.keyCapHeight)
        }
    }

    private var accessibilityText: String {
        var text = CalmModeText.name(mode) + " mode"
        if let combo { text += ", shortcut \(KeyCodeReference.displayName(for: combo))" }
        return text + ". " + CalmModeText.summary(mode)
    }
}

/// With no modes yet: offer the starters in one click.
private struct CalmStarterModesCard: View {
    let onAdd: () -> Void

    private var names: String {
        let names = DictationMode.starters.map(\.name)
        guard let last = names.last else { return "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No modes yet")
                .font(CalmFont.note)
                .foregroundStyle(CalmColor.muted)
                .frame(height: CalmMetrics.keyCapHeight)
            VStack(alignment: .leading, spacing: 10) {
                Text("Start with three")
                    .font(CalmFont.sf(14.5, weight: 600))
                    .foregroundStyle(CalmColor.ink)
                Text("\(names). Say a name first, or give one a shortcut.")
                    .calmType(.description)
                    .foregroundStyle(CalmColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
            Spacer(minLength: 0)
            Button("Add them", action: onAdd)
                .calmButton(.secondary, size: .small)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .calmCard()
    }
}

// MARK: - Editor

/// New mode or Edit mode: name, how it writes, an optional language, and
/// an optional shortcut recorded in place. Editing adds Delete.
struct CalmModeDialog: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.calmDismissDialog) private var dismissDialog

    @State private var draft: DictationMode
    @State private var shortcut: HotKeyCombo?
    @State private var isRecording = false
    @State private var listenerWasRunning = false
    @State private var isConfirmingDelete = false
    @FocusState private var isNameFocused: Bool
    private let isNew: Bool

    init(mode: DictationMode, isNew: Bool) {
        _draft = State(initialValue: mode)
        _shortcut = State(initialValue: HotKeyCombo(storageString: mode.shortcut))
        self.isNew = isNew
    }

    var body: some View {
        Group {
            if isConfirmingDelete {
                confirmation
            } else {
                editor
            }
        }
        .background {
            CalmKeyCapture(isCapturing: $isRecording, onCancel: recordingCancelled, onCapture: recorded)
        }
        .onAppear {
            if isNew { DispatchQueue.main.async { isNameFocused = true } }
        }
        .onDisappear { stopRecording() }
    }

    // MARK: Editor

    private var editor: some View {
        CalmDialog(
            isNew ? "New mode" : "Edit mode",
            description: "A mode writes one dictation its own way, whatever app you are in.",
            width: CalmMetrics.dialogListWidth
        ) {
            CalmStylesDialogScroll {
                CalmTextField(
                    "Name", text: $draft.name, prompt: "e.g. Formal",
                    error: nameError, focus: $isNameFocused
                )
                CalmStylesDialogToggle(
                    "Say the name to switch",
                    note: "“\(sayExample), …” at the start of a dictation uses this mode. The name has to be followed by a pause.",
                    isOn: $draft.listensForName
                )
                CalmStylesDialogRow("Style") {
                    CalmDropdown(selection: $draft.style, options: CalmStylesOptions.styles)
                }
                CalmStylesDialogRow("Tone", note: toneNote) {
                    CalmDropdown(selection: $draft.intent, options: CalmStylesOptions.intents)
                        .disabled(!draft.style.supportsWording || draft.cleanup != .inherit)
                }
                CalmStylesDialogRow("AI cleanup") {
                    CalmDropdown(selection: $draft.cleanup, options: CalmStylesOptions.cleanup)
                }
                CalmStylesDialogRow("Cleanup level") {
                    CalmDropdown(selection: $draft.cleanupLevel, options: CalmStylesOptions.levels)
                        .disabled(draft.cleanup != .inherit)
                }
                CalmStylesDialogRow(
                    "Language",
                    note: "Used when the shortcut starts the dictation. Models made for one language keep theirs."
                ) {
                    CalmDropdown(selection: $draft.language, options: languageOptions)
                }
                shortcutRow
                CalmTextEditor(
                    "Custom cleanup instructions", text: promptBinding,
                    prompt: "Leave blank to use the instructions from Smart Cleanup.", minHeight: 60
                )
            }
        } footer: {
            CalmDialogFooter(
                primaryTitle: isNew ? "Create" : "Save",
                isPrimaryEnabled: canSave,
                onPrimary: save,
                leading: {
                    if !isNew {
                        Button("Delete") { isConfirmingDelete = true }.calmButton(.quietAmber)
                    }
                }
            )
        }
    }

    /// Formal and Casual need the rewording switch on Styles to be on.
    private var toneNote: String? {
        guard draft.intent != .preserve, !appState.writingRewriteEnabled else { return nil }
        return "Turn on “Reword to sound Formal or Casual” on this page for this tone to apply."
    }

    private var sayExample: String {
        draft.trimmedName.isEmpty ? "Formal" : draft.trimmedName
    }

    private var nameError: String? {
        guard !draft.trimmedName.isEmpty else { return nil }
        return DictationModeStore.nameProblem(draft.name, id: draft.id, in: appState.dictationModes)
    }

    private var canSave: Bool {
        DictationModeStore.nameProblem(draft.name, id: draft.id, in: appState.dictationModes) == nil
            && !isRecording && shortcutProblem == nil
    }

    private var promptBinding: Binding<String> {
        Binding(get: { draft.cleanupPrompt ?? "" }, set: { draft.cleanupPrompt = $0 })
    }

    private var languageOptions: [CalmOption<String?>] {
        var codes = appState.spokenLanguages
        if let current = draft.languageOverride, !codes.contains(current) { codes.append(current) }
        return [CalmOption(nil, "Same as Language setting")]
            + codes.map { CalmOption(Optional($0), SpokenLanguages.displayName(for: $0)) }
    }

    private func save() {
        var mode = draft
        mode.name = draft.trimmedName
        mode.shortcut = shortcut?.storageString ?? ""
        appState.saveDictationMode(mode)
    }

    // MARK: Shortcut

    private var shortcutProblem: String? {
        guard let shortcut else { return nil }
        return ShortcutValidation.problem(with: shortcut, action: .dictationMode(draft.id), appState: appState)
    }

    private var shortcutRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shortcut").calmType(.rowTitle).foregroundStyle(CalmColor.ink)
                    Text(shortcut == nil && !isRecording ? "Optional" : "Hold to talk, or press once to start and again to stop")
                        .calmType(.description)
                        .foregroundStyle(CalmColor.muted)
                }
                Spacer(minLength: 0)
                shortcutControl.fixedSize()
            }
            if let shortcutProblem, !isRecording {
                CalmInlineNotice(shortcutProblem, tone: .warning)
            }
        }
    }

    @ViewBuilder
    private var shortcutControl: some View {
        if isRecording {
            HStack(spacing: 8) {
                CalmRecordingKeyCap()
                Button("Cancel", action: stopRecording).calmButton(.quiet, size: .small)
            }
        } else if let shortcut {
            HStack(spacing: 8) {
                Button(action: startRecording) { CalmKeyCombo(combo: shortcut) }
                    .buttonStyle(CalmPlainFocusStyle(radius: 8))
                    .focusEffectDisabled()
                    .help("Record different keys")
                    .accessibilityLabel("Shortcut \(KeyCodeReference.displayName(for: shortcut)). Change")
                Button("Remove") { self.shortcut = nil }
                    .calmButton(.quiet, size: .small)
            }
        } else {
            Button("Record shortcut", action: startRecording).calmButton(.secondary)
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        listenerWasRunning = appState.beginShortcutCapture()
        isRecording = true
    }

    private func stopRecording() {
        guard isRecording || appState.isCapturingShortcut else { return }
        isRecording = false
        appState.endShortcutCapture(restartListener: listenerWasRunning)
        listenerWasRunning = false
    }

    private func recorded(_ combo: HotKeyCombo) {
        shortcut = combo
        appState.endShortcutCapture(restartListener: listenerWasRunning)
        listenerWasRunning = false
    }

    private func recordingCancelled() {
        appState.endShortcutCapture(restartListener: listenerWasRunning)
        listenerWasRunning = false
    }

    // MARK: Delete

    private var confirmation: some View {
        let name = CalmModeText.name(draft)
        let description = shortcut.map { "Its shortcut \(KeyCodeReference.displayName(for: $0)) stops working. Your other modes are kept." }
            ?? "Your other modes are kept."
        return CalmDialog("Delete “\(name)”?", description: description) {
            CalmDialogFooter(
                primaryTitle: "Delete", primaryKind: .destructive,
                onCancel: { isConfirmingDelete = false },
                onPrimary: {
                    appState.deleteDictationMode(draft.id)
                    dismissDialog?()
                }
            )
        }
    }
}
