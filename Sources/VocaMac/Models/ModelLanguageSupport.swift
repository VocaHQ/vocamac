// ModelLanguageSupport.swift
// VocaMac
//
// What each speech model understands and how the models compare, so the
// model picker can be narrowed to the languages someone actually speaks.

import Foundation

// MARK: - ModelLanguageCoverage

/// The languages a speech model transcribes.
enum ModelLanguageCoverage: Equatable {
    /// Whisper's multilingual training set: every language in
    /// `TranscriptionLanguage.catalog`, and more.
    case broad

    /// A fixed set of ISO 639-1 codes.
    case only(Set<String>)

    /// Whatever the macOS speech framework supports on this Mac, which only
    /// the system can answer.
    case system
}

// MARK: - ModelSize + Languages

extension ModelSize {

    /// The 25 European languages Parakeet TDT 0.6B v3 was trained on.
    static let parakeetV3Languages: Set<String> = [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
        "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk",
    ]

    /// The 30 languages Qwen3-ASR lists (its Chinese dialects fold into `zh`).
    static let qwen3AsrLanguages: Set<String> = [
        "ar", "cs", "da", "de", "el", "en", "es", "fa", "fi", "fil", "fr", "hi", "hu",
        "id", "it", "ja", "ko", "mk", "ms", "nl", "pl", "pt", "ro", "ru", "sv", "th",
        "tr", "vi", "yue", "zh",
    ]

    /// Languages this model transcribes.
    var languageCoverage: ModelLanguageCoverage {
        switch self {
        case .tiny, .base, .small, .medium,
             .largeV3, .largeV3Turbo, .largeV3Latest, .largeV3LatestTurbo,
             .largeV3LatestCompact, .largeV3LatestTurboCompact:
            return .broad
        // Distil-Whisper was distilled on English speech only.
        case .distilLargeV3Compact, .distilLargeV3TurboCompact:
            return .only(["en"])
        case .vocaHinglish:
            return .only(["hi"])
        case .parakeetV3:
            return .only(Self.parakeetV3Languages)
        case .parakeetV2, .parakeetTdtCtc110m, .moonshineTiny, .moonshineBase:
            return .only(["en"])
        case .appleSpeech:
            return .system
        case .senseVoiceSmall:
            return .only(["zh", "yue", "en", "ja", "ko"])
        case .gigaamV3:
            return .only(["ru"])
        case .canary180mFlash:
            if case .canary(_, _, let languages)? = SherpaModelCatalog.spec(for: self)?.kind {
                return .only(languages)
            }
            return .only(["en", "es", "de", "fr"])
        case .qwen3Asr06B:
            return .only(Self.qwen3AsrLanguages)
        }
    }

    /// Whether the model can translate speech into English.
    ///
    /// Only Whisper models trained with translation data qualify. Whisper
    /// Turbo (WhisperKit's `v20240930` builds) was fine-tuned without it and
    /// answers in the spoken language, and Distil-Whisper is English-only.
    var translatesToEnglish: Bool {
        switch self {
        case .tiny, .base, .small, .medium, .largeV3:
            return true
        default:
            return false
        }
    }

    /// Accuracy on a 0–1 scale, from `qualityDescription`.
    var accuracyScore: Double {
        switch qualityDescription {
        case "Good":      return 0.4
        case "Better":    return 0.55
        case "Great":     return 0.7
        case "Best":      return 1.0
        case "Legacy":    return 0.55
        default:          return 0.85
        }
    }

    /// Speed on a 0–1 scale, from `relativeSpeed` (1 is fastest).
    var speedScore: Double {
        Double(max(1, 6 - relativeSpeed)) / 5
    }

    /// A one-line description for the model picker.
    var pickerSummary: String {
        switch self {
        case .tiny:                      return "Comes with VocaMac. Smallest and fastest Whisper, fine for quick notes."
        case .base:                      return "A small download that is noticeably more accurate than Tiny."
        case .small:                     return "Balanced accuracy and speed across Whisper's languages."
        case .largeV3LatestTurboCompact: return "Close to Whisper's best accuracy at a fraction of the size."
        case .distilLargeV3Compact:      return "English-only Whisper, distilled to run faster."
        case .distilLargeV3TurboCompact: return "English-only Whisper, distilled and tuned for speed."
        case .largeV3LatestCompact:      return "Whisper's best accuracy, compressed to about 600 MB."
        case .largeV3Latest:             return "Whisper's best accuracy at full precision. Large and slower."
        case .largeV3LatestTurbo:        return "Whisper Turbo at full precision."
        case .largeV3:                   return "The original Whisper Large v3. Large and slow."
        case .largeV3Turbo:              return "Whisper Large v3 Turbo."
        case .medium:                    return "Kept for older settings."
        case .vocaHinglish:        return "Writes spoken Hindi in Roman script (Hinglish)."
        case .parakeetV3:                return "Very fast on the Neural Engine, with 25 European languages."
        case .parakeetV2:                return "Very fast on the Neural Engine, with top English accuracy."
        case .parakeetTdtCtc110m:        return "A compact English model with low memory use."
        case .appleSpeech:               return "Built into macOS. Nothing to download in VocaMac."
        case .moonshineTiny:             return "A tiny English model for Macs short on memory."
        case .moonshineBase:             return "A small English model, more accurate than Moonshine Tiny."
        case .senseVoiceSmall:           return "Chinese, Cantonese, English, Japanese, and Korean."
        case .gigaamV3:                  return "A Russian specialist that adds punctuation."
        case .canary180mFlash:           return "English, Spanish, German, and French in a compact model."
        case .qwen3Asr06B:               return "30 languages, including Hindi, Arabic, and Thai."
        }
    }
}

