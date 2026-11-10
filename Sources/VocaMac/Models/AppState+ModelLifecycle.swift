// AppState+ModelLifecycle.swift
// VocaMac
//
// Model loading and unloading, and keeping the cleanup model warm. Moved out of AppState.swift unchanged.

import Foundation
import SwiftUI
import Combine
import AppKit
import os

extension AppState {

    // MARK: - Model Management

    func loadModel(_ size: ModelSize? = nil) async {
        _ = try? await modelOperationSerializer.run { [self] in
            await performLoadModel(size)
        }
    }

    /// Perform one model load after earlier model operations have completed.
    func performLoadModel(_ size: ModelSize? = nil) async {
        loadGeneration += 1
        let generation = loadGeneration

        let previousLoadedModelName = transcriber.loadedModelName
        let previousModelSize = currentModel?.size
            ?? previousLoadedModelName.flatMap { modelManager.modelSize(from: $0) }
            ?? ModelSize(rawValue: selectedModelSize)
        let hadLoadedModel = transcriber.isModelLoaded

        // Decide the model here rather than passing nil and letting WhisperKit
        // auto-select. Its choice arrives with no progress reporting and lands
        // in its own cache, and it is only a WhisperKit choice, so it can
        // never reach the other three engines. Resolving first means the
        // download and memory paths below always know what they are handling.
        guard let targetSize = size ?? resolvedDefaultModel() else {
            let failureMessage = "No speech model is available for this Mac."
            showTemporaryError(failureMessage)
            VocaLogger.error(.appState, failureMessage)
            clearActiveModelState()
            return
        }
        let modelName = modelManager.modelIdentifier(for: targetSize)

        // Refuse known-too-large loads before WhisperKit/CoreML can hang the
        // UI spinner under memory pressure (vocamac#250). Leave any already
        // loaded model alone — we never started a load, so do not restore/clear.
        //
        // The resident model is still in memory at this point: the router only
        // unloads it once the load is under way. Credit what it will release,
        // or switching away from a large engine (Parakeet especially) is
        // measured against memory that model is about to give back.
        let reclaimableGB = hadLoadedModel ? (previousModelSize?.ramRequiredGB ?? 0) : 0
        if !modelFitsInMemory(targetSize, reclaimableGB) {
            let isFirstLoad = !CompiledModelRecord().hasLoaded(targetSize)
            let needed = String(
                format: "%.1f",
                isFirstLoad ? targetSize.firstLoadRAMRequiredGB : targetSize.ramRequiredGB
            )
            let failureMessage =
                "Not enough free memory to load \(targetSize.displayName) "
                + "(~\(needed) GB needed). Free RAM or choose a smaller model."
            showTemporaryError(failureMessage)
            VocaLogger.error(.appState, failureMessage)
            return
        }

        // Fetch the weights ourselves when they are missing, so the wait shows
        // real download progress. Left to the engine it is a silent multi-GB
        // transfer behind a spinner that only ever says "Loading model…" —
        // and for WhisperKit the files land in its own cache rather than ours.
        // Settings' "Download & Load" already does this; every other entry
        // point (a hotkey reloading after the files were deleted, a language
        // change, an intent) arrives here instead.
        //
        // Downloads run outside `modelOperationSerializer`, so this cannot
        // deadlock behind itself; it joins a download of the same model that
        // Settings already started.
        if !modelManager.isModelDownloaded(targetSize) {
            VocaLogger.info(
                .appState,
                "\(targetSize.displayName) is not downloaded — fetching it before loading"
            )
            // A bundled copy costs a file move instead of a transfer.
            if await installBundledOrFallback(preferred: targetSize) {
                refreshModelStatuses()
            }
            if !modelManager.isModelDownloaded(targetSize) {
                await performDownloadModel(targetSize)
            }
            guard generation == loadGeneration else {
                clearLoadingFlag(for: targetSize)
                return
            }
            guard modelManager.isModelDownloaded(targetSize) else {
                // The download path owns its own messaging, including staying
                // quiet when the user cancelled, so do not invent one here.
                clearLoadingFlag(for: targetSize)
                return
            }
        }

        // Mark the model as loading in the UI
        if let idx = availableModels.firstIndex(where: { $0.size == targetSize }) {
            availableModels[idx].isLoading = true
            availableModels[idx].loadingStatus = "Preparing…"
        }

        do {
            // The files are present by now, so the engine loads from our own
            // cache instead of fetching its own copy. WhisperKit handles
            // tokenizer fetching itself — we don't pre-validate those files.
            let folderURL = modelManager.modelFolder(for: targetSize)
            let isFirstLoad = !CompiledModelRecord().hasLoaded(targetSize)
            if isFirstLoad && targetSize.engine.compilesForNeuralEngine {
                VocaLogger.info(
                    .appState,
                    "First load of \(targetSize.displayName) on this macOS build: compiling for the Neural Engine"
                )
            }

            // Update status: unpacking
            if let idx = availableModels.firstIndex(where: { $0.size == targetSize }) {
                availableModels[idx].loadingStatus = targetSize.loadingStatus(
                    forPhase: "Unpacking model…", isFirstLoad: isFirstLoad
                )
            }

            // Load model with status callback. Kept as a task of its own so
            // Force Recovery can give up on a load that never returns.
            let onPhaseChange: @Sendable (String) -> Void = { [weak self] phase in
                Task { @MainActor in
                    guard let self = self else { return }
                    if let idx = self.availableModels.firstIndex(where: { $0.size == targetSize }) {
                        self.availableModels[idx].loadingStatus = targetSize.loadingStatus(
                            forPhase: phase, isFirstLoad: isFirstLoad
                        )
                    }
                }
            }
            let speech = transcriber
            let load = Task { try await speech.loadModel(name: modelName, folder: folderURL, onPhaseChange: onPhaseChange) }
            inFlightModelLoad = load
            defer { if inFlightModelLoad == load { inFlightModelLoad = nil } }
            try await withTaskCancellationHandler {
                try await load.value
            } onCancel: {
                load.cancel()
            }
            // CoreML has cached the compile even if a newer load supersedes
            // this one, so record it before any early return.
            CompiledModelRecord().recordLoad(targetSize)

            // A newer loadModel started while we were waiting; leave UI to it.
            guard generation == loadGeneration else {
                clearLoadingFlag(for: targetSize)
                return
            }

            // Persist the resolved model as the user's preference
            selectedModelSize = targetSize.rawValue

            // The outgoing model was in use until now.
            stampModelsInUse()
            // Update model states — clear all, then mark the loaded one as active
            for i in availableModels.indices {
                let matches = availableModels[i].size == targetSize
                availableModels[i].isActive = matches
                availableModels[i].isLoading = false
                availableModels[i].loadingStatus = "Loading…"
                if matches {
                    availableModels[i].isDownloaded = modelManager.isModelDownloaded(targetSize)
                    currentModel = availableModels[i]
                }
            }

            stampModelsInUse()
            lastModelUnloadReason = nil
            processMemoryBeforeUnloadMB = nil
            processMemoryAfterUnloadMB = nil
            VocaLogger.info(.appState, "Model ready: \(targetSize.displayName)")
            downloadVocabularyBoostIfUseful()
        } catch {
            // A newer load superseded this one; do not restore over it.
            guard generation == loadGeneration else {
                clearLoadingFlag(for: targetSize)
                return
            }

            for i in availableModels.indices {
                availableModels[i].isLoading = false
                availableModels[i].loadingStatus = "Loading…"
            }

            let failureMessage = "Failed to load \(targetSize.displayName): \(error.localizedDescription)"
            showTemporaryError(failureMessage)
            VocaLogger.error(.appState, failureMessage)

            await restorePreviousModelIfNeeded(
                afterFailedLoadFor: targetSize,
                previousSize: previousModelSize,
                previousName: previousLoadedModelName,
                hadLoadedModel: hadLoadedModel,
                originalFailureMessage: failureMessage
            )
        }
    }

