// OnboardingModelGuidance.swift
// VocaMac
//
// Language-led speech-model recommendations for the first-run experience.

import Foundation

/// A single, decision-light model recommendation for onboarding.
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
        let candidates = candidateRecommendations(for: languageCode)
        let supported = Set(availableModels.lazy.filter(\.isSupported).map(\.size))
        return candidates.first { supported.contains($0.model) }
            ?? candidates.first { $0.model == .tiny && supported.contains(.tiny) }
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
