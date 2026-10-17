// CalmGeneralSettingsTests.swift
// VocaMac
//
// Tests for Settings › General, Languages and System (v3): the row
// summaries, the language fit, the shortcut recorder's listener pause,
// saving the dictation key, the overlay choice, and the auto-pause list.

import XCTest
@testable import VocaMac

// MARK: - Summaries

final class CalmSettingsSummaryTests: XCTestCase {

    func testLanguagesSummaryNamesTheFit() {
        XCTAssertEqual(
            CalmSettingsSummary.languages(spoken: ["en", "de"], modelName: "Parakeet v3", missing: []),
            "English, German · Parakeet v3 understands both"
        )
        XCTAssertEqual(
            CalmSettingsSummary.languages(spoken: ["en"], modelName: "Parakeet v3", missing: []),
            "English · Parakeet v3 understands it"
        )
        XCTAssertEqual(
            CalmSettingsSummary.languages(spoken: ["en", "de", "fr"], modelName: "Whisper", missing: []),
            "English, German, French · Whisper understands all of them"
        )
    }

    func testLanguagesSummarySaysWhatIsMissing() {
        XCTAssertEqual(
            CalmSettingsSummary.languages(spoken: ["en", "hi"], modelName: "Parakeet v3", missing: ["hi"]),
            "English, Hindi · Parakeet v3 doesn’t understand Hindi"
        )
    }

    func testLanguagesSummaryWithoutLanguagesOrModel() {
        XCTAssertEqual(CalmSettingsSummary.languages(spoken: [], modelName: "Parakeet v3", missing: []),
                       "Any language · worked out each time")
        XCTAssertEqual(CalmSettingsSummary.languages(spoken: ["en"], modelName: nil, missing: []), "English")
    }

    func testFitTitleAndDetail() {
        let fits = CalmLanguageFit(modelName: "Parakeet v3", spoken: ["en", "de"], missing: [], suggestion: nil)
        XCTAssertEqual(CalmSettingsSummary.fitTitle(fits), "Parakeet v3 understands English and German.")
        XCTAssertNil(CalmSettingsSummary.fitDetail(fits))

        let misfit = CalmLanguageFit(modelName: "Parakeet v3", spoken: ["en", "hi"], missing: ["hi"], suggestion: .largeV3)
        XCTAssertEqual(CalmSettingsSummary.fitTitle(misfit), "Parakeet v3 doesn’t understand Hindi.")
        XCTAssertEqual(CalmSettingsSummary.fitDetail(misfit), "Whisper Large v3 understands all of your languages.")

        let stuck = CalmLanguageFit(modelName: "Parakeet v3", spoken: ["hi"], missing: ["hi"], suggestion: nil)
        XCTAssertEqual(CalmSettingsSummary.fitDetail(stuck), "No model on this Mac understands all of your languages yet.")
    }

    func testRecognitionTitles() {
        let auto = TranscriptionLanguage.auto.code
        XCTAssertEqual(CalmSettingsSummary.recognitionTitle(code: auto, spokenCount: 2), "My languages")
        XCTAssertEqual(CalmSettingsSummary.recognitionTitle(code: auto, spokenCount: 0), "Any language")
        XCTAssertEqual(CalmSettingsSummary.recognitionTitle(code: auto, spokenCount: 1), TranscriptionLanguage.auto.displayName)
        XCTAssertEqual(CalmSettingsSummary.recognitionTitle(code: "de", spokenCount: 2), "German")
    }

    func testRecognitionDetail() {
        XCTAssertEqual(CalmSettingsSummary.recognitionDetail(selected: "de", spoken: ["en", "de"]),
                       "Only German. Fewer mix-ups.")
        XCTAssertEqual(CalmSettingsSummary.recognitionDetail(selected: "auto", spoken: ["en", "de"]),
                       "Works out which one you’re speaking each time")
        XCTAssertEqual(CalmSettingsSummary.recognitionDetail(selected: "auto", spoken: []),
                       "Works out the language each time")
    }

