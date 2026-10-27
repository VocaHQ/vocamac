// CalmHomeGettingStarted.swift
// VocaMac
//
// Home's Get started checklist: four first steps, each with a button that
// opens where it's done. It goes away once every step is done, or when
// dismissed.

import SwiftUI

/// Get started: the first steps, ticked off as they're done.
struct CalmHomeGettingStarted: View {
    @EnvironmentObject private var appState: AppState
    @Environment(CalmNavigator.self) private var navigator
    @AppStorage("calm.home.gettingStarted.dismissed") private var isDismissed = false

    var body: some View {
        let done = appState.calmGettingStartedDone
        if !isDismissed, done.count < CalmGettingStartedStep.allCases.count {
            VStack(alignment: .leading, spacing: CalmMetrics.groupLabelGap) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Get started").calmType(.groupLabel).accessibilityAddTraits(.isHeader)
                    Text("\(done.count) of \(CalmGettingStartedStep.allCases.count) done")
                        .font(CalmFont.note)
                        .foregroundStyle(CalmColor.muted)
                    Spacer(minLength: 8)
                    Button { isDismissed = true } label: { CalmIcon(.close, size: 13) }
                        .calmIconButton(size: 28)
                        .help("Hide Get started")
                        .accessibilityLabel("Hide Get started")
                }
                .padding(.leading, 2)
                CalmPanel {
                    ForEach(CalmGettingStartedStep.allCases) { step in
                        row(step, isDone: done.contains(step))
                    }
                }
            }
        }
    }

    private func row(_ step: CalmGettingStartedStep, isDone: Bool) -> some View {
        HStack(spacing: 14) {
            CalmCheckCircle(isOn: isDone)
            CalmRowLabel(title: step.title) {
                CalmRowDescription(text: step.detail)
            }
            .opacity(isDone ? 0.6 : 1)
            if !isDone {
                Button(step.actionTitle) { open(step) }.calmButton(.secondary, size: .small)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, CalmMetrics.rowInset)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isDone ? "Done" : "Not done")
    }

    private func open(_ step: CalmGettingStartedStep) {
        switch step {
        case .dictate: navigator.openSettings(.general)
        case .pickModel:
            navigator.modelsTab = .speech
            navigator.openSettings(.models)
        case .addWord: navigator.show(.dictionary)
        case .smartCleanup: navigator.openSettings(.cleanup, target: "cleanup")
        }
    }
}
