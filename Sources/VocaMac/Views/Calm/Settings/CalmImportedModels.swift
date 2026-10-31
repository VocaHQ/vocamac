// CalmImportedModels.swift
// VocaMac
//
// Settings › Models › All models: models you brought yourself. Import a
// folder or .zip with a vocamodel.json, see where each came from and its
// licence, choose which one runs, delete it, or fetch one from the vetted
// community list.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The imported models panel and the community catalog under it.
struct CalmImportedModels: View {
    @EnvironmentObject private var appState: AppState

    @State private var isImporting = false
    @State private var message: String?
    @State private var busyID: String?
    @State private var progress: Double?
    @State private var confirmsDelete: InstalledCustomModel?

    var body: some View {
        let imported = appState.importedModels
        let installedIDs = Set(imported.map(\.id))
        let community = appState.communityModels.filter { !installedIDs.contains($0.id) }
        CalmGroup("Your own models") {
            VStack(alignment: .leading, spacing: 10) {
                CalmPanel {
                    ForEach(imported) { model in
                        row(model)
                    }
                    CalmRow(
                        imported.isEmpty ? "Import a model" : "Import another",
                        description: "A folder or .zip with a vocamodel.json: a Whisper CoreML fine-tune, "
                            + "a sherpa-onnx model, or a GGUF for Writing AI."
                    ) {
                        HStack(spacing: 8) {
                            if isImporting { ProgressView().controlSize(.small) }
                            Button("Import…", action: chooseAndImport)
                                .calmButton(.secondary)
                                .disabled(isImporting || busyID != nil)
                            Button("How") { NSWorkspace.shared.open(Self.guideURL) }
                                .calmButton(.quiet)
                        }
                    }
                }
                if AppDistribution.hasSelfUpdate {
                    communityPanel(community)
                }
                if let message {
                    CalmInlineNotice(message, tone: .warning)
                }
            }
        }
        .settingsTarget("imported-models")
        .calmDialog(item: $confirmsDelete) { model in
            CalmDialog(
                "Delete \(model.manifest.name)?",
                description: "This removes its files from this Mac. "
                    + (appState.isImportedModelInUse(model) ? "VocaMac switches to another model first." : "")
            ) {
                CalmDialogFooter(primaryTitle: "Delete", primaryKind: .destructive) {
                    Task { await appState.deleteImportedModel(model) }
                }
            }
        }
    }

    static let guideURL = URL(string: "https://github.com/VocaHQ/vocamac/blob/main/docs/CUSTOM_MODELS.md")
        ?? URL(fileURLWithPath: "/")

    // MARK: Rows

    private func row(_ model: InstalledCustomModel) -> some View {
        let inUse = appState.isImportedModelInUse(model)
        return CalmRow(model.manifest.name, description: { details(model) }, trailing: {
            HStack(spacing: 8) {
                if inUse {
                    CalmTag("In use", tone: .success)
                } else {
                    Button("Use") { Task { await appState.useImportedModel(model) } }
                        .calmButton(.secondary)
                        .disabled(busyID != nil)
                }
                Button("Delete") { confirmsDelete = model }
                    .calmButton(.quietDestructive)
            }
        })
    }

    private func details(_ model: InstalledCustomModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(CalmImportedModelText.summary(model))
                .font(CalmFont.note)
                .foregroundStyle(CalmColor.muted)
            if let provenance = CalmImportedModelText.provenance(model.manifest) {
                Text(provenance)
                    .font(CalmFont.note)
                    .foregroundStyle(CalmColor.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(provenance)
            }
        }
    }

    @ViewBuilder
    private func communityPanel(_ entries: [CommunityModelEntry]) -> some View {
        CalmPanel {
            ForEach(entries) { entry in
                CalmRow(entry.manifest.name, description: CalmImportedModelText.summary(entry)) {
                    HStack(spacing: 8) {
                        if busyID == entry.id {
                            if let progress { Text("\(Int(progress * 100))%").font(CalmFont.note) }
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Download") { install(entry) }
                                .calmButton(.secondary)
                                .disabled(busyID != nil || isImporting)
                        }
                    }
                }
            }
            CalmRow(
                "Community models",
                description: entries.isEmpty
                    ? "Models other people converted and VocaHQ checked. None are listed yet."
                    : "Models other people converted and VocaHQ checked. Nothing downloads until you choose one."
            ) {
                Button("Check") { Task { await appState.refreshCommunityModels() } }
                    .calmButton(.quiet)
            }
        }
    }

    // MARK: Actions

    private func chooseAndImport() {
        let panel = NSOpenPanel()
        panel.title = "Import a Model"
        panel.message = "Choose a model folder, or a .zip of one, with a vocamodel.json inside."
        panel.canChooseDirectories = true
        panel.canChooseFiles = !AppDistribution.isAppStore
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = AppDistribution.isAppStore ? [.folder] : [.folder, .zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isImporting = true
        message = nil
        Task {
            message = await appState.importModel(from: url)
            isImporting = false
        }
    }

    private func install(_ entry: CommunityModelEntry) {
        busyID = entry.id
        progress = 0
        message = nil
        Task {
            message = await appState.installCommunityModel(entry) { value in
                Task { @MainActor in progress = value }
            }
            busyID = nil
            progress = nil
        }
    }
}

/// The words the imported models panel uses.
enum CalmImportedModelText {
    /// “Whisper (CoreML) · 253 MB · Tamil · Verified”.
    static func summary(_ model: InstalledCustomModel) -> String {
        var parts = [model.manifest.engine.displayName]
        if let bytes = model.manifest.fileSizeBytes, bytes > 0 { parts.append(CalmModelText.size(bytes: bytes)) }
        if !model.manifest.languages.isEmpty { parts.append(SpokenLanguages.list(model.manifest.languages)) }
        parts.append(model.isVerified ? "Checksum verified" : "No checksum")
        return parts.joined(separator: " · ")
    }

    static func summary(_ entry: CommunityModelEntry) -> String {
        var parts = [entry.manifest.engine.displayName]
        if let bytes = entry.downloadBytes ?? entry.manifest.fileSizeBytes, bytes > 0 {
            parts.append(CalmModelText.size(bytes: bytes))
        }
        if !entry.manifest.languages.isEmpty { parts.append(SpokenLanguages.list(entry.manifest.languages)) }
        if let notes = entry.notes { parts.append(notes) }
        return parts.joined(separator: " · ")
    }

    /// “From huggingface.co/… · MIT licence”, or nil when the manifest says neither.
    static func provenance(_ manifest: CustomModelManifest) -> String? {
        var parts: [String] = []
        if let source = manifest.source, !source.isEmpty { parts.append("From \(source)") }
        if let license = manifest.license, !license.isEmpty { parts.append("\(license) licence") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
