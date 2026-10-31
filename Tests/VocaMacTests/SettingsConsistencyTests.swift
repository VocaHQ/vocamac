// SettingsConsistencyTests.swift
// VocaMac Tests
//
// One control for languages and one for sounds, and the stored settings
// from older versions brought into line with them.

import XCTest
@testable import VocaMac

final class LanguageSyncTests: XCTestCase {

    func testOneLanguagePinsRecognitionAndSeveralDetect() {
        XCTAssertEqual(LanguageSync.recognitionLanguage(for: ["hi"]), "hi")
        XCTAssertEqual(LanguageSync.recognitionLanguage(for: ["hi", "en"]), "auto")
        XCTAssertEqual(LanguageSync.recognitionLanguage(for: []), "auto")
    }

    func testRecognitionChoicesAreTheSpokenLanguages() {
        XCTAssertEqual(LanguageSync.recognitionChoices(spoken: ["en", "hi"], current: "auto"), ["auto", "en", "hi"])
        XCTAssertEqual(LanguageSync.recognitionChoices(spoken: ["en", "hi"], current: "hi"), ["auto", "en", "hi"])
        // An imported pin outside the list stays visible rather than blank.
        XCTAssertEqual(LanguageSync.recognitionChoices(spoken: ["en"], current: "de"), ["auto", "en", "de"])
    }

    func testAPinnedLanguageJoinsTheSpokenLanguages() {
        XCTAssertEqual(LanguageSync.reconciledSpokenLanguages(spoken: ["en"], recognition: "de"), ["de", "en"])
        XCTAssertNil(LanguageSync.reconciledSpokenLanguages(spoken: ["en", "de"], recognition: "de"))
        XCTAssertNil(LanguageSync.reconciledSpokenLanguages(spoken: ["en"], recognition: "auto"))
        XCTAssertNil(LanguageSync.reconciledSpokenLanguages(spoken: ["en"], recognition: "not-a-language"))
    }
}

final class SoundPreferenceTests: XCTestCase {

    func testOffIsOneChoice() {
        XCTAssertEqual(SoundPreference.displayed(enabled: true, tone: .glass), .glass)
        XCTAssertEqual(SoundPreference.displayed(enabled: false, tone: .glass), .off)
        // The old picker's own Off with the switch on played nothing.
        XCTAssertEqual(SoundPreference.displayed(enabled: true, tone: .off), .off)
    }

    func testChoosingOffKeepsTheLastTone() {
        let off = SoundPreference.stored(for: .off, currentTone: .glass)
        XCTAssertFalse(off.enabled)
        XCTAssertEqual(off.tone, .glass)

        let glass = SoundPreference.stored(for: .glass, currentTone: .voca)
        XCTAssertTrue(glass.enabled)
        XCTAssertEqual(glass.tone, .glass)
    }
}

