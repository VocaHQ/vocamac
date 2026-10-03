// OnboardingVerificationView.swift
// VocaMac
//
// Optional checks at the end of onboarding: the real shortcut, and text
// reaching another app.

import SwiftUI

/// Safe shortcut practice first, then an optional user-confirmed insertion in
/// a blank document they choose. Neither check blocks finishing onboarding.
struct OnboardingVerificationView: View {
    @EnvironmentObject var appState: AppState
    var interactive = true

    private var verification: OnboardingVerification { appState.onboardingVerification }
    private var busy: Bool { appState.isRecording || appState.appStatus == .processing }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(interactive ? "Try it the way you'll use it" : "What you tested")
                .font(VocaDesign.display(19)).accessibilityAddTraits(.isHeader)
            check("Microphone", passed: verification.microphoneWorks,
                  done: "A recording produced text", pending: "Not tested yet")
            check("Shortcut", passed: verification.shortcutDictationWorks,
                  done: "Your shortcut started a dictation",
                  pending: verification.shortcutDetected ? "Shortcut detected. Finish the recording to complete the test." : "Not tested yet")
            check("Text insertion", passed: verification.insertionConfirmed,
                  done: "You confirmed your words appeared in another app", pending: "Not tested yet")

            if interactive {
                Divider()
                controls
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vocaCard()
    }

    @ViewBuilder
    private var controls: some View {
        switch verification.mode {
        case .shortcut:
            Text(shortcutInstructions + " The result stays here; nothing is typed into another app.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Button("Done Testing") { appState.armOnboardingVerification(nil) }
                .buttonStyle(VocaOutlineButtonStyle())
                .disabled(busy)
        case .insertion:
            Text("Click into a blank document in TextEdit or another app, then dictate with your shortcut. Come back here once your words appear.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("My Words Appeared") { appState.confirmOnboardingInsertion() }
                    .buttonStyle(VocaOutlineButtonStyle())
                    .disabled(!verification.insertionAttempted || busy)
                Button("Cancel") { appState.armOnboardingVerification(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(busy)
            }
        case nil:
            HStack {
                Button("Test My Shortcut") { appState.armOnboardingVerification(.shortcut) }
                    .buttonStyle(VocaOutlineButtonStyle())
                    .disabled(busy || appState.inputMonitoringPermission != .granted || appState.micPermission != .granted)
                Button("Test Typing Into an App") { appState.armOnboardingVerification(.insertion) }
                    .buttonStyle(VocaOutlineButtonStyle())
                    .disabled(busy || !appState.isDictationReady)
                Spacer()
                Text("Optional").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var shortcutInstructions: String {
        let keys = KeyCodeReference.displayName(for: HotKeyCombo(keyCode: appState.hotKeyCode, modifiers: appState.hotKeyModifiers))
        return appState.activationMode == .pushToTalk
            ? "Hold \(keys), speak, then release."
            : "Double-tap \(keys), speak, then double-tap again to finish."
    }

    private func check(_ title: String, passed: Bool, done: String, pending: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: passed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(passed ? VocaDesign.success : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(passed ? done : pending)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