    /// Clear the loading spinner on a superseded load without touching others.
    private func clearLoadingFlag(for size: ModelSize?) {
        guard let size,
              let idx = availableModels.firstIndex(where: { $0.size == size }) else {
            return
        }
        availableModels[idx].isLoading = false
        availableModels[idx].loadingStatus = "Loading…"
    }

    /// Reload the active model when "Transcribe as you speak" no longer
    /// matches the loaded encoder (a Unified checkpoint's streaming export is
    /// a different model).
    ///
    /// Queued behind any model operation in progress and decided only once it
    /// has finished: a change made while a load is under way is compared
    /// with what that load actually produced, so it is never dropped.
    func reloadModelForLiveStreamingChangeIfNeeded() async {
        _ = try? await modelOperationSerializer.run { @MainActor [self] in
            guard let size = liveStreamingReloadTarget() else { return }
            VocaLogger.info(.appState, "Transcribe as you speak changed — reloading \(size.displayName)")
            await performLoadModel(size)
        }
    }

    /// The loaded model, when its encoder disagrees with the setting.
    ///
    /// Nil when the chosen model is not the loaded one (an imported backup
    /// can pick another): reloading the old model would save it over that
    /// choice, and the next load applies the setting anyway.
    func liveStreamingReloadTarget() -> ModelSize? {
        guard let size = currentModel?.size,
              ModelSize(rawValue: selectedModelSize) == size,
              size.transcribesWhileSpeaking,
              transcriber.isModelLoaded,
              transcriber.isLiveStreamingLoaded != parakeetLiveStreaming else {
            return nil
        }
        return size
    }

