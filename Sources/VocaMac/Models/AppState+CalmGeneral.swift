// AppState+CalmGeneral.swift
// VocaMac
//
// What Settings › General, Languages and System need from the app beyond
// plain stored settings: the one-line summaries their rows show, the
// language fit of the speech model, the shortcut recorder's listener
// pause, and the in-window test dictation.

import Foundation

// MARK: - Defaults

/// What “Use default” in the dictation-key recorder puts back. Mirrors the
/// `@AppStorage` defaults in `AppState`.
enum CalmDictationKeyDefaults {
    /// Right Option.
    static let combo = HotKeyCombo(keyCode: 61, modifiers: [])
    static let mode: ActivationMode = .pushToTalk
    static let doubleTapThreshold = 0.4
}

// MARK: - Language fit

/// Whether the speech model understands the languages the user speaks,
/// and a model that does when it doesn't.
struct CalmLanguageFit: Equatable {
    /// The model's name, or nil when no model is chosen.
    let modelName: String?
    /// Spoken language codes, in the user's order.
    let spoken: [String]
    /// Spoken languages the model doesn't understand.
    let missing: [String]
    /// A model that covers every spoken language, when the current one doesn't.
    let suggestion: ModelSize?

    /// Whether the model understands every spoken language.
    var fits: Bool { missing.isEmpty }
}

// MARK: - Summaries

/// The short texts General and System rows show. Pure, so they are
/// tested without an `AppState`.
enum CalmSettingsSummary {
    /// The Languages row: “English, German · Parakeet v3 understands both”.
    static func languages(spoken: [String], modelName: String?, missing: [String]) -> String {
        guard !spoken.isEmpty else { return "Any language · worked out each time" }
        let names = spoken.map(SpokenLanguages.displayName(for:)).joined(separator: ", ")
        guard let modelName else { return names }
        guard missing.isEmpty else {
            return "\(names) · \(modelName) doesn’t understand \(SpokenLanguages.list(missing))"
        }
        switch spoken.count {
        case 1: return "\(names) · \(modelName) understands it"
        case 2: return "\(names) · \(modelName) understands both"
        default: return "\(names) · \(modelName) understands all of them"
        }
    }

    /// The fit notice's main line on the Languages page.
    static func fitTitle(_ fit: CalmLanguageFit) -> String {
        guard let model = fit.modelName else { return "Choose a speech model for your languages." }
        if fit.spoken.isEmpty { return "\(model) works out the language each time." }
        if fit.fits { return "\(model) understands \(SpokenLanguages.list(fit.spoken))." }
        return "\(model) doesn’t understand \(SpokenLanguages.list(fit.missing))."
    }

    /// The fit notice's second line when the model misses a language.
    static func fitDetail(_ fit: CalmLanguageFit) -> String? {
        guard !fit.fits else { return nil }
        guard let suggestion = fit.suggestion else {
            return "No model on this Mac understands all of your languages yet."
        }
        return "\(CalmModelText.name(suggestion)) understands all of your languages."
    }

    /// The name of a “Listen for” choice.
    static func recognitionTitle(code: String, spokenCount: Int) -> String {
        guard code == TranscriptionLanguage.auto.code else { return SpokenLanguages.displayName(for: code) }
        switch spokenCount {
        case 0: return "Any language"
        case 1: return TranscriptionLanguage.auto.displayName
        default: return "My languages"
        }
    }

    /// The line under “Listen for”.
    static func recognitionDetail(selected: String, spoken: [String]) -> String {
        guard selected == TranscriptionLanguage.auto.code else {
            return "Only \(SpokenLanguages.displayName(for: selected)). Fewer mix-ups."
        }
        switch spoken.count {
        case 0: return "Works out the language each time"
        case 1: return "Works out the language each time, expecting \(SpokenLanguages.displayName(for: spoken[0]))"
        default: return "Works out which one you’re speaking each time"
        }
    }