    func testSuggestedLanguagesPreferTheMacThenCommonOnesAndSkipChosen() {
        let suggested = CalmSettingsSummary.suggestedLanguages(chosen: ["en"], preferredLanguages: ["en-IN", "hi-IN"])
        XCTAssertEqual(suggested.first, "hi")
        XCTAssertEqual(suggested.count, 3)
        XCTAssertFalse(suggested.contains("en"))
        XCTAssertEqual(Set(suggested).count, suggested.count)
    }

    func testSuggestedLanguagesRespectLimit() {
        XCTAssertEqual(CalmSettingsSummary.suggestedLanguages(chosen: [], preferredLanguages: [], limit: 2), ["en", "es"])
        XCTAssertEqual(CalmSettingsSummary.suggestedLanguages(chosen: [], preferredLanguages: [], limit: 0), [])
    }

    func testOverlaySummary() {
        XCTAssertEqual(CalmSettingsSummary.overlay(style: .live, position: .bottom), "Live panel at the bottom of the screen")
        XCTAssertEqual(CalmSettingsSummary.overlay(style: .minimal, position: .nearCursor), "Small pill near the cursor")
        XCTAssertEqual(CalmSettingsSummary.overlay(style: .off, position: .top), "Nothing on screen")
        XCTAssertEqual(CalmSettingsSummary.overlayPositionTitle(.top), "Top of the screen")
    }

    func testSilenceSummary() {
        XCTAssertEqual(CalmSettingsSummary.sensitivity(threshold: 0.005), "High")
        XCTAssertEqual(CalmSettingsSummary.sensitivity(threshold: 0.01), "Medium")
        XCTAssertEqual(CalmSettingsSummary.sensitivity(threshold: 0.03), "Low")
        XCTAssertEqual(CalmSettingsSummary.seconds(2), "2 s")
        XCTAssertEqual(CalmSettingsSummary.seconds(1.5), "1.5 s")
        XCTAssertEqual(CalmSettingsSummary.seconds(0.96), "1 s")
        XCTAssertEqual(CalmSettingsSummary.silence(threshold: 0.01, duration: 2),
                       "Medium sensitivity · stops after 2 s of quiet")
    }

    /// The Silence dialog's seconds field commits what is typed as it is
    /// typed, in the user's locale; half-typed text is not a number yet.
    func testNumberFieldParsesAndFormatsInTheLocale() {
        let english = Locale(identifier: "en_US")
        let german = Locale(identifier: "de_DE")
        XCTAssertEqual(CalmNumberField.parse("2.5", locale: english), 2.5)
        XCTAssertEqual(CalmNumberField.parse(" 12 ", locale: english), 12)
        XCTAssertEqual(CalmNumberField.parse("2,5", locale: german), 2.5)
        XCTAssertNil(CalmNumberField.parse("", locale: english))
        XCTAssertNil(CalmNumberField.parse("abc", locale: english))
        XCTAssertEqual(CalmNumberField.format(2.5, locale: english), "2.5")
        XCTAssertEqual(CalmNumberField.format(2.5, locale: german), "2,5")
        XCTAssertEqual(CalmNumberField.format(300, locale: english), "300")
    }

    func testAutoPauseSummary() {
        XCTAssertEqual(CalmSettingsSummary.autoPause(isEnabled: false, appNames: ["Steam"]), "Off")
        XCTAssertEqual(CalmSettingsSummary.autoPause(isEnabled: true, appNames: []), "On · no apps yet")
        XCTAssertEqual(CalmSettingsSummary.autoPause(isEnabled: true, appNames: ["Steam"]), "While Steam is open")
        XCTAssertEqual(CalmSettingsSummary.autoPause(isEnabled: true, appNames: ["Steam", "Blender"]),
                       "While Steam or Blender is open")
        XCTAssertEqual(CalmSettingsSummary.autoPause(isEnabled: true, appNames: ["Steam", "Blender", "Xcode", "Logic"]),
                       "While Steam, Blender or 2 more is open")
    }

