// CustomModelRegistry.swift
// VocaMac
//
// Models the user brings: imported from a folder (or a .zip of one) with a
// `vocamodel.json`, checked, copied under Application Support, and selected
// through the custom slots in the model catalog (`ModelSize.customWhisperKit`,
// `.customSherpaOnnx`, `CleanupModelKind.customGGUF`).

import CryptoKit
import Foundation

// MARK: - Errors

enum CustomModelError: LocalizedError, Equatable {
    case manifestMissing
    case manifestUnreadable(String)
    case invalid([String])
    case checksumMismatch(expected: String, actual: String)
    case duplicateID(String)
    case notFound(String)
    case zipUnsupported
    case unzipFailed(String)

    var errorDescription: String? {
        switch self {
        case .manifestMissing:
            return "No \(CustomModelManifest.fileName) was found in the folder or in a single folder inside it."
        case .manifestUnreadable(let reason):
            return "\(CustomModelManifest.fileName) could not be read: \(reason)"
        case .invalid(let problems):
            return problems.joined(separator: " ")
        case .checksumMismatch(let expected, let actual):
            return "The files don't match the manifest's sha256 (expected \(expected.prefix(12))…, got \(actual.prefix(12))…). "
                + "The download may be incomplete or changed."
        case .duplicateID(let id):
            return "A model with the id “\(id)” is already installed. Delete it first, or change the id."
        case .notFound(let id):
            return "No imported model has the id “\(id)”."
        case .zipUnsupported:
            return "This build can't unzip models. Unzip it in Finder and import the folder."
        case .unzipFailed(let reason):
            return "The .zip could not be unpacked: \(reason)"
        }
    }
}

// MARK: - Installed model

/// An imported model and where it lives.
struct InstalledCustomModel: Equatable, Sendable, Identifiable {
    let manifest: CustomModelManifest
    let directory: URL

    var id: String { manifest.id }

    /// Whether the manifest's checksum was checked on import.
    var isVerified: Bool { manifest.sha256 != nil }

    /// The GGUF file, for a Writing AI model.
    var ggufURL: URL? {
        guard manifest.engine == .cleanup, let name = manifest.gguf else { return nil }
        return directory.appendingPathComponent(name)
    }
}

// MARK: - Registry

/// Imported models on this Mac and which one each slot uses.
///
/// Unchecked Sendable: the only mutable state, the scan cache and the
/// in-process slot overrides, is read and written under `lock`.
final class CustomModelRegistry: @unchecked Sendable {
    /// The registry the app and the CLI share.
    static let shared = CustomModelRegistry(
        root: CustomModelRegistry.defaultRoot,
        defaults: AppCLIPreferencesReader.applicationDefaults()
    )

    static var defaultRoot: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport
            .appendingPathComponent("VocaMac", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("custom", isDirectory: true)
    }

    /// Preference key holding the active model id for a slot.
    static func activeKey(for engine: CustomModelEngine) -> String {
        "vocamac.customModel.active.\(engine.rawValue)"
    }

    let root: URL
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cachedModels: [InstalledCustomModel]?
    /// Slot choices for this process only (a CLI `--model` override).
    private var processOverrides: [CustomModelEngine: String] = [:]

    init(root: URL, defaults: UserDefaults) {
        self.root = root
        self.defaults = defaults
    }

    // MARK: Reading

    /// Every imported model, sorted by name.
    func installedModels() -> [InstalledCustomModel] {
        lock.lock()
        if let cachedModels {
            lock.unlock()
            return cachedModels
        }
        lock.unlock()

        let scanned = scan()
        lock.lock()
        cachedModels = scanned
        lock.unlock()
        return scanned
    }

    func model(id: String) -> InstalledCustomModel? {
        installedModels().first { $0.id == id }
    }

    func models(for engine: CustomModelEngine) -> [InstalledCustomModel] {
        installedModels().filter { $0.manifest.engine == engine }
    }

