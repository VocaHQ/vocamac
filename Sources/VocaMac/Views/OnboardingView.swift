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
        case .permissions: return "Connect your voice to your Mac."
        case .modelSetup: return "Tune VocaMac to your voice."
        case .hotkeyConfig: return "One shortcut. Your flow."
        case .quickTest: return "Try your first dictation."
        case .complete: return "Make it part of your day."
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
        case .modelSetup: return "Tell us what you speak; VocaMac will recommend a local model."
        case .hotkeyConfig: return "Choose the gesture that feels natural to you."
        case .quickTest: return "Record a sentence, then optionally check your shortcut and text insertion."
        case .complete: return "VocaMac lives in your menu bar, ready when you need it."
        }
    }

    var stepNumber: String {
        "Step \(rawValue + 1) of \(OnboardingStep.allCases.count)"
    }

    /// The scene behind the step. Setup runs from dawn to night, so moving
    /// through it reads as a day passing.
    var mood: SceneMood {
        switch self {
        case .welcome: return .dawn
        case .permissions, .modelSetup: return .day
        case .hotkeyConfig, .quickTest: return .dusk
        case .complete: return .night
        }
    }

    /// The caption at the foot of the scene, e.g. "01 — Welcome".
    var sceneCaption: String {
        String(format: "%02d — ", rawValue + 1) + shortTitle
    }

    /// The saved step unfinished onboarding reopens on; see
    /// `AppState.onboardingStartStep`.
    static func resumeStep(defaults: UserDefaults = .standard) -> OnboardingStep {
        guard defaults.object(forKey: PreferenceKey.onboardingResumeStep) != nil else { return .welcome }
        return OnboardingStep(rawValue: defaults.integer(forKey: PreferenceKey.onboardingResumeStep)) ?? .welcome
    }

    /// Keep the final escape hatch available while optional background work finishes.
    func disablesNavigation(
        practiceBusy: Bool,
        isRecording: Bool,
        appStatus: AppStatus
    ) -> Bool {
        guard self != .complete else { return false }
        return practiceBusy || isRecording || appStatus == .processing
    }
}

// MARK: - OnboardingView