// MARK: - ModelLanguageFit

/// How well a model covers the languages someone speaks.
struct ModelLanguageFit: Equatable {
    /// Spoken languages the model understands, in the order they were given.
    let covered: [String]

    /// Spoken languages the model does not understand.
    let missing: [String]

    var coversAll: Bool { missing.isEmpty }
    var coversAny: Bool { !covered.isEmpty }
}

// MARK: - ModelPickerScope

/// Which slice of the catalog the model picker lists.
enum ModelPickerScope: String, CaseIterable, Identifiable {
    /// Models that understand every language the user speaks.
    case forYou
    /// Models on disk, in use, loading, or downloading.
    case downloaded
    /// The whole catalog.
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forYou:     return "For You"
        case .downloaded: return "Downloaded"
        case .all:        return "All Models"
        }
    }
}

// MARK: - ModelPickerCatalog

/// Filtering and ordering for the language-led model picker.
enum ModelPickerCatalog {

    /// Apple Speech languages to assume until the system has been asked.
    static let fallbackSystemLanguages: Set<String> = [
        "de", "en", "es", "fr", "it", "ja", "ko", "pt", "yue", "zh",
    ]

    /// Language codes a model understands, or nil when it covers all of them.
    static func languageCodes(
        for size: ModelSize,
        systemLanguages: Set<String>?
    ) -> Set<String>? {
        switch size.languageCoverage {
        case .broad:              return nil
        case .only(let codes):    return codes
        case .system:             return systemLanguages ?? fallbackSystemLanguages
        }
    }

    /// Which of the spoken languages a model covers.
    static func fit(
        of size: ModelSize,
        for spokenLanguages: [String],
        systemLanguages: Set<String>? = nil
    ) -> ModelLanguageFit {
        guard let codes = languageCodes(for: size, systemLanguages: systemLanguages) else {
            return ModelLanguageFit(covered: spokenLanguages, missing: [])
        }
        return ModelLanguageFit(
            covered: spokenLanguages.filter { codes.contains($0) },
            missing: spokenLanguages.filter { !codes.contains($0) }
        )
    }

    /// Whether a model matches free-text search by name, creator, engine,
    /// a language it covers, or "translate".
    static func matches(
        _ size: ModelSize,
        search: String,
        systemLanguages: Set<String>? = nil
    ) -> Bool {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }

        if size.translatesToEnglish, "translates".hasPrefix(needle) || needle.hasPrefix("translat") {
            return true
        }

        let fields = [size.displayName, size.creator.displayName, size.engine.displayName, size.pickerSummary]
        if fields.contains(where: { $0.lowercased().contains(needle) }) { return true }

