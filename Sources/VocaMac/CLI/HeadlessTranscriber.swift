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
    static let applicationDomain = "com.vocamac.app"
    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? Self.applicationDefaults()
    }

    /// VocaMac's own preferences, from the app binary or from a separately
    /// built CLI binary.
    static func applicationDefaults() -> UserDefaults {
        if Bundle.main.bundleIdentifier == applicationDomain {
            // Inside the app, .standard already is com.vocamac.app. Asking
            // UserDefaults for its own identifier as a suite emits a warning.
            return .standard
        }
        return UserDefaults(suiteName: applicationDomain) ?? .standard
    }

    var selectedModelIdentifier: String? {
        defaults.string(forKey: PreferenceKey.selectedModelSize)
    }

    var selectedLanguageIdentifier: String? {
        defaults.string(forKey: PreferenceKey.selectedLanguage)
    }
}

/// Headless orchestration that deliberately bypasses AppState and GUI services.
/// Unchecked: every stored property is an immutable `let`, and the CLI runs
/// one command at a time.
final class HeadlessTranscriber: @unchecked Sendable {
    typealias TranscriberFactory = (_ language: String?) -> SpeechTranscribing

    private let modelManager: ModelManaging
    private let preferences: CLIPreferencesReading
    private let audioLoader: AudioFileLoading
    private let transcriberFactory: TranscriberFactory
    private let compiledModels: CompiledModelRecord?
    /// The cleanup model service for `--pieces --cleanup`. Created only when
    /// asked for, so plain transcription never touches llama.cpp.
    let cleanerFactory: @MainActor () -> TranscriptCleaning

    /// - Parameter compiledModels: Where to record a successful load, so the
    ///   app's memory gate knows CoreML has compiled the model. `nil` records
    ///   nothing.
    init(
        modelManager: ModelManaging,
        preferences: CLIPreferencesReading,
        audioLoader: AudioFileLoading,
        transcriberFactory: @escaping TranscriberFactory,
        compiledModels: CompiledModelRecord? = nil,
        cleanerFactory: @escaping @MainActor () -> TranscriptCleaning = { TranscriptCleanupService() }
    ) {
        self.modelManager = modelManager
        self.preferences = preferences
        self.audioLoader = audioLoader
        self.transcriberFactory = transcriberFactory
        self.compiledModels = compiledModels
        self.cleanerFactory = cleanerFactory
    }

    convenience init(
        modelManager: ModelManaging,
        preferences: CLIPreferencesReading,
        audioLoader: AudioFileLoading,
        transcriber: SpeechTranscribing,
        compiledModels: CompiledModelRecord? = nil,
        cleanerFactory: @escaping @MainActor () -> TranscriptCleaning = { TranscriptCleanupService() }
    ) {
        self.init(
            modelManager: modelManager,
            preferences: preferences,
            audioLoader: audioLoader,
            transcriberFactory: { _ in transcriber },
            compiledModels: compiledModels,
            cleanerFactory: cleanerFactory
        )
    }

    /// Transcribe one file with an optional one-request model and language override.
    func transcribe(
        fileURL: URL,
        modelOverride: String?,
        languageOverride: String?
    ) async throws -> CLITranscriptionResponse {
        // A model named for this request is chosen for this request only.
        defer { (modelManager as? CustomModelManaging)?.clearCustomModelOverrides() }
        let prepared = try await prepareTranscription(
            fileURL: fileURL, modelOverride: modelOverride, languageOverride: languageOverride
        )
        let model = prepared.model
        let loadedAudio = prepared.audio
        let language = prepared.language
        let transcriber = prepared.transcriber

        do {
            // Only model and language follow app prefs (see docs/CLI.md); translate
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
            compiledModels?.recordLoad(model)
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
        // Import slots are listed as the models they hold, below.
        var entries = ModelSize.allCases.filter { !$0.isCustom }.map { model in
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
        if let imports = modelManager as? CustomModelManaging {
            for imported in imports.importedModels() {
                guard let slot = imported.manifest.engine.modelSlot else { continue }
                let isActive = slot.activeCustomModel?.id == imported.id
                entries.append(CLIModelResponse(
                    id: imported.id,
                    name: imported.manifest.name,
                    engine: slot.engine.cliIdentifier,
                    selected: selectedModel == slot && isActive,
                    downloaded: true,
                    supported: slot.isAvailableOnThisSystem,
                    systemManaged: false
                ))
            }
        }
        return CLIModelListResponse(models: entries)
    }

    private func resolveModel(identifier: String?) throws -> ModelSize {
        // Start from the app's saved choices: an earlier request's one-off
        // model (MCP serves many requests in one process) must not linger.
        (modelManager as? CustomModelManaging)?.clearCustomModelOverrides()
        guard let identifier, !identifier.isEmpty else {
            // Matches AppState's @AppStorage default, so a fresh install (or
            // prefs that never persisted the key) behaves the same headlessly.
            return .tiny
        }
        if let model = ModelSize(rawValue: identifier) ?? modelManager.modelSize(from: identifier) {
            return model
        }
        // An imported model, named by its manifest id: run it in its slot for
        // this process only, leaving the app's choice alone.
        if let imports = modelManager as? CustomModelManaging,
           let imported = imports.importedModels().first(where: { $0.id == identifier }),
           let slot = imported.manifest.engine.modelSlot {
            try? imports.activateCustomModel(id: imported.id, persist: false)
            return slot
        }
        throw CLIError(.modelNotFound, "Unknown model: \(identifier)")
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
