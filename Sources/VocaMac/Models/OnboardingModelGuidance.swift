// OnboardingModelGuidance.swift
// VocaMac
//
// Language-led speech-model recommendations for the first-run experience.

import Foundation

/// What matters most when suggesting a model. Changing this never selects it.
enum SpeechModelPriority: String, CaseIterable, Identifiable {
    case balanced, smallestDownload, accuracy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .balanced: return "Balanced"
        case .smallestDownload: return "Smallest download"
        case .accuracy: return "Higher accuracy"
        }
    }
}

/// A single, decision-light model recommendation shared by onboarding and Settings.
struct OnboardingModelRecommendation: Equatable {
    let model: ModelSize
    let title: String
    let explanation: String
}

/// Chooses a speech model from catalog facts instead of asking new users to
/// compare engines, architectures, or benchmark labels.
enum OnboardingModelGuidance {
    static func recommendation(
        for languageCode: String,
        availableModels: [WhisperModelInfo]
    ) -> OnboardingModelRecommendation? {
        recommendation(for: languageCode == "auto" ? [] : [languageCode], availableModels: availableModels)
    }

    /// Only supported local models covering every chosen language are eligible.
    static func recommendation(
        for languages: [String],
        availableModels: [WhisperModelInfo],
        priority: SpeechModelPriority = .balanced,
        systemLanguages: Set<String>? = nil
    ) -> OnboardingModelRecommendation? {
        let codes = languages.filter { $0 != "auto" }
        let eligible = availableModels.filter {
            $0.isSupported && !$0.size.isRemotelyHosted
                && ModelPickerCatalog.fit(of: $0.size, for: codes, systemLanguages: systemLanguages).coversAll
        }
        guard !eligible.isEmpty else { return nil }
        if priority == .balanced {
            let candidates = candidateRecommendations(for: codes.count == 1 ? codes[0] : "auto")
            if let match = candidates.first(where: { candidate in eligible.contains { $0.size == candidate.model } }) {
                return match
            }
        }
        let ranked = eligible.sorted { lhs, rhs in
            if priority == .smallestDownload {
                // System-managed assets have no known download size in our catalog.
                if lhs.size.isSystemManaged != rhs.size.isSystemManaged { return !lhs.size.isSystemManaged }
                if lhs.size.fileSizeBytes != rhs.size.fileSizeBytes { return lhs.size.fileSizeBytes < rhs.size.fileSizeBytes }
            } else if lhs.size.accuracyScore != rhs.size.accuracyScore {
                return lhs.size.accuracyScore > rhs.size.accuracyScore
            }
            if lhs.size.speedScore != rhs.size.speedScore { return lhs.size.speedScore > rhs.size.speedScore }
            return lhs.size.rawValue < rhs.size.rawValue
        }
        guard let selected = ranked.first else { return nil }
        let title: String
        let explanation: String
        switch priority {
        case .balanced:
            title = "Supported model for your languages"
            explanation = "A supported local choice when the usual balanced recommendations do not cover your languages."
        case .smallestDownload:
            title = selected.size.isSystemManaged ? "System-managed speech model" : "Smallest download for your languages"
            explanation = selected.size.isSystemManaged
                ? "macOS manages this model's assets. Their download size is not available in the catalog."
                : "A supported model with a small download. Accuracy and memory use vary by model."
        case .accuracy:
            title = "Higher accuracy for your languages"
            explanation = "Prioritizes the catalog's estimated accuracy among supported models for your languages. Larger models can take longer."
        }
        return OnboardingModelRecommendation(model: selected.size, title: title, explanation: explanation)
    }

    /// Candidate order follows explicit model language coverage. Whisper
    /// Small is the broad fallback when no specialist covers the language.
    private static func candidateRecommendations(
        for languageCode: String
    ) -> [OnboardingModelRecommendation] {
        let broad = OnboardingModelRecommendation(
            model: .small,
            title: "Balanced multilingual dictation",
            explanation: "A stronger general-purpose choice when you use this language or switch between languages."
        )
        let bundled = OnboardingModelRecommendation(
            model: .tiny,
            title: "Bundled starter model",
            explanation: "Already included, with the smallest memory footprint. You can choose another model later."
        )

        let specialist: OnboardingModelRecommendation?
        switch languageCode {
        case "en":
            specialist = OnboardingModelRecommendation(
                model: .parakeetTdtCtc110m,
                title: "Fast English dictation",
                explanation: "Optimized for English, with a smaller download and low memory use."
            )
        case "ru":
            specialist = OnboardingModelRecommendation(
                model: .gigaamV3,
                title: "Russian specialist",
                explanation: "A compact speech model built specifically for Russian dictation."
            )
        case "zh", "ja", "ko":
            specialist = OnboardingModelRecommendation(
                model: .senseVoiceSmall,
                title: "East Asian language specialist",
                explanation: "A compact model with explicit Chinese, Japanese, Korean, and English support."
            )
        case "es", "de", "fr":
            specialist = OnboardingModelRecommendation(
                model: .canary180mFlash,
                title: "Focused multilingual dictation",
                explanation: "A compact model with explicit English, Spanish, German, and French support."
            )
        default:
            specialist = nil
        }

        return [specialist, broad, bundled].compactMap { $0 }
    }
}
