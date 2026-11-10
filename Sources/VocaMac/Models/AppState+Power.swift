// AppState+Power.swift
// VocaMac
//
// Power management and auto-pause. Moved out of AppState.swift unchanged.

import Foundation
import SwiftUI
import Combine
import AppKit
import os

extension AppState {

    // MARK: - Power Management

    /// Wire auto-pause, idle unload, and sleep/wake monitors.
    func setupPowerManagement() {
        autoPauseMonitor.getConfig = { [weak self] in
            guard let self else {
                return (false, [], AutoPauseMonitor.defaultPollIntervalSeconds)
            }
            return (
                self.autoPauseEnabled,
                self.autoPauseApps,
                self.autoPausePollIntervalSeconds
            )
        }
        autoPauseMonitor.onPause = { [weak self] in
            Task { @MainActor in
                await self?.handleAutoPauseEntered()
            }
        }
        autoPauseMonitor.onResume = { [weak self] in
            Task { @MainActor in
                await self?.handleAutoPauseCleared()
            }
        }

        modelKeepAlive.getConfig = { [weak self] in
            guard let self else {
                return (false, ModelKeepAlive.defaultIdleTimeoutSeconds)
            }
            return (self.modelKeepAliveEnabled, self.modelKeepAliveIdleTimeoutSeconds)
        }
        modelKeepAlive.isSafeToUnload = { [weak self] in
            guard let self else { return false }
            // The cleanup LLM holds as much RAM as a speech model, so idle
            // unload has to consider it too — otherwise enabling keep-alive
            // frees the transcriber and leaves a GGUF resident forever.
            return self.appStatus == .idle
                && !self.isAutoPaused
                && (self.transcriber.isModelLoaded || self.transcriptCleanup.isLoaded)
        }
        modelKeepAlive.onIdleUnload = { [weak self] in
            Task { @MainActor in
                await self?.unloadActiveModel(reason: .idleKeepAlive)
            }
        }

        sleepWakeMonitor.onWillSleep = { [weak self] in
            self?.handleWillSleep()
        }
        sleepWakeMonitor.onDidWake = { [weak self] in
            guard let self else { return }
            VocaLogger.info(.appState, "Wake recovery: refreshing hotkey health")
            self.checkPermissions()
            if self.permissionManager.allPermissionsGranted {
                self.syncHotKeyConfiguration()
                self.restartHotKeyListenerIfNeeded()
            }
            if !self.isAutoPaused {
                self.modelKeepAlive.bump()
            }
        }

        $appStatus
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .idle:
                    if !self.isAutoPaused {
                        self.modelKeepAlive.bump()
                    }
                case .recording, .processing, .error:
                    self.modelKeepAlive.cancel()
                }
            }
            .store(in: &cancellables)

        autoPauseMonitor.start()
        modelKeepAlive.start()
        sleepWakeMonitor.start()
        if !skipSystemIntegration {
            AudioDeviceMonitor.shared.start()
        }
    }

    /// The Mac is about to sleep. A dictation in progress is stopped as if
    /// the key came up rather than discarded: its audio is saved to History
    /// first, so it is transcribed (now or after wake) or can be retried,
    /// instead of lost with a closed lid.
    func handleWillSleep() {
        modelKeepAlive.cancel()
        guard isCapturingAudio else { return }
        VocaLogger.info(.appState, "Mac is going to sleep mid-dictation — stopping and keeping the audio")
        Task { @MainActor [weak self] in await self?.stopRecordingAndTranscribe() }
    }

    /// Unload the resident model and clear active UI flags.
    func unloadActiveModel(reason: ModelUnloadReason) async {
        // The idle timer fired on an earlier turn; a dictation may have
        // started since, and unloading under it fails it at stop.
        if reason == .idleKeepAlive,
           appStatus != .idle || isCapturingAudio || isTranscribing || isLoadingModelForRecording {
            VocaLogger.info(.appState, "Idle unload skipped: a dictation started (\(dictationFlags))")
            return
        }
        VocaLogger.info(.appState, "Unloading model (reason=\(reason.rawValue))")
        modelKeepAlive.cancel()
        let beforeMB = ProcessMonitor.currentResidentMemoryMB()
        processMemoryBeforeUnloadMB = beforeMB
        await transcriber.unloadModel()
        transcriptCleanup.unload()
        // Give the allocator a beat to release pages before sampling again.
        try? await Task.sleep(nanoseconds: 150_000_000)
        let afterMB = ProcessMonitor.currentResidentMemoryMB()
        processMemoryAfterUnloadMB = afterMB
        lastModelUnloadReason = reason
        for i in availableModels.indices {
            availableModels[i].isActive = false
            availableModels[i].isLoading = false
        }
        currentModel = nil
        VocaLogger.info(
            .appState,
            "Unload complete (reason=\(reason.rawValue), RSS \(String(format: "%.0f", beforeMB))→\(String(format: "%.0f", afterMB)) MB)"
        )
    }

    /// Approximate RAM freed by the last unload, when both samples exist.
    var approximateMemoryFreedMB: Double? {
        guard let before = processMemoryBeforeUnloadMB,
              let after = processMemoryAfterUnloadMB,
              before > after else {
            return nil
        }
        return before - after
    }

    /// User-facing summary of why the model is currently unloaded.
    var modelUnloadStatusMessage: String? {
        guard !transcriber.isModelLoaded else { return nil }
        if isAutoPaused {
            if let name = autoPauseTriggerDisplayName, !name.isEmpty {
                return "Paused while \(name) is running. The speech model was unloaded to free memory."
            }
            return "Paused by a listed app. The speech model was unloaded to free memory."
        }
        switch lastModelUnloadReason {
        case .idleKeepAlive:
            return "Model unloaded after idle timeout. Next dictation reloads it."
        case .autoPause:
            return "Model unloaded by auto-pause."
        case .manual:
            return "Model unloaded."
        case .none:
            return nil
        }
    }

    /// The chosen speech model is not on this Mac and none is on the way.
    ///
    /// A model that is downloaded but not loaded yet, or unloaded on purpose
    /// (idle timeout, auto-pause), is not missing: the next dictation loads it.
    var needsSpeechModel: Bool {
        appStatus == .idle
            && !transcriber.isModelLoaded
            // Not yet populated at launch: nothing is known to be missing.
            && !availableModels.isEmpty
            && !availableModels.contains { $0.size.rawValue == selectedModelSize && $0.isDownloaded }
            && !availableModels.contains { $0.isLoading || $0.downloadProgress != nil }
    }

    /// Ensure a model is loaded before dictation (lazy reload after idle unload).
    func ensureModelLoaded() async {
        guard !transcriber.isModelLoaded else { return }
        let size = ModelSize(rawValue: selectedModelSize)
            ?? currentModel?.size
            ?? .tiny
        VocaLogger.info(.appState, "Ensuring model loaded: \(size.displayName)")
        // Checked again once earlier model operations finish: a load queued
        // ahead of this one may already have loaded a model.
        _ = try? await modelOperationSerializer.run { @MainActor [self] in
            guard !transcriber.isModelLoaded else { return }
            await performLoadModel(size)
        }
    }

    var autoPausedMessage: String {
        if let name = autoPauseTriggerDisplayName ?? autoPauseMonitor.activeTrigger?.displayName, !name.isEmpty {
            return "Dictation is paused while \(name) is running."
        }
        return "Dictation is paused while a listed app is running."
    }

    /// A listed app started: stop any recording and unload the model.
    /// Internal so tests can drive it; the monitor calls it in the app.
    func handleAutoPauseEntered() async {
        isAutoPaused = true
        autoPauseTriggerDisplayName = autoPauseMonitor.activeTrigger?.displayName
        modelKeepAlive.cancel()

        queuedRecordingStart = nil
        discardEarlyCapture()
        if isCapturingAudio {
            VocaLogger.warning(.appState, "Auto-pause entered while recording: stopping without inject")
            recordingGeneration = UUID()
            _ = await stopAudioEngine()
            showOverlayFailure(autoPausedMessage)
            discardRecordingState()
            isTranscribing = false
            appStatus = .idle
        }

        if isTranscribing {
            VocaLogger.info(.appState, "Auto-pause entered while a dictation is finishing: unloading once it is delivered")
            autoPauseUnloadDeferred = true
            return
        }
        await unloadModelForAutoPause()
    }

    func unloadModelForAutoPause() async {
        if transcriber.isModelLoaded {
            await unloadActiveModel(reason: .autoPause)
        } else {
            lastModelUnloadReason = .autoPause
        }
    }

    /// Runs the unload `handleAutoPauseEntered` put off, once the dictation
    /// it was waiting on is delivered, if the pause still holds.
    func runDeferredAutoPauseUnload() {
        guard autoPauseUnloadDeferred else { return }
        autoPauseUnloadDeferred = false
        Task { @MainActor [weak self] in
            guard let self, self.isAutoPaused, !self.isTranscribing, !self.isCapturingAudio else { return }
            VocaLogger.info(.appState, "Dictation delivered during auto-pause: unloading the model now")
            await self.unloadModelForAutoPause()
        }
    }

    /// The listed apps quit: reload the model so the next dictation is ready.
    func handleAutoPauseCleared() async {
        autoPauseUnloadDeferred = false
        isAutoPaused = false
        autoPauseTriggerDisplayName = nil
        // Warm-reload so the next hotkey is ready (Linux behavior).
        await ensureModelLoaded()
        modelKeepAlive.bump()
    }

    /// Build the model list shown in Settings and onboarding.
    ///
    /// The base catalog is curated for M-series Macs, then extended with any
    /// exact variants WhisperKit marks supported for the current device.
    /// Models whose engine cannot run on this system at all (e.g. Apple
    /// Speech before macOS 26, Parakeet on Intel) are excluded entirely.
    /// Other engines report every model they can run as supported, so only
    /// WhisperKit's list extends the catalog; otherwise a model left out of
    /// it on purpose (Canary 180M Flash) would come straight back. A legacy
    /// model still appears while it is the selected one.
    private func modelCatalog() -> [ModelSize] {
        var catalog = ModelSize.standardCatalog.filter { $0.isAvailableOnThisSystem }

        for size in ModelSize.allCases
        where size.engine == .whisperKit && size.isAvailableOnThisSystem && modelManager.isModelSupported(size) {
            if !catalog.contains(size) {
                catalog.append(size)
            }
        }

        if let selected = ModelSize(rawValue: selectedModelSize),
           !catalog.contains(selected) {
            catalog.append(selected)
        }

        return catalog
    }

    /// Recreate model UI state from the latest catalog and local cache status.
    func rebuildAvailableModels() {
        availableModels = modelCatalog().map { size in
            // A folder is only returned once its files check out, so it
            // answers "downloaded" too; asking again walked every file twice.
            let folder = modelManager.modelFolder(for: size)
            return WhisperModelInfo(
                size: size,
                filePath: folder,
                isDownloaded: folder != nil || modelManager.isModelDownloaded(size),
                isActive: size.rawValue == selectedModelSize,
                isSupported: modelManager.isModelSupported(size)
            )
        }
    }

    /// Resolve WhisperKit's recommended exact model variant into app metadata.
    private func recommendedModelSize() -> ModelSize? {
        guard let recommended = deviceRecommendedModel,
              let size = modelManager.modelSize(from: recommended),
              modelManager.isModelSupported(size) else {
            return nil
        }
        return size
    }

    /// The model a load with no explicit size should use: the stored
    /// preference, corrected to something this Mac supports, else whatever
    /// this device is recommended. Nil only when the catalog offers nothing.
    func resolvedDefaultModel() -> ModelSize? {
        if let stored = ModelSize(rawValue: selectedModelSize) {
            return startupFallbackModel(for: stored)
        }
        return currentModel?.size ?? recommendedModelSize()
    }

    /// Pick a supported startup model when the stored preference is no longer valid.
    func startupFallbackModel(for preferred: ModelSize) -> ModelSize {
        guard !modelManager.isModelSupported(preferred) else {
            return preferred
        }

        // Stay on the engine the user was already using where possible.
        // Without this, the catalog order alone decides the fallback, and a
        // Whisper user could land on a different engine — notably Apple
        // Speech, which always counts as downloaded because macOS owns it.
        if let sameEngine = availableModels.last(where: {
            $0.size.engine == preferred.engine && $0.isSupported && $0.isDownloaded
        })?.size {
            return sameEngine
        }

        // Custom Endpoint is always marked downloaded (nothing to install) and
        // sits last in the catalog, so leaving it in this fallback would auto-
        // select a remote upload path the user never chose. Keep it only when
        // it was the explicit preference (handled by the early return above).
        if let downloadedSupported = availableModels.last(where: {
            $0.isSupported && $0.isDownloaded && $0.size.engine != .customEndpoint
        })?.size {
            return downloadedSupported
        }

        if let recommended = recommendedModelSize() {
            return recommended
        }

        return .tiny
    }
}