    /// Languages offered as one-click chips: the Mac's own languages
    /// first, then widely spoken ones, never one already chosen.
    static func suggestedLanguages(
        chosen: [String], preferredLanguages: [String] = Locale.preferredLanguages, limit: Int = 3
    ) -> [String] {
        let fromSystem = SpokenLanguages.guess(selectedLanguage: TranscriptionLanguage.auto.code,
                                               preferredLanguages: preferredLanguages)
        let common = ["en", "es", "fr", "de", "hi", "zh", "ja", "pt"]
        let selectable = Set(TranscriptionLanguage.selectable.map(\.code))
        var result: [String] = []
        for code in fromSystem + common
        where selectable.contains(code) && !chosen.contains(code) && !result.contains(code) {
            guard result.count < limit else { break }
            result.append(code)
        }
        return result
    }

    /// Where an overlay position puts it, as a phrase (“at the bottom of the screen”).
    static func overlayPlace(_ position: OverlayPosition) -> String {
        switch position {
        case .nearCursor: return "near the cursor"
        case .top: return "at the top of the screen"
        case .bottom: return "at the bottom of the screen"
        }
    }

    /// An overlay position as a menu item.
    static func overlayPositionTitle(_ position: OverlayPosition) -> String {
        switch position {
        case .nearCursor: return "Near the cursor"
        case .top: return "Top of the screen"
        case .bottom: return "Bottom of the screen"
        }
    }

    /// The While you talk row: “Live panel at the bottom of the screen”.
    static func overlay(style: OverlayStyle, position: OverlayPosition) -> String {
        switch style {
        case .off: return "Nothing on screen"
        case .minimal: return "Small pill \(overlayPlace(position))"
        case .live: return "Live panel \(overlayPlace(position))"
        }
    }

    /// How quiet counts as silence, in words.
    static func sensitivity(threshold: Double) -> String {
        if threshold < 0.01 { return "High" }
        if threshold < 0.03 { return "Medium" }
        return "Low"
    }

