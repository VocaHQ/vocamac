// CalmModelsStorage.swift
// VocaMac
//
// The bottom of each Models tab: On this Mac (the tab's downloaded models
// with their size on disk, last use, Use and Remove) and This Mac (chip,
// memory, the space models take and Free up space).

import AppKit
import SwiftUI

/// Which Models tab a storage section belongs to.
enum CalmModelsStorageTab {
    case speech(CalmSpeechPickFlow)
    case writing(CalmWritingPickFlow)
}

/// On this Mac and This Mac for one tab. Measures the downloads off the
/// main thread, again whenever a model arrives, leaves or goes into use.
struct CalmModelsOnThisMac: View {
    let tab: CalmModelsStorageTab

    @EnvironmentObject private var appState: AppState
    @State private var storage: CalmModelStorage?
    @State private var showsFreeUp = false

    var body: some View {
        VStack(alignment: .leading, spacing: CalmMetrics.sheetGap) {
            if let storage {
                downloads(storage)
                thisMac(storage)
            }
        }
        .task(id: measureKey) { storage = await appState.calmMeasureModelStorage() }
        .calmDialog(isPresented: $showsFreeUp) {
            CalmFreeUpSpaceDialog(models: idleModels) { remove(idleModels) }
        }
    }

    /// Changes whenever the list or its In use labels would.
    private var measureKey: String {
        let speech = appState.calmDownloadedSpeechModels.map(\.rawValue)
        let writing = appState.calmDownloadedWritingModels.map(\.rawValue)
        let inUse = [appState.calmLoadedSpeechModel?.rawValue, appState.calmCleanupModelInUse?.rawValue]
        let removals = String(appState.unlistedModelRemovals)
        return (speech + ["|"] + writing + ["|"] + inUse.map { $0 ?? "-" } + [removals]).joined(separator: ",")
    }

    private var idleModels: [CalmDownloadedModel] {
        storage?.idle(removable: canRemove) ?? []
    }

    // MARK: On this Mac

