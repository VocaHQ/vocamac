// CalmSystemAutoPauseDialog.swift
// VocaMac
//
// Settings › System › Pause for apps: the switch, the apps that pause
// dictation while they run, and a second step that picks a running app
// to add (one dialog with steps, since a dialog can't open another).

import SwiftUI

/// Pause dictation, and free the speech model's memory, while listed apps run.
struct CalmAutoPauseDialog: View {
    @EnvironmentObject private var appState: AppState

    private enum Step { case list, add }

    @State private var step: Step
    @State private var runningApps: [RunningAppSnapshot] = []
    @State private var search = ""
    @State private var picked: RunningAppSnapshot?
    @FocusState private var isSearchFocused: Bool

    /// - Parameter startsAdding: Open on the running-apps step (previews).
    init(startsAdding: Bool = false, runningApps: [RunningAppSnapshot] = []) {
        _step = State(initialValue: startsAdding ? .add : .list)
        _runningApps = State(initialValue: runningApps)
    }

    /// The notice shown while a listed app has paused dictation.
    static func pausedNotice(trigger: String?) -> String {
        trigger.map { "Paused now while \($0) is open" } ?? "Paused now by a listed app"
    }

    var body: some View {
        switch step {
        case .list: listStep
        case .add: addStep
        }
    }

    // MARK: Steps

    private var listStep: some View {
        CalmDialog(
            "Pause for apps",
            description: "While one of these apps is open, dictation pauses and the speech model’s memory is freed. It loads again when they quit.",
            width: CalmMetrics.dialogListWidth
        ) {
            HStack(spacing: 16) {
                Text("Pause dictation while these apps run").calmType(.rowTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CalmSwitch(isOn: $appState.autoPauseEnabled).accessibilityLabel("Pause dictation while these apps run")
            }
            .contentShape(Rectangle())
            .onTapGesture { appState.autoPauseEnabled.toggle() }

            Group {
                if appState.autoPauseApps.isEmpty {
                    Text("No apps yet. Add a game or another heavy app.")
                        .font(CalmFont.description)
                        .foregroundStyle(CalmColor.muted)
                        .padding(.vertical, 22)
                        .frame(maxWidth: .infinity)
                        .calmCreateCard()
                } else {
                    CalmList {
                        ForEach(appState.autoPauseApps) { app in
                            CalmListRow(padding: .compact, alignment: .center, alwaysShowsActions: true) {
                                CalmAppTile(name: app.displayName)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.displayName).font(CalmFont.body).foregroundStyle(CalmColor.ink)
                                    if let detail = app.bundleIdentifier ?? app.processName {
                                        Text(detail).font(CalmFont.note).foregroundStyle(CalmColor.muted).lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            } actions: {
                                Button { appState.removeAutoPauseApp(app) } label: {
                                    CalmIcon(.trash, size: 16)
                                }
                                .calmIconButton()
                                .accessibilityLabel("Remove \(app.displayName)")
                            }
                        }
                    }
                    .calmDialogScrollingList()
                }
            }
            .calmDisabledByParent(!appState.autoPauseEnabled)

            if appState.isAutoPaused {
                CalmInlineNotice(Self.pausedNotice(trigger: appState.autoPauseTriggerDisplayName))
                    .padding(.top, -8)
            }
        } footer: {
            CalmDialogFooter(primaryTitle: "Done", cancelTitle: nil, onPrimary: {}, leading: {
                Button {
                    openAddStep()
                } label: {
                    CalmButtonLabel("Add app", icon: .plus)
                }
                .calmButton(.secondary)
                .disabled(!appState.autoPauseEnabled)
            })
        }
    }

    private var addStep: some View {
        CalmDialog("Add an app", description: "Pick one that’s open now.", width: CalmMetrics.dialogListWidth) {
            CalmSearchField(text: $search, prompt: "Search open apps", focus: $isSearchFocused)
            if candidates.isEmpty {
                CalmNoResults(message: search.isEmpty ? "No other apps are open." : "No open app matches “\(search)”.") {
                    search = ""
                }
            } else {
                ScrollView {
                    CalmList {
                        ForEach(candidates, id: \.self) { app in
                            Button { picked = app } label: {
                                HStack(spacing: 12) {
                                    CalmAppTile(name: app.displayName)
                                    Text(app.displayName).font(CalmFont.body).foregroundStyle(CalmColor.ink)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if picked == app {
                                        CalmIcon(.check, size: 14, weight: 2.4).foregroundStyle(CalmColor.ink)
                                    }
                                }
                                .padding(.vertical, 10)
                                .padding(.horizontal, 14)
                                .background(picked == app ? CalmColor.panel2 : .clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(CalmPlainFocusStyle(radius: 0))
                            .focusEffectDisabled()
                            .accessibilityAddTraits(picked == app ? .isSelected : [])
                        }
                    }
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            CalmDialogFooter(
                primaryTitle: "Add", isPrimaryEnabled: picked != nil, cancelTitle: "Back",
                onCancel: { step = .list }, dismissesOnPrimary: false,
                onPrimary: addPicked
            )
        }
        .onAppear { isSearchFocused = true }
    }

    // MARK: Helpers

    /// Open apps not yet listed, filtered by the search.
    private var candidates: [RunningAppSnapshot] {
        let listed = Set(appState.autoPauseApps.map(\.id))
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return runningApps.filter { app in
            !listed.contains(AutoPauseAppEntry.from(snapshot: app).id)
                && (needle.isEmpty || app.displayName.lowercased().contains(needle))
        }
    }

    private func addPicked() {
        if let picked { appState.addAutoPauseApp(AutoPauseAppEntry.from(snapshot: picked)) }
        step = .list
    }

    private func openAddStep() {
        runningApps = AutoPauseMatching.workspaceRunningApps()
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        search = ""
        picked = nil
        step = .add
    }
}
