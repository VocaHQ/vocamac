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
        case .balanced: return "A balance of speed and accuracy"
        case .smallestDownload: return "The smallest download"
        case .accuracy: return "The highest accuracy"
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

    /// A recommended model's first load may take at most this share of the
    /// Mac's memory. The load itself is gated on free memory, which changes
    /// by the minute; a suggestion has to hold still, so it goes by installed
    /// memory and leaves the rest for macOS and the apps being dictated into.
    static let memoryShare = 0.5

    /// Only supported local models covering every chosen language are
    /// eligible, and among those only the ones that fit this Mac's memory.
    ///
    /// - Parameter memoryGB: Installed memory. Nil skips the memory check.
    static func recommendation(
        for languages: [String],
        availableModels: [WhisperModelInfo],
        priority: SpeechModelPriority = .balanced,
        systemLanguages: Set<String>? = nil,
        memoryGB: Int? = nil
    ) -> OnboardingModelRecommendation? {
        let codes = languages.filter { $0 != "auto" }
        // A model without language detection only suits someone who speaks
        // exactly one of its languages; otherwise every recording would be
        // decoded as one language.
        let covering = availableModels.filter {
            $0.isSupported && !$0.size.isRemotelyHosted
                && ($0.size.needsOneLanguage ? codes.count == 1 : true)
                && ModelPickerCatalog.fit(of: $0.size, for: codes, systemLanguages: systemLanguages).coversAll
        }
        let fitting = covering.filter { model in
            guard let memoryGB else { return true }
            return model.size.firstLoadRAMRequiredGB <= Double(memoryGB) * memoryShare
        }
        // When nothing fits comfortably, the lightest model is still the
        // most likely to load.
        let lightest = covering.min { $0.size.firstLoadRAMRequiredGB < $1.size.firstLoadRAMRequiredGB }
        let eligible = fitting.isEmpty ? [lightest].compactMap { $0 } : fitting
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
            title = "Understands all your languages"
            explanation = "Understands every language you chose and fits this Mac's memory."
        case .smallestDownload:
            title = selected.size.isSystemManaged ? "Managed by macOS" : "Smallest download for your languages"
            explanation = selected.size.isSystemManaged
                ? "macOS downloads and updates this model itself."
                : "The smallest download that understands every language you chose."
        case .accuracy:
            title = "Most accurate for your languages"
            explanation = "The most accurate model, by the catalog's estimate, that fits this Mac's memory. Larger models are slower."
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

        // English: Parakeet Unified had the fewest errors of the Parakeet
        // models on a 45-sentence, 5-voice synthetic English set (1.6 %,
        // against v3 2.2 %, Ultra 2.8 % and 110M 4.7 % after number
        // formatting is normalized) and writes punctuation and digits. 110M
        // stays next for Macs where Unified does not fit.
        let compactEnglish = OnboardingModelRecommendation(
            model: .parakeetTdtCtc110m,
            title: "Fast English dictation",
            explanation: "Optimized for English, with a smaller download and low memory use."
        )
        var specialists: [OnboardingModelRecommendation] = []
        switch languageCode {
        case "en":
            specialists = [
                OnboardingModelRecommendation(
                    model: .parakeetUnified,
                    title: "Accurate English dictation",
                    explanation: "The most accurate English Parakeet, with punctuation and numbers written as digits. Very fast on the Neural Engine."
                ),
                compactEnglish,
            ]
        case "ru":
            specialists = [OnboardingModelRecommendation(
                model: .gigaamV3,
                title: "Russian specialist",
                explanation: "A compact speech model built specifically for Russian dictation."
            )]
        case "zh", "ja", "ko":
            specialists = [OnboardingModelRecommendation(
                model: .senseVoiceSmall,
                title: "East Asian language specialist",
                explanation: "A compact model with explicit Chinese, Japanese, Korean, and English support."
            )]
        case "es", "de", "fr":
            specialists = [OnboardingModelRecommendation(
                model: .canary180mFlash,
                title: "Focused multilingual dictation",
                explanation: "A compact model with explicit English, Spanish, German, and French support."
            )]
        default:
            // The rest of Parakeet's European languages: far faster than
            // Whisper Small on the Neural Engine. v3 rather than Ultra: on
            // synthetic Italian and Swedish speech Ultra was no better
            // (Swedish 17 % against v3's 10 %).
            if ModelSize.parakeetV3Languages.contains(languageCode) {
                specialists = [OnboardingModelRecommendation(
                    model: .parakeetV3,
                    title: "Fast multilingual dictation",
                    explanation: "Very fast on the Neural Engine, with 25 European languages."
                )]
            }
        }

        return specialists + [broad, bundled]
    }
}