        // A language name ("hindi") or code ("hi") finds the models that
        // speak it. Codes must match exactly: "hi" is inside "chinese".
        let languageCodes = TranscriptionLanguage.catalog
            .filter { $0.code != TranscriptionLanguage.auto.code }
            .filter { $0.displayName.lowercased().hasPrefix(needle) || $0.code == needle }
            .map(\.code)
        return languageCodes.contains { fit(of: size, for: [$0], systemLanguages: systemLanguages).coversAll }
    }

    /// The models a scope lists, best fit first.
    ///
    /// Downloaded models keep their place in the ranking rather than moving
    /// to the top, so the order always means "how well this fits you", and
    /// each row's button says whether it still needs downloading.
    ///
    /// - Parameters:
    ///   - scope: Which slice of the catalog to list.
    ///   - models: The catalog with its runtime state.
    ///   - spokenLanguages: ISO codes the user speaks. Empty means every
    ///     model fits.
    ///   - search: Free text; empty matches everything.
    ///   - recommended: This Mac's recommended model, listed first.
    ///   - systemLanguages: Apple Speech's languages, when known.
    static func models(
        in scope: ModelPickerScope,
        from models: [WhisperModelInfo],
        spokenLanguages: [String],
        search: String = "",
        recommended: ModelSize? = nil,
        systemLanguages: Set<String>? = nil
    ) -> [ModelSize] {
        let fitOf = { (size: ModelSize) in
            fit(of: size, for: spokenLanguages, systemLanguages: systemLanguages)
        }
        let visible = models.filter { model in
            guard matches(model.size, search: search, systemLanguages: systemLanguages) else { return false }
            switch scope {
            case .forYou:     return fitOf(model.size).coversAll
            case .downloaded: return isInstalled(model)
            case .all:        return true
            }
        }

        // Fit tiers only matter where models that miss a language are listed.
        let tier = { (size: ModelSize) -> Int in
            guard scope != .forYou else { return 0 }
            let fit = fitOf(size)
            return fit.coversAll ? 0 : fit.coversAny ? 1 : 2
        }
        return visible.sorted { lhs, rhs in
            if scope == .downloaded, lhs.isActive != rhs.isActive { return lhs.isActive }
            let lhsTier = tier(lhs.size)
            let rhsTier = tier(rhs.size)
            if lhsTier != rhsTier { return lhsTier < rhsTier }
            let lhsRecommended = lhs.isSupported && lhs.size == recommended
            let rhsRecommended = rhs.isSupported && rhs.size == recommended
            if lhsRecommended != rhsRecommended { return lhsRecommended }
            if lhs.isSupported != rhs.isSupported { return lhs.isSupported }
            let lhsRank = rank(lhs.size)
            let rhsRank = rank(rhs.size)
            if lhsRank != rhsRank { return lhsRank > rhsRank }
            return lhs.size.fileSizeBytes < rhs.size.fileSizeBytes
        }
        .map(\.size)
    }

    /// Whether a model belongs under Downloaded.
    static func isInstalled(_ model: WhisperModelInfo) -> Bool {
        model.isDownloaded || model.isActive || model.isLoading || model.downloadProgress != nil
    }

    /// Accuracy counts twice as much as speed: a fast model that mishears
    /// costs more time than a slower one that does not.
    static func rank(_ size: ModelSize) -> Double {
        size.accuracyScore * 2 + size.speedScore
    }
}

// MARK: - SpokenLanguages

/// The languages someone dictates in, which steer the model picker.
///
/// Stored as comma-separated ISO codes. A missing value means the person
/// has not chosen yet; an empty one means they cleared the list and want
/// every model shown.
enum SpokenLanguages {

    /// At most this many languages are guessed from the system.
    static let maximumGuessed = 3

    /// Parse stored codes, dropping blanks, duplicates, and unknown codes.
    static func decode(_ stored: String) -> [String] {
        normalized(stored.split(separator: ",").map(String.init))
    }

    static func encode(_ codes: [String]) -> String {
        normalized(codes).joined(separator: ",")
    }

    /// The stored list, or a guess when nothing has been stored.
    static func resolve(
        stored: String?,
        selectedLanguage: String,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> [String] {
        if let stored { return decode(stored) }
        return guess(selectedLanguage: selectedLanguage, preferredLanguages: preferredLanguages)
    }

    /// A first guess: the pinned transcription language, then the Mac's
    /// preferred languages (so "en-IN, hi-IN" becomes English and Hindi).
    static func guess(selectedLanguage: String, preferredLanguages: [String]) -> [String] {
        var candidates: [String] = []
        if selectedLanguage != TranscriptionLanguage.auto.code {
            candidates.append(selectedLanguage)
        }
        candidates += preferredLanguages.compactMap { identifier in
            Locale(identifier: identifier).language.languageCode?.identifier
        }
        return Array(normalized(candidates).prefix(maximumGuessed))
    }

    /// Display name for a code, including codes outside the catalog.
    static func displayName(for code: String) -> String {
        TranscriptionLanguage.catalog.first { $0.code == code }?.displayName
            ?? Locale(identifier: "en").localizedString(forLanguageCode: code)
            ?? code
    }

    /// "English", "English and Hindi", "English, Hindi, and French".
    static func list(_ codes: [String]) -> String {
        let names = codes.map(displayName(for:))
        switch names.count {
        case 0:  return ""
        case 1:  return names[0]
        case 2:  return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and " + (names.last ?? "")
        }
    }

    /// System codes that name a catalog language differently.
    private static let aliases = ["nb": "no", "nn": "no", "iw": "he", "in": "id"]

    private static func normalized(_ codes: [String]) -> [String] {
        let known = Set(TranscriptionLanguage.selectable.map(\.code))
        var seen = Set<String>()
        return codes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .map { aliases[$0] ?? $0 }
            .filter { known.contains($0) && seen.insert($0).inserted }
    }
}