/// Main onboarding wizard container: a painted scene on the left that changes
/// with the time of day as setup moves on, and the step itself on paper to
/// the right.
struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @State private var currentStep: OnboardingStep = .welcome
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var practiceBusy = false
    @State private var didBeginVerification = false
    /// The opening: the scene fills the window behind the name, then draws
    /// back to the side to make room for the first step.
    @State private var introExpanded = true
    @State private var introDone = false

    static let sceneWidth: CGFloat = 380

    /// `initialStep` reopens unfinished onboarding where it was left, and
    /// lets previews open on a later step. The opening plays only on Welcome.
    init(initialStep: OnboardingStep = .welcome, onFinished: @escaping () -> Void) {
        _currentStep = State(initialValue: initialStep)
        _introExpanded = State(initialValue: initialStep == .welcome)
        _introDone = State(initialValue: initialStep != .welcome)
        self.onFinished = onFinished
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                stepColumn
                    .padding(.leading, Self.sceneWidth)
                    .opacity(introDone ? 1 : 0)
                    // Hidden during the opening, so Return can't advance a
                    // step nobody has seen yet.
                    .disabled(!introDone)
                scenePanel
                    .frame(width: introExpanded ? geometry.size.width : Self.sceneWidth)
                    .frame(maxHeight: .infinity)
                    .clipped()
            }
        }
        .ignoresSafeArea()
        .frame(minWidth: 880, idealWidth: 960, minHeight: 600, idealHeight: 640)
        .vocaPaperBackground()
        .tint(VocaDesign.accent)
        .onAppear {
            appState.setOnboardingOpen(true)
            if !didBeginVerification {
                appState.onboardingVerification = OnboardingVerification()
                didBeginVerification = true
            }
            appState.triggerStartupIfNeeded()
            playIntro()
        }
        .onDisappear {
            appState.armOnboardingVerification(nil)
            appState.setOnboardingOpen(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.checkPermissions()
        }
        .onChange(of: currentStep) {
            appState.recordOnboardingStep(currentStep)
        }
    }

    // MARK: - Scene

    private var scenePanel: some View {
        ZStack(alignment: .topLeading) {
            ZStack {
                VocaScene(mood: currentStep.mood)
                    .id(currentStep.mood)
                    .transition(.opacity)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.2), value: currentStep.mood)

            if introExpanded {
                VStack(spacing: 10) {
                    Text("VocaMac")
                        .font(VocaDesign.display(88))
                        .riseIn(delay: 0.15, distance: 10)
                    Text("SPEAK · WRITE · ANYWHERE")
                        .font(.system(size: 13, weight: .medium))
                        .tracking(3)
                        .opacity(0.85)
                        .riseIn(delay: 0.45, distance: 6)
                }
                .foregroundStyle(Color(nsColor: VocaPalette.ivory))
                .shadow(color: .black.opacity(0.3), radius: 18)
                // Up in the sky, clear of the waveform over the lake.
                .padding(.bottom, 200)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 1.04)))
            }

            if introDone {
                sceneText
                    .id(currentStep)
                    .frame(width: Self.sceneWidth, alignment: .leading)
            }
        }
    }

    private var sceneText: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                VocaMarkView(size: 20)
                Text("VocaMac")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(1)
            }
            .riseIn(delay: 0.05, distance: 8)
            RevealHeadline(text: currentStep.title, size: 44, delay: 0.15)
            if currentStep == .welcome {
                Text("Private voice typing that lives in your menu bar.")
                    .font(.system(size: 14))
                    .opacity(0.9)
                    .riseIn(delay: 0.6)
            }
            Spacer(minLength: 0)
            Text(currentStep.sceneCaption)
                .font(.system(size: 12))
                .tracking(0.7)
                .opacity(0.85)
                .riseIn(delay: 0.5, distance: 6)
            Label(appState.speechProcessingDescription, systemImage: appState.speechProcessingIsRemote ? "network" : "lock.shield")
                .font(.caption)
                .opacity(0.8)
                .riseIn(delay: 0.6, distance: 6)
        }
        .foregroundStyle(Color(nsColor: VocaPalette.ivory))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 1)
        .padding(.horizontal, 32)
        .padding(.top, 56)
        .padding(.bottom, 26)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Step

    private var stepColumn: some View {
        VStack(spacing: 0) {
            ScrollView {
                if introDone {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(currentStep.shortTitle.uppercased())
                                .font(VocaDesign.eyebrow)
                                .tracking(1.6)
                                .foregroundStyle(VocaDesign.accent)
                                .riseIn(delay: 0.1)
                            Text(currentStep.subtitle)
                                .font(VocaDesign.display(30))
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                                .riseIn(delay: 0.18)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)

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
                        .riseIn(delay: 0.3, distance: 20)
                        // Paper outline buttons wherever a step didn't pick a style.
                        .buttonStyle(VocaOutlineButtonStyle())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.top, 48)
                    .id(currentStep)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollContentBackground(.hidden)

            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if currentStep != .welcome {
                Button("Back", action: goToPreviousStep)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            if currentStep != .complete {
                Button("Set up later", action: skipOnboarding)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("You can adjust permissions, language, models, and shortcuts later in Settings.")
            }
            Spacer()
            VocaStepProgress(count: OnboardingStep.allCases.count, current: currentStep.rawValue)
            Button(action: currentStep == .complete ? completeOnboarding : goToNextStep) {
                VocaArrowLabel(
                    title: primaryActionTitle,
                    systemImage: currentStep == .complete ? "checkmark" : "arrow.right"
                )
            }
            .buttonStyle(VocaPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .font(.system(size: 13.5))
        .disabled(currentStep.disablesNavigation(
            practiceBusy: practiceBusy,
            isRecording: appState.isRecording,
            appStatus: appState.appStatus
        ))
        .padding(.horizontal, 44)
        .padding(.vertical, 22)
    }

    private var primaryActionTitle: String {
        switch currentStep {
        case .welcome: return "Let's get started"
        case .quickTest: return "Continue"
        case .complete: return "Finish setup"
        default: return "Continue"
        }
    }

    // MARK: - Navigation

    /// Holds the name over the full scene for a moment, then opens the
    /// window onto the first step. Under Reduce Motion it starts there.
    private func playIntro() {
        guard !introDone else { return }
        guard !reduceMotion else {
            introExpanded = false
            introDone = true
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.timingCurve(0.75, 0, 0.2, 1, duration: 1.3)) {
                introExpanded = false
            }
            try? await Task.sleep(for: .seconds(0.7))
            introDone = true
        }
    }

    private func goToNextStep() {
        if let nextStep = OnboardingStep(rawValue: currentStep.rawValue + 1) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                currentStep = nextStep
            }
        }
    }

    private func goToPreviousStep() {
        if let prevStep = OnboardingStep(rawValue: currentStep.rawValue - 1) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                currentStep = prevStep
            }
        }
    }

    private func skipOnboarding() {
        completeOnboarding()
    }

    private func completeOnboarding() {
        appState.completeOnboarding()
        onFinished()
    }
}

