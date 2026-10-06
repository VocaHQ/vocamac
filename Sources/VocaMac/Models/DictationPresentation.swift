// DictationPresentation.swift
// VocaMac
//
// What the UI says about a dictation before it happens: whether it can
// start, where it is processed, and what will be done to the words.

import Foundation

/// What one dictation into one destination gets, in the words Settings uses.
struct OutputConfigurationSummary: Equatable {
    let format: String
    /// Nil when the transcript is typed exactly as transcribed.
    let cleanup: String?
    /// Nil when the wording is left as spoken.
    let tone: String?

    /// - Parameter recognitionLanguage: The language dictation is pinned to,
    ///   or "auto". Tone rewrites English only, so the summary must not
    ///   promise one for a dictation that cannot be English.
    init(
        profile: WritingProfile, cleanupEnabled: Bool, rewritingEnabled: Bool, level: CleanupLevel,
        recognitionLanguage: String = TranscriptionLanguage.auto.code
    ) {
        guard profile.cleanup != .raw else {
            format = "Exactly as transcribed"
            cleanup = nil
            tone = nil
            return
        }
        format = "\(profile.format.displayName) format"
        let effectiveLevel = profile.cleanupLevel ?? level
        let cleans = profile.cleanup == .inherit && effectiveLevel != .none
        if cleans, cleanupEnabled {
            cleanup = "\(effectiveLevel.displayName) cleanup"
        } else if cleans, effectiveLevel.removesHesitations {
            // "Um", "uh" and spoken corrections go without the model.
            cleanup = "Fillers removed"
        } else {
            cleanup = "No cleanup"
        }
        let rewrites = cleans && cleanupEnabled && rewritingEnabled
            && profile.allowsRewrite && profile.intent != .preserve
        let name = "\(profile.intent.displayName) tone"
        if !rewrites {
            tone = nil
        } else if recognitionLanguage == TranscriptionLanguage.auto.code {
            // Detection decides per dictation; say which language gets it.
            tone = "\(name) in English"
        } else {
            tone = DictationOutputPipeline.isEnglish(recognitionLanguage) ? name : nil
        }
    }

    var description: String {
        [format, cleanup, tone].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Whether a dictation can start right now, and if not, the one thing missing.
enum DictationReadiness: Equatable {
    case needsMicrophone
    case needsInputMonitoring
    case needsAccessibility
    case preparingModel
    case needsModel
    /// Ready; `preparingAnother` while a different model downloads or loads.
    case ready(preparingAnother: Bool)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .needsMicrophone: return "Microphone access needed"
        case .needsInputMonitoring: return "Shortcut access needed"
        case .needsAccessibility: return "Text insertion access needed"
        case .preparingModel: return "Preparing speech model…"
        case .needsModel: return "Choose a speech model"
        case .ready(let preparingAnother): return preparingAnother ? "Ready · preparing another model" : "Ready"
        }
    }
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
    // MARK: - Model Recommendation

    var modelRecommendationPriority: SpeechModelPriority {
        get { SpeechModelPriority(rawValue: modelRecommendationPriorityStorage) ?? .balanced }
        set { modelRecommendationPriorityStorage = newValue.rawValue }
    }

    /// The model suggested for the languages the user speaks. Onboarding and
    /// the model list both show this one, and onboarding downloads it.
    var speechModelRecommendation: OnboardingModelRecommendation? {
        OnboardingModelGuidance.recommendation(
            for: spokenLanguages, availableModels: availableModels,
            priority: modelRecommendationPriority, systemLanguages: appleSpeechLanguages,
            memoryGB: systemCapabilities?.physicalMemoryGB ?? SystemInfo.physicalMemoryGB
        )
    }

    /// Onboarding asks only which languages the user speaks. One language
    /// pins recognition to it; several, or none, leave detection on.
    func setOnboardingSpokenLanguages(_ languages: [String]) {
        spokenLanguages = languages
        let automatic = TranscriptionLanguage.auto.code
        let only = languages.count == 1 ? languages[0] : automatic
        let recognized = TranscriptionLanguage.catalog.contains { $0.code == only } ? only : automatic
        if selectedLanguage != recognized { selectedLanguage = recognized }
    }

    // MARK: - Processing Location

    /// Loaded engine wins over a preference while a replacement is loading.
    var speechProcessingIsRemote: Bool {
        (currentModel?.size ?? ModelSize(rawValue: selectedModelSize))?.isRemotelyHosted == true
    }

    var speechProcessingDescription: String {
        speechProcessingIsRemote ? "Audio sent to your endpoint" : "Processed on this Mac"
    }

    /// Whether cleanup of `profile` sends its transcript to the endpoint.
    /// Code and Terminal text is always cleaned on this Mac.
    func cleanupIsRemote(for profile: WritingProfile) -> Bool {
        guard transcriptCleanupEnabled, !cleanupEndpoint.isLocal,
              profile.cleanup == .inherit, profile.format.supportsWording else { return false }
        return (profile.cleanupLevel ?? transcriptCleanupLevel) != .none
    }

    /// What leaves this Mac for the next dictation, or nil when nothing does.
    var nextDictationRemoteNotice: String? {
        switch (speechProcessingIsRemote, cleanupIsRemote(for: nextOutputProfile)) {
        case (true, true): return "Audio and transcript are sent to your endpoints"
        case (true, false): return "Audio is sent to your endpoint"
        case (false, true): return "Transcript is sent to your cleanup endpoint"
        case (false, false): return nil
        }
    }

    // MARK: - Output Summary

    /// The profile the next dictation gets: a one-off choice, or the style
    /// the menu shows, which includes a website rule once its page is read.
    var nextOutputProfile: WritingProfile {
        nextWritingProfile ?? activeWritingStyle.profile
    }

    var nextOutputSummary: OutputConfigurationSummary { outputSummary(for: nextOutputProfile) }

    func outputSummary(for profile: WritingProfile) -> OutputConfigurationSummary {
        OutputConfigurationSummary(
            profile: profile, cleanupEnabled: transcriptCleanupEnabled,
            rewritingEnabled: writingRewriteEnabled, level: transcriptCleanupLevel,
            recognitionLanguage: selectedLanguage
        )
    }

    // MARK: - Readiness

    var dictationReadiness: DictationReadiness {
        if micPermission != .granted { return .needsMicrophone }
        if inputMonitoringPermission != .granted { return .needsInputMonitoring }
        if accessibilityPermission != .granted { return .needsAccessibility }
        if availableModels.contains(where: { $0.isLoading || $0.downloadProgress != nil }) {
            return whisperService.isModelLoaded ? .ready(preparingAnother: true) : .preparingModel
        }
        if availableModels.isEmpty && !whisperService.isModelLoaded { return .preparingModel }
        if needsSpeechModel { return .needsModel }
        return .ready(preparingAnother: false)
    }

    var dictationReadinessTitle: String { dictationReadiness.title }
    var isDictationReady: Bool { dictationReadiness.isReady }

    var lastDictationText: String? {
        let saved = historyEnabled ? (lastUnsavedDictation ?? historyStore.latestDeliveredText) : nil
        let text = saved ?? lastOutput?.text ?? heldOutput
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    // MARK: - Onboarding Verification

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
