// CalmModelsActions.swift
// VocaMac
//
// What picking a model in Settings › Models does, following the board's
// Behaviour rules: a model that isn't downloaded starts downloading at once
// while the current one keeps working, then VocaMac switches and loads it;
// one download at a time (picking another stops the first); downloads go on
// when the sheet closes. The pick in flight and a failed download live here,
// outside the views, so they survive the sheet closing and reopening.

import Observation
import SwiftUI

/// The pick in flight on each Models tab, and the last one that failed.
@MainActor
@Observable
final class CalmModelPicker {
    /// The one picker the window shares.
    static let shared = CalmModelPicker()

    /// The speech model being downloaded or loaded because the user picked it.
    private(set) var pendingSpeech: ModelSize?
    /// The speech model whose download last failed (cleared by the next pick).
    private(set) var failedSpeech: ModelSize?
    /// The writing model being downloaded or loaded because the user picked it.
    private(set) var pendingWriting: CleanupModelKind?
    /// The writing model whose download last failed.
    private(set) var failedWriting: CleanupModelKind?
    /// The model being fetched for Command Mode alone.
    private(set) var pendingCommandMode: CleanupModelKind?

    @ObservationIgnored private var cancelledSpeech: Set<ModelSize> = []
    @ObservationIgnored private var cancelledWriting: Set<CleanupModelKind> = []

    // MARK: Speech

    /// Start using `size`: download it first when needed, then load it. The
    /// model in use keeps working until the new one is ready.
    func startSpeech(_ size: ModelSize, cancelling other: ModelSize?, appState: AppState) {
        if let other { cancelSpeechDownload(other, appState: appState) }
        failedSpeech = nil
        cancelledSpeech.remove(size)
        pendingSpeech = size
        Task { @MainActor [weak self] in
            if appState.availableModels.first(where: { $0.size == size })?.isDownloaded != true {
                await appState.downloadModel(size)
            }
            guard let self, self.pendingSpeech == size else { return }
            guard appState.availableModels.first(where: { $0.size == size })?.isDownloaded == true else {
                self.pendingSpeech = nil
                if !self.cancelledSpeech.contains(size) { self.failedSpeech = size }
                return
            }
            await appState.loadModel(size)
            if self.pendingSpeech == size { self.pendingSpeech = nil }
        }
    }

    /// Stop a speech model's download. The model in use stays.
    func cancelSpeechDownload(_ size: ModelSize, appState: AppState) {
        cancelledSpeech.insert(size)
        if pendingSpeech == size { pendingSpeech = nil }
        appState.modelManager.cancelDownload(for: size)
    }

    /// Forget a failure once its card has been seen to fail and the user moved on.
    func clearSpeechFailure() { failedSpeech = nil }

    // MARK: Writing

    /// Put `kind` to work for `role`, downloading it first when needed.
    /// Picking a model on this Mac while cleanup runs on a server brings
    /// cleanup back to this Mac once the model is downloaded and loaded.
    func startWriting(_ kind: CleanupModelKind, role: CalmWritingRole, cancelling other: CleanupModelKind?, appState: AppState) {
        if other != nil { cancelWritingDownload(appState: appState) }
        failedWriting = nil
        cancelledWriting.remove(kind)
        let isForCleanup = role != .commandMode
        if isForCleanup { pendingWriting = kind } else { pendingCommandMode = kind }
        let movesFromServer = isForCleanup && !appState.cleanupEndpoint.isLocal
        Task { @MainActor [weak self] in
            // Only `.cleanup` may move both while they share a model: a
            // Command-Mode-only or cleanup-only pick must not change the other.
            if role != .cleanup, appState.sharesAIModel { await appState.setSharesAIModel(false) }
            if movesFromServer {
                await appState.calmMoveCleanupToThisMac(kind, for: role.aiRole) { [weak self] in
                    self?.pendingWriting == kind
                }
            } else {
                await appState.useAIModel(kind, for: role.aiRole)
            }
            guard let self else { return }
            if isForCleanup {
                guard self.pendingWriting == kind else { return }
                self.pendingWriting = nil
            } else {
                guard self.pendingCommandMode == kind else { return }
                self.pendingCommandMode = nil
            }
            if !appState.transcriptCleanup.isDownloaded(kind), !self.cancelledWriting.contains(kind) {
                self.failedWriting = kind
            }
        }
    }

    /// Download a writing model without using it yet.
    func downloadWritingOnly(_ kind: CleanupModelKind, appState: AppState) {
        failedWriting = nil
        cancelledWriting.remove(kind)
        Task { @MainActor [weak self] in
            await appState.downloadAIModel(kind)
            guard let self else { return }
            if !appState.transcriptCleanup.isDownloaded(kind), !self.cancelledWriting.contains(kind) {
                self.failedWriting = kind
            }
        }
    }

    /// Stop the writing model download in progress.
    func cancelWritingDownload(appState: AppState) {
        if case .downloading(let kind, _) = appState.transcriptCleanup.modelState {
            cancelledWriting.insert(kind)
            if pendingWriting == kind { pendingWriting = nil }
            if pendingCommandMode == kind { pendingCommandMode = nil }
        }
        appState.cancelCleanupDownload()
    }
}

// MARK: - Speech card and row state

/// Where one speech model stands, for its card or row.
enum CalmSpeechModelState: Equatable {
    case inUse
    case loading(String)
    case downloading(Double)
    case failed
    case onThisMac
    case needsDownload
    case needsSetup
    case server

    init(model: WhisperModelInfo, failed: Bool, endpointIsValid: Bool) {
        if let progress = model.downloadProgress {
            self = .downloading(progress)
        } else if model.isLoading {
            self = .loading(model.loadingStatus)
        } else if model.isActive {
            self = .inUse
        } else if failed {
            self = .failed
        } else if model.size.isRemotelyHosted {
            self = endpointIsValid ? .server : .needsSetup
        } else if model.isDownloaded {
            self = .onThisMac
        } else {
            self = .needsDownload
        }
    }
}

/// Where one writing model stands, for its card or row.
enum CalmWritingModelState: Equatable {
    case inUse
    case commandModeOnly
    case loading
    case downloading(Double)
    case failed
    case onThisMac
    case needsDownload

    @MainActor
    init(kind: CleanupModelKind, appState: AppState, failed: Bool) {
        let state = appState.transcriptCleanup.modelState
        if case .downloading(let active, let progress) = state, active == kind {
            self = .downloading(progress)
        } else if case .loading(let active) = state, active == kind {
            self = .loading
        } else if failed {
            self = .failed
        } else if !appState.transcriptCleanup.isDownloaded(kind) {
            self = .needsDownload
        } else if appState.calmCleanupModelInUse == kind {
            self = .inUse
        } else if appState.commandModeEngine == .local(kind) {
            self = .commandModeOnly
        } else {
            self = .onThisMac
        }
    }
}