final class SettingsConsistencyTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsConsistencyTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: Automatic styles

    func testAFreshInstallGetsAutomaticStylesAndKeepsThemOnceStylesAreSetUp() {
        SettingsConsistency.normalize(defaults: defaults)
        XCTAssertEqual(defaults.object(forKey: PreferenceKey.automaticWritingStyles) as? Bool, true)

        // Setting up an app later must not read as an older install.
        defaults.set("{}", forKey: PreferenceKey.writingStyleBindings)
        SettingsConsistency.normalize(defaults: defaults)
        XCTAssertEqual(defaults.object(forKey: PreferenceKey.automaticWritingStyles) as? Bool, true)
    }

    func testAnInstallThatAlreadySetUpStylesKeepsItsBehaviour() {
        for key in [
            PreferenceKey.writingStyleBindings, PreferenceKey.writingStyleDefault,
            PreferenceKey.websiteStyleBindings, CalmStyleGroupStore.defaultsKey,
        ] {
            defaults.removeObject(forKey: PreferenceKey.automaticWritingStyles)
            defaults.set("x", forKey: key)
            SettingsConsistency.normalize(defaults: defaults)
            XCTAssertEqual(defaults.object(forKey: PreferenceKey.automaticWritingStyles) as? Bool, false, key)
            defaults.removeObject(forKey: key)
        }
    }

    func testAnExplicitAutomaticChoiceIsNeverChanged() {
        defaults.set(false, forKey: PreferenceKey.automaticWritingStyles)
        SettingsConsistency.normalize(defaults: defaults)
        XCTAssertEqual(defaults.object(forKey: PreferenceKey.automaticWritingStyles) as? Bool, false)
    }

    // MARK: Number writing

    func testAFreshInstallWritesNumbersByStyle() {
        SettingsConsistency.normalize(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: PreferenceKey.numbersAsDigits))

        // Finishing onboarding later must not read as an older install.
        defaults.set(true, forKey: PreferenceKey.onboardingCompleted)
        SettingsConsistency.normalize(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: PreferenceKey.numbersAsDigits))
    }

    func testAnOlderInstallKeepsWordsItHadByDefault() {
        defaults.set(true, forKey: PreferenceKey.onboardingCompleted)
        SettingsConsistency.normalize(defaults: defaults)
        XCTAssertEqual(defaults.object(forKey: PreferenceKey.numbersAsDigits) as? Bool, false)
    }

    func testAnOlderInstallsDigitsChoiceStays() {
        defaults.set(true, forKey: PreferenceKey.onboardingCompleted)
        defaults.set(true, forKey: PreferenceKey.numbersAsDigits)
        SettingsConsistency.normalize(defaults: defaults)
        XCTAssertEqual(defaults.object(forKey: PreferenceKey.numbersAsDigits) as? Bool, true)
    }

    func testAPinnedLanguageIsAddedToTheStoredList() {
        defaults.set("en,hi", forKey: PreferenceKey.spokenLanguages)
        defaults.set("de", forKey: PreferenceKey.selectedLanguage)

        SettingsConsistency.normalize(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: PreferenceKey.spokenLanguages), "de,en,hi")
        XCTAssertEqual(defaults.string(forKey: PreferenceKey.selectedLanguage), "de", "Recognition is never changed")

        // Running again changes nothing.
        SettingsConsistency.normalize(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: PreferenceKey.spokenLanguages), "de,en,hi")
    }

    func testUnstoredLanguagesAreLeftToTheGuess() {
        defaults.set("de", forKey: PreferenceKey.selectedLanguage)

        SettingsConsistency.normalize(defaults: defaults)

        XCTAssertNil(defaults.string(forKey: PreferenceKey.spokenLanguages))
    }

    func testAToneOfOffBecomesSoundOff() {
        defaults.set(DictationTone.off.rawValue, forKey: PreferenceKey.dictationTone)

        SettingsConsistency.normalize(defaults: defaults)

        XCTAssertEqual(defaults.object(forKey: SettingsConsistency.soundEffectsEnabledKey) as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: PreferenceKey.dictationTone), DictationTone.defaultTone.rawValue)
        XCTAssertEqual(
            SoundPreference.displayed(
                enabled: defaults.bool(forKey: SettingsConsistency.soundEffectsEnabledKey),
                tone: DictationTone.resolved(stored: defaults.string(forKey: PreferenceKey.dictationTone))
            ),
            .off
        )
    }

    func testARealToneIsLeftAlone() {
        defaults.set(DictationTone.glass.rawValue, forKey: PreferenceKey.dictationTone)
        defaults.set(false, forKey: SettingsConsistency.soundEffectsEnabledKey)

        SettingsConsistency.normalize(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: PreferenceKey.dictationTone), "glass")
        XCTAssertEqual(defaults.object(forKey: SettingsConsistency.soundEffectsEnabledKey) as? Bool, false)
    }
}

@MainActor
final class AppStateSettingsConsistencyTests: XCTestCase {

    func testSpokenLanguagesDriveRecognition() {
        let (appState, _) = AppState.makeTestState()
        let originalSpoken = appState.spokenLanguagesStorage
        let originalLanguage = appState.selectedLanguage
        defer {
            appState.spokenLanguagesStorage = originalSpoken
            appState.selectedLanguage = originalLanguage
        }

        appState.setSpokenLanguages(["fr"])
        XCTAssertEqual(appState.selectedLanguage, "fr")

        appState.setSpokenLanguages(["fr", "en"])
        XCTAssertEqual(appState.selectedLanguage, "auto")
        XCTAssertEqual(appState.spokenLanguages, ["fr", "en"])
    }

    func testSoundCueIsOneControl() {
        let (appState, _) = AppState.makeTestState()
        let originalEnabled = appState.soundEffectsEnabled
        let originalTone = appState.dictationTone
        defer {
            appState.soundEffectsEnabled = originalEnabled
            appState.dictationTone = originalTone
        }
        appState.soundEffectsEnabled = true
        appState.dictationTone = .glass

        appState.soundCue = .off
        XCTAssertFalse(appState.soundEffectsEnabled)
        XCTAssertEqual(appState.dictationTone, .glass)
        XCTAssertEqual(appState.soundCue, .off)

        appState.soundCue = .chirp
        XCTAssertTrue(appState.soundEffectsEnabled)
        XCTAssertEqual(appState.soundCue, .chirp)
    }
}
