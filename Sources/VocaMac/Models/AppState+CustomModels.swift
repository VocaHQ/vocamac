// AppState+CustomModels.swift
// VocaMac
//
// Bringing your own model: importing a folder or .zip with a
// `vocamodel.json`, choosing which imported model a slot runs, deleting one,
// and the community catalog of vetted models. The files and checks live in
// `CustomModelRegistry`; this decides what the running app does about them.

import Foundation

extension AppState {
    /// Imported models, or none when the model manager can't import (tests).
    var importedModels: [InstalledCustomModel] {
        (modelManager as? CustomModelManaging)?.importedModels() ?? []
    }

    /// Whether `model` is the one its slot runs now.
    func isActiveImportedModel(_ model: InstalledCustomModel) -> Bool {
        if let slot = model.manifest.engine.modelSlot {
            return slot.activeCustomModel?.id == model.id
        }
        return CustomModelRegistry.shared.activeModel(for: .cleanup)?.id == model.id
    }

    /// Whether `model` is what dictation, cleanup or Command Mode uses now.
    func isImportedModelInUse(_ model: InstalledCustomModel) -> Bool {
        guard isActiveImportedModel(model) else { return false }
        if let slot = model.manifest.engine.modelSlot {
            return selectedModelSize == slot.rawValue
        }
        let users = Self.importedGGUFUsers(cleanupKind: selectedCleanupModelKind, commandEngine: commandModeEngine)
        return users.cleanup || users.command
    }

    /// Which of cleanup and Command Mode run the imported GGUF slot.
    nonisolated static func importedGGUFUsers(
        cleanupKind: CleanupModelKind, commandEngine: CommandModeEngine
    ) -> (cleanup: Bool, command: Bool) {
        var command = false
        if case .local(.customGGUF) = commandEngine { command = true }
        return (cleanupKind == .customGGUF, command)
    }

    // MARK: Importing

    /// Check and copy in a model. Returns nil when it worked, or why not.
    func importModel(from source: URL) async -> String? {
        guard let manager = modelManager as? CustomModelManaging else { return "This build can't import models." }
        do {
            let installed = try await manager.importCustomModel(from: source)
            rebuildAvailableModels()
            objectWillChange.send()
            VocaLogger.info(.appState, "Imported \(installed.manifest.name)")
            return nil
        } catch {
            VocaLogger.warning(.appState, "Model import failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    /// Make `model` the one its slot runs, and use it now: load it for
    /// dictation, or for cleanup.
    func useImportedModel(_ model: InstalledCustomModel) async {
        guard let manager = modelManager as? CustomModelManaging else { return }
        do {
            try manager.activateCustomModel(id: model.id, persist: true)
        } catch {
            showTemporaryError(error.localizedDescription)
            return
        }
        rebuildAvailableModels()
        objectWillChange.send()
        if let slot = model.manifest.engine.modelSlot {
            await loadModel(slot)
        } else {
            // The slot's kind doesn't change between imported GGUFs, so the
            // service would treat a loaded one as already in place.
            if transcriptCleanup.loadedKind == .customGGUF { transcriptCleanup.unload() }
            if transcriptCleanupEnabled {
                await loadCleanupModel(.customGGUF)
            } else {
                transcriptCleanupModel = CleanupModelKind.customGGUF.rawValue
            }
        }
    }

    /// Delete an imported model. One in use is swapped out first, so no
    /// engine is left holding files that are gone.
    func deleteImportedModel(_ model: InstalledCustomModel) async {
        guard let manager = modelManager as? CustomModelManaging else { return }
        let wasInUse = isImportedModelInUse(model)
        let ggufUsers = Self.importedGGUFUsers(cleanupKind: selectedCleanupModelKind, commandEngine: commandModeEngine)
        if wasInUse {
            if model.manifest.engine.modelSlot != nil {
                let fallback = importedReplacement(for: model) == nil ? recommendedModelSize() : nil
                await whisperService.unloadModel()
                if let fallback { selectedModelSize = fallback.rawValue }
            } else {
                // Services match a loaded model by kind alone, so one still
                // holding this GGUF would keep serving it under the next
                // model's name. Unload every slot that has it.
                if transcriptCleanup.loadedKind == .customGGUF { transcriptCleanup.unload() }
                if commandModelSlot?.loadedKind == .customGGUF { commandModelSlot?.unload() }
                let hasReplacement = importedReplacement(for: model) != nil
                if ggufUsers.cleanup, !hasReplacement {
                    transcriptCleanupModel = CleanupModelKind.defaultKind.rawValue
                }
                if ggufUsers.command, !hasReplacement {
                    commandModeEngine = .local(.defaultKind)
                }
            }
        }
        do {
            try await manager.deleteCustomModel(id: model.id)
        } catch {
            showTemporaryError("Could not delete \(model.manifest.name): \(error.localizedDescription)")
        }
        rebuildAvailableModels()
        objectWillChange.send()
        if wasInUse {
            if let slot = model.manifest.engine.modelSlot, slot.activeCustomModel != nil {
                await loadModel(slot)
            } else if model.manifest.engine.modelSlot != nil {
                await loadModel(ModelSize(rawValue: selectedModelSize))
            } else {
                await syncTranscriptCleanup()
            }
        }
    }

    /// The imported model of the same engine that takes over when `model`
    /// is deleted: the only one left, which the registry then picks.
    private func importedReplacement(for model: InstalledCustomModel) -> InstalledCustomModel? {
        let others = importedModels.filter { $0.manifest.engine == model.manifest.engine && $0.id != model.id }
        return others.count == 1 ? others[0] : nil
    }

    // MARK: Community catalog

    /// How often the catalog is asked for, on the update check's schedule.
    static let communityCatalogInterval: TimeInterval = 24 * 60 * 60
    static let communityCatalogCheckedKey = "vocamac.customModel.communityCatalogCheckedAt"

    /// Vetted community models from the last fetch.
    var communityModels: [CommunityModelEntry] {
        CommunityModelCatalog().cachedEntries()
    }

    /// Ask for the catalog if a day has passed, alongside the update check.
    /// Builds without self-update (the App Store) never ask.
    func refreshCommunityModelsIfNeeded(now: Date = Date()) async {
        guard AppDistribution.hasSelfUpdate, !skipSystemIntegration else { return }
        let last = UserDefaults.standard.double(forKey: Self.communityCatalogCheckedKey)
        guard now.timeIntervalSince1970 - last > Self.communityCatalogInterval else { return }
        await refreshCommunityModels()
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.communityCatalogCheckedKey)
    }

    /// Ask for the catalog now (Settings' Check button).
    func refreshCommunityModels() async {
        _ = await CommunityModelCatalog().refresh()
        objectWillChange.send()
    }

    /// Download a community model's .zip, check it, and import it. Returns
    /// nil when it worked, or why not.
    func installCommunityModel(_ entry: CommunityModelEntry, onProgress: @escaping @Sendable (Double) -> Void) async -> String? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vocamac-community-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = folder.appendingPathComponent("\(entry.id).zip")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await FileDownloader.download(from: entry.downloadURL, to: archive, onProgress: onProgress)
            if let expected = entry.archiveSHA256?.lowercased() {
                let actual = try await ModelManager.sha256HexInBackground(ofFileAt: archive)
                guard actual == expected else {
                    return CustomModelError.checksumMismatch(expected: expected, actual: actual).localizedDescription
                }
            }
        } catch is CancellationError {
            return nil
        } catch {
            return "Could not download \(entry.manifest.name): \(error.localizedDescription)"
        }
        return await importModel(from: archive)
    }
}
