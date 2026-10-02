import Foundation

/// An honest description of the processing choices for one destination.
struct OutputConfigurationSummary: Equatable {
    let format: String
    let cleanup: String
    let tone: String

    init(profile: WritingProfile, cleanupEnabled: Bool, rewritingEnabled: Bool, level: CleanupLevel) {
        guard profile.cleanup != .raw else {
            format = "Exactly as transcribed"
            cleanup = "All text transformations bypassed"
            tone = "As spoken"
            return
        }
        format = "\(profile.format.displayName) formatting"
        let effectiveLevel = profile.cleanupLevel ?? level
        if profile.cleanup == .off {
            cleanup = "Formatting only · AI cleanup off"
        } else if effectiveLevel == .none {
            cleanup = "Cleanup off · level None"
        } else if cleanupEnabled {
            cleanup = "\(effectiveLevel.displayName) cleanup"
        } else if effectiveLevel.removesHesitations {
            cleanup = "Basic filler/correction rules · AI cleanup off"
        } else {
            cleanup = "AI cleanup off"
        }
        let rewrites = cleanupEnabled && rewritingEnabled && effectiveLevel != .none && profile.allowsRewrite
        tone = rewrites && profile.intent != .preserve ? "\(profile.intent.displayName) tone · English only" : "As spoken"
    }

    var description: String { [format, cleanup, tone].joined(separator: " · ") }
}

/// Optional onboarding verification. An insertion check is confirmed by the
/// person using the destination app, never inferred from an injection request.
struct OnboardingVerification: Equatable {
    enum Mode { case shortcut, insertion }
    var mode: Mode?
    var microphoneWorks = false
    var shortcutDetected = false
    var shortcutDictationWorks = false
    var insertionAttempted = false
    var insertionConfirmed = false
}

extension AppState {
    var modelRecommendationPriority: SpeechModelPriority {
        get { SpeechModelPriority(rawValue: modelRecommendationPriorityStorage) ?? .balanced }
        set { modelRecommendationPriorityStorage = newValue.rawValue }
    }

    var speechModelRecommendation: OnboardingModelRecommendation? {
        OnboardingModelGuidance.recommendation(
            for: spokenLanguages, availableModels: availableModels,
            priority: modelRecommendationPriority, systemLanguages: appleSpeechLanguages
        )
    }

    /// Loaded engine wins over a preference while a replacement is loading.
    var speechProcessingIsRemote: Bool {
        (currentModel?.size ?? ModelSize(rawValue: selectedModelSize))?.isRemotelyHosted == true
    }

    var speechProcessingDescription: String {
        speechProcessingIsRemote ? "Audio sent to your endpoint" : "Processed on this Mac"
    }

    var cleanupProcessingDescription: String {
        cleanupEndpoint.isLocal ? "Text cleanup runs on this Mac" : "Text cleanup sends the prompt and transcript to your endpoint"
    }

    var nextOutputProfile: WritingProfile {
        nextWritingProfile ?? resolveWritingStyle(for: writingStyleTargetApp).profile
    }

    var nextOutputSummary: OutputConfigurationSummary { outputSummary(for: nextOutputProfile) }

    func outputSummary(for profile: WritingProfile) -> OutputConfigurationSummary {
        OutputConfigurationSummary(
            profile: profile, cleanupEnabled: transcriptCleanupEnabled,
            rewritingEnabled: writingRewriteEnabled, level: transcriptCleanupLevel
        )
    }

    var dictationReadinessTitle: String {
        if micPermission != .granted { return "Microphone access needed" }
        if inputMonitoringPermission != .granted { return "Shortcut access needed" }
        if accessibilityPermission != .granted { return "Text insertion access needed" }
        if availableModels.contains(where: { $0.isLoading || $0.downloadProgress != nil }) {
            return whisperService.isModelLoaded ? "Ready · preparing another model" : "Preparing speech model…"
        }
        if availableModels.isEmpty && !whisperService.isModelLoaded { return "Preparing speech model…" }
        if needsSpeechModel { return "Choose a speech model" }
        return "Ready"
    }

    var isDictationReady: Bool { dictationReadinessTitle == "Ready" || dictationReadinessTitle.hasPrefix("Ready ·") }

    var lastDictationText: String? {
        let text = (historyEnabled ? historyStore.latestDeliveredText : nil) ?? lastOutput?.text ?? heldOutput
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// The hardware shortcut uses the normal recording path. During an
    /// explicitly armed shortcut check its output stays inside onboarding.
    func startRecordingFromActivationShortcut() async {
        if onboardingVerification.mode == .shortcut {
            onboardingVerification.shortcutDetected = true
            await startRecording(injectResult: false, verifiesShortcut: true)
        } else {
            if onboardingVerification.mode == .insertion {
                onboardingVerification.shortcutDetected = true
            }
            await startRecording(verifiesShortcut: onboardingVerification.mode == .insertion)
        }
    }

    func armOnboardingVerification(_ mode: OnboardingVerification.Mode?) {
        onboardingVerification.mode = mode
        if mode == .insertion {
            onboardingVerification.insertionAttempted = false
            onboardingVerification.insertionConfirmed = false
        }
    }

    func confirmOnboardingInsertion() {
        guard onboardingVerification.insertionAttempted else { return }
        onboardingVerification.insertionConfirmed = true
        onboardingVerification.mode = nil
    }
}