    /// Seconds as “2 s” or “1.5 s”.
    static func seconds(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return "\(Int(rounded)) s" }
        return String(format: "%.1f s", rounded)
    }

    /// The Silence row: “Medium sensitivity · stops after 2 s of quiet”.
    static func silence(threshold: Double, duration: Double) -> String {
        "\(sensitivity(threshold: threshold)) sensitivity · stops after \(seconds(duration)) of quiet"
    }

    /// The Pause for apps row.
    static func autoPause(isEnabled: Bool, appNames: [String]) -> String {
        guard isEnabled else { return "Off" }
        switch appNames.count {
        case 0: return "On · no apps yet"
        case 1: return "While \(appNames[0]) is open"
        case 2: return "While \(appNames[0]) or \(appNames[1]) is open"
        default: return "While \(appNames[0]), \(appNames[1]) or \(appNames.count - 2) more is open"
        }
    }

    /// The Microphone row: the device in use, and whether the chosen one is missing.
    static func microphone(
        selectedID: String, selectedName: String, devices: [AudioDevice]
    ) -> (text: String, isUnavailable: Bool) {
        if selectedID.isEmpty {
            guard let system = devices.first(where: \.isDefault) else { return ("Follows the system input", false) }
            return ("\(system.name) · follows the system", false)
        }
        if let device = devices.first(where: { $0.id == selectedID }) { return (device.name, false) }
        let name = selectedName.isEmpty ? "Selected microphone" : selectedName
        return ("\(name) is unavailable · using the system input", true)
    }

    /// The line under a device in the microphone picker.
    static func deviceDetail(_ device: AudioDevice) -> String {
        var parts: [String] = []
        parts.append(device.isBuiltIn ? "Built in" : "External")
        if device.isDefault { parts.append("macOS default") }
        if device.channelCount > 2 { parts.append("\(device.channelCount) inputs") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - AppState

extension AppState {
    /// The speech model dictation uses, or will once it loads.
    var calmActiveSpeechModel: ModelSize? {
        currentModel?.size ?? ModelSize(rawValue: selectedModelSize)
    }

    /// How well the speech model fits the languages the user speaks.
    var calmLanguageFit: CalmLanguageFit {
        let spoken = spokenLanguages
        guard let model = calmActiveSpeechModel else {
            return CalmLanguageFit(modelName: nil, spoken: spoken, missing: [], suggestion: nil)
        }
        let missing = ModelPickerCatalog.fit(of: model, for: spoken, systemLanguages: appleSpeechLanguages).missing
        let suggestion = missing.isEmpty ? nil : speechModelRecommendation.map(\.model).flatMap { $0 == model ? nil : $0 }
        return CalmLanguageFit(modelName: CalmModelText.name(model), spoken: spoken, missing: missing, suggestion: suggestion)
    }

    /// The Languages row in General.
    var calmLanguageSummary: String {
        let fit = calmLanguageFit
        return CalmSettingsSummary.languages(spoken: fit.spoken, modelName: fit.modelName, missing: fit.missing)
    }

    // MARK: Shortcut recording

    /// Stop the dictation listener while a shortcut is recorded, so the
    /// keys pressed only go to the recorder.
    ///
    /// - Returns: Whether the listener was running (pass it to `endShortcutCapture`).
    func beginShortcutCapture() -> Bool {
        isCapturingShortcut = true
        let wasListening = hotKeyManager.isListening
        if wasListening { hotKeyManager.stopListening() }
        return wasListening
    }

    /// Resume the dictation listener after recording, with the saved key.
    func endShortcutCapture(restartListener: Bool) {
        isCapturingShortcut = false
        guard restartListener else { return }
        hotKeyManager.startListening(
            keyCode: hotKeyCode,
            mode: activationMode,
            doubleTapThreshold: doubleTapThreshold,
            safetyTimeout: Double(maxRecordingDuration) + 5.0,
            modifiers: hotKeyModifiers
        )
        syncShortcutConfiguration()
    }

    /// Save the dictation key, how it starts, and the double-tap speed together.
    func applyDictationKey(_ combo: HotKeyCombo, mode: ActivationMode, doubleTapThreshold threshold: Double) {
        hotKeyCode = combo.keyCode
        hotKeyModifiers = combo.modifiers
        activationMode = mode
        doubleTapThreshold = threshold
        syncHotKeyConfiguration()
    }

    // MARK: Overlay

    /// Choose what shows on screen while dictating.
    func setOverlayStyle(_ style: OverlayStyle) {
        overlayStyle = style
        showCursorIndicator = style != .off
    }

    // MARK: Auto-pause

    /// Add an app to the auto-pause list, once.
    func addAutoPauseApp(_ entry: AutoPauseAppEntry) {
        var apps = autoPauseApps
        guard !apps.contains(where: { $0.id == entry.id }) else { return }
        apps.append(entry)
        autoPauseApps = apps
    }

    // MARK: Test dictation

    /// A dictation started somewhere else (the shortcut) is running.
    var isDictatingOutsideSettingsTest: Bool {
        (isRecording || appStatus == .recording) && !isPracticeRecording
    }

    /// Whether the Test dictation button can be pressed now.
    var canToggleSettingsTestDictation: Bool {
        !isDictatingOutsideSettingsTest && appStatus != .processing && !(isAutoPaused && !isRecording)
    }

    /// Start a test dictation whose result stays in the window, or stop
    /// the one running.
    func toggleSettingsTestDictation() async {
        if isPracticeRecording {
            await stopRecordingAndTranscribe()
            return
        }
        guard !isDictatingOutsideSettingsTest else { return }
        settingsTestResultText = nil
        guard appStatus == .idle, !isRecording, !isStartingSettingsTest else { return }
        isStartingSettingsTest = true
        defer { isStartingSettingsTest = false }
        await startRecording(injectResult: false)
    }

    /// Stop a running test dictation when its row goes away (leaving
    /// General, closing Settings or the window), so the microphone doesn't
    /// stay on. The result is kept for when the row comes back. A test
    /// still waiting for its speech model (a cold start opens the
    /// microphone first) is cancelled instead: the microphone closes now,
    /// not when the load ends, and nothing is transcribed.
    func stopSettingsTestDictation() async {
        if isSettingsTestRecording {
            await stopRecordingAndTranscribe()
        } else if isStartingSettingsTest, !isCapturingAudio {
            await cancelRecording()
        }
    }
}
