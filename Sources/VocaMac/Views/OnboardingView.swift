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
    case modelSetup = 2
    case hotkeyConfig = 3
    case quickTest = 4
    case complete = 5

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Speak freely. Write anywhere."
        case .permissions: return "Connect your voice to your Mac"
        case .modelSetup: return "Tune VocaMac to your voice"
        case .hotkeyConfig: return "One shortcut. Your flow."
        case .quickTest: return "Try your first dictation"
        case .complete: return "Make it part of your day"
        }
    }

    var shortTitle: String {
        switch self {
        case .welcome: return "Welcome"
        case .permissions: return "Permissions"
        case .modelSetup: return "Language & model"
        case .hotkeyConfig: return "Your shortcut"
        case .quickTest: return "Try it out"
        case .complete: return "Ready to go"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: return "Private voice typing that feels at home on macOS."
        case .permissions: return "Three permissions, each with a clear purpose."
        case .modelSetup: return "Tell us what you speak most; VocaMac will recommend a local model."
        case .hotkeyConfig: return "Choose the gesture that feels natural to you."
        case .quickTest: return "Record a sentence and see your words appear here."
        case .complete: return "VocaMac lives in your menu bar, ready when you need it."
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
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var practiceBusy = false

    var body: some View {
        HStack(spacing: 0) {
            journeySidebar
            Divider()
            VStack(spacing: 0) {
                VocaPageHeader(title: currentStep.title, subtitle: currentStep.subtitle)
                ScrollView {
                    Group {
                        switch currentStep {
                        case .welcome: WelcomeStep()
                        case .permissions: PermissionsStep()
                        case .modelSetup: ModelSetupStep()
                        case .hotkeyConfig: HotkeyConfigStep()
                        case .quickTest: QuickTestStep(isBusy: $practiceBusy)
                        case .complete: CompleteStep()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .id(currentStep)
                    .transition(.opacity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack(spacing: 12) {
                    if currentStep != .welcome {
                        Button("Back", action: goToPreviousStep)
                            .buttonStyle(.bordered)
                    }
                    if currentStep != .complete {
                        Button("Set up later", action: skipOnboarding)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("You can adjust permissions, language, models, and shortcuts later in Settings.")
                    }
                    Spacer()
                    Button(action: currentStep == .complete ? completeOnboarding : goToNextStep) {
                        HStack(spacing: 8) {
                            Text(primaryActionTitle)
                            Image(systemName: currentStep == .complete ? "checkmark" : "arrow.right")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(VocaDesign.accentSolid)
                    .keyboardShortcut(.defaultAction)
                }
                .disabled(practiceBusy || appState.isRecording || appState.appStatus == .processing)
                .padding(22)
            }
        }
        .frame(minWidth: 780, idealWidth: 840, minHeight: 600, idealHeight: 650)
        .background(VocaDesign.canvas)
        .tint(VocaDesign.accent)
        .onAppear {
            appState.triggerStartupIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.checkPermissions()
        }
    }

    private var primaryActionTitle: String {
        switch currentStep {
        case .welcome: return "Let's get started"
        case .quickTest: return "Continue"
        case .complete: return "Finish setup"
        default: return "Continue"
        }
    }

    private var journeySidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 10) {
                BrandLogoView(size: 36)
                Text("VocaMac").font(.title3.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("A little setup.\nA lot less typing.")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text("Make room for your voice.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 18) {
                ForEach(OnboardingStep.allCases) { step in
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(step == currentStep ? VocaDesign.accent : Color.primary.opacity(0.06))
                            if step.rawValue < currentStep.rawValue {
                                Image(systemName: "checkmark").foregroundStyle(VocaDesign.accent)
                            } else {
                                Text("\(step.rawValue + 1)")
                                    .foregroundStyle(step == currentStep ? Color(nsColor: .windowBackgroundColor) : .secondary)
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
                        Text(step.shortTitle)
                            .font(.callout.weight(step == currentStep ? .semibold : .regular))
                            .foregroundStyle(step == currentStep ? .primary : .secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(step.shortTitle), \(step == currentStep ? "current step" : step.rawValue < currentStep.rawValue ? "completed" : "upcoming")")
                }
            }
            Spacer()
            Label("Speech stays on this Mac", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 245)
        .frame(maxHeight: .infinity)
        .background(VocaSidebarMaterial())
    }

    // MARK: - Navigation

    private func goToNextStep() {
        if let nextStep = OnboardingStep(rawValue: currentStep.rawValue + 1) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                currentStep = nextStep
            }
        }
    }

    private func goToPreviousStep() {
        if let prevStep = OnboardingStep(rawValue: currentStep.rawValue - 1) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                currentStep = prevStep
            }
        }
    }

    private func skipOnboarding() {
        appState.completeOnboarding()
        onFinished()
    }

    private func completeOnboarding() {
        appState.completeOnboarding()
        onFinished()
    }
}

// MARK: - Step 1: Welcome

struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 18) {
                Label("FROM THOUGHT TO TEXT", systemImage: "waveform")
                    .font(.caption.weight(.semibold)).tracking(1.3)
                    .foregroundStyle(VocaDesign.accent)
                Text("“Let's turn that idea into something.”")
                    .font(.system(size: 27, weight: .medium, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack(spacing: 12) {
                    Label("Activate", systemImage: "keyboard")
                    Image(systemName: "arrow.right")
                    Label("Speak", systemImage: "mic")
                    Image(systemName: "arrow.right")
                    Label("Done", systemImage: "checkmark")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .vocaCard()
            welcomeFeature("Write where you work", detail: "Dictate into messages, documents, and text fields.", icon: "text.cursor")
            welcomeFeature("Your speech stays yours", detail: "Speech-to-text runs locally on your Mac.", icon: "lock.shield")
            welcomeFeature("Start small. Make it yours.", detail: "Tiny is included. Download other speech models later for more languages or accuracy.", icon: "slider.horizontal.3")
        }
        .padding(16)
    }

    private func welcomeFeature(_ title: String, detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(VocaDesign.accent)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Step 2: Permissions

/// What stops working for each permission still missing, in step order.
enum OnboardingPermissionGaps {
    static func consequences(
        microphone: PermissionStatus,
        accessibility: PermissionStatus,
        inputMonitoring: PermissionStatus
    ) -> [String] {
        var gaps: [String] = []
        if microphone != .granted {
            gaps.append("Without Microphone, VocaMac can't hear you, so dictation won't work.")
        }
        if accessibility != .granted {
            gaps.append("Without Accessibility, VocaMac can't type your words into other apps.")
        }
        if inputMonitoring != .granted {
            gaps.append("Without Input Monitoring, your shortcut won't start dictation.")
        }
        return gaps
    }
}

struct PermissionsStep: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
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
                    description: "Insert your words into the app you are using",
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

            let gaps = OnboardingPermissionGaps.consequences(
                microphone: appState.micPermission,
                accessibility: appState.accessibilityPermission,
                inputMonitoring: appState.inputMonitoringPermission
            )
            if !gaps.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(gaps, id: \.self) { gap in
                            Text(gap)
                        }
                        Text("You can continue now and enable these later in Settings.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .vocaCard()
                .accessibilityElement(children: .combine)
            }

            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(VocaDesign.accent)
                Text("After enabling VocaMac in System Settings → Privacy & Security, return here. Permission status refreshes automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .vocaCard()
        }
        .padding(16)
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
                    Label("Enabled", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(VocaDesign.accent)
                } else {
                    Button(action: action) {
                        Text(status == .notDetermined ? "Enable" : "Open Settings")
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(VocaDesign.accent)
                            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(VocaDesign.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(VocaDesign.line))
    }

    private var statusColor: Color {
        switch status {
        case .granted: return VocaDesign.accent
        case .denied: return .red
        case .notDetermined: return .secondary
        }
    }
}

// MARK: - Step 3: Language and Model

struct ModelSetupStep: View {
    @EnvironmentObject var appState: AppState
    @State private var didRequestRecommendation = false

    private var recommendation: OnboardingModelRecommendation? {
        OnboardingModelGuidance.recommendation(
            for: appState.selectedLanguage,
            availableModels: appState.availableModels
        )
    }

    private var recommendedModel: WhisperModelInfo? {
        guard let recommendation else { return nil }
        return appState.availableModels.first { $0.size == recommendation.model }
    }

    private var selectedLanguageName: String {
        TranscriptionLanguage.catalog.first { $0.code == appState.selectedLanguage }?.displayName
            ?? "your language"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Which language do you speak most?")
                    .font(.headline)
                Picker("Most-used language", selection: $appState.selectedLanguage) {
                    Text("I switch between languages").tag(TranscriptionLanguage.auto.code)
                    Divider()
                    ForEach(TranscriptionLanguage.selectable) { language in
                        Text(language.displayName).tag(language.code)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 300, alignment: .leading)

                Text(appState.selectedLanguage == TranscriptionLanguage.auto.code
                     ? "VocaMac will detect the language for each dictation."
                     : "Pinning \(selectedLanguageName) helps recognition avoid guessing the wrong language.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .vocaCard()

            if let recommendation, let model = recommendedModel {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.title3)
                            .foregroundStyle(VocaDesign.accent)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Recommended for you")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(VocaDesign.accent)
                            Text(recommendation.title)
                                .font(.headline)
                            Text(recommendation.explanation)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    HStack(spacing: 10) {
                        Label(model.size.displayName, systemImage: "waveform")
                        Text("•")
                        Text(model.size.fileSizeDescription)
                        Text("•")
                        Text("~\(String(format: "%.1f", model.size.ramRequiredGB)) GB RAM")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    modelAction(for: model)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .vocaCard()
            } else {
                Label("The bundled starter model will be used on this Mac.", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .vocaCard()
            }

            Text("This step is optional. Downloads continue in the background, and the recommended model is loaded automatically when it is ready.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .padding(16)
        .onChange(of: appState.selectedLanguage) {
            Task { @MainActor in
                await appState.onboardingLanguageDidChange()
            }
        }
    }

    @ViewBuilder
    private func modelAction(for model: WhisperModelInfo) -> some View {
        if model.isActive {
            Label("Ready to use", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(VocaDesign.success)
        } else if let progress = model.downloadProgress {
            HStack(spacing: 10) {
                ProgressView(value: progress)
                    .frame(maxWidth: 180)
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Cancel") {
                    appState.cancelOnboardingModelPreparation()
                }
                .controlSize(.small)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Downloading \(model.size.displayName)")
            .accessibilityValue("\(Int(progress * 100)) percent")
        } else if model.isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.loadingStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 10) {
                Button(model.isDownloaded ? "Use this model" : "Download & use") {
                    didRequestRecommendation = true
                    Task { @MainActor in
                        await appState.prepareOnboardingRecommendedModel()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(VocaDesign.accentSolid)
                .disabled(appState.isPreparingOnboardingModel)

                if didRequestRecommendation, let error = appState.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}


struct HotkeyConfigStep: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                // Activation Mode — the same control the Dictation settings
                // page uses, so the choice looks the same in both places.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Activation mode")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    ActivationModeSelector(selection: $appState.activationMode)
                }

                Divider()

                // Hotkey Selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Shortcut")
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
                        Text("Double-tap speed")
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .vocaCard()
        }
        .padding(16)
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
    @Binding var isBusy: Bool
    @State private var testResult: String?
    @State private var testFeedback: String?
    @State private var isPreparing = false
    private var isRecording: Bool { appState.isPracticeRecording }
    private var externalRecording: Bool {
        (appState.isRecording || appState.appStatus == .recording) && !appState.isPracticeRecording
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 16) {
                // Recording button
                Button(action: toggleRecording) {
                    VStack(spacing: 8) {
                        Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(isRecording ? Color.red : VocaDesign.accent)

                        Text(isRecording ? "Finish recording" : testFeedback != nil ? "Try again" : "Record a sentence")
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
                .buttonStyle(.plain)
                .padding(24)
                .disabled(isBusy || externalRecording || appState.appStatus == .processing)

                if externalRecording {
                    Text("Dictation is active in another app. Finish it with your shortcut before trying a practice recording.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let feedback = testFeedback ?? appState.errorMessage {
                    Label(feedback, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Test result display
                if let result = testResult {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(VocaDesign.accent)
                            Text("Transcription result")
                                .font(.caption)
                                .fontWeight(.semibold)
                        }

                        Text(result)
                            .font(.subheadline)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(VocaDesign.accent.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 8))

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
                        Text(isPreparing ? "Preparing your speech model…" : "Transcribing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .vocaCard()

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(VocaDesign.accent)
                Text("Try: “Today is a good day to try something new.” Use the button above; this practice stays here and is not pasted into another app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .padding(16)
        .onChange(of: appState.settingsTestResultText) { _, result in
            testResult = result
        }
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
                    } else if case .error(let message) = appState.transcriptCleanup.modelState {
                        // A failed download must not read as success. Onboarding
                        // is the one place the user cannot go and check.
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text("\(message) You can retry in Settings → Cleanup.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !appState.transcriptCleanup.isDownloaded(appState.selectedCleanupModelKind) {
                        ProgressView().controlSize(.small)
                        Text("Starting cleanup model download…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(VocaDesign.accent)
                        Text("Cleanup is on. You can carry on — it finishes in the background.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "wand.and.stars")
                        .font(.caption)
                        .foregroundStyle(VocaDesign.accent)
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
        guard !isBusy, !externalRecording else { return }
        isBusy = true
        Task { @MainActor in
            defer {
                isBusy = false
                isPreparing = false
            }
            testFeedback = nil
            if isRecording {
                await appState.stopRecordingAndTranscribe()
                testResult = appState.settingsTestResultText
                testFeedback = appState.errorMessage
                if testResult == nil && testFeedback == nil {
                    testFeedback = "No speech was detected. Try again and speak a little closer to your microphone."
                }
            } else {
                testResult = nil
                appState.settingsTestResultText = nil
                isPreparing = true
                if appState.appStatus == .error { appState.forceRecovery() }
                // Re-check after the Task hop: a hotkey may have started ordinary dictation.
                if (appState.isRecording || appState.appStatus == .recording) && !appState.isPracticeRecording {
                    testFeedback = "Dictation is active in another app. Finish it with your shortcut before trying a practice recording."
                    isPreparing = false
                } else if appState.isPracticeRecording || appState.appStatus != .idle || appState.isRecording {
                    isPreparing = false
                } else {
                    await appState.startRecording(injectResult: false)
                    if !isRecording { testFeedback = appState.errorMessage }
                }
            }
        }
    }
}

// MARK: - Step 6: Complete

struct CompleteStep: View {
    @EnvironmentObject var appState: AppState

    private var permissionsReady: Bool {
        appState.micPermission == .granted && appState.accessibilityPermission == .granted
            && appState.inputMonitoringPermission == .granted
    }

    var body: some View {
        // The wizard header already carries this step's title, so the panel
        // states the outcome once, on the same left margin as every other step.
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: permissionsReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 30))
                    .foregroundStyle(permissionsReady ? VocaDesign.accent : Color.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(permissionsReady ? "Your voice has a new home." : "Finish permissions to start.")
                        .font(.title3.weight(.semibold))
                    Text("Find the microphone in your menu bar.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            // Summary
            VStack(alignment: .leading, spacing: 12) {
                if appState.micPermission == .granted {
                    SummaryItem(icon: "mic.fill", text: "Microphone access enabled")
                } else {
                    Label("Microphone access still needed", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
                if appState.accessibilityPermission == .granted {
                    SummaryItem(icon: "hand.raised.fill", text: "Accessibility permission granted")
                } else {
                    Label("Accessibility access still needed", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
                if appState.inputMonitoringPermission == .granted {
                    SummaryItem(icon: "keyboard.fill", text: "Input monitoring enabled")
                } else {
                    Label("Input Monitoring access still needed", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
                SummaryItem(icon: "keyboard", text: "Hotkey: \(KeyCodeReference.displayName(for: HotKeyCombo(keyCode: appState.hotKeyCode, modifiers: appState.hotKeyModifiers)))")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .vocaCard()

            // Launch at Login option
            Toggle(isOn: Binding(
                get: { appState.launchAtLogin },
                set: { appState.setLaunchAtLogin($0) }
            )) {
                HStack(spacing: 10) {
                    Image(systemName: "sunrise.fill")
                        .foregroundStyle(VocaDesign.accent)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at Login")
                            .font(.subheadline)
                        Text("Start VocaMac automatically when you log in")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                }
            }
            .toggleStyle(.switch)
            .frame(maxWidth: .infinity, alignment: .leading)
            .vocaCard()

            if !appState.transcriptCleanupEnabled {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                        .font(.caption)
                        .foregroundStyle(VocaDesign.accent)
                    Text("Want “um” and “uh” removed automatically? Settings → Cleanup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("You can adjust settings anytime from the VocaMac menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }
}

struct SummaryItem: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(VocaDesign.accent)
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
    OnboardingView(onFinished: {})
        .environmentObject(AppState.production())
}
#endif
