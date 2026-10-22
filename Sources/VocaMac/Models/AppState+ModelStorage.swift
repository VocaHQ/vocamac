// AppState+ModelStorage.swift
// VocaMac
//
// What Settings › Models shows about this Mac: the models on disk with
// their real size and last use, free space, memory and chip, how well a
// model fits this Mac, and which models Free up space offers.

import Foundation

// MARK: - Downloaded models

/// One downloaded model in a Models tab's On this Mac list.
struct CalmDownloadedModel: Identifiable, Equatable, Sendable {
    let id: DownloadedModelID
    /// Where its files are, for Show in Finder.
    let location: URL?
    /// Its size on disk, measured.
    let bytes: Int64
    let usage: ModelUsageLog.Entry?
}

/// The downloaded models and the room left beside them, measured off the
/// main thread.
struct CalmModelStorage: Equatable, Sendable {
    var speech: [CalmDownloadedModel] = []
    var writing: [CalmDownloadedModel] = []
    /// Free space on the volume holding the models; nil when unreadable.
    var freeBytes: Int64?

    var all: [CalmDownloadedModel] { speech + writing }

    /// Disk use of every listed model. Models that share a folder (Parakeet
    /// versions served from one cache) count once.
    var totalBytes: Int64 {
        var seen = Set<String>()
        return all.reduce(0) { total, model in
            if let path = model.location?.standardizedFileURL.path, !seen.insert(path).inserted { return total }
            return total + model.bytes
        }
    }

    /// The models Free up space offers: removable, and idle for
    /// `ModelUsageLog.idleDays`.
    func idle(removable: (DownloadedModelID) -> Bool, now: Date = Date()) -> [CalmDownloadedModel] {
        all.filter { removable($0.id) && ModelUsageLog.isIdle($0.usage, now: now) }
    }
}

// MARK: - Fit

/// How a model sits in this Mac's memory, for the All models rows.
enum CalmMemoryFit: Equatable, Sendable {
    /// Within the share a pick card may use.
    case comfortable
    /// Loads, but takes much of the memory beside the user's apps.
    case tight
    /// Needs more memory than this Mac has; the load is refused.
    case tooBig

    /// The fit of a model needing `requiredGB` on a Mac with `memoryGB`,
    /// where the cards keep to `share` of it.
    static func of(requiredGB: Double, memoryGB: Int, share: Double) -> CalmMemoryFit {
        if requiredGB > Double(memoryGB) { return .tooBig }
        if requiredGB > Double(memoryGB) * share { return .tight }
        return .comfortable
    }

    /// The amber line a row shows, or nil when it fits comfortably.
    func warning(requiredGB: Double, memoryGB: Int) -> String? {
        let need = CalmModelText.trimmed(requiredGB, decimals: 1)
        switch self {
        case .comfortable: return nil
        case .tight: return "Needs about \(need) GB, a lot for this Mac’s \(memoryGB) GB"
        case .tooBig: return "Needs about \(need) GB, more than this Mac has"
        }
    }
}

// MARK: - Text

extension CalmModelText {
    /// “Used today”, “Used yesterday”, “Used 3 days ago”, “Used 5 weeks ago”;
    /// nil when the log has no use on record.
    static func lastUsed(_ entry: ModelUsageLog.Entry?, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let used = entry?.lastUsed else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: used), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: return "Used today"
        case 1: return "Used yesterday"
        case 2..<14: return "Used \(days) days ago"
        case 14..<60: return "Used \(days / 7) weeks ago"
        default: return "Used \(days / 30) months ago"
        }
    }

    /// “Apple M1 Pro · 16 GB memory”.
    static func device(chip: String, memoryGB: Int) -> String {
        let known = !chip.isEmpty && chip != "Unknown"
        return known ? "\(chip) · \(memoryGB) GB memory" : "\(memoryGB) GB memory"
    }

    /// “Models use 5.8 GB · 120 GB free”.
    static func storage(totalBytes: Int64, freeBytes: Int64?) -> String {
        let used = "Models use \(size(bytes: totalBytes))"
        guard let freeBytes else { return used }
        return "\(used) · \(roughSize(bytes: freeBytes)) free"
    }

    /// Free space, without false precision: “115 GB”, “4.2 GB”.
    static func roughSize(bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_000_000_000
        if gigabytes >= 10 { return "\(Int(gigabytes.rounded())) GB" }
        if gigabytes >= 1 { return "\(trimmed(gigabytes, decimals: 1)) GB" }
        return size(bytes: bytes)
    }
}

// MARK: - AppState

extension AppState {
    /// Speech models with files on this Mac. Apple Speech and your own
    /// server keep theirs elsewhere.
    var calmDownloadedSpeechModels: [ModelSize] {
        availableModels
            .filter { $0.isDownloaded && !$0.size.isSystemManaged && !$0.size.isRemotelyHosted }
            .map(\.size)
    }

