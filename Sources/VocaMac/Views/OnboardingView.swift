// OnboardingView.swift
// VocaMac
//
// Multi-step onboarding wizard for first-time users.
// Guides users through welcome, permissions, model selection, hotkey setup, and testing.

import SwiftUI

// MARK: - Onboarding Step Enum

/// Represents the current step in the onboarding flow
enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome = 0
    case permissions = 1
    case hotkeyConfig = 2
    case quickTest = 3
    case complete = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome to VocaMac"
        case .permissions: return "Grant Permissions"
        case .hotkeyConfig: return "Configure Hotkey"
        case .quickTest: return "Quick Test"
        case .complete: return "All Set!"
        }
    }

    var stepNumber: String {
        "Step \(rawValue + 1) of \(OnboardingStep.allCases.count)"
    }
}

// MARK: - OnboardingView

/// Main onboarding wizard container
struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @State private var currentStep: OnboardingStep = .welcome

    var body: some View {
        ZStack {
            // Background
            Color(nsColor: .controlBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Step indicator
                HStack {
                    Text(currentStep.stepNumber)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        ForEach(OnboardingStep.allCases, id: \.self) { step in
                            Circle()
                                .fill(step.rawValue <= currentStep.rawValue ? Color.blue : Color.gray.opacity(0.3))
                                .frame(width: 8, height: 8)
                        }
                    }
                }
                .padding()
                .borderBottom()

                // Step content (scrollable to handle varying content heights)
                ScrollView {
                    Group {
                        switch currentStep {
                        case .welcome:
                            WelcomeStep()
                        case .permissions:
                            PermissionsStep()
                        case .hotkeyConfig:
                            HotkeyConfigStep()
                        case .quickTest:
                            QuickTestStep()
                        case .complete:
                            CompleteStep()
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                // Navigation buttons
                HStack(spacing: 12) {
                    if currentStep == .welcome {
                        Button(action: skipOnboarding) {
                            Text("Skip Setup")
                                .font(.body)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.gray.opacity(0.2))
                                .foregroundStyle(.primary)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .help("Skip setup and don't show again. You can re-run it from Menu Bar → Setup Wizard.")
                    } else if currentStep != .complete {
                        Button(action: skipOnboarding) {
                            Text("Skip")
                                .font(.body)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Skip setup and don't show again.")
                    }
                    if currentStep != .welcome {
                        Button(action: goToPreviousStep) {
                            Text("Back")
                                .font(.body)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.gray.opacity(0.2))
                                .foregroundStyle(.primary)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                    }

                    Spacer()

                    if currentStep != .complete {
                        Button(action: goToNextStep) {
                            Text(currentStep == .quickTest ? "Finish" : "Continue")
                                .font(.body)
                                .fontWeight(.medium)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                .background(Color.blue)
                                .foregroundStyle(.white)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button(action: completeOnboarding) {
                            Text("Start Using VocaMac")
                                .font(.body)
                                .fontWeight(.medium)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                .background(Color.blue)
                                .foregroundStyle(.white)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding()
            }
        }
        .frame(width: 600, height: 550)
        .onAppear {
            Task { @MainActor in
                await appState.performStartup()
            }
        }
    }

    // MARK: - Navigation

    private func goToNextStep() {
        if let nextStep = OnboardingStep(rawValue: currentStep.rawValue + 1) {
            withAnimation(.easeInOut(duration: 0.3)) {
                currentStep = nextStep
            }
        }
    }

    private func goToPreviousStep() {
        if let prevStep = OnboardingStep(rawValue: currentStep.rawValue - 1) {
            withAnimation(.easeInOut(duration: 0.3)) {
                currentStep = prevStep
            }
        }
    }

    private func skipOnboarding() {
        appState.completeOnboarding()
    }

    private func completeOnboarding() {
        appState.completeOnboarding()
    }
}

// MARK: - Step 1: Welcome

struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            BrandLogoView(size: 80)

            // App name and tagline
            VStack(spacing: 8) {
                Text("VocaMac")
                    .font(.system(size: 40, weight: .bold))

                Text("Your voice, your Mac, your privacy")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            // Description
            VStack(alignment: .leading, spacing: 12) {
                Label("Dictate directly into any app", systemImage: "doc.text")
                Label("All processing happens on your Mac", systemImage: "lock.fill")
                Label("No internet required, no data leaves your device", systemImage: "network.slash")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)

            Spacer()

            Text("This guide will set up VocaMac in just a few minutes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding()
    }
}

// MARK: - Step 2: Permissions

struct PermissionsStep: View {
    @EnvironmentObject var appState: AppState

    private var allPermissionsGranted: Bool {
        appState.micPermission == .granted &&
        appState.accessibilityPermission == .granted &&
        appState.inputMonitoringPermission == .granted
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("VocaMac needs a few permissions to work properly.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

            VStack(spacing: 12) {
                OnboardingPermissionRow(
                    icon: "mic.fill",
                    name: "Microphone",
                    description: "Record audio for transcription",
                    status: appState.micPermission,
                    action: { appState.requestMicrophonePermission() }
                )

                OnboardingPermissionRow(
                    icon: "hand.raised.fill",
                    name: "Accessibility",
                    description: "Monitor hotkey presses to activate recording",
                    status: appState.accessibilityPermission,
                    action: { appState.requestAccessibilityPermission() }
                )

                OnboardingPermissionRow(
                    icon: "keyboard.fill",
                    name: "Input Monitoring",
                    description: "Detect keyboard and mouse input for activation",
                    status: appState.inputMonitoringPermission,
                    action: { appState.requestInputMonitoringPermission() }
                )
            }
            .padding()

            Spacer()

            if !allPermissionsGranted {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                    Text("Some permissions are missing. VocaMac may not work correctly until all permissions are granted. You can set them later in Settings → Debug.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.yellow.opacity(0.05))
                .cornerRadius(8)
                .padding(.horizontal)
            }

            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text("You can grant these permissions in System Settings > Privacy & Security.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.blue.opacity(0.05))
            .cornerRadius(8)
            .padding(.horizontal)

            Spacer()
        }
        .padding()
    }
}

// MARK: - Onboarding Permission Row

struct OnboardingPermissionRow: View {
    let icon: String
    let name: String
    let description: String
    let status: PermissionStatus
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .frame(width: 32)
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                    .fontWeight(.medium)

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                if status == .granted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.green)
                } else {
                    Button(action: action) {
                        Text(status == .notDetermined ? "Grant" : "Open Settings")
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue)
                            .foregroundStyle(.white)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
    }

    private var statusColor: Color {
        switch status {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined: return .gray
        }
    }
}


struct HotkeyConfigStep: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            Text("Choose how to activate VocaMac.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

            VStack(spacing: 16) {
                // Activation Mode
                VStack(alignment: .leading, spacing: 8) {
                    Text("Activation Mode")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    Picker("Mode", selection: $appState.activationMode) {
                        ForEach(ActivationMode.allCases) { mode in
                            VStack(alignment: .leading) {
                                Text(mode.displayName)
                            }
                            .tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    Text(appState.activationMode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Hotkey Selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hotkey")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    HotKeySelectionControl(
                        pickerLabel: "Key",
                        footerText: "VocaMac reserves this key while running."
                    )
                }

                if appState.activationMode == .doubleTapToggle {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Double-tap Speed")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)

                        HStack {
                            Slider(
                                value: $appState.doubleTapThreshold,
                                in: 0.2...0.8,
                                step: 0.05,
                                onEditingChanged: { isEditing in
                                    if !isEditing {
                                        appState.syncHotKeyConfiguration()
                                    }
                                }
                            )
                            Text("\(String(format: "%.2f", appState.doubleTapThreshold))s")
                                .monospacedDigit()
                                .frame(width: 40)
                        }

                        Text("How fast you need to double-tap.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .background(Color.gray.opacity(0.05))
            .cornerRadius(8)

            Spacer()
        }
        .padding()
        // Keep the live listener aligned with wizard fields.
        // Completion syncs the full persisted config.
        .onChange(of: appState.activationMode) {
            appState.syncHotKeyConfiguration()
        }
        .onChange(of: appState.hotKeyCode) {
            appState.syncHotKeyConfiguration()
        }
        .onChange(of: appState.hotKeyModifiers) {
            appState.syncHotKeyConfiguration()
        }
    }
}

// MARK: - Step 5: Quick Test

struct QuickTestStep: View {
    @EnvironmentObject var appState: AppState
    @State private var isRecording = false
    @State private var testResult: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Let's test your setup with a quick recording.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

            Spacer()

            VStack(spacing: 16) {
                // Recording button
                Button(action: toggleRecording) {
                    VStack(spacing: 8) {
                        Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(isRecording ? .red : .blue)

                        Text(isRecording ? "Recording..." : "Click to Record")
                            .font(.body)
                            .fontWeight(.semibold)

                        if isRecording {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 8)
                                    .scaleEffect(1.2)

                                Text("Recording audio...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .disabled(appState.appStatus == .processing)

                // Test result display
                if let result = testResult {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Transcription Result")
                                .font(.caption)
                                .fontWeight(.semibold)
                        }

                        Text(result)
                            .font(.subheadline)
                            .lineLimit(4)
                            .padding()
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(6)

                        // Only offered when the transcript actually shows the
                        // problem. A clean first dictation is no argument for
                        // downloading a model.
                        if TranscriptCleanup.containsFillers(result) {
                            cleanupOffer
                        }
                    }
                } else if appState.appStatus == .processing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8, anchor: .center)
                        Text("Transcribing...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.gray.opacity(0.05))
            .cornerRadius(8)

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text("Try saying a short phrase like 'Hello world'.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding()
    }

    /// Optional, inline, and never blocking: the download runs in the
    /// background and onboarding continues regardless.
    @ViewBuilder
    private var cleanupOffer: some View {
        let descriptor = appState.selectedCleanupModelKind.descriptor

        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if appState.transcriptCleanupEnabled {
                HStack(spacing: 8) {
                    if case .downloading(_, let progress) = appState.transcriptCleanup.modelState {
                        ProgressView(value: progress).frame(width: 60)
                        Text("Downloading cleanup model — \(Int(progress * 100))%")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Text("Cleanup is on. You can carry on — it finishes in the background.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "wand.and.stars")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notice the filler words?")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text("VocaMac can drop “um” and “uh” and punctuate what you said, all on this Mac. Downloads \(descriptor.sizeDescription) in the background — you can set it up later in Settings → Cleanup instead.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Button("Set Up") {
                        appState.startCleanupSetupInBackground()
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.top, 2)
    }

    private func toggleRecording() {
        if isRecording {
            Task { @MainActor in
                await appState.stopRecordingAndTranscribe()
                isRecording = false
                testResult = appState.lastTranscription?.text
            }
        } else {
            Task { @MainActor in
                testResult = nil
                await appState.startRecording()
                isRecording = appState.appStatus == .recording || appState.isRecording
            }
        }
    }
}

// MARK: - Step 6: Complete

struct CompleteStep: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Success icon
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)

            // Heading
            VStack(spacing: 8) {
                Text("You're All Set!")
                    .font(.title)
                    .fontWeight(.bold)

                Text("VocaMac is ready to use")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            // Summary
            VStack(alignment: .leading, spacing: 12) {
                SummaryItem(icon: "mic.fill", text: "Microphone access enabled")
                if appState.accessibilityPermission == .granted {
                    SummaryItem(icon: "hand.raised.fill", text: "Accessibility permission granted")
                }
                if appState.inputMonitoringPermission == .granted {
                    SummaryItem(icon: "keyboard.fill", text: "Input monitoring enabled")
                }
                SummaryItem(icon: "keyboard", text: "Hotkey: \(KeyCodeReference.displayName(for: HotKeyCombo(keyCode: appState.hotKeyCode, modifiers: appState.hotKeyModifiers)))")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.green.opacity(0.05))
            .cornerRadius(8)

            // Launch at Login option
            Toggle(isOn: Binding(
                get: { appState.launchAtLogin },
                set: { appState.setLaunchAtLogin($0) }
            )) {
                HStack(spacing: 10) {
                    Image(systemName: "sunrise.fill")
                        .foregroundStyle(.orange)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at Login")
                            .font(.subheadline)
                        Text("Start VocaMac automatically when you log in")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding()
            .background(Color.blue.opacity(0.05))
            .cornerRadius(8)

            if !appState.transcriptCleanupEnabled {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Text("Want “um” and “uh” removed automatically? Settings → Cleanup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

            Text("You can adjust settings anytime from the VocaMac menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding()
    }
}

struct SummaryItem: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.green)
                .frame(width: 20)

            Text(text)
                .font(.subheadline)

            Spacer()
        }
    }
}

// MARK: - Helpers

extension View {
    func borderBottom() -> some View {
        VStack(spacing: 0) {
            self
            Divider()
        }
    }
}

#if DEBUG
#Preview {
    OnboardingView()
        .environmentObject(AppState.production())
}
#endif
