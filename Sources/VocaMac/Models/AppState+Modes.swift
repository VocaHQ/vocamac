// AppState+Modes.swift
// VocaMac
//
// Modes (`DictationMode`): the list Settings edits, the mode the current
// recording is in, and the language it is transcribed in.

import Foundation

extension AppState {

    // MARK: - Modes

    /// The user's modes, in the order Settings shows them.
    var dictationModes: [DictationMode] {
        get { DictationModeStore.decode(dictationModesJSON) }
        set {
            dictationModesJSON = DictationModeStore.encode(newValue)
            syncShortcutConfiguration()
        }
    }

    func dictationMode(withID id: UUID) -> DictationMode? {
        dictationModes.first { $0.id == id }
    }

    /// The mode the current recording was started in by its shortcut.
    var recordingMode: DictationMode? {
        recordingModeID.flatMap(dictationMode(withID:))
    }

    /// The language to transcribe in: a mode's own, when its shortcut
    /// started the dictation and the model takes a language per dictation,
    /// otherwise the language setting. Nil means detect it.
    func transcriptionLanguage(for mode: DictationMode?) -> String? {
        if let language = mode?.languageOverride {
            // sherpa-onnx builds the language into the loaded model; switching
            // would mean a reload in the middle of a dictation.
            if currentModel?.size.bindsLanguageAtLoadTime == true {
                VocaLogger.info(.appState, "\(mode?.summaryLabel ?? "Mode") keeps the model's language: this model is loaded for one language")
            } else {
                return language
            }
        }
        return selectedLanguage == "auto" ? nil : selectedLanguage
    }

    /// The shortcut of the mode being dictated in, for the overlay hint.
    var activeModeShortcutText: String? {
        // A finished recording's mode is left in `recordingModeID` until the
        // next start replaces it, so it counts only while capturing.
        guard let id = pendingModeID ?? (isCapturingAudio ? recordingModeID : nil),
              let mode = dictationMode(withID: id),
              let combo = HotKeyCombo(storageString: mode.shortcut) else { return nil }
        return CalmKeyCaps.compactText(for: combo)
    }

    // MARK: Editing

    func saveDictationMode(_ mode: DictationMode) {
        var modes = dictationModes
        if let index = modes.firstIndex(where: { $0.id == mode.id }) {
            modes[index] = mode
        } else {
            modes.append(mode)
        }
        dictationModes = modes
    }

    func deleteDictationMode(_ id: UUID) {
        dictationModes = dictationModes.filter { $0.id != id }
    }

    /// Add the starter modes, keeping any mode already called the same.
    func addStarterModes() {
        let existing = Set(dictationModes.map { ModePrefix.normalized($0.name) })
        let starters = DictationMode.starters
            .filter { !existing.contains(ModePrefix.normalized($0.name)) }
            .map { starter -> DictationMode in
                var mode = starter
                mode.id = UUID()
                return mode
            }
        dictationModes += starters
    }

    // MARK: - Silent microphone

    /// Warn in the overlay while the microphone sends nothing but silence,
    /// and stop warning as soon as it sends sound.
    func observeInputLevel(_ level: Float) {
        guard isRecording, appStatus == .recording else { return }
        let wasWarning = silentInputMonitor.isWarning
        let isWarning = silentInputMonitor.observe(level: level, at: Date())
        guard isWarning != wasWarning else { return }
        cursorOverlay.setInputSilent(isWarning)
        if isWarning {
            let device = selectedAudioDeviceName.isEmpty ? "the microphone" : selectedAudioDeviceName
            VocaLogger.warning(
                .appState,
                "No sound from \(device) \(SilentInputMonitor.window)s into the recording"
            )
            DictationAnnouncement.post("No sound from the microphone")
        }
    }
}
