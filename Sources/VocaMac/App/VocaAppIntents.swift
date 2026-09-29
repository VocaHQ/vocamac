// VocaAppIntents.swift
// VocaMac

import AppIntents

@available(macOS 14.0, *)
struct StartVocaDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Start VocaMac Dictation"
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
    static let title: LocalizedStringResource = "Stop VocaMac Dictation"
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
    static let title: LocalizedStringResource = "Paste Last VocaMac Dictation"
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
    static let title: LocalizedStringResource = "Transcribe a File with VocaMac"
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