    /// Writing models with a GGUF on this Mac.
    var calmDownloadedWritingModels: [CleanupModelKind] {
        CleanupModelKind.allCases.filter { transcriptCleanup.isDownloaded($0) }
    }

    /// Measure the downloaded models and free space. Folder walks run off
    /// the main thread: a large Whisper model is thousands of files.
    func calmMeasureModelStorage() async -> CalmModelStorage {
        let listed = calmDownloadedSpeechModels
        let writing = calmDownloadedWritingModels.map { (DownloadedModelID.writing($0), transcriptCleanup.modelFileURL(for: $0)) }
        let manager = modelManager
        let volume = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let found = await Task.detached(priority: .utility) {
            // Every model on disk, not just the ones the picker offers this
            // Mac: an older download (Whisper Medium) stays on disk after
            // WhisperKit stops listing it, and still takes space.
            let onDisk = ModelSize.allCases.filter {
                !$0.isSystemManaged && !$0.isRemotelyHosted && !listed.contains($0) && manager.isModelDownloaded($0)
            }
            func measured(_ pairs: [(DownloadedModelID, URL?)]) -> [CalmDownloadedModel] {
                pairs.map { id, url in
                    CalmDownloadedModel(id: id, location: url, bytes: url.map(Self.diskBytes(at:)) ?? 0, usage: nil)
                }
            }
            let speech = (listed + onDisk).map { (DownloadedModelID.speech($0), manager.modelFolder(for: $0)) }
            return CalmModelStorage(
                speech: measured(speech),
                writing: measured(writing),
                freeBytes: volume.flatMap(ModelManager.volumeAvailableCapacity(at:))
            )
        }.value
        // The usage log lives on the main actor; attach it after measuring.
        modelUsageLog.noteSeen(found.all.map(\.id))
        let usage = modelUsageLog.entries()
        func withUsage(_ models: [CalmDownloadedModel]) -> [CalmDownloadedModel] {
            models.map { CalmDownloadedModel(id: $0.id, location: $0.location, bytes: $0.bytes, usage: usage[$0.id.storageKey]) }
        }
        return CalmModelStorage(speech: withUsage(found.speech), writing: withUsage(found.writing), freeBytes: found.freeBytes)
    }

    /// The size of a model folder, or of a single model file (a GGUF).
    nonisolated static func diskBytes(at url: URL) -> Int64 {
        let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true { return ModelManager.directorySize(at: url) }
        return Int64(values?.fileSize ?? 0)
    }

    /// Stamp the models in use after a dictation, at most once an hour. A
    /// model can stay loaded for weeks; without this its date would be its
    /// load, and once replaced by a path that doesn't stamp (cleanup moved
    /// to a server, Command Mode moved to Apple Intelligence) it would look
    /// idle the day it stopped being used.
    func stampModelsInUseIfStale(now: Date = Date()) {
        if let last = lastModelUsageStamp, now.timeIntervalSince(last) < 3600 { return }
        lastModelUsageStamp = now
        stampModelsInUse()
    }

    /// Stamp the models working now as used. Called as a model loads and
    /// before another replaces it, so the outgoing one keeps a fresh date.
    func stampModelsInUse() {
        var models: [DownloadedModelID] = []
        if let size = calmLoadedSpeechModel, !size.isSystemManaged, !size.isRemotelyHosted {
            models.append(.speech(size))
        }
        if let kind = calmCleanupModelInUse, transcriptCleanup.isDownloaded(kind) {
            models.append(.writing(kind))
        }
        if case .local(let kind) = commandModeEngine, transcriptCleanup.isDownloaded(kind) {
            models.append(.writing(kind))
        }
        modelUsageLog.markUsed(models)
    }

    /// How `size` fits this Mac's memory; nil for models whose memory
    /// isn't VocaMac's (Apple Speech, your own server).
    func calmMemoryFit(_ size: ModelSize) -> CalmMemoryFit? {
        guard !size.isSystemManaged, !size.isRemotelyHosted else { return nil }
        return .of(requiredGB: size.firstLoadRAMRequiredGB, memoryGB: calmMemoryGB, share: OnboardingModelGuidance.memoryShare)
    }

    /// How a writing model fits beside the speech model and the user's apps.
    func calmMemoryFit(_ kind: CleanupModelKind) -> CalmMemoryFit {
        .of(requiredGB: kind.descriptor.ramRequiredGB, memoryGB: calmMemoryGB, share: CalmModelPicks.writingMemoryShare)
    }

    /// “Apple M1 Pro · 16 GB memory”.
    var calmDeviceSummary: String {
        CalmModelText.device(chip: systemCapabilities?.processorName ?? SystemInfo.processorName, memoryGB: calmMemoryGB)
    }
}

extension CalmModelText {
    /// “Needs 2.1 GB free to download, 1.4 GB left”, when a download
    /// would be refused for space.
    static func diskWarning(required: Int64, free: Int64) -> String? {
        guard required > free else { return nil }
        return "Needs \(size(bytes: required)) free to download, \(roughSize(bytes: free)) left"
    }
}
