// CalmPrivacyDialogs.swift
// VocaMac
//
// Settings › Privacy and History › Never save from these apps: the apps
// whose dictations are typed as usual but never saved to History, and a
// second step that picks an open app to add (one dialog with steps,
// since a dialog can't open another).

import SwiftUI

/// The apps History never saves from, with an Add step.
struct CalmExcludedAppsDialog: View {
    @EnvironmentObject private var appState: AppState

    private enum Step { case list, add }

    @State private var step: Step
    @State private var runningApps: [RunningAppSnapshot]
    @State private var search = ""
    @State private var picked: RunningAppSnapshot?
    @FocusState private var isSearchFocused: Bool

    /// - Parameters:
    ///   - startsAdding: Open on the open-apps step (renders, previews).
    ///   - runningApps: Open apps to offer; read from the workspace when the Add step opens.
    init(startsAdding: Bool = false, runningApps: [RunningAppSnapshot] = []) {
        _step = State(initialValue: startsAdding ? .add : .list)
        _runningApps = State(initialValue: runningApps)
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
            "Never save from these apps",
            description: "For password managers, banking or anything private. Dictation still works in them; it just isn’t kept in History.",
            width: CalmMetrics.dialogListWidth
        ) {
            if appState.historyExcludedApps.isEmpty {
                Text("No apps yet.")
                    .font(CalmFont.description)
                    .foregroundStyle(CalmColor.muted)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
                    .calmCreateCard()
            } else {
                ScrollView {
                    CalmList {
                        ForEach(appState.historyExcludedApps) { app in
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
                                Button { appState.removeHistoryExcludedApp(app) } label: {
                                    CalmIcon(.trash, size: 16)
                                }
                                .calmIconButton()
                                .help("Remove \(app.displayName)")
                                .accessibilityLabel("Remove \(app.displayName)")
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            CalmDialogFooter(primaryTitle: "Done", cancelTitle: nil, onPrimary: {}, leading: {
                Button(action: openAddStep) {
                    CalmButtonLabel("Add app", icon: .plus)
                }
                .calmButton(.secondary)
            })
        }
    }

    private var addStep: some View {
        CalmDialog("Add an app", description: "Pick one that’s open now.", width: CalmMetrics.dialogListWidth) {
            CalmSearchField(text: $search, prompt: "Search open apps", focus: $isSearchFocused)
            let candidates = Self.candidates(
                running: runningApps, excluded: appState.historyExcludedApps, search: search
            )
            if candidates.isEmpty {
                CalmNoResults(message: search.isEmpty ? "No other apps are open." : "No open app matches “\(search)”.") {
                    search = ""
                }
            } else {
                ScrollView {
                    CalmList {
                        ForEach(candidates, id: \.self) { app in
                            appChoice(app)
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

    private func appChoice(_ app: RunningAppSnapshot) -> some View {
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

    // MARK: Helpers

    /// Open apps not yet excluded whose name matches `search`, in the order given.
    static func candidates(
        running: [RunningAppSnapshot], excluded: [AutoPauseAppEntry], search: String
    ) -> [RunningAppSnapshot] {
        let listed = Set(excluded.map(\.id))
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return running.filter { app in
            !listed.contains(AutoPauseAppEntry.from(snapshot: app).id)
                && (needle.isEmpty || app.displayName.lowercased().contains(needle))
        }
    }

    private func addPicked() {
        if let picked { appState.addHistoryExcludedApp(AutoPauseAppEntry.from(snapshot: picked)) }
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
