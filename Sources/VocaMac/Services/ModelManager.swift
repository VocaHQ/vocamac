// ModelManager.swift
// VocaMac
//
// Manages model lifecycle across engines. WhisperKit models use WhisperKit's
// built-in model management; Parakeet models are downloaded and cached by
// FluidAudio; Apple Speech assets are owned by the OS. All models are CoreML
// format, downloaded from HuggingFace and cached locally.

import CryptoKit
import Foundation
import WhisperKit
import FluidAudio

// MARK: - ModelManagerError

enum ModelManagerError: LocalizedError {
    case modelNotAvailable(String)
    case downloadFailed(reason: String)
    case deviceNotSupported(model: String)
    case missingModelDirectory(String)
    case tokenizerAssetsUnavailable(String)
    case checksumMismatch(model: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .modelNotAvailable(let name):
            return "Model '\(name)' is not available."
        case .downloadFailed(let reason):
            return "Model download failed: \(reason)"
        case .deviceNotSupported(let model):
            return "Model '\(model)' is too large for this device."
        case .missingModelDirectory(let path):
            return "Model files are missing at: \(path)"
        case .tokenizerAssetsUnavailable(let model):
            return "Tokenizer assets are missing for model '\(model)'."
        case .checksumMismatch(let model, let expected, let actual):
            return "The download for '\(model)' did not match its expected contents "
                + "(expected \(expected.prefix(12))…, got \(actual.prefix(12))…). "
                + "It was discarded. Please try again."
        }
    }
}

// MARK: - ModelManager

final class ModelManager {

    // MARK: - Properties

    /// HuggingFace repository for WhisperKit CoreML models
    private let modelRepo = "argmaxinc/whisperkit-coreml"
    private let bundledModelsDirectory = "BundledModels/whisperkit-coreml"
    private let requiredTokenizerFiles = ["tokenizer.json", "tokenizer_config.json"]
    private let requiredModelDirectories = [
        "MelSpectrogram.mlmodelc",
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc"
    ]

    private var fileManager: FileManager { .default }

    /// Cached result of `totalDiskUsage()`, with the time it was measured.
    private var cachedDiskUsage: (bytes: Int64, measuredAt: CFAbsoluteTime)?
    private let diskUsageCacheLock = NSLock()

    /// How long a disk usage measurement stays valid without explicit
    /// invalidation. Covers model files changed outside the app.
    private static let diskUsageCacheTTL: CFAbsoluteTime = 5.0

    private var bundledModelsBase: URL? {
        Bundle.main.resourceURL?.appendingPathComponent(bundledModelsDirectory, isDirectory: true)
    }

    private func installedModelDirectory(for size: ModelSize) -> URL {
        modelStorageBase.appendingPathComponent(whisperKitModelName(for: size), isDirectory: true)
    }

    private func hasRequiredModelAssets(at directory: URL) -> Bool {
        requiredModelDirectories.allSatisfy { componentName in
            Self.hasUsableCoreMLComponent(at: directory.appendingPathComponent(componentName, isDirectory: true))
        }
    }

    /// Validate that a compiled CoreML component has both graph metadata and weights.
    static func hasUsableCoreMLComponent(at directory: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }

        let metadata = directory.appendingPathComponent("metadata.json")
        let hasMetadata = fileManager.fileExists(atPath: metadata.path)
        let hasModelDefinition = [
            "model.mil",
            "model.mlmodel",
            "coremldata.bin",
        ].contains { fileName in
            fileManager.fileExists(atPath: directory.appendingPathComponent(fileName).path)
        }
        let hasWeights = fileManager.fileExists(
            atPath: directory
                .appendingPathComponent("weights", isDirectory: true)
                .appendingPathComponent("weight.bin")
                .path
        )

