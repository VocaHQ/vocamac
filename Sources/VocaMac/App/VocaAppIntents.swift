// VocaAppIntents.swift
// VocaMac

import AppIntents

@available(macOS 14.0, *)
struct StartVocaDictationIntent: AppIntent {
#if APP_STORE
    static let title: LocalizedStringResource = "Start Voca Dictation"
#else
    static let title: LocalizedStringResource = "Start VocaMac Dictation"
#endif
    static let description = IntentDescription("Start recording with the currently selected speech model.")
    // Run in the background: bringing VocaMac forward would make it the
    // destination for the dictation instead of the app the user was in.
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await AppState.production().handleDeepLink(.startDictation)
        return .result()
    }
}

@available(macOS 14.0, *)
struct StopVocaDictationIntent: AppIntent {
#if APP_STORE
    static let title: LocalizedStringResource = "Stop Voca Dictation"
#else
    static let title: LocalizedStringResource = "Stop VocaMac Dictation"
#endif
    static let description = IntentDescription("Stop recording, transcribe, and type the result.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await AppState.production().handleDeepLink(.stopDictation)
        return .result()
    }
}

@available(macOS 14.0, *)
struct PasteLastVocaDictationIntent: AppIntent {
#if APP_STORE
    static let title: LocalizedStringResource = "Paste Last Voca Dictation"
#else
    static let title: LocalizedStringResource = "Paste Last VocaMac Dictation"
#endif
    static let description = IntentDescription("Type the most recent saved dictation at the cursor.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await AppState.production().handleDeepLink(.pasteLast)
        return .result()
    }
}

@available(macOS 14.0, *)
struct TranscribeVocaFileIntent: AppIntent {
#if APP_STORE
    static let title: LocalizedStringResource = "Transcribe a File with Voca"
#else
    static let title: LocalizedStringResource = "Transcribe a File with VocaMac"
#endif
    static let description = IntentDescription("Transcribe an audio or video file with the currently selected local speech model.")
    static let openAppWhenRun = false

    @Parameter(title: "Audio or Video File")
    var file: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let suffix = URL(fileURLWithPath: file.filename).pathExtension
        let name = UUID().uuidString + (suffix.isEmpty ? "" : ".\(suffix)")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try file.data.write(to: url, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await AppState.production().transcribeFile(at: url)
        return .result(value: result.text)
    }
}

/// Command Mode without speaking: Shortcuts supplies the instruction, and it
/// is applied to whatever is selected in the app in front.
@available(macOS 14.0, *)
struct EditSelectedTextWithVocaIntent: AppIntent {
#if APP_STORE
    static let title: LocalizedStringResource = "Edit Selected Text with Voca"
#else
    static let title: LocalizedStringResource = "Edit Selected Text with VocaMac"
#endif
    static let description = IntentDescription(
        "Apply a Command Mode instruction, such as “fix grammar and spelling”, to the text selected in the frontmost app. With nothing selected, the instruction says what to write at the cursor."
    )
    // Run in the background: bringing VocaMac forward would take the
    // selection's app out of front, and the edit would have nowhere to go.
    static let openAppWhenRun = false

    @Parameter(title: "Instruction", description: "What to do with the selected text, or a saved command's name.")
    var instruction: String

    static var parameterSummary: some ParameterSummary {
        Summary("Edit the selected text: \(\.$instruction)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let appState = AppState.production()
        let saved = SavedCommandStore.command(named: instruction, in: appState.savedCommands)
        await appState.runCommand(instruction: saved?.instruction ?? instruction)
        return .result()
    }
}

@available(macOS 14.0, *)
struct VocaMacShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartVocaDictationIntent(),
            phrases: ["Start dictation with \(.applicationName)"],
            shortTitle: "Start Dictation",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StopVocaDictationIntent(),
            phrases: ["Stop dictation with \(.applicationName)"],
            shortTitle: "Stop Dictation",
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: PasteLastVocaDictationIntent(),
            phrases: ["Paste my last \(.applicationName) dictation"],
            shortTitle: "Paste Last Dictation",
            systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: TranscribeVocaFileIntent(),
            phrases: ["Transcribe a file with \(.applicationName)"],
            shortTitle: "Transcribe File",
            systemImageName: "waveform.badge.plus"
        )
    }
}