    /// The model a slot runs: this process's override, else the saved choice,
    /// else the only model of that engine. Nil when there is none.
    func activeModel(for engine: CustomModelEngine) -> InstalledCustomModel? {
        let candidates = models(for: engine)
        lock.lock()
        let override = processOverrides[engine]
        lock.unlock()
        if let override, let model = candidates.first(where: { $0.id == override }) { return model }
        if let saved = defaults.string(forKey: Self.activeKey(for: engine)),
           let model = candidates.first(where: { $0.id == saved }) {
            return model
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Choose the model a slot runs. With `persist` false the choice lasts
    /// for this process only, which is what a one-off CLI request wants.
    func setActive(_ id: String, persist: Bool = true) throws {
        guard let model = model(id: id) else { throw CustomModelError.notFound(id) }
        if persist {
            defaults.set(id, forKey: Self.activeKey(for: model.manifest.engine))
        } else {
            lock.lock()
            processOverrides[model.manifest.engine] = id
            lock.unlock()
        }
    }

    /// Forget the scan, after files changed outside `importModel`/`delete`.
    /// Forget every process-only choice (`setActive(_:persist: false)`).
    func clearProcessOverrides() {
        lock.lock()
        processOverrides.removeAll()
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        cachedModels = nil
        lock.unlock()
    }

    private func scan() -> [InstalledCustomModel] {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var found: [InstalledCustomModel] = []
        for folder in folders {
            let manifestURL = folder.appendingPathComponent(CustomModelManifest.fileName)
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(CustomModelManifest.self, from: data),
                  manifest.id == folder.lastPathComponent else { continue }
            found.append(InstalledCustomModel(manifest: manifest, directory: folder))
        }
        return found.sorted { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending }
    }

    // MARK: Importing

    /// Check a model folder (or a .zip of one) and copy it in. Returns the
    /// installed model. Nothing is left behind when a check fails. Reads and
    /// hashes every file, so call it off the main thread.
    @discardableResult
    func importModel(from source: URL) throws -> InstalledCustomModel {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }

        let unpacked: URL
        if source.pathExtension.lowercased() == "zip" {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try Self.unzip(source, into: staging)
            unpacked = staging
        } else {
            unpacked = source
        }

        let folder = try Self.modelFolder(in: unpacked)
        var manifest = try Self.readManifest(in: folder)
        var problems = manifest.problems(in: folder)
        // A link could point anywhere: writing the completion marker through
        // one truncated a file outside the folder. Only real files come in.
        problems += Self.symbolicLinks(in: folder).map { "“\($0)” is a symbolic link. Import a folder of real files." }
        guard problems.isEmpty else { throw CustomModelError.invalid(problems) }
        guard model(id: manifest.id) == nil,
              !fileManager.fileExists(atPath: root.appendingPathComponent(manifest.id).path) else {
            throw CustomModelError.duplicateID(manifest.id)
        }

        if let expected = manifest.sha256?.lowercased() {
            let actual = try CustomModelDigest.digest(of: manifest, in: folder)
            guard actual == expected else { throw CustomModelError.checksumMismatch(expected: expected, actual: actual) }
        }

        // Copy into place under a temporary name, then rename, so a crash
        // mid-copy never leaves a folder that scans as a model.
        let copying = root.appendingPathComponent(".copy-\(UUID().uuidString)", isDirectory: true)
        try fileManager.copyItem(at: folder, to: copying)
        // Measured, not taken from the manifest: the memory check before a
        // load estimates from it, and a wrong small number would pass it.
        manifest.fileSizeBytes = CustomModelDigest.size(of: copying)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: copying.appendingPathComponent(CustomModelManifest.fileName), options: .atomic)
            if manifest.engine == .sherpaOnnx {
                // What SherpaService looks for before it trusts a folder.
                let marker = copying.appendingPathComponent(SherpaService.completionMarkerName)
                try? fileManager.removeItem(at: marker)
                try Data().write(to: marker, options: .withoutOverwriting)
            }
            try fileManager.moveItem(at: copying, to: root.appendingPathComponent(manifest.id, isDirectory: true))
        } catch {
            try? fileManager.removeItem(at: copying)
            throw error
        }
        invalidate()
        VocaLogger.info(.modelManager, "Imported custom model \(manifest.id) (\(manifest.engine.rawValue))")
        guard let installed = model(id: manifest.id) else { throw CustomModelError.notFound(manifest.id) }
        return installed
    }

    /// Delete an imported model and forget it as a slot's choice.
    func delete(id: String) throws {
        guard let model = model(id: id) else { throw CustomModelError.notFound(id) }
        try FileManager.default.removeItem(at: model.directory)
        let key = Self.activeKey(for: model.manifest.engine)
        if defaults.string(forKey: key) == id { defaults.removeObject(forKey: key) }
        lock.lock()
        if processOverrides[model.manifest.engine] == id { processOverrides[model.manifest.engine] = nil }
        lock.unlock()
        invalidate()
        VocaLogger.info(.modelManager, "Deleted custom model \(id)")
    }

    /// Paths (relative to `folder`) of every symbolic link inside it.
    static func symbolicLinks(in folder: URL) -> [String] {
        guard let items = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []
        ) else { return [] }
        let base = folder.standardizedFileURL.path
        var links: [String] = []
        for case let item as URL in items
        where (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            let path = item.standardizedFileURL.path
            links.append(path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : item.lastPathComponent)
        }
        return links.sorted()
    }

    /// The folder holding `vocamodel.json`: `directory` itself, or its only
    /// subfolder (how most zips unpack).
    static func modelFolder(in directory: URL) throws -> URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.appendingPathComponent(CustomModelManifest.fileName).path) {
            return directory
        }
        let children = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        let folders = children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { $0.lastPathComponent != "__MACOSX" }
        if folders.count == 1,
           fileManager.fileExists(atPath: folders[0].appendingPathComponent(CustomModelManifest.fileName).path) {
            return folders[0]
        }
        throw CustomModelError.manifestMissing
    }

    static func readManifest(in folder: URL) throws -> CustomModelManifest {
        let url = folder.appendingPathComponent(CustomModelManifest.fileName)
        do {
            return try JSONDecoder().decode(CustomModelManifest.self, from: Data(contentsOf: url))
        } catch let error as DecodingError {
            throw CustomModelError.manifestUnreadable(Self.describe(error))
        } catch {
            throw CustomModelError.manifestUnreadable(error.localizedDescription)
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _): return "“\(key.stringValue)” is missing."
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "“\(path)”: \(context.debugDescription)"
        @unknown default: return error.localizedDescription
        }
    }

    private static func unzip(_ archive: URL, into directory: URL) throws {
#if APP_STORE
        throw CustomModelError.zipUnsupported
#else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CustomModelError.unzipFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw CustomModelError.unzipFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
#endif
    }
}

