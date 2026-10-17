// CalmModelsFlows.swift
// VocaMac
//
// The steps between clicking a model and VocaMac using it: the questions a
// pick may need (experimental model, stopping a download past half way),
// details and Remove from this Mac, shared by the Models tabs and the All
// models lists. Each page owns one flow; `.calmSpeechPickDialogs(_:)` and
// `.calmWritingPickDialogs(_:)` attach its dialogs.

import Observation
import SwiftUI

// MARK: - Speech

/// One page's speech-model pick flow.
@MainActor
@Observable
final class CalmSpeechPickFlow {
    /// A question or sheet the flow is showing.
    enum Prompt: Identifiable {
        case experimental(ModelSize)
        case stopDownload(ModelSize, progress: Double, then: ModelSize)
        case details(ModelSize)
        case remove(ModelSize)

        var id: String {
            switch self {
            case .experimental(let size): return "experimental-\(size.rawValue)"
            case .stopDownload(let size, _, let next): return "stop-\(size.rawValue)-\(next.rawValue)"
            case .details(let size): return "details-\(size.rawValue)"
            case .remove(let size): return "remove-\(size.rawValue)"
            }
        }
    }

    var prompt: Prompt?
    var showsServer = false

    /// Pick `size`, asking first when the pick needs it.
    func pick(_ size: ModelSize, appState: AppState, confirmedExperimental: Bool = false, confirmedStop: Bool = false) {
        switch CalmModelPicks.speechStep(
            for: size, models: appState.availableModels,
            confirmedExperimental: confirmedExperimental, confirmedStop: confirmedStop
        ) {
        case .nothing:
            return
        case .setUpServer:
            showsServer = true
        case .confirmExperimental:
            prompt = .experimental(size)
        case .confirmStopDownload(let other, let progress):
            prompt = .stopDownload(other, progress: progress, then: size)
        case .start(let cancelling):
            CalmModelPicker.shared.startSpeech(size, cancelling: cancelling, appState: appState)
        }
    }

    /// Run `action` once the dialog that asked for it has closed, so a
    /// follow-up question isn't dismissed with it.
    func afterDismiss(_ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in action() }
    }

    /// Whether Remove from this Mac may be offered: never for the model in
    /// use, one busy loading or downloading, a built-in one, or Whisper Tiny.
    static func canRemove(_ model: WhisperModelInfo) -> Bool {
        model.isDownloaded && !model.isActive && !model.isLoading && model.downloadProgress == nil
            && !model.size.isSystemManaged && model.size != .tiny
    }
}

private struct CalmSpeechPickDialogs: ViewModifier {
    @Bindable var flow: CalmSpeechPickFlow
    @EnvironmentObject private var appState: AppState

    func body(content: Content) -> some View {
        content
            .calmDialog(item: $flow.prompt) { prompt in dialog(for: prompt) }
            .calmDialog(isPresented: $flow.showsServer) { CalmSpeechServerDialog() }
    }

    @ViewBuilder
    private func dialog(for prompt: CalmSpeechPickFlow.Prompt) -> some View {
        switch prompt {
        case .experimental(let size):
            let downloaded = appState.availableModels.first { $0.size == size }?.isDownloaded == true
            CalmConfirmDialog(
                title: "Use an experimental model?",
                message: "\(CalmModelText.name(size)) isn’t verified on this Mac’s chip. It may fail to load, or run slower than tuned models.",
                actionTitle: downloaded ? "Use anyway" : "Download and use",
                actionKind: .primary
            ) {
                flow.afterDismiss { flow.pick(size, appState: appState, confirmedExperimental: true) }
            }
        case .stopDownload(let other, let progress, let next):
            CalmConfirmDialog(
                title: "Stop downloading \(CalmModelText.name(other))?",
                message: "It’s \(Int((progress * 100).rounded()))% done. One model downloads at a time, so \(CalmModelText.name(next)) downloads instead.",
                actionTitle: "Stop and switch"
            ) {
                flow.afterDismiss {
                    flow.pick(next, appState: appState, confirmedExperimental: true, confirmedStop: true)
                }
            }
        case .details(let size):
            CalmModelDetailsDialog(speech: size, appState: appState) {
                flow.afterDismiss { flow.pick(size, appState: appState) }
            }
        case .remove(let size):
            CalmConfirmDialog(
                title: "Remove \(CalmModelText.name(size))?",
                message: "Frees \(CalmModelText.downloadSize(size)). You can download it again any time.",
                actionTitle: "Remove"
            ) {
                Task { await appState.deleteModel(size) }
            }
        }
    }
}

// MARK: - Writing

