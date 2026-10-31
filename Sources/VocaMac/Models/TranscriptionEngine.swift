// TranscriptionEngine.swift
// VocaMac
//
// Identifies which speech-to-text engine runs a given model. Each engine has
// its own model format, storage layout, and runtime service.

import Foundation

/// Preference keys shared between `AppState`'s `@AppStorage` properties and
/// services that must read the same setting outside the view layer.
enum PreferenceKey {
    static let onboardingCompleted = "vocamac.hasCompletedOnboarding"
    /// The onboarding step to reopen on, until onboarding is finished.
    static let onboardingResumeStep = "vocamac.onboarding.resumeStep"
    static let askedForAccessibility = "vocamac.permissions.askedForAccessibility"
    static let askedForInputMonitoring = "vocamac.permissions.askedForInputMonitoring"
    static let selectedModelSize = "vocamac.selectedModelSize"
    static let selectedLanguage = "vocamac.selectedLanguage"
    static let appendTrailingSpace = "vocamac.appendTrailingSpace"
    static let autoCapitalize = "vocamac.autoCapitalize"
    static let numbersAsDigits = "vocamac.numbersAsDigits"
    static let numberSymbols = "vocamac.numberSymbols"
    static let spokenEmoji = "vocamac.spokenEmoji"
    static let pauseParagraphs = "vocamac.pauseParagraphs"
    static let autoPauseEnabled = "vocamac.autoPause.enabled"
    static let autoPauseApps = "vocamac.autoPause.apps"
    static let autoPausePollInterval = "vocamac.autoPause.pollIntervalSeconds"
    static let modelKeepAliveEnabled = "vocamac.modelKeepAlive.enabled"
    static let modelKeepAliveIdleTimeout = "vocamac.modelKeepAlive.idleTimeoutSeconds"
    static let dictationTone = "vocamac.dictationTone"
    static let writingStyleEnabled = "vocamac.writingStyle.enabled"
    static let writingStyleDefault = "vocamac.writingStyle.defaultStyle"
    static let writingStyleBindings = "vocamac.writingStyle.bindings"
    /// Bool: apps VocaMac knows get their kind's style until the user gives
    /// them one (`WritingStyleResolver.automaticStyle`).
    static let automaticWritingStyles = "vocamac.writingStyle.automatic"
    static let writingIntent = "vocamac.writingStyle.intent"
    static let writingRewriteEnabled = "vocamac.writingStyle.experimentalRewrite"
    static let duckOtherAudioEnabled = "vocamac.duckOtherAudio.enabled"
    static let pauseSpotifyEnabled = "vocamac.pauseSpotify.enabled"
    static let transcriptCleanupEnabled = "vocamac.transcriptCleanup.enabled"
    static let transcriptCleanupModel = "vocamac.transcriptCleanup.model"
    static let transcriptCleanupPrompt = "vocamac.transcriptCleanup.prompt"
    static let transcriptCleanupLevel = "vocamac.transcriptCleanup.level"
    /// When each downloaded model was last in use (`ModelUsageLog`).
    static let modelUsageLog = "vocamac.models.usageLog"
    static let processWhileSpeaking = "vocamac.dictation.processWhileSpeaking"
    static let cleanupEndpoint = "vocamac.transcriptCleanup.endpoint"
    static let speechEndpoint = "vocamac.speech.endpoint"
    static let historyEnabled = "vocamac.history.enabled"
    static let historyKeepsAudio = "vocamac.history.keepAudio"
    static let historyRetention = "vocamac.history.retention"
    static let historyExcludedApps = "vocamac.history.excludedApps"
    static let escapeCancelsDictation = "vocamac.shortcuts.escapeCancels"
    static let pasteLastShortcut = "vocamac.shortcuts.pasteLast"
    static let handsFreeShortcut = "vocamac.shortcuts.handsFree"
    static let commandModeShortcut = "vocamac.shortcuts.commandMode"
    /// `HotKeyCombo.storageString` for Silent Mode, or empty when it is off.
    static let silentModeShortcut = "vocamac.shortcuts.silentMode"
    /// Double, `ArticulationSensitivity.range`: how readily lip movement counts as speech.
    static let silentModeSensitivity = "vocamac.silentMode.sensitivity"
    /// Bool: the dictation key records silently too, while Silent Mode is on.
    static let silentModeUsesDictationKey = "vocamac.silentMode.usesDictationKey"
    /// Bool: the overlay shows the camera picture behind the lip outline.
    static let silentModeShowsVideo = "vocamac.silentMode.showsVideo"
    /// `AVCaptureDevice.uniqueID` of the chosen camera, or empty for the built-in one.
    static let silentModeCameraID = "vocamac.silentMode.cameraID"
    /// Bool: Silent Mode reads mouthed words with the lip-reading model
    /// (true) or decodes a whisper with the speech model (false).
    static let silentModeReadsLips = "vocamac.silentMode.readsLips"
    static let commandModeEngine = "vocamac.commandMode.engine"
    static let commandModeClipboardFallback = "vocamac.commandMode.clipboardFallback"
    static let aiModelsKeptSeparate = "vocamac.aiModels.keepSeparate"
    /// Leave the cleanup model out when a dictation has nothing for it to do.
    static let cleanupSkipsCleanText = "vocamac.transcriptCleanup.skipCleanText"
    /// `CommandReviewMode` raw value.
    static let commandModeReview = "vocamac.commandMode.review"
    /// JSON `[SavedCommand]`.
    static let savedCommands = "vocamac.commandMode.savedCommands"
    static let voiceActionsEnabled = "vocamac.commandMode.voiceActions"
    /// Names of the Shortcuts Command Mode may run, one per line.
    static let voiceActionShortcuts = "vocamac.commandMode.voiceActionShortcuts"
    static let mouseTriggerButton = "vocamac.shortcuts.mouseButton"
    static let wordReplacements = "vocamac.dictionary.replacements"
    static let dictionarySuggestions = "vocamac.dictionary.suggestions"
    static let dismissedDictionarySuggestions = "vocamac.dictionary.dismissedSuggestions"
    static let learnCorrectionsMode = "vocamac.dictionary.learnMode"
    /// Bool: the learning mode's default has been settled for this install
    /// (see `AppState.settleLearnModeDefault`).
    static let learnModeDefaultSettled = "vocamac.dictionary.learnModeDefaultSettled"
    /// JSON `[String]`: fillers the user always deletes, removed for them.
    static let personalFillers = "vocamac.dictionary.personalFillers"
    /// [String: Int]: dictations each filler was deleted from, until learned.
    static let personalFillerCounts = "vocamac.dictionary.personalFillerCounts"
    /// [String]: fillers the user took back; never learned again.
    static let rejectedPersonalFillers = "vocamac.dictionary.rejectedPersonalFillers"
    /// JSON `[LearnedLowercaseApp]`: apps where dictation starts in lowercase.
    static let learnedLowercaseApps = "vocamac.writingStyle.learnedLowercaseApps"
    /// [String: [Double]]: per app ID, [lowercased starts, last seen as
    /// seconds since 1970], until learned.
    static let lowercaseStartCounts = "vocamac.writingStyle.lowercaseStartCounts"
    /// [String]: app IDs the user took a learned lowercase start back for.
    static let rejectedLowercaseApps = "vocamac.writingStyle.rejectedLowercaseApps"
    /// [String: Int]: screen respellings seen, by suggestion key.
    static let screenRespellingCounts = "vocamac.dictionary.screenRespellingCounts"
    /// Date of the last look through History for names said again and again.
    static let lastFrequentNameScan = "vocamac.dictionary.lastFrequentNameScan"
    static let useScreenContext = "vocamac.dictionary.screenContext"
    static let websiteStyleBindings = "vocamac.writingStyle.websiteBindings"
    /// Bool: dictation into a terminal running a coding agent is prose.
    static let codingAgentsAsProse = "vocamac.writingStyle.codingAgentsAsProse"
    static let externalMicWhenLidClosed = "vocamac.audio.externalMicWhenLidClosed"
    static let skipSilence = "vocamac.audio.skipSilence"
    static let spokenLanguages = "vocamac.spokenLanguages"
    static let modelRecommendationPriority = "vocamac.modelRecommendationPriority"
    /// Prefix of one key per model: the macOS build it last loaded on.
    static let compiledModelBuildPrefix = "vocamac.models.compiledBuild."
}