// MARK: - Step 1: Welcome

struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("“Let's turn that idea into something.”")
                    .font(VocaDesign.display(24))
                    .fixedSize(horizontal: false, vertical: true)
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
            .padding(.bottom, 10)

            welcomeFeature("Write where you work", detail: "Dictate into messages, documents, and text fields.", icon: "text.cursor")
                .riseIn(delay: 0.45)
            welcomeFeature("Your speech stays yours", detail: "Speech-to-text runs on this Mac unless you choose a Custom Endpoint.", icon: "lock.shield")
                .riseIn(delay: 0.55)
            welcomeFeature("Start small. Make it yours.", detail: "Tiny is included. Download other speech models later for more languages or accuracy.", icon: "slider.horizontal.3")
                .riseIn(delay: 0.65)
        }
        .padding(16)
    }

    private func welcomeFeature(_ title: String, detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 17, weight: .light)).foregroundStyle(VocaDesign.accent)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 13)
        .overlay(alignment: .top) { Rectangle().fill(VocaDesign.line).frame(height: 1) }
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
                .riseIn(delay: 0.4)

                OnboardingPermissionRow(
                    icon: "hand.raised.fill",
                    name: "Accessibility",
                    description: "Insert your words into the app you are using",
                    status: appState.accessibilityPermission,
                    action: { appState.requestAccessibilityPermission() }
                )
                .riseIn(delay: 0.5)

                OnboardingPermissionRow(
                    icon: "keyboard.fill",
                    name: "Input Monitoring",
                    description: "Detect keyboard and mouse input for activation",
                    status: appState.inputMonitoringPermission,
                    action: { appState.requestInputMonitoringPermission() }
                )
                .riseIn(delay: 0.6)
            }

            let gaps = OnboardingPermissionGaps.consequences(
                microphone: appState.micPermission,
                accessibility: appState.accessibilityPermission,
                inputMonitoring: appState.inputMonitoringPermission
            )
            if !gaps.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(VocaDesign.clay)
                        .frame(width: 7, height: 7)
                        .padding(.top, 4)
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

            if appState.permissionsMayNeedRelaunch {
                PermissionHelpCard()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Text("After enabling VocaMac in System Settings → Privacy & Security, return here. Permission status refreshes automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .riseIn(delay: 0.7)
        }
        .padding(16)
    }
}

// MARK: - Permission Help