/// One page's writing-model pick flow.
@MainActor
@Observable
final class CalmWritingPickFlow {
    enum Prompt: Identifiable {
        case stopDownload(CleanupModelKind, progress: Double, then: CleanupModelKind, role: CalmWritingRole)
        case details(CleanupModelKind)
        case remove(CleanupModelKind)

        var id: String {
            switch self {
            case .stopDownload(let kind, _, let next, _): return "stop-\(kind.rawValue)-\(next.rawValue)"
            case .details(let kind): return "details-\(kind.rawValue)"
            case .remove(let kind): return "remove-\(kind.rawValue)"
            }
        }
    }

    var prompt: Prompt?
    var showsCleanupServer = false

    /// Pick `kind` for `role`, asking first when another download is past half way.
    func pick(_ kind: CleanupModelKind, role: CalmWritingRole = .cleanup, appState: AppState, confirmedStop: Bool = false) {
        switch CalmModelPicks.writingStep(
            for: kind, state: appState.transcriptCleanup.modelState,
            isInUse: Self.isInUse(kind, role: role, appState: appState), confirmedStop: confirmedStop
        ) {
        case .nothing:
            return
        case .confirmStopDownload(let other, let progress):
            prompt = .stopDownload(other, progress: progress, then: kind, role: role)
        case .start(let cancelling):
            CalmModelPicker.shared.startWriting(kind, role: role, cancelling: cancelling, appState: appState)
        }
    }

    func afterDismiss(_ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in action() }
    }

    /// Whether picking `kind` for `role` has nothing left to do: that job
    /// already runs it and its file is on this Mac. A configured model that
    /// isn't downloaded is not in use, so picking it downloads it.
    static func isInUse(_ kind: CleanupModelKind, role: CalmWritingRole, appState: AppState) -> Bool {
        guard appState.transcriptCleanup.isDownloaded(kind) else { return false }
        switch role {
        case .cleanup: return appState.calmCleanupModelInUse == kind
        case .cleanupOnly: return appState.calmCleanupModelInUse == kind && !appState.sharesAIModel
        case .commandMode: return appState.commandModeEngine == .local(kind) && !appState.sharesAIModel
        }
    }

    /// Never offered for a model either feature is using.
    @MainActor
    static func canRemove(_ kind: CleanupModelKind, appState: AppState) -> Bool {
        appState.transcriptCleanup.isDownloaded(kind)
            && appState.selectedCleanupModelKind != kind
            && appState.commandModeEngine != .local(kind)
    }
}

/// Which job a writing-model pick is for.
enum CalmWritingRole: Equatable, Sendable {
    /// Smart Cleanup, and Command Mode too while they share a model.
    case cleanup
    /// Smart Cleanup alone: stops sharing first.
    case cleanupOnly
    /// Command Mode alone.
    case commandMode

    var aiRole: AIModelRole { self == .commandMode ? .commandMode : .cleanup }
}

private struct CalmWritingPickDialogs: ViewModifier {
    @Bindable var flow: CalmWritingPickFlow
    @EnvironmentObject private var appState: AppState

    func body(content: Content) -> some View {
        content
            .calmDialog(item: $flow.prompt) { prompt in dialog(for: prompt) }
            .calmDialog(isPresented: $flow.showsCleanupServer) { CalmCleanupServerDialog() }
    }

    @ViewBuilder
    private func dialog(for prompt: CalmWritingPickFlow.Prompt) -> some View {
        switch prompt {
        case .stopDownload(let other, let progress, let next, let role):
            CalmConfirmDialog(
                title: "Stop downloading \(CalmModelText.name(other))?",
                message: "It’s \(Int((progress * 100).rounded()))% done. One model downloads at a time, so \(CalmModelText.name(next)) downloads instead.",
                actionTitle: "Stop and switch"
            ) {
                flow.afterDismiss { flow.pick(next, role: role, appState: appState, confirmedStop: true) }
            }
        case .details(let kind):
            CalmModelDetailsDialog(writing: kind, appState: appState) {
                flow.afterDismiss { flow.pick(kind, appState: appState) }
            }
        case .remove(let kind):
            CalmConfirmDialog(
                title: "Remove \(CalmModelText.name(kind))?",
                message: "Frees \(CalmModelText.downloadSize(kind)). You can download it again any time.",
                actionTitle: "Remove"
            ) {
                appState.deleteCleanupModel(kind)
            }
        }
    }
}

extension View {
    /// Attaches a speech pick flow's dialogs.
    func calmSpeechPickDialogs(_ flow: CalmSpeechPickFlow) -> some View {
        modifier(CalmSpeechPickDialogs(flow: flow))
    }

    /// Attaches a writing pick flow's dialogs.
    func calmWritingPickDialogs(_ flow: CalmWritingPickFlow) -> some View {
        modifier(CalmWritingPickDialogs(flow: flow))
    }
}
