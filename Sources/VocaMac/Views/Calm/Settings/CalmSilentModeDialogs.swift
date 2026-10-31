// CalmSilentModeDialogs.swift
// VocaMac
//
// Teach a silent command: pick what it does and the word to mouth, then
// mouth the word a few times while the camera watches. Each take is cut to
// the movement and kept as lip measurements; Save adds the command.

import SwiftUI

/// What the teach dialog starts from: a new command, or more takes for one.
struct CalmSilentTeachDraft: Identifiable {
    let id = UUID()
    var commandID: UUID?
    var action: SilentCommandAction
    var word: String
    var takes: [LipTake]

    /// A new command for the first action not taught yet.
    @MainActor
    init(appState: AppState) {
        let action = appState.untaughtSilentActions.first ?? .pressReturn
        commandID = nil
        self.action = action
        word = action.suggestedWord
        takes = []
    }

    /// More takes for `command`.
    init(editing command: SilentCommand) {
        commandID = command.id
        action = command.action
        word = command.word
        takes = command.takes
    }
}

struct CalmSilentTeachDialog: View {
    let draft: CalmSilentTeachDraft

    @EnvironmentObject private var appState: AppState
    @Environment(\.calmDismissDialog) private var dismissDialog

    @State private var action: SilentCommandAction
    @State private var word: String
    @State private var takes: [LipTake]
    @State private var isRecording = false
    @State private var progress: Double = 0
    @State private var missedLast = false
    @State private var recording: Task<Void, Never>?

    /// How long one take listens. A short word takes under a second; the
    /// rest is room to start late.
    static let takeSeconds: Double = 2.2

    init(draft: CalmSilentTeachDraft) {
        self.draft = draft
        _action = State(initialValue: draft.action)
        _word = State(initialValue: draft.word)
        _takes = State(initialValue: draft.takes)
    }

    var body: some View {
        CalmDialog(
            draft.commandID == nil ? "Teach a silent command" : "Add takes for \(draft.action.title)",
            description: "Mouth the word the way you will when you use it: no sound needed. Three takes are enough to start; more make it surer."
        ) {
            if draft.commandID == nil {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("When I mouth it").calmType(.rowTitle)
                        Text(action.detail).calmType(.description)
                    }
                    Spacer(minLength: 0)
                    CalmDropdown(
                        selection: actionBinding,
                        options: appState.untaughtSilentActions.map { CalmOption($0, $0.title) }
                    )
                    .accessibilityLabel("Command")
                }
            }
            CalmTextField("Word to mouth", text: $word, prompt: action.suggestedWord)

            HStack(alignment: .center, spacing: 18) {
                SilentFaceTile(live: appState.silentMode.live, cornerRadius: 12)
                    .frame(width: 200, height: 150)
                    .environment(\.colorScheme, .dark)
                CalmSilentTakePanel(
                    live: appState.silentMode.live,
                    word: word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? action.suggestedWord : word.trimmingCharacters(in: .whitespacesAndNewlines),
                    takeCount: takes.count,
                    isRecording: isRecording,
                    progress: progress,
                    onRecord: recordTake
                )
            }

            if missedLast {
                CalmInlineNotice("Didn’t see your lips move in that take. Face the camera and try again.", tone: .warning)
            }
        } footer: {
            CalmDialogFooter(primaryTitle: "Save", isPrimaryEnabled: canSave, onPrimary: save) {
                if !takes.isEmpty, !isRecording {
                    Button("Start over") {
                        takes = draft.commandID == nil ? [] : draft.takes
                        missedLast = false
                    }
                    .calmButton(.quiet)
                }
            }
        }
        .onAppear {
            appState.syncSilentModeSettings()
            Task { await appState.silentMode.begin(.teaching) }
        }
        .onDisappear {
            recording?.cancel()
            _ = appState.silentMode.finishTake()
            appState.silentMode.end(.teaching)
        }
    }

    // MARK: Takes

    private var canSave: Bool {
        !isRecording && takes.count >= SilentCommand.minimumTakes
            && !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var actionBinding: Binding<SilentCommandAction> {
        Binding(
            get: { action },
            set: { newAction in
                // Follow the action's suggested word until the user types their own.
                if word.isEmpty || word == action.suggestedWord { word = newAction.suggestedWord }
                action = newAction
            }
        )
    }

    private func recordTake() {
        guard !isRecording else { return }
        missedLast = false
        isRecording = true
        progress = 0
        appState.silentMode.beginTake()
        withAnimation(.linear(duration: Self.takeSeconds)) { progress = 1 }
        recording = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.takeSeconds))
            let frames = appState.silentMode.finishTake()
            isRecording = false
            guard !Task.isCancelled else { return }
            if let take = appState.silentTake(from: frames) {
                takes.append(take)
            } else {
                missedLast = true
            }
        }
    }

    private func save() {
        appState.saveSilentCommand(
            id: draft.commandID, action: action,
            word: word.trimmingCharacters(in: .whitespacesAndNewlines), takes: takes
        )
    }
}

/// The take side of the teach dialog: what to do now, the takes so far, and
/// the button. Watches the camera so the button waits for it.
private struct CalmSilentTakePanel: View {
    @ObservedObject var live: SilentLiveState
    let word: String
    let takeCount: Int
    let isRecording: Bool
    let progress: Double
    let onRecord: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isRecording ? "Mouth “\(word)” now" : title)
                .calmType(.rowTitle)
            dots
            if isRecording {
                CalmProgressBar(value: progress)
                    .frame(maxWidth: 200)
            }
            Button(isRecording ? "Watching…" : (takeCount == 0 ? "Record a take" : "Record another"), action: onRecord)
                .calmButton(isRecording ? .secondary : .primary)
                .disabled(isRecording || !live.phase.isCameraOn)
            if case .unavailable(let reason) = live.phase {
                CalmInlineNotice(reason, tone: .warning)
            } else if live.phase == .searching {
                CalmInlineNotice("Looking for your face. Face the camera.", tone: .info)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        let needed = max(0, SilentCommand.minimumTakes - takeCount)
        if needed == 0 { return "\(takeCount) takes. Ready to save" }
        return needed == 1 ? "1 more take" : "\(needed) more takes"
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(0..<max(SilentCommand.minimumTakes, takeCount), id: \.self) { index in
                Circle()
                    .fill(index < takeCount ? CalmColor.accent : CalmColor.panel2)
                    .overlay(Circle().strokeBorder(CalmColor.line2, lineWidth: index < takeCount ? 0 : 1))
                    .frame(width: 10, height: 10)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(takeCount) of \(SilentCommand.minimumTakes) takes")
    }
}