    @ViewBuilder
    private func downloads(_ storage: CalmModelStorage) -> some View {
        let models: [CalmDownloadedModel] = {
            switch tab {
            case .speech: return storage.speech
            case .writing: return storage.writing
            }
        }()
        if !models.isEmpty {
            let total = CalmModelStorage(speech: models).totalBytes
            CalmGroup(nil) {
                HStack(alignment: .firstTextBaseline) {
                    Text("On this Mac").calmType(.groupLabel).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Text("\(models.count) \(models.count == 1 ? "model" : "models") · \(CalmModelText.size(bytes: total))")
                        .font(CalmFont.note)
                        .foregroundStyle(CalmColor.muted)
                }
                .padding(.horizontal, 2)
                CalmPanel {
                    ForEach(models) { model in
                        row(model)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ model: CalmDownloadedModel) -> some View {
        switch (model.id, tab) {
        case (.speech(let size), .speech(let flow)):
            speechRow(size, model: model, flow: flow)
        case (.writing(let kind), .writing(let flow)):
            writingRow(kind, model: model, flow: flow)
        default:
            EmptyView()
        }
    }

    private func speechRow(_ size: ModelSize, model: CalmDownloadedModel, flow: CalmSpeechPickFlow) -> some View {
        let info = appState.availableModels.first { $0.size == size }
        let state = info.map {
            CalmSpeechModelState(model: $0, failed: false, endpointIsValid: appState.calmSpeechEndpointIsValid)
        } ?? .onThisMac
        let status: CalmDownloadedStatus
        switch state {
        case _ where info == nil: status = .note("Not offered on this Mac")
        case .inUse: status = .inUse("In use")
        case .loading(let text): status = .busy(CalmSpeechModelsTab.loadingText(text))
        case .downloading(let progress): status = .busy("Downloading \(Int((progress * 100).rounded()))%")
        default: status = .idle
        }
        return CalmDownloadedRow(
            name: CalmModelText.name(size),
            variant: CalmModelText.variant(size, isBundled: appState.modelManager.bundledModelFolder(for: size) != nil),
            logo: CalmLogoName(engine: size.engine),
            meta: meta(model),
            status: status,
            canRemove: canRemove(.speech(size)),
            onUse: { flow.pick(size, appState: appState) },
            onRemove: { flow.prompt = .remove(size) },
            menu: { CalmSpeechModelMenu(size: size, flow: flow) }
        )
    }

    private func writingRow(_ kind: CleanupModelKind, model: CalmDownloadedModel, flow: CalmWritingPickFlow) -> some View {
        let state = CalmWritingModelState(kind: kind, appState: appState, failed: false)
        let status: CalmDownloadedStatus
        switch state {
        case .inUse: status = .inUse(appState.sharesAIModel ? "In use for both" : "In use")
        case .commandModeOnly: status = .inUse("Used by Command Mode")
        case .loading: status = .busy("Getting ready…")
        case .downloading(let progress): status = .busy("Downloading \(Int((progress * 100).rounded()))%")
        case .failed, .onThisMac, .needsDownload: status = .idle
        }
        return CalmDownloadedRow(
            name: CalmModelText.name(kind),
            variant: CalmModelText.variant(kind),
            logo: kind == .ministral3_3b_q4_k_m ? .ministral : .qwen,
            meta: meta(model),
            status: status,
            canRemove: CalmWritingPickFlow.canRemove(kind, appState: appState),
            onUse: { flow.pick(kind, appState: appState) },
            onRemove: { flow.prompt = .remove(kind) },
            menu: { CalmWritingModelMenu(kind: kind, flow: flow) }
        )
    }

    /// “1.6 GB · Used 3 days ago”.
    private func meta(_ model: CalmDownloadedModel) -> String {
        ([CalmModelText.size(bytes: model.bytes)] + [CalmModelText.lastUsed(model.usage)].compactMap { $0 })
            .joined(separator: " · ")
    }

    // MARK: This Mac

    private func thisMac(_ storage: CalmModelStorage) -> some View {
        let idle = idleModels
        return CalmGroup("This Mac") {
            CalmPanel {
                CalmRow("Chip and memory", description: appState.calmDeviceSummary)
                CalmRow("Storage", description: storageNote(storage, idle: idle)) {
                    if !idle.isEmpty {
                        Button("Free up space…") { showsFreeUp = true }.calmButton(.secondary)
                    }
                }
                .settingsTarget("models-storage")
            }
        }
    }

    private func storageNote(_ storage: CalmModelStorage, idle: [CalmDownloadedModel]) -> String {
        let usage = CalmModelText.storage(totalBytes: storage.totalBytes, freeBytes: storage.freeBytes)
        guard !idle.isEmpty else { return usage }
        let count = idle.count == 1 ? "1 model hasn’t" : "\(idle.count) models haven’t"
        return "\(usage). \(count) been used in \(ModelUsageLog.idleDays) days."
    }

    // MARK: Removing

    private func canRemove(_ id: DownloadedModelID) -> Bool {
        switch id {
        case .speech(let size):
            guard let info = appState.availableModels.first(where: { $0.size == size }) else {
                // Not offered here, so not loadable: removable unless loaded.
                return appState.calmLoadedSpeechModel != size && size != .tiny
            }
            return CalmSpeechPickFlow.canRemove(info)
        case .writing(let kind):
            return CalmWritingPickFlow.canRemove(kind, appState: appState)
        }
    }

    private func remove(_ models: [CalmDownloadedModel]) {
        Task { @MainActor in
            for model in models where canRemove(model.id) {
                switch model.id {
                case .speech(let size): await appState.deleteModel(size)
                case .writing(let kind): appState.deleteCleanupModel(kind)
                }
            }
        }
    }
}

// MARK: - Row

/// What a downloaded row shows on the right.
enum CalmDownloadedStatus: Equatable {
    case inUse(String)
    /// Loading or downloading: no Use button meanwhile.
    case busy(String)
    /// Nothing to do but read, like a model this Mac no longer offers.
    case note(String)
    case idle
}

/// One downloaded model: logo, name and variant, size and last use, then
/// In use or Use, and Remove. Right-click opens the model's menu.
struct CalmDownloadedRow<Menu: View>: View {
    let name: String
    var variant: String?
    let logo: CalmLogoName
    let meta: String
    let status: CalmDownloadedStatus
    let canRemove: Bool
    let onUse: () -> Void
    let onRemove: () -> Void
    @ViewBuilder let menu: () -> Menu

    var body: some View {
        HStack(spacing: 12) {
            CalmLogo(logo, box: 28)
            VStack(alignment: .leading, spacing: 2) {
                (Text(name).font(CalmFont.rowTitle).foregroundStyle(CalmColor.ink)
                    + Text(variant.map { " \($0)" } ?? "").font(CalmFont.body).foregroundStyle(CalmColor.muted))
                    .lineLimit(1)
                Text(meta).font(CalmFont.note).foregroundStyle(CalmColor.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
            if canRemove {
                Button(action: onRemove) { CalmIcon(.trash, size: 15) }
                    .calmIconButton(size: 28)
                    .help("Remove from this Mac")
                    .accessibilityLabel("Remove \(name) from this Mac")
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, CalmMetrics.rowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu { menu() }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var trailing: some View {
        switch status {
        case .inUse(let text):
            Text(text).font(CalmFont.sf(12.5, weight: 600)).foregroundStyle(CalmColor.accent).fixedSize()
        case .busy(let text):
            HStack(spacing: 5) {
                CalmSpinner(size: 13, weight: 2.4)
                Text(text)
            }
            .font(CalmFont.note)
            .foregroundStyle(CalmColor.ink2)
            .fixedSize()
        case .note(let text):
            Text(text).font(CalmFont.note).foregroundStyle(CalmColor.muted).fixedSize()
        case .idle:
            Button("Use", action: onUse)
                .calmButton(.secondary, size: .small)
                .accessibilityLabel("Use \(name)")
        }
    }
}

// MARK: - Free up space

/// Lists the idle models and removes them all.
struct CalmFreeUpSpaceDialog: View {
    let models: [CalmDownloadedModel]
    let onRemove: () -> Void

    var body: some View {
        let total = CalmModelStorage(speech: models).totalBytes
        CalmDialog(
            "Free up \(CalmModelText.size(bytes: total))?",
            description: "These models haven’t been used in \(ModelUsageLog.idleDays) days. You can download them again any time."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(models) { model in
                    HStack {
                        Text(Self.name(model.id)).font(CalmFont.body).foregroundStyle(CalmColor.ink)
                        Spacer(minLength: 8)
                        Text(CalmModelText.size(bytes: model.bytes)).font(CalmFont.note).foregroundStyle(CalmColor.muted)
                    }
                }
            }
            .calmDialogScrollingList()
        } footer: {
            CalmDialogFooter(
                primaryTitle: models.count == 1 ? "Remove 1 model" : "Remove \(models.count) models",
                primaryKind: .destructive,
                onPrimary: onRemove
            )
        }
    }

    static func name(_ id: DownloadedModelID) -> String {
        switch id {
        case .speech(let size): return CalmModelText.name(size)
        case .writing(let kind): return CalmModelText.name(kind)
        }
    }
}

// MARK: - Show in Finder

enum CalmModelFiles {
    /// Where a downloaded model's files are, or nil when nothing is on disk.
    @MainActor
    static func location(of id: DownloadedModelID, appState: AppState) -> URL? {
        switch id {
        case .speech(let size): return appState.modelManager.modelFolder(for: size)
        case .writing(let kind): return appState.transcriptCleanup.modelFileURL(for: kind)
        }
    }

    /// Selects the model's folder or file in Finder.
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