    func testMicrophoneSummary() {
        let builtIn = AudioDevice(id: "a", name: "MacBook Pro Microphone", isDefault: true,
                                  sampleRate: 48_000, channelCount: 1, isBuiltIn: true)
        let usb = AudioDevice(id: "b", name: "Studio Mic", isDefault: false, sampleRate: 48_000, channelCount: 4)

        let following = CalmSettingsSummary.microphone(selectedID: "", selectedName: "", devices: [builtIn, usb])
        XCTAssertEqual(following.text, "MacBook Pro Microphone · follows the system")
        XCTAssertFalse(following.isUnavailable)

        XCTAssertEqual(CalmSettingsSummary.microphone(selectedID: "b", selectedName: "Studio Mic", devices: [builtIn, usb]).text,
                       "Studio Mic")

        let missing = CalmSettingsSummary.microphone(selectedID: "c", selectedName: "AirPods", devices: [builtIn])
        XCTAssertTrue(missing.isUnavailable)
        XCTAssertEqual(missing.text, "AirPods is unavailable · using the system input")

        XCTAssertEqual(CalmSettingsSummary.microphone(selectedID: "", selectedName: "", devices: []).text,
                       "Follows the system input")
    }

    func testDeviceDetail() {
        let builtIn = AudioDevice(id: "a", name: "Mic", isDefault: true, sampleRate: 48_000, channelCount: 1, isBuiltIn: true)
        let interface = AudioDevice(id: "b", name: "Interface", isDefault: false, sampleRate: 48_000, channelCount: 8)
        XCTAssertEqual(CalmSettingsSummary.deviceDetail(builtIn), "Built in · macOS default")
        XCTAssertEqual(CalmSettingsSummary.deviceDetail(interface), "External · 8 inputs")
    }

    func testModelNames() {
        XCTAssertEqual(CalmModelText.name(.parakeetV3), "Parakeet v3")
        XCTAssertEqual(CalmModelText.name(.small), "Whisper Small")
        XCTAssertEqual(CalmModelText.name(.tiny), "Whisper Tiny")
        XCTAssertEqual(CalmModelText.name(.largeV3Turbo), "Whisper Large v3 Turbo")
        XCTAssertEqual(CalmModelText.name(.vocaHinglish), "Voca Hinglish")
        XCTAssertEqual(CalmModelText.name(.appleSpeech), "Apple Speech")
    }

    func testAutoPauseNotice() {
        XCTAssertEqual(CalmAutoPauseDialog.pausedNotice(trigger: "Steam"), "Paused now while Steam is open")
        XCTAssertEqual(CalmAutoPauseDialog.pausedNotice(trigger: nil), "Paused now by a listed app")
    }
}

// MARK: - AppState helpers