    /// Reload the active model when the transcription language changes and
    /// the engine bakes that language into the loaded model (sherpa-onnx,
    /// Nemotron Unified, SenseVoice on the Neural Engine). Other engines
    /// take the language per transcription and need no reload.
    func reloadModelForLanguageChangeIfNeeded() async {
        guard let size = currentModel?.size,
              size.bindsLanguageAtLoadTime,
              transcriber.isModelLoaded else {
            return
        }

        VocaLogger.info(.appState, "Language changed to \(selectedLanguage) — reloading \(size.displayName)")
        await loadModel(size)
    }

    /// What a language change is judged by: the recognition language, and
    /// the language a model that binds it at load would be given.
    var languageChangeKey: String {
        let pinned = selectedLanguage == TranscriptionLanguage.auto.code ? nil : selectedLanguage
        let loadLanguage = TranscriptionRouter.loadLanguage(selected: pinned, spoken: spokenLanguages)
        return "\(selectedLanguage)|\(loadLanguage ?? TranscriptionLanguage.auto.code)"
    }

    // MARK: Cleanup warm-up

    /// The options a dictation into `profile` is processed with.
    func dictationOptions(
        profile: WritingProfile, language: String?, contextTerms: [String], preview: Bool = false
    ) -> DictationOutputOptions {
        DictationOutputOptions(
            profile: profile, snippetList: snippets,
            cleanupEnabled: transcriptCleanupEnabled, rewritingEnabled: writingRewriteEnabled,
            model: selectedCleanupModelKind, customPrompt: effectiveCleanupPrompt,
            cleanupLevel: transcriptCleanupLevel, language: language, spokenLanguages: spokenLanguages,
            autoCapitalize: autoCapitalize, trailingSpace: appendTrailingSpace,
            preview: preview,
            dictionary: dictionaryContext(contextTerms: contextTerms, language: language),
            numbers: numberWriting, numberSymbols: numberSymbols,
            spokenEmoji: spokenEmoji, skipWhenClean: skipCleanDictations
        )
    }

    /// Load the cleanup model and have it read the prompt the next dictation
    /// into `target` will use.
    ///
    /// llama.cpp keeps the tokens of its last request and reads only what is
    /// new. The cleanup prompt is about a thousand tokens and comes first, so
    /// once it has been read a dictation costs only its own words — but after
    /// a load, a Command Mode edit, or a switch between a prose app and a
    /// terminal, the next dictation used to read all of it while the user
    /// waited. This reads it ahead: at launch, after an edit, and when a
    /// recording starts, while the user is still speaking.
    func warmCleanupModel(
        for target: RunningAppSnapshot? = nil, codingAgentTerminal: RunningAppSnapshot? = nil
    ) async {
        guard cleanupUsesLocalModel else { return }
        let target = target ?? frontmostAppResolver.styleTargetApp()
        let profile = nextWritingProfile
            ?? resolveWritingStyle(for: target, codingAgentTerminal: codingAgentTerminal).profile
        let language = selectedLanguage == "auto" ? nil : selectedLanguage
        await outputPipeline.warmUp(
            options: dictationOptions(profile: profile, language: language, contextTerms: [])
        )
    }

    /// Start a dictation that runs until the shortcut is pressed again (or
    /// silence ends it), whatever the activation mode is.
    func toggleHandsFreeDictation() async {
        if isCapturingAudio {
            await stopRecordingAndTranscribe()
            return
        }
        isHandsFreeSession = true
        await startRecording()
        if !isRecording {
            isHandsFreeSession = false
        }
    }

    /// Type the most recent dictation again at the cursor.
    func pasteLastDictation() {
        guard !isRecording, appStatus != .recording else { return }
        guard let text = lastDictationText else {
            showTemporaryError("There's no dictation to paste yet.")
            return
        }
        VocaLogger.info(.appState, "Pasting the last dictation again (\(text.count) chars)")
        textInjector.inject(text: text, preserveClipboard: preserveClipboard)
    }

    /// Something the menu's Cancel can stop: a recording, or a dictation
    /// still being transcribed or cleaned up.
    var canCancelDictation: Bool { isCapturingAudio || isTranscribing || isLoadingModelForRecording }

    func refreshCancelKeyArming(status: AppStatus? = nil) {
        guard let monitor = hotKeyManager as? HotKeyShortcutMonitoring else { return }
        let current = status ?? appStatus
        // A result on screen is closed with Escape whatever the dictation
        // setting says: it is the only key the panel has.
        monitor.setCancelKeyArmed(
            (escapeCancelsDictation && (current == .recording || isTranscribing || isLoadingModelForRecording))
                || commandReview != nil
        )
    }
}
