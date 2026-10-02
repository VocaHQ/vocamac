import SwiftUI

/// Safe shortcut practice first, then an optional user-confirmed insertion in
/// a blank document they choose. Neither check blocks finishing onboarding.
struct OnboardingVerificationView: View {
    @EnvironmentObject var appState: AppState
    var interactive = true

    private var busy: Bool { appState.isRecording || appState.appStatus == .processing }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check your everyday workflow").font(.headline).accessibilityAddTraits(.isHeader)
            check("Microphone", passed: appState.onboardingVerification.microphoneWorks,
                  detail: "Not tested yet")
            check("Shortcut", passed: appState.onboardingVerification.shortcutDictationWorks,
                  detail: appState.onboardingVerification.shortcutDetected ? "Shortcut detected; finish a recording to check transcription" : "Not tested yet")
            check("Text insertion", passed: appState.onboardingVerification.insertionConfirmed,
                  detail: appState.onboardingVerification.insertionConfirmed ? "Confirmed by you in another app" : "Not confirmed yet")

            if interactive {
                if appState.onboardingVerification.mode == .shortcut {
                    Text(shortcutInstructions + " This test stays here and won't type into another app.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Button("End Shortcut Test") { appState.armOnboardingVerification(nil) }
                        .disabled(busy)
                } else if appState.onboardingVerification.mode == .insertion {
                    Text("Open a blank document in TextEdit or another app, click in it, then use your shortcut to dictate. Return here after your words appear.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text("This check types into the app you choose. " + appState.speechProcessingDescription + ".")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("My Words Appeared") { appState.confirmOnboardingInsertion() }
                            .disabled(!appState.onboardingVerification.insertionAttempted || busy)
                        Button("End Insertion Check") { appState.armOnboardingVerification(nil) }
                            .disabled(busy)
                    }
                } else {
                    HStack {
                        Button("Test My Shortcut") { appState.armOnboardingVerification(.shortcut) }
                            .disabled(busy || appState.inputMonitoringPermission != .granted || appState.micPermission != .granted)
                        Button("Try Text Insertion") { appState.armOnboardingVerification(.insertion) }
                            .disabled(busy || !appState.isDictationReady)
                    }
                    Text("Optional. You can finish setup without these checks.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vocaCard()
    }

    private var shortcutInstructions: String {
        let keys = KeyCodeReference.displayName(for: HotKeyCombo(keyCode: appState.hotKeyCode, modifiers: appState.hotKeyModifiers))
        return appState.activationMode == .pushToTalk
            ? "Hold \(keys), speak, then release."
            : "Double-tap \(keys), speak, then double-tap again to finish."
    }

    private func check(_ title: String, passed: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: passed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(passed ? VocaDesign.success : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(passed && title != "Text insertion" ? "Tested successfully" : detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