@MainActor
final class CalmGeneralAppStateTests: XCTestCase {
    private let touchedKeys = [
        "vocamac.hotKeyCode", "vocamac.hotKeyModifiers", "vocamac.activationMode", "vocamac.doubleTapThreshold",
        "vocamac.overlayStyle", "vocamac.showCursorIndicator", PreferenceKey.autoPauseApps,
    ]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in touchedKeys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in touchedKeys {
            if let value = saved[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    func testShortcutCapturePausesAndResumesTheListener() {
        let (appState, mocks) = AppState.makeTestState()
        mocks.hotKeyManager.isListening = true
        let startsBefore = mocks.hotKeyManager.startListeningCallCount

        let wasListening = appState.beginShortcutCapture()
        XCTAssertTrue(wasListening)
        XCTAssertTrue(appState.isCapturingShortcut)
        XCTAssertFalse(mocks.hotKeyManager.isListening)

        appState.endShortcutCapture(restartListener: wasListening)
        XCTAssertFalse(appState.isCapturingShortcut)
        XCTAssertTrue(mocks.hotKeyManager.isListening)
        XCTAssertEqual(mocks.hotKeyManager.startListeningCallCount, startsBefore + 1)
        XCTAssertEqual(mocks.hotKeyManager.lastKeyCode, appState.hotKeyCode)
        XCTAssertEqual(mocks.hotKeyManager.lastSafetyTimeout, Double(appState.maxRecordingDuration) + 5)
    }

    func testShortcutCaptureLeavesAStoppedListenerStopped() {
        let (appState, mocks) = AppState.makeTestState()
        mocks.hotKeyManager.isListening = false
        let startsBefore = mocks.hotKeyManager.startListeningCallCount

        let wasListening = appState.beginShortcutCapture()
        XCTAssertFalse(wasListening)
        appState.endShortcutCapture(restartListener: wasListening)

        XCTAssertFalse(mocks.hotKeyManager.isListening)
        XCTAssertEqual(mocks.hotKeyManager.startListeningCallCount, startsBefore)
        XCTAssertFalse(appState.isCapturingShortcut)
    }

    func testApplyDictationKeySavesAllThreeAndSyncs() {
        let (appState, mocks) = AppState.makeTestState()
        let updatesBefore = mocks.hotKeyManager.updateConfigurationCallCount

        appState.applyDictationKey(HotKeyCombo(keyCode: 54, modifiers: []), mode: .doubleTapToggle, doubleTapThreshold: 0.55)

        XCTAssertEqual(appState.hotKeyCode, 54)
        XCTAssertEqual(appState.hotKeyModifiers, [])
        XCTAssertEqual(appState.activationMode, .doubleTapToggle)
        XCTAssertEqual(appState.doubleTapThreshold, 0.55, accuracy: 0.0001)
        XCTAssertGreaterThan(mocks.hotKeyManager.updateConfigurationCallCount, updatesBefore)
    }

    func testDictationKeyDefaultsMatchAppStateDefaults() {
        let (appState, _) = AppState.makeTestState()
        XCTAssertEqual(CalmDictationKeyDefaults.combo, HotKeyCombo(keyCode: appState.hotKeyCode, modifiers: appState.hotKeyModifiers))
        XCTAssertEqual(CalmDictationKeyDefaults.mode, appState.activationMode)
        XCTAssertEqual(CalmDictationKeyDefaults.doubleTapThreshold, appState.doubleTapThreshold, accuracy: 0.0001)
    }

    func testSetOverlayStyleKeepsTheCursorIndicatorInStep() {
        let (appState, _) = AppState.makeTestState()
        appState.setOverlayStyle(.off)
        XCTAssertEqual(appState.overlayStyle, .off)
        XCTAssertFalse(appState.showCursorIndicator)
        appState.setOverlayStyle(.live)
        XCTAssertEqual(appState.overlayStyle, .live)
        XCTAssertTrue(appState.showCursorIndicator)
    }

    func testAddAutoPauseAppAddsOnce() {
        let (appState, _) = AppState.makeTestState()
        let steam = AutoPauseAppEntry(id: "com.valvesoftware.steam", displayName: "Steam",
                                      bundleIdentifier: "com.valvesoftware.steam")
        appState.addAutoPauseApp(steam)
        appState.addAutoPauseApp(steam)
        XCTAssertEqual(appState.autoPauseApps.map(\.id), ["com.valvesoftware.steam"])
    }

    func testLanguageFitReportsMissingLanguagesAndASuggestion() {
        let (appState, _) = AppState.makeTestState()
        appState.selectedModelSize = ModelSize.parakeetV2.rawValue
        appState.setSpokenLanguages(["en", "hi"])

        let fit = appState.calmLanguageFit
        XCTAssertEqual(fit.modelName, "Parakeet v2")
        XCTAssertEqual(fit.missing, ["hi"])
        XCTAssertFalse(fit.fits)
        XCTAssertNotEqual(fit.suggestion, .parakeetV2)
        if let suggestion = fit.suggestion {
            XCTAssertTrue(ModelPickerCatalog.fit(of: suggestion, for: ["en", "hi"]).coversAll)
        }
        XCTAssertTrue(appState.calmLanguageSummary.contains("doesn’t understand Hindi"))
    }

    func testLanguageFitWhenTheModelCoversEverything() {
        let (appState, _) = AppState.makeTestState()
        appState.selectedModelSize = ModelSize.largeV3.rawValue
        appState.setSpokenLanguages(["en", "de"])

        let fit = appState.calmLanguageFit
        XCTAssertTrue(fit.fits)
        XCTAssertNil(fit.suggestion)
        XCTAssertEqual(appState.calmLanguageSummary, "English, German · Whisper Large v3 understands both")
    }

    func testTestDictationIsBlockedWhileDictatingElsewhere() async {
        let (appState, _) = AppState.makeTestState()
        XCTAssertFalse(appState.isDictatingOutsideSettingsTest)
        XCTAssertTrue(appState.canToggleSettingsTestDictation)

        appState.isRecording = true
        XCTAssertTrue(appState.isDictatingOutsideSettingsTest)
        XCTAssertFalse(appState.canToggleSettingsTestDictation)

        appState.settingsTestResultText = "kept"
        await appState.toggleSettingsTestDictation()
        XCTAssertEqual(appState.settingsTestResultText, "kept", "A dictation elsewhere must not be touched")
        appState.isRecording = false
    }

    /// Leaving General (or closing the window) stops a test dictation, and
    /// only that: an ordinary dictation keeps going.
    func testLeavingGeneralStopsOnlyATestDictation() async {
        let (appState, _) = AppState.makeTestState()
        await appState.toggleSettingsTestDictation()
        XCTAssertTrue(appState.isSettingsTestRecording)
        await appState.stopSettingsTestDictation()
        XCTAssertFalse(appState.isPracticeRecording)
        XCTAssertFalse(appState.isRecording)

        await appState.startRecording()
        XCTAssertTrue(appState.isRecording)
        XCTAssertFalse(appState.isSettingsTestRecording)
        await appState.stopSettingsTestDictation()
        XCTAssertTrue(appState.isRecording, "An ordinary dictation is not the test's to stop")
        await appState.cancelRecording()
    }

    /// On a cold start the test opens the microphone and waits for the
    /// speech model before it counts as recording. Leaving General then
    /// must still close the microphone, at once, and transcribe nothing.
    func testLeavingGeneralWhileTheTestWaitsForTheModelClosesTheMicrophone() async {
        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.tiny]
        let whisperService = MockWhisperService()
        whisperService.loadedModelName = nil
        whisperService.isModelLoaded = false
        whisperService.loadDelayNanoseconds = 1_000_000_000
        let (appState, mocks) = AppState.makeTestState(modelManager: modelManager, whisperService: whisperService)
        let originalModel = appState.selectedModelSize
        defer { appState.selectedModelSize = originalModel }
        appState.selectedModelSize = ModelSize.tiny.rawValue

        let start = Task { await appState.toggleSettingsTestDictation() }
        await waitUntil { mocks.audioEngine.isCurrentlyRecording }
        XCTAssertTrue(mocks.audioEngine.isCurrentlyRecording)
        XCTAssertFalse(appState.isSettingsTestRecording, "Not recording yet: the model is still loading")
        XCTAssertTrue(appState.isStartingSettingsTest)

        await appState.stopSettingsTestDictation()
        await waitUntil { !mocks.audioEngine.isCurrentlyRecording }
        XCTAssertFalse(mocks.audioEngine.isCurrentlyRecording, "The microphone must close before the load ends")
        XCTAssertFalse(mocks.whisperService.isModelLoaded, "Closed while the model was still loading")

        await start.value
        XCTAssertFalse(appState.isStartingSettingsTest)
        XCTAssertFalse(appState.isRecording)
        XCTAssertFalse(mocks.audioEngine.isCurrentlyRecording)
        XCTAssertNil(appState.settingsTestResultText)
        XCTAssertEqual(mocks.textInjector.injectCallCount, 0)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