/// Help for a permission that won't come on: drag VocaMac into the list
/// when it isn't there, and quit and reopen when it is on but still reads as
/// off. macOS applies Input Monitoring, and sometimes Accessibility, only to
/// a process started after the grant.
struct PermissionHelpCard: View {
    @EnvironmentObject var appState: AppState
    @State private var relaunchFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Every permission is on and only the hotkey waits on a reopen,
            // so the list already has VocaMac in it.
            if appState.permissionsAwaitingGrant {
                dragToAddRow
                Divider()
            }
            relaunchRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vocaCard()
        .accessibilityElement(children: .contain)
    }

    private var dragToAddRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable()
                .frame(width: 34, height: 34)
                .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                .help("Drag into the Accessibility or Input Monitoring list in System Settings")
                .accessibilityLabel("VocaMac app icon")
                .accessibilityHint("Drag into the list in System Settings")

            VStack(alignment: .leading, spacing: 2) {
                Text("Don't see VocaMac in the list?")
                    .font(.system(size: 13.5, weight: .semibold))
                Text("Drag this icon into the list in System Settings, then switch it on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var relaunchRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(VocaDesign.accent)
                .frame(width: 34, height: 34)
                .background(VocaDesign.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(appState.permissionsAwaitingGrant ? "Turned VocaMac on, but it still shows as off?" : "One more step for your shortcut")
                    .font(.system(size: 13.5, weight: .semibold))
                Text(appState.permissionsAwaitingGrant
                     ? "macOS can wait to apply Accessibility and Input Monitoring until VocaMac reopens."
                     : "Every permission is on, but macOS hasn't connected your shortcut yet. Reopening VocaMac fixes this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button {
                        relaunchFailed = !AppRelauncher.relaunch()
                    } label: {
                        Label("Quit & Reopen", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(VocaOutlineButtonStyle())

                    Text(relaunchFailed
                         ? "VocaMac couldn't reopen itself. Quit it from the menu bar and open it again."
                         : "Setup picks up right here.")
                        .font(.caption)
                        .foregroundStyle(relaunchFailed ? VocaDesign.warning : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            }
        }
    }
}

// MARK: - Onboarding Permission Row

struct OnboardingPermissionRow: View {
    let icon: String
    let name: String
    let description: String
    let status: PermissionStatus
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(statusColor)
                .frame(width: 36, height: 36)
                .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13.5, weight: .semibold))

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            ZStack(alignment: .trailing) {
                if status == .granted {
                    Label("Allowed", systemImage: "checkmark")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(VocaDesign.accent)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else {
                    Button(status == .notDetermined ? "Allow…" : "Open Settings", action: action)
                        .buttonStyle(VocaOutlineButtonStyle())
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.6), value: status)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(VocaDesign.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(VocaDesign.line))
    }

    private var statusColor: Color {
        switch status {
        case .granted, .notDetermined: return VocaDesign.accent
        case .denied: return VocaDesign.warning
        }
    }
}

// MARK: - Step 3: Language and Model

struct ModelSetupStep: View {
    @EnvironmentObject var appState: AppState
    @State private var didRequestRecommendation = false

