// HeadlessTranscriber.swift
// VocaMac
//
// Resolves app preferences and runs one transcription without AppState.

import Foundation

/// Read-only access to the GUI app's persisted model and language choices.
protocol CLIPreferencesReading {
    var selectedModelIdentifier: String? { get }
    var selectedLanguageIdentifier: String? { get }
}

/// Reads the VocaMac application preference domain without mutating it.
struct AppCLIPreferencesReader: CLIPreferencesReading {
    private static let applicationDomain = "com.vocamac.app"
    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        if let defaults {
            self.defaults = defaults
        } else if Bundle.main.bundleIdentifier == Self.applicationDomain {
            // Inside the app, .standard already is com.vocamac.app. Asking
            // UserDefaults for its own identifier as a suite emits a warning.
            self.defaults = .standard
        } else {
            self.defaults = UserDefaults(suiteName: Self.applicationDomain) ?? .standard
        }
    }

    var selectedModelIdentifier: String? {
        defaults.string(forKey: PreferenceKey.selectedModelSize)
    }

    var selectedLanguageIdentifier: String? {
        defaults.string(forKey: PreferenceKey.selectedLanguage)
    }
}

/// Headless orchestration that deliberately bypasses AppState and GUI services.
final class HeadlessTranscriber {
    typealias TranscriberFactory = (_ language: String?) -> SpeechTranscribing

    private let modelManager: ModelManaging
    private let preferences: CLIPreferencesReading
    private let audioLoader: AudioFileLoading
    private let transcriberFactory: TranscriberFactory
    /// The cleanup model service for `--pieces --cleanup`. Created only when
    /// asked for, so plain transcription never touches llama.cpp.
    let cleanerFactory: @MainActor () -> TranscriptCleaning

    init(
        modelManager: ModelManaging,
        preferences: CLIPreferencesReading,
        audioLoader: AudioFileLoading,
        transcriberFactory: @escaping TranscriberFactory,
        cleanerFactory: @escaping @MainActor () -> TranscriptCleaning = { TranscriptCleanupService() }
    ) {
        self.modelManager = modelManager
        self.preferences = preferences
        self.audioLoader = audioLoader
        self.transcriberFactory = transcriberFactory
        self.cleanerFactory = cleanerFactory
    }

    convenience init(
        modelManager: ModelManaging,
        preferences: CLIPreferencesReading,
        audioLoader: AudioFileLoading,
        transcriber: SpeechTranscribing,
        cleanerFactory: @escaping @MainActor () -> TranscriptCleaning = { TranscriptCleanupService() }
    ) {
        self.init(
            modelManager: modelManager,
            preferences: preferences,
            audioLoader: audioLoader,
            transcriberFactory: { _ in transcriber },
            cleanerFactory: cleanerFactory
        )
    }

    /// Transcribe one file with an optional one-request model and language override.
    func transcribe(
        fileURL: URL,
        modelOverride: String?,
        languageOverride: String?
    ) async throws -> CLITranscriptionResponse {
        let prepared = try await prepareTranscription(
            fileURL: fileURL, modelOverride: modelOverride, languageOverride: languageOverride
        )
        let model = prepared.model
        let loadedAudio = prepared.audio
        let language = prepared.language
        let transcriber = prepared.transcriber

        do {
            // Only model and language follow app prefs (see README); translate
            // and custom vocabulary are intentionally always off headlessly.
            let result = try await transcriber.transcribe(
                audioData: loadedAudio.samples,
                language: language,
                translate: false,
                vocabulary: ""
            )
            return CLITranscriptionResponse(
                text: result.text,
                model: model.rawValue,
                engine: model.engine.cliIdentifier,
                detectedLanguage: result.detectedLanguage,
                durationSeconds: result.duration,
                audioLengthSeconds: loadedAudio.durationSeconds
            )
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError(.transcriptionFailed, "Transcription failed: \(error.localizedDescription)")
        }
    }

    struct PreparedTranscription {
        let model: ModelSize
        let audio: LoadedAudioFile
        let language: String?
        let transcriber: SpeechTranscribing
    }

    /// Resolve and validate the model, load the audio, and load the model.
    func prepareTranscription(
        fileURL: URL,
        modelOverride: String?,
        languageOverride: String?
    ) async throws -> PreparedTranscription {
        let model = try resolveModel(identifier: modelOverride ?? preferences.selectedModelIdentifier)
        try validateAvailability(of: model)

        let loadedAudio = try audioLoader.loadAudio(at: fileURL)
        let language = resolvedLanguage(override: languageOverride)
        let transcriber = transcriberFactory(language)
        do {
            try await transcriber.loadModel(
                name: modelManager.modelIdentifier(for: model), folder: modelManager.modelFolder(for: model)
            )
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError(.transcriptionFailed, "Transcription failed: \(error.localizedDescription)")
        }
        return PreparedTranscription(model: model, audio: loadedAudio, language: language, transcriber: transcriber)
    }

    /// Return the complete known model catalog with current runtime state.
    func listModels() -> CLIModelListResponse {
        let selectedModel = try? resolveModel(identifier: preferences.selectedModelIdentifier)
        let entries = ModelSize.allCases.map { model in
            CLIModelResponse(
                id: model.rawValue,
                name: model.displayName,
                engine: model.engine.cliIdentifier,
                selected: model == selectedModel,
                downloaded: model.isSystemManaged || modelManager.isModelDownloaded(model),
                supported: modelManager.isModelSupported(model),
                systemManaged: model.isSystemManaged
            )
        }
        return CLIModelListResponse(models: entries)
    }

    private func resolveModel(identifier: String?) throws -> ModelSize {
        guard let identifier, !identifier.isEmpty else {
            // Matches AppState's @AppStorage default, so a fresh install (or
            // prefs that never persisted the key) behaves the same headlessly.
            return .tiny
        }
        guard let model = ModelSize(rawValue: identifier) ?? modelManager.modelSize(from: identifier) else {
            throw CLIError(.modelNotFound, "Unknown model: \(identifier)")
        }
        return model
    }

    private func validateAvailability(of model: ModelSize) throws {
        guard modelManager.isModelSupported(model) else {
            throw CLIError(.modelUnsupported, "Model is not supported on this Mac: \(model.rawValue)")
        }
        guard model.isSystemManaged || modelManager.isModelDownloaded(model) else {
            throw CLIError(.modelNotDownloaded, "Model is not downloaded: \(model.rawValue)")
        }
        guard model.isSystemManaged || modelManager.modelFolder(for: model) != nil else {
            throw CLIError(.modelNotDownloaded, "Model files are missing: \(model.rawValue)")
        }
    }

    private func resolvedLanguage(override: String?) -> String? {
        let identifier = override ?? preferences.selectedLanguageIdentifier ?? "auto"
        return identifier == "auto" ? nil : identifier
    }
}