// MARK: - Digest

/// The checksum a manifest's `sha256` is compared with.
enum CustomModelDigest {
    /// For a GGUF, the file's own SHA-256 (what Hugging Face shows). For a
    /// folder, `folderDigest`.
    static func digest(of manifest: CustomModelManifest, in folder: URL) throws -> String {
        if manifest.engine == .cleanup, let gguf = manifest.gguf {
            return try ModelManager.sha256Hex(ofFileAt: folder.appendingPathComponent(gguf))
        }
        return try folderDigest(at: folder)
    }

    /// SHA-256 of the lines `shasum -a 256` prints for every file in the
    /// folder except `vocamodel.json` and hidden files, sorted by path:
    ///
    ///     cd model && find . -type f ! -name vocamodel.json ! -name '.*' -print0 \
    ///       | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256
    static func folderDigest(at folder: URL) throws -> String {
        var listing = ""
        for relative in try files(in: folder) {
            let hash = try ModelManager.sha256Hex(ofFileAt: folder.appendingPathComponent(relative))
            listing += "\(hash)  ./\(relative)\n"
        }
        return SHA256.hash(data: Data(listing.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Relative paths of the files the digest covers, in `sort -z` order.
    static func files(in folder: URL) throws -> [String] {
        let base = folder.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: []
        ) else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let name = url.lastPathComponent
            guard name != CustomModelManifest.fileName, !name.hasPrefix(".") else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            paths.append(String(path.dropFirst(base.count + 1)))
        }
        // `sort -z` compares bytes ("./A" before "./a"); so does this.
        return paths.sorted { Array(("./" + $0).utf8).lexicographicallyPrecedes(Array(("./" + $1).utf8)) }
    }

    /// Bytes on disk under `folder`.
    static func size(of folder: URL) -> Int64 {
        ModelManager.directorySize(at: folder)
    }
}