    private var recommendation: OnboardingModelRecommendation? {
        appState.speechModelRecommendation
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
            // One question. The recognition language follows from the
            // answer, and the finer choices wait in Settings → Speech Model.
            VStack(alignment: .leading, spacing: 10) {
                Text("Which languages do you speak?")
                    .font(.system(size: 13.5, weight: .semibold))
                SpokenLanguagesField(languages: Binding(
                    get: { appState.spokenLanguages },
                    set: { appState.setOnboardingSpokenLanguages($0) }
                ))
                Text(appState.selectedLanguage == TranscriptionLanguage.auto.code
                     ? "VocaMac works out which language you're speaking each time you dictate."
                     : "VocaMac listens for \(selectedLanguageName). Add another language if you switch between them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .vocaCard()

            if let recommendation, let model = recommendedModel {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("RECOMMENDED FOR YOU")
                                .font(VocaDesign.eyebrow)
                                .tracking(1.2)
                                .foregroundStyle(VocaDesign.accent)
                            Text(recommendation.title)
                                .font(VocaDesign.display(22))
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
                Label("No single model on this Mac understands all of these languages. Remove one, or pick a model later in Settings → Speech Model.", systemImage: "info.circle")
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
                await appState.languageDidChange()
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
                // Only onboarding's own download is ours to cancel; the same
                // model may be downloading because Settings asked for it.
                if appState.isPreparingOnboardingModel {
                    Button("Cancel") {
                        appState.cancelOnboardingModelPreparation()
                    }
                    .controlSize(.small)
                }
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
            .help(model.loadingStatus == ModelSize.firstLoadStatus ? ModelSize.firstLoadExplanation : "")
        } else {
            HStack(spacing: 10) {
                Button(model.isDownloaded ? "Use this model" : "Download & Use") {
                    didRequestRecommendation = true
                    Task { @MainActor in
                        await appState.prepareOnboardingRecommendedModel()
                    }
                }
                .buttonStyle(VocaOutlineButtonStyle())
                .disabled(appState.isPreparingOnboardingModel)

                if didRequestRecommendation, let error = appState.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(VocaDesign.warning)
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
                    Text("ACTIVATION MODE")
                        .font(VocaDesign.eyebrow)
                        .tracking(1.2)
                        .foregroundStyle(.secondary)

                    ActivationModeSelector(selection: $appState.activationMode)
                }

                Divider()

                // Hotkey Selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("SHORTCUT")
                        .font(VocaDesign.eyebrow)
                        .tracking(1.2)
                        .foregroundStyle(.secondary)

                    HotKeySelectionControl(
                        pickerLabel: "Key",
                        footerText: "VocaMac reserves this key while running."
                    )
                }

                if appState.activationMode == .doubleTapToggle {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("DOUBLE-TAP SPEED")
                            .font(VocaDesign.eyebrow)
                            .tracking(1.2)
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
                // Recording button: an ink disc that turns clay and breathes
                // while it listens.
                Button(action: toggleRecording) {
                    VStack(spacing: 12) {
                        RecordDisc(isRecording: isRecording)
                        Text(isRecording ? "Finish recording" : testFeedback != nil ? "Try again" : "Record a sentence")
                            .font(.system(size: 13.5, weight: .semibold))
                        if isRecording {
                            Text("Listening…")
                                .font(VocaDesign.display(15))
                                .foregroundStyle(.secondary)
                                .transition(.opacity)
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

                        Text("“\(result)”")
                            .font(VocaDesign.display(18))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))

                        // Only offered when the transcript actually shows the
                        // problem. A clean first dictation is no argument for
                        // downloading a model.
                        if TranscriptCleanup.containsFillers(result), appState.cleanupEndpoint.isLocal {
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

            OnboardingVerificationView()

            HStack(alignment: .top, spacing: 8) {
                Text("Try: “Today is a good day to try something new.” Use the button above; this practice stays here and is not pasted into another app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .padding(16)
        .onDisappear { appState.armOnboardingVerification(nil) }
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
                            .foregroundStyle(VocaDesign.warning)
                        Text("\(message) You can retry in Settings → Smart Cleanup.")
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
                        Text("VocaMac can drop “um” and “uh” and punctuate what you said, all on this Mac. Downloads \(descriptor.sizeDescription) in the background — you can set it up later in Settings → Smart Cleanup instead.")
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

/// The practice record button.
private struct RecordDisc: View {
    let isRecording: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        ZStack {
            Circle()
                .fill(VocaDesign.clay.opacity(0.18))
                .frame(width: 92, height: 92)
                .scaleEffect(isRecording && breathe ? 1.12 : 0.8)
                .opacity(isRecording ? 1 : 0)
            Circle()
                .fill(isRecording ? VocaDesign.clay : VocaDesign.ink)
                .frame(width: 68, height: 68)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(isRecording ? Color.white : VocaDesign.onInk)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 96, height: 96)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: isRecording)
        .onChange(of: isRecording) { _, recording in
            guard recording, !reduceMotion else {
                breathe = false
                return
            }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
        .accessibilityHidden(true)
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
                    .foregroundStyle(permissionsReady ? VocaDesign.accent : VocaDesign.warning)
                VStack(alignment: .leading, spacing: 3) {
                    Text(permissionsReady ? "Your voice has a new home." : "Finish permissions to start.")
                        .font(VocaDesign.display(22))
                    Text("Find the waveform in your menu bar.")
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
                        .foregroundStyle(VocaDesign.warning)
                }
                if appState.accessibilityPermission == .granted {
                    SummaryItem(icon: "hand.raised.fill", text: "Accessibility permission granted")
                } else {
                    Label("Accessibility access still needed", systemImage: "exclamationmark.circle")
                        .foregroundStyle(VocaDesign.warning)
                }
                if appState.inputMonitoringPermission == .granted {
                    SummaryItem(icon: "keyboard.fill", text: "Input monitoring enabled")
                } else {
                    Label("Input Monitoring access still needed", systemImage: "exclamationmark.circle")
                        .foregroundStyle(VocaDesign.warning)
                }
                SummaryItem(icon: "keyboard", text: "Hotkey: \(KeyCodeReference.displayName(for: HotKeyCombo(keyCode: appState.hotKeyCode, modifiers: appState.hotKeyModifiers)))")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .vocaCard()

            // Three empty circles on the last screen would read as failure.
            if appState.onboardingVerification.microphoneWorks {
                OnboardingVerificationView(interactive: false)
            }

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
                    Text("Want “um” and “uh” removed automatically? Settings → Smart Cleanup.")
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