        return hasMetadata && hasModelDefinition && hasWeights
    }

    private func hasRequiredTokenizerAssets(at directory: URL) -> Bool {
        requiredTokenizerFiles.allSatisfy { fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    private func createParentDirectoryIfNeeded(for directory: URL) throws {
        try fileManager.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func replaceDirectory(at destination: URL, with source: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private func tokenizerAssetSourceDirectory(for modelDirectory: URL) -> URL? {
        let snapshotsDirectory = modelDirectory.appendingPathComponent("snapshots", isDirectory: true)
        guard let snapshotDirectories = try? fileManager.contentsOfDirectory(
            at: snapshotsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return snapshotDirectories.first(where: { snapshotURL in
            (try? snapshotURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        })
    }

    private func repairTokenizerAssetsIfNeeded(in modelDirectory: URL, for size: ModelSize) throws {
        let modelName = whisperKitModelName(for: size)
        guard !hasRequiredTokenizerAssets(at: modelDirectory) else { return }

        // Search all known tokenizer locations (snapshots, openai cache, etc.)
        let candidates = tokenizerSearchDirectories(for: size)
        for candidateDir in candidates {
            if hasRequiredTokenizerAssets(at: candidateDir) {
                for fileName in requiredTokenizerFiles {
                    let sourceURL = candidateDir.appendingPathComponent(fileName)
                    let destinationURL = modelDirectory.appendingPathComponent(fileName)
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        try fileManager.removeItem(at: destinationURL)
                    }
                    try fileManager.copyItem(at: sourceURL, to: destinationURL)
                }
                VocaLogger.info(.modelManager, "Repaired tokenizer assets for \(modelName) from \(candidateDir.path)")
                return
            }
        }

        throw ModelManagerError.tokenizerAssetsUnavailable(modelName)
    }

    private func validateModelDirectory(_ directory: URL, for size: ModelSize) throws {
        guard hasRequiredModelAssets(at: directory) else {
            throw ModelManagerError.missingModelDirectory(directory.path)
        }
        try repairTokenizerAssetsIfNeeded(in: directory, for: size)
    }

    private func installBundledModel(from sourceDirectory: URL, to destinationDirectory: URL, for size: ModelSize) throws {
        let modelName = whisperKitModelName(for: size)
        try createParentDirectoryIfNeeded(for: destinationDirectory)
        try replaceDirectory(at: destinationDirectory, with: sourceDirectory)
        invalidateDiskUsageCache()
        try validateModelDirectory(destinationDirectory, for: size)
        VocaLogger.info(.modelManager, "Installed bundled model: \(modelName)")
    }

    private func bundledModelDirectory(forModelNamed modelName: String) -> URL? {
        guard let bundledModelsBase else { return nil }
        let directory = bundledModelsBase.appendingPathComponent(modelName, isDirectory: true)
        return fileManager.fileExists(atPath: directory.path) ? directory : nil
    }

    private func isBundledModelSupported(_ size: ModelSize) -> Bool {
        size == .tiny
    }

    private func ensureInstalledModelReady(for size: ModelSize) throws -> URL {
        let installedDirectory = installedModelDirectory(for: size)
        guard fileManager.fileExists(atPath: installedDirectory.path) else {
            throw ModelManagerError.missingModelDirectory(installedDirectory.path)
        }
        try validateModelDirectory(installedDirectory, for: size)
        return installedDirectory
    }

    func bundledModelFolder(for size: ModelSize) -> URL? {
        guard isBundledModelSupported(size) else { return nil }
        return bundledModelDirectory(forModelNamed: whisperKitModelName(for: size))
    }

    @discardableResult
    func installBundledModelIfAvailable(for size: ModelSize) throws -> Bool {
        guard let sourceDirectory = bundledModelFolder(for: size) else { return false }
        let destinationDirectory = installedModelDirectory(for: size)
        try installBundledModel(from: sourceDirectory, to: destinationDirectory, for: size)
        return true
    }

    func ensureTokenizerAssets(for size: ModelSize) throws -> URL {
        try ensureInstalledModelReady(for: size)
    }


    /// Local base directory passed to WhisperKit's downloadBase config.
    /// WhisperKit creates its own subdirectory structure under this path.
    private var downloadBase: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("VocaMac")
            .appendingPathComponent("models")
    }

    /// Actual directory where WhisperKit stores downloaded model files.
    /// WhisperKit nests models under: downloadBase/models/<repo>/
    private var modelStorageBase: URL {
        downloadBase
            .appendingPathComponent("models")
            .appendingPathComponent(modelRepo)
    }

    // MARK: - Model Discovery

    /// Get WhisperKit's recommendation for the current device
    func deviceRecommendation() -> (defaultModel: String, supported: [String], disabled: [String]) {
        let rec = WhisperKit.recommendedModels()
        return (
            defaultModel: rec.default,
            supported: rec.supported,
            disabled: rec.disabled
        )
    }

    /// FluidAudio's model version for a Parakeet catalog entry.
    private func parakeetVersion(for size: ModelSize) -> AsrModelVersion? {
        ParakeetService.modelVersion(for: size)
    }

    /// Directory where FluidAudio caches a Parakeet model's files.
    private func parakeetDirectory(for version: AsrModelVersion) -> URL {
        AsrModels.defaultCacheDirectory(for: version)
    }

    /// Map a ModelSize enum to the identifier its engine understands.
    /// WhisperKit uses its own variant names; other engines use the
    /// ModelSize raw value directly.
    func modelIdentifier(for size: ModelSize) -> String {
        switch size.engine {
        case .whisperKit:
            return whisperKitModelName(for: size)
        case .parakeet, .appleSpeech, .sherpaOnnx:
            return size.rawValue
        }
    }

    /// Map a ModelSize enum to WhisperKit model variant name
    func whisperKitModelName(for size: ModelSize) -> String {
        switch size {
        case .tiny:
            return "openai_whisper-tiny"
        case .base:
            return "openai_whisper-base"
        case .small:
            return "openai_whisper-small"
        case .largeV3LatestTurboCompact:
            return "openai_whisper-large-v3-v20240930_turbo_632MB"
        case .distilLargeV3Compact:
            return "distil-whisper_distil-large-v3_594MB"
        case .distilLargeV3TurboCompact:
            return "distil-whisper_distil-large-v3_turbo_600MB"
        case .largeV3LatestCompact:
            return "openai_whisper-large-v3-v20240930_626MB"
        case .largeV3Latest:
            return "openai_whisper-large-v3-v20240930"
        case .largeV3LatestTurbo:
            return "openai_whisper-large-v3-v20240930_turbo"
        case .largeV3:
            return "openai_whisper-large-v3"
        case .largeV3Turbo:
            return "openai_whisper-large-v3_turbo"
        case .medium:
            return "openai_whisper-medium"
        case .parakeetV3, .parakeetV2, .appleSpeech,
             .moonshineTiny, .moonshineBase, .senseVoiceSmall, .gigaamV3, .canary180mFlash:
            // Not WhisperKit models — identified by their raw value.
            return size.rawValue
        }
    }

    /// Check if a model is downloaded locally
    func isModelDownloaded(_ size: ModelSize) -> Bool {
        switch size.engine {
        case .whisperKit:
            guard let modelDir = modelFolder(for: size) else { return false }
            return hasRequiredModelAssets(at: modelDir)
        case .parakeet:
            guard let version = parakeetVersion(for: size) else { return false }
            return AsrModels.modelsExist(at: parakeetDirectory(for: version), version: version)
        case .appleSpeech:
            // Assets are system-managed; installation happens at load time.
            return true
        case .sherpaOnnx:
            guard let spec = SherpaModelCatalog.spec(for: size) else { return false }
            return SherpaService.modelFilesExist(for: spec)
        }
    }

    /// Get the local folder path for a downloaded or installed model
    func modelFolder(for size: ModelSize) -> URL? {
        switch size.engine {
        case .whisperKit:
            let modelDir = installedModelDirectory(for: size)
            if fileManager.fileExists(atPath: modelDir.path), hasRequiredModelAssets(at: modelDir) {
                return modelDir
            }
            return nil
        case .parakeet:
            guard let version = parakeetVersion(for: size),
                  isModelDownloaded(size) else { return nil }
            return parakeetDirectory(for: version)
        case .appleSpeech:
            return nil
        case .sherpaOnnx:
            guard let spec = SherpaModelCatalog.spec(for: size),
                  SherpaService.modelFilesExist(for: spec) else { return nil }
            return SherpaService.modelDirectory(for: spec)
        }
    }

    /// List all downloaded models
    func downloadedModels() -> [ModelSize] {
        ModelSize.allCases.filter { isModelDownloaded($0) }
    }

    /// Check if a model size is supported on this device.
    ///
    /// WhisperKit models use exact variant matching against WhisperKit's
    /// per-device recommendation; other engines gate on system capability.
    func isModelSupported(_ size: ModelSize) -> Bool {
        switch size.engine {
        case .whisperKit:
            let rec = WhisperKit.recommendedModels()
            let modelName = whisperKitModelName(for: size)

            if rec.disabled.contains(modelName) {
                return false
            }

            return rec.supported.contains(modelName)
        case .parakeet, .appleSpeech, .sherpaOnnx:
            return size.isAvailableOnThisSystem
        }
    }

    /// Map an engine model identifier back to a ModelSize, if it matches one of our known sizes.
    func modelSize(from identifier: String) -> ModelSize? {
        ModelSize.allCases.first { modelIdentifier(for: $0) == identifier }
    }

    // MARK: - Model Download

    /// After WhisperKit downloads a model, ensure the tokenizer assets are
    /// present alongside the CoreML model files in our installed directory.
    ///
    /// WhisperKit downloads CoreML weights from argmaxinc/whisperkit-coreml but
    /// stores tokenizer files separately under openai/whisper-<size>. The
    /// tokenizer files may land inside a HuggingFace snapshots subdirectory
    /// rather than at the top level.  We search common locations and copy the
    /// tokenizer JSON files into the model directory so `ensureTokenizerAssets`
    /// succeeds on the next `loadModel` call.
    private func consolidateWhisperKitDownload(for size: ModelSize) throws {
        let modelName = whisperKitModelName(for: size)
        let destination = installedModelDirectory(for: size)

        // Already fully consolidated — nothing to do
        if hasRequiredModelAssets(at: destination) && hasRequiredTokenizerAssets(at: destination) {
            return
        }

        guard fileManager.fileExists(atPath: destination.path),
              hasRequiredModelAssets(at: destination) else {
            VocaLogger.warning(.modelManager, "Model assets not found at \(destination.path) — skipping consolidation")
            return
        }

        // Tokenizer files are already present — done
        if hasRequiredTokenizerAssets(at: destination) {
            VocaLogger.info(.modelManager, "Tokenizer assets already present for \(modelName)")
            return
        }

        // Search for tokenizer files in likely locations:
        // 1. openai/whisper-<size>/ directory (HuggingFace flat download)
        // 2. openai/whisper-<size>/snapshots/<hash>/ (HuggingFace Hub cache layout)
        // 3. The model directory's own snapshots/ subdirectory
        let candidateDirectories = tokenizerSearchDirectories(for: size)

        for candidateDir in candidateDirectories {
            if hasRequiredTokenizerAssets(at: candidateDir) {
                for file in requiredTokenizerFiles {
                    let src = candidateDir.appendingPathComponent(file)
                    let dst = destination.appendingPathComponent(file)
                    if fileManager.fileExists(atPath: dst.path) {
                        try? fileManager.removeItem(at: dst)
                    }
                    try fileManager.copyItem(at: src, to: dst)
                }
                VocaLogger.info(.modelManager, "Consolidated tokenizer assets for \(modelName) from \(candidateDir.path)")
                return
            }
        }

        VocaLogger.warning(.modelManager, "Could not find tokenizer assets for \(modelName) in any known location")
    }

    /// Returns candidate directories where tokenizer files may be found,
    /// ordered from most likely to least likely.
    private func tokenizerSearchDirectories(for size: ModelSize) -> [URL] {
        var candidates: [URL] = []
        let modelsBase = downloadBase.appendingPathComponent("models")

        // 1. openai/whisper-<size>/ (flat download)
        let openaiDir = modelsBase
            .appendingPathComponent("openai")
            .appendingPathComponent("whisper-\(size.rawValue)", isDirectory: true)
        candidates.append(openaiDir)

        // 2. openai/whisper-<size>/snapshots/<hash>/ (Hub cache layout)
        if let snapshotDir = tokenizerAssetSourceDirectory(for: openaiDir) {
            candidates.append(snapshotDir)
        }

        // 3. The model directory's own snapshots/ subdirectory
        let modelDir = installedModelDirectory(for: size)
        if let snapshotDir = tokenizerAssetSourceDirectory(for: modelDir) {
            candidates.append(snapshotDir)
        }

        return candidates
    }

    /// Download a model using its engine's built-in download mechanism.
    /// The model will be downloaded from HuggingFace and cached locally.
    /// - Parameters:
    ///   - size: The model size to download
    ///   - onProgress: Progress callback (0.0 to 1.0)
    func downloadModel(
        size: ModelSize,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        // New files on disk in every branch that can succeed.
        defer { invalidateDiskUsageCache() }

        switch size.engine {
        case .whisperKit:
            try await downloadWhisperKitModel(size: size, onProgress: onProgress)
        case .parakeet:
            try await downloadParakeetModel(size: size, onProgress: onProgress)
        case .appleSpeech:
            // System-managed — nothing to download here. Asset installation
            // happens in AppleSpeechService.loadModel via AssetInventory.
            onProgress(1.0)
        case .sherpaOnnx:
            try await downloadSherpaModel(size: size, onProgress: onProgress)
        }
    }

    /// Download a sherpa-onnx model archive and extract it into the sherpa
    /// storage directory. The archive download reports real progress; the
    /// final extraction step is mapped to the last 5%.
    private func downloadSherpaModel(
        size: ModelSize,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        guard let spec = SherpaModelCatalog.spec(for: size) else {
            throw ModelManagerError.modelNotAvailable(size.rawValue)
        }

        VocaLogger.info(.modelManager, "Downloading ONNX model: \(size.rawValue)")

        let root = SherpaService.storageRoot
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        // Download and extract through a staging directory, then move the
        // finished model into place. `tar` writes entries as it goes, so
        // extracting straight into the destination would leave a directory of
        // truncated weights behind if the archive is incomplete — and those
        // files look real enough that the app would offer to load them.
        // Unique per attempt so two downloads of the same model cannot
        // overwrite each other's staging area.
        let staging = root.appendingPathComponent(
            ".staging-\(spec.directoryName)-\(UUID().uuidString)",
            isDirectory: true
        )
        let destination = SherpaService.modelDirectory(for: spec)

        func discardStaging() {
            try? fileManager.removeItem(at: staging)
        }

        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { discardStaging() }

        let archiveDestination = staging.appendingPathComponent(spec.archiveURL.lastPathComponent)

        do {
            try await FileDownloader.download(from: spec.archiveURL, to: archiveDestination) { fraction in
                onProgress(fraction * 0.95)
            }

            // Check the archive against its known digest before unpacking it:
            // everything inside is handed to native ONNX code.
            let digest = try Self.sha256Hex(ofFileAt: archiveDestination)
            guard digest.caseInsensitiveCompare(spec.sha256) == .orderedSame else {
                throw ModelManagerError.checksumMismatch(
                    model: size.rawValue,
                    expected: spec.sha256,
                    actual: digest
                )
            }

            try Self.extractTarArchive(at: archiveDestination, into: staging)
            try? fileManager.removeItem(at: archiveDestination)

            let extracted = staging.appendingPathComponent(spec.directoryName, isDirectory: true)
            let missing = spec.requiredFiles.filter {
                !fileManager.fileExists(atPath: extracted.appendingPathComponent($0).path)
            }
            guard missing.isEmpty else {
                throw ModelManagerError.missingModelDirectory(
                    "\(extracted.path) (missing: \(missing.joined(separator: ", ")))"
                )
            }

            // Swap the finished model in without a window where neither copy
            // is in place: move any existing install aside first, and only
            // delete it once the new one has landed.
            let displaced = fileManager.fileExists(atPath: destination.path)
                ? staging.appendingPathComponent(".replaced", isDirectory: true)
                : nil
            if let displaced {
                try fileManager.moveItem(at: destination, to: displaced)
            }
            do {
                try fileManager.moveItem(at: extracted, to: destination)
            } catch {
                // Put the previous install back rather than leaving nothing.
                if let displaced {
                    try? fileManager.moveItem(at: displaced, to: destination)
                }
                throw error
            }

            // Written last: this marker is what makes the model count as
            // installed, so a crash before this point leaves it re-downloadable.
            // If marking or validation fails, restore the displaced install so
            // the user keeps a working model instead of a half-finished one.
            do {
                try SherpaService.markModelComplete(for: spec)
                guard SherpaService.modelFilesExist(for: spec) else {
                    throw ModelManagerError.missingModelDirectory(destination.path)
                }
            } catch {
                if let displaced {
                    try? fileManager.removeItem(at: destination)
                    try? fileManager.moveItem(at: displaced, to: destination)
                } else {
                    try? fileManager.removeItem(at: destination)
                }
                throw error
            }

            onProgress(1.0)
            VocaLogger.info(.modelManager, "ONNX model '\(size.rawValue)' installed at: \(destination.path)")
        } catch {
            VocaLogger.error(.modelManager, "Download failed for '\(size.rawValue)': \(error.localizedDescription)")
            throw ModelManagerError.downloadFailed(reason: error.localizedDescription)
        }
    }

    /// SHA-256 of a file, read in chunks so a large archive never has to be
    /// held in memory all at once.
    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Extract a .tar.bz2 archive using the system tar.
    static func extractTarArchive(at archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["xjf", archive.path, "-C", directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ModelManagerError.downloadFailed(
                reason: "Archive extraction failed (tar exited with \(process.terminationStatus))"
            )
        }
    }

    /// Download a Parakeet model through FluidAudio, which reports real
    /// download progress (unlike the WhisperKit path below).
    private func downloadParakeetModel(
        size: ModelSize,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        guard let version = parakeetVersion(for: size) else {
            throw ModelManagerError.modelNotAvailable(size.rawValue)
        }

        VocaLogger.info(.modelManager, "Downloading Parakeet model: \(size.rawValue)")

        do {
            try await AsrModels.download(version: version) { progress in
                onProgress(progress.fractionCompleted)
            }

            let directory = parakeetDirectory(for: version)
            guard AsrModels.modelsExist(at: directory, version: version) else {
                throw ModelManagerError.missingModelDirectory(directory.path)
            }

            onProgress(1.0)
            VocaLogger.info(.modelManager, "Parakeet model '\(size.rawValue)' downloaded to: \(directory.path)")
        } catch {
            VocaLogger.error(.modelManager, "Download failed for '\(size.rawValue)': \(error.localizedDescription)")
            throw ModelManagerError.downloadFailed(reason: error.localizedDescription)
        }
    }

    /// Download a WhisperKit model using WhisperKit's built-in mechanism.
    private func downloadWhisperKitModel(
        size: ModelSize,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        VocaLogger.info(.modelManager, "Downloading model: \(whisperKitModelName(for: size))")

        // Ensure download directory exists
        try FileManager.default.createDirectory(
            at: downloadBase,
            withIntermediateDirectories: true
        )

        do {
            // WhisperKit handles downloading from HuggingFace automatically
            // when we initialize with a model name. We create a temporary
            // instance just to trigger the download.
            let config = WhisperKitConfig(model: whisperKitModelName(for: size))
            config.downloadBase = downloadBase
            config.prewarm = false
            config.load = false  // Don't load into memory, just download

            // Report initial progress
            onProgress(0.05)

            // Simulate progress while downloading, since WhisperKit doesn't
            // expose granular download progress in this usage pattern.
            // Use `try` (not `try?`) so Task.sleep throws on cancellation,
            // which cleanly exits the loop.
            let progressTask = Task { @Sendable in
                var currentProgress = 0.05
                do {
                    while !Task.isCancelled && currentProgress < 0.90 {
                        try await Task.sleep(nanoseconds: 800_000_000)  // 0.8s intervals
                        guard !Task.isCancelled else { break }
                        currentProgress += Double.random(in: 0.03...0.08)
                        currentProgress = min(currentProgress, 0.90)
                        onProgress(currentProgress)
                    }
                } catch {
                    // Task was cancelled — stop updating progress
                }
            }

            let _ = try await WhisperKit(config)

            // Stop the simulated progress and report completion
            progressTask.cancel()
            try? await Task.sleep(nanoseconds: 50_000_000)

            // WhisperKit downloads CoreML models to a temp directory with a
            // symlink from modelStorageBase. macOS may clean up temp files,
            // so we consolidate into a permanent location — the same path
            // used by installBundledModel. This ensures downloaded models
            // survive temp directory cleanup.
            try consolidateWhisperKitDownload(for: size)

            let installedDir = installedModelDirectory(for: size)
            guard hasRequiredModelAssets(at: installedDir) else {
                throw ModelManagerError.missingModelDirectory(installedDir.path)
            }

            onProgress(1.0)
            VocaLogger.info(.modelManager, "Model '\(whisperKitModelName(for: size))' downloaded successfully to: \(installedDir.path)")
        } catch {
            VocaLogger.error(.modelManager, "Download failed for '\(whisperKitModelName(for: size))': \(error.localizedDescription)")
            throw ModelManagerError.downloadFailed(reason: error.localizedDescription)
        }
    }

    /// Cancel an active download (WhisperKit handles this internally)
    func cancelDownload(for size: ModelSize) {
        // WhisperKit manages downloads internally via URLSession
        // For MVP, we rely on task cancellation at the caller level
        VocaLogger.info(.modelManager, "Download cancellation requested for \(size.displayName)")
    }

    // MARK: - Model Deletion

    /// Delete a downloaded model's local files
    func deleteModel(_ size: ModelSize) throws {
        let modelDir: URL
        switch size.engine {
        case .whisperKit:
            modelDir = modelStorageBase.appendingPathComponent(whisperKitModelName(for: size))
        case .parakeet:
            guard let version = parakeetVersion(for: size) else { return }
            modelDir = parakeetDirectory(for: version)
        case .appleSpeech:
            // System-managed assets cannot be deleted by the app.
            return
        case .sherpaOnnx:
            guard let spec = SherpaModelCatalog.spec(for: size) else { return }
            modelDir = SherpaService.modelDirectory(for: spec)
        }

        if FileManager.default.fileExists(atPath: modelDir.path) {
            try FileManager.default.removeItem(at: modelDir)
            invalidateDiskUsageCache()
            VocaLogger.info(.modelManager, "Deleted model: \(modelIdentifier(for: size))")
        }
    }

    // MARK: - Utilities

    /// Directories that hold downloaded model files, across all engines.
    private var modelStorageDirectories: [URL] {
        [
            modelStorageBase,
            parakeetDirectory(for: .v3),
            parakeetDirectory(for: .v2),
            SherpaService.storageRoot,
        ]
    }

    /// Get total disk space used by downloaded models across all engines.
    ///
    /// Walking every model file costs a few milliseconds, and the settings UI
    /// asks for this from a SwiftUI view body — which re-renders far more
    /// often than model files change. The result is cached and invalidated
    /// whenever this manager downloads or deletes a model; the TTL is a
    /// backstop for files changed outside the app.
    func totalDiskUsage() -> Int64 {
        diskUsageCacheLock.lock()
        if let cached = cachedDiskUsage,
           CFAbsoluteTimeGetCurrent() - cached.measuredAt < Self.diskUsageCacheTTL {
            diskUsageCacheLock.unlock()
            return cached.bytes
        }
        diskUsageCacheLock.unlock()

        let fm = FileManager.default
        var totalSize: Int64 = 0
        for directory in modelStorageDirectories {
            guard fm.fileExists(atPath: directory.path) else { continue }
            if let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let fileURL as URL in enumerator {
                    if let attrs = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                       let size = attrs.fileSize {
                        totalSize += Int64(size)
                    }
                }
            }
        }

        diskUsageCacheLock.lock()
        cachedDiskUsage = (bytes: totalSize, measuredAt: CFAbsoluteTimeGetCurrent())
        diskUsageCacheLock.unlock()

        return totalSize
    }

    /// Drop the cached disk usage so the next read re-measures.
    func invalidateDiskUsageCache() {
        diskUsageCacheLock.lock()
        cachedDiskUsage = nil
        diskUsageCacheLock.unlock()
    }

    /// Human-readable disk usage string
    func diskUsageDescription() -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalDiskUsage())
    }
}

// MARK: - ModelManaging Conformance

extension ModelManager: ModelManaging {}
