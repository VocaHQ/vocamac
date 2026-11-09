// CalmSystemDeliveryDialogs.swift
// VocaMac
//
// Settings › System › Putting text in apps: the apps that always get
// typed text, and the terminals and editors where Auto Send may press
// Return. One dialog with a list step and an add step, since a dialog
// can't open another.

import SwiftUI

/// Which app list a `CalmDeliveryAppsDialog` edits.
enum CalmDeliveryAppList: Identifiable {
    case typed
    case autoSend

    var id: Self { self }

    var title: String {
        switch self {
        case .typed: return "Always type in these apps"
        case .autoSend: return "Auto Send in these apps too"
        }
    }

    var description: String {
        switch self {
        case .typed:
            return "For apps that ignore ⌘V or paste something else, like remote desktops and some games. Text is typed key by key."
        case .autoSend:
            return "Terminals and code editors are left out of Auto Send, since Return runs a command there. Add one to send in it anyway."
        }
    }

    var emptyMessage: String {
        switch self {
        case .typed: return "No apps yet."
        case .autoSend: return "No apps yet. Every other app already sends."
        }
    }

    /// The row's summary of the listed apps.
    static func summary(_ names: [String]) -> String {
        switch names.count {
        case 0: return "None"
        case 1, 2: return names.joined(separator: " and ")
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }
}

/// Edits one of the delivery app lists, with an Add step.
struct CalmDeliveryAppsDialog: View {
    let list: CalmDeliveryAppList

    @EnvironmentObject private var appState: AppState

    private enum Step { case list, add }

    @State private var step: Step = .list
    @State private var runningApps: [RunningAppSnapshot] = []
    @State private var search = ""
    @State private var picked: RunningAppSnapshot?
    @FocusState private var isSearchFocused: Bool

    private var apps: [AutoPauseAppEntry] {
        switch list {
        case .typed: return appState.typedInsertionApps
        case .autoSend: return appState.autoSendApps
        }
    }

    private func setApps(_ entries: [AutoPauseAppEntry]) {
        switch list {
        case .typed: appState.typedInsertionApps = entries
        case .autoSend: appState.autoSendApps = entries
        }
    }

    var body: some View {
        switch step {
        case .list: listStep
        case .add: addStep
        }
    }

    private var listStep: some View {
        CalmDialog(list.title, description: list.description, width: CalmMetrics.dialogListWidth) {
            if apps.isEmpty {
                Text(list.emptyMessage)
                    .font(CalmFont.description)
                    .foregroundStyle(CalmColor.muted)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
                    .calmCreateCard()
            } else {
                ScrollView {
                    CalmList {
                        ForEach(apps) { app in
                            CalmListRow(padding: .compact, alignment: .center, alwaysShowsActions: true) {
                                CalmAppTile(name: app.displayName, bundleIdentifier: app.bundleIdentifier)
                                Text(app.displayName).font(CalmFont.body).foregroundStyle(CalmColor.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } actions: {
                                Button { setApps(apps.filter { $0.id != app.id }) } label: {
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
            let candidates = CalmExcludedAppsDialog.candidates(running: runningApps, excluded: apps, search: search)
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
                                    CalmAppTile(name: app.displayName, bundleIdentifier: app.bundleIdentifier)
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

    private func addPicked() {
        if let picked {
            let entry = AutoPauseAppEntry.from(snapshot: picked)
            if !apps.contains(where: { $0.id == entry.id }) { setApps(apps + [entry]) }
        }
        step = .list
    }

    private func openAddStep() {
        runningApps = AppIdentityMatching.workspacePickableApps()
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        search = ""
        picked = nil
        step = .add
    }
}
