// SettingsConsistency.swift
// VocaMac
//
// Pairs of stored settings that used to be set in two places and could
// disagree, and the rules that keep each pair saying one thing.

import Foundation

// MARK: - Languages

/// "I speak" (the spoken languages) is the one language setting. The
/// recognition language follows it, and can only be narrowed to one of them.
enum LanguageSync {
    private static var automatic: String { TranscriptionLanguage.auto.code }

    /// The recognition language for a new list of spoken languages: one
    /// language pins recognition to it; several, or none, leave detection on.
    static func recognitionLanguage(for spoken: [String]) -> String {
        guard spoken.count == 1, let only = spoken.first,
              TranscriptionLanguage.catalog.contains(where: { $0.code == only }) else { return automatic }
        return only
    }

    /// What the recognition picker offers: Auto-detect, then each spoken
    /// language. A pinned language outside the list (an imported setting)
    /// stays listed so the picker never shows a blank selection.
    static func recognitionChoices(spoken: [String], current: String) -> [String] {
        var choices = [automatic] + spoken.filter { $0 != automatic }
        if current != automatic, !choices.contains(current) { choices.append(current) }
        return choices
    }

    /// Spoken languages that include a pinned recognition language, or nil
    /// when they already agree. Recognition is left as it is: this only adds
    /// to the list, so a stored setting never changes what dictation hears.
    static func reconciledSpokenLanguages(spoken: [String], recognition: String) -> [String]? {
        guard recognition != automatic, !spoken.contains(recognition),
              TranscriptionLanguage.selectable.contains(where: { $0.code == recognition }) else { return nil }
        return [recognition] + spoken
    }
}

// MARK: - Sound

/// Start and stop sounds are one choice: a tone, or Off. Stored as two
/// settings (on/off and which tone) for the dictation path, which only reads
/// the switch.
enum SoundPreference {
    /// The tone the picker shows.
    static func displayed(enabled: Bool, tone: DictationTone) -> DictationTone {
        enabled ? tone : .off
    }

    /// The two stored values for a picker choice. Choosing Off keeps the
    /// last tone, so turning sounds back on doesn't forget it.
    static func stored(for choice: DictationTone, currentTone: DictationTone) -> (enabled: Bool, tone: DictationTone) {
        choice.playsCues ? (true, choice) : (false, currentTone)
    }
}

// MARK: - Stored Settings

/// Brings stored settings from older versions (or an imported backup) into
/// line with the single controls above. Idempotent, so it runs every launch.
enum SettingsConsistency {
    static let soundEffectsEnabledKey = "vocamac.soundEffectsEnabled"

    static func normalize(defaults: UserDefaults) {
        normalizeLanguages(defaults: defaults)
        normalizeSound(defaults: defaults)
        normalizeAutomaticStyles(defaults: defaults)
        normalizeNumberWriting(defaults: defaults)
    }

    static let numberWritingDecidedKey = "vocamac.numberWriting.decided"

    /// Numbers by style (`NumberWriting.automatic`) arrived after numbers were
    /// words unless the user turned digits on. An install that finished
    /// onboarding before that never chose words — it had them by default —
    /// so it keeps them, stored as a choice; a new install gets numbers by
    /// style. Decided once, on the first launch that has the setting.
    static func normalizeNumberWriting(defaults: UserDefaults) {
        guard !defaults.bool(forKey: numberWritingDecidedKey) else { return }
        defaults.set(true, forKey: numberWritingDecidedKey)
        guard defaults.object(forKey: PreferenceKey.numbersAsDigits) == nil,
              defaults.bool(forKey: PreferenceKey.onboardingCompleted) else { return }
        defaults.set(false, forKey: PreferenceKey.numbersAsDigits)
        VocaLogger.info(.appState, "Numbers stay as words: this install had them before numbers by style")
    }

    /// Automatic styles (known apps get their kind's style without a rule)
    /// arrived after styles shipped inert. An install that already set
    /// styles up chose how its apps without a rule come out, so it keeps
    /// that; everyone else gets automatic styles. Decided once, on the first
    /// launch that has the setting, and stored so a style set up later
    /// doesn't turn it off.
    static func normalizeAutomaticStyles(defaults: UserDefaults) {
        guard defaults.object(forKey: PreferenceKey.automaticWritingStyles) == nil else { return }
        let configuredStyles = [
            PreferenceKey.writingStyleBindings, PreferenceKey.writingStyleDefault,
            PreferenceKey.websiteStyleBindings, CalmStyleGroupStore.defaultsKey,
        ].contains { defaults.object(forKey: $0) != nil }
        defaults.set(!configuredStyles, forKey: PreferenceKey.automaticWritingStyles)
    }

    /// A recognition language pinned in Settings → Language that isn't among
    /// the spoken languages joins them.
    static func normalizeLanguages(defaults: UserDefaults) {
        // Nothing stored means the list is guessed, pinned language first.
        guard let stored = defaults.string(forKey: PreferenceKey.spokenLanguages) else { return }
        let recognition = defaults.string(forKey: PreferenceKey.selectedLanguage) ?? TranscriptionLanguage.auto.code
        guard let reconciled = LanguageSync.reconciledSpokenLanguages(
            spoken: SpokenLanguages.decode(stored), recognition: recognition
        ) else { return }
        defaults.set(SpokenLanguages.encode(reconciled), forKey: PreferenceKey.spokenLanguages)
        VocaLogger.info(.appState, "Added the recognition language \(recognition) to the spoken languages")
    }

    /// The tone picker's Off used to be separate from the sounds switch. A
    /// tone of Off with the switch on played nothing; it now reads as Off.
    static func normalizeSound(defaults: UserDefaults) {
        let tone = DictationTone.resolved(stored: defaults.string(forKey: PreferenceKey.dictationTone))
        guard !tone.playsCues, defaults.object(forKey: soundEffectsEnabledKey) as? Bool != false else { return }
        defaults.set(false, forKey: soundEffectsEnabledKey)
        // A real tone to come back to when sounds are turned on again.
        defaults.set(DictationTone.defaultTone.rawValue, forKey: PreferenceKey.dictationTone)
        VocaLogger.info(.appState, "Sound set to Off: the stored tone was Off")
    }
}