/// The on-device inference engine backing a model in the catalog.
enum TranscriptionEngine: String, CaseIterable, Codable, Identifiable {
    /// NVIDIA Parakeet TDT via FluidAudio — CoreML on the Neural Engine.
    case parakeet

    /// OpenAI Whisper via WhisperKit — CoreML with Metal/ANE acceleration.
    case whisperKit

    /// Apple's SpeechAnalyzer/SpeechTranscriber — built into macOS 26+,
    /// assets are downloaded and managed by the system.
    case appleSpeech

    /// Community ONNX models via sherpa-onnx — CPU-only specialists
    /// (tiny English models, Chinese, Russian, European languages).
    case sherpaOnnx

    /// A Whisper-compatible HTTP endpoint the user hosts — no model on this
    /// Mac; each recording is uploaded for the server to transcribe.
    case customEndpoint

    var id: String { rawValue }

    /// Section title shown in the model picker.
    var displayName: String {
        switch self {
        case .parakeet:    return "Parakeet"
        case .whisperKit:  return "Whisper"
        case .appleSpeech: return "Apple Speech"
        case .sherpaOnnx:  return "Specialized (ONNX)"
        case .customEndpoint: return "Custom Endpoint"
        }
    }

    /// One-line description shown under the section title.
    var summary: String {
        switch self {
        case .parakeet:
            return "NVIDIA's dictation models on the Neural Engine — fastest transcription with excellent accuracy."
        case .whisperKit:
            return "OpenAI's Whisper models — widest language coverage (100+ languages) and translation to English."
        case .appleSpeech:
            return "Managed by macOS — no model files in VocaMac's folder, though the system may download language assets the first time you use one."
        case .sherpaOnnx:
            return "Community models for specific needs — tiny English models for low-RAM Macs, plus Chinese, Russian, and European language specialists. Runs on CPU."
        case .customEndpoint:
            return "A Whisper-compatible server you run — VocaMac sends each recording to your endpoint and pastes its transcript."
        }
    }

    /// Whether the engine can translate speech to English.
    var supportsTranslation: Bool {
        self == .whisperKit
    }

    /// Whether the engine biases transcription toward user-provided vocabulary.
    var supportsCustomVocabulary: Bool {
        self == .whisperKit
    }

    /// Whether CoreML compiles this engine's models for the Neural Engine on
    /// their first load, which can take minutes.
    var compilesForNeuralEngine: Bool {
        self == .whisperKit || self == .parakeet
    }

}
