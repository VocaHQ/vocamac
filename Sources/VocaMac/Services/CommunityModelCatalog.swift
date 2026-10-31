// CommunityModelCatalog.swift
// VocaMac
//
// The list of vetted community models, published as `community-models.json`
// beside Voca Hinglish in VocaHQ/whisperkit-coreml. Fetched on the update
// check's schedule with an ETag, so an unchanged list costs a 304; cached on
// disk so Settings can show it offline. Nothing is downloaded until the user
// picks a model.

import Foundation

// MARK: - Document

/// One model the catalog offers: its manifest, and the .zip to fetch.
struct CommunityModelEntry: Codable, Equatable, Identifiable, Sendable {
    var manifest: CustomModelManifest
    /// An https URL of a .zip holding the model folder and its `vocamodel.json`.
    var downloadURL: URL
    var downloadBytes: Int64?
    /// SHA-256 of the .zip, checked before it is unpacked.
    var archiveSHA256: String?
    /// One line for the picker.
    var notes: String?

    var id: String { manifest.id }
}

/// `community-models.json`.
struct CommunityModelCatalogDocument: Codable, Equatable, Sendable {
    var version: Int
    var models: [CommunityModelEntry]
}

// MARK: - Client

/// Fetches and caches the community catalog.
///
/// Unchecked Sendable: `fetch` is a `@Sendable` closure and the cache is
/// files on disk, written whole with atomic writes.
final class CommunityModelCatalog: @unchecked Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let defaultURL = URL(string: "https://huggingface.co/VocaHQ/whisperkit-coreml/resolve/main/community-models.json")
        ?? URL(fileURLWithPath: "/")

    /// The newest document format this build reads.
    static let supportedVersion = 1

    static var defaultCacheDirectory: URL {
        CustomModelRegistry.defaultRoot.deletingLastPathComponent()
    }

    let url: URL
    private let cacheDirectory: URL
    private let fetch: Fetch

    init(url: URL = defaultURL, cacheDirectory: URL = defaultCacheDirectory, fetch: Fetch? = nil) {
        self.url = url
        self.cacheDirectory = cacheDirectory
        self.fetch = fetch ?? Self.urlSessionFetch
    }

    private var cacheURL: URL { cacheDirectory.appendingPathComponent("community-models.json") }
    private var eTagURL: URL { cacheDirectory.appendingPathComponent("community-models.etag") }

    /// The entries last fetched, or none.
    func cachedEntries() -> [CommunityModelEntry] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [] }
        return Self.entries(in: data) ?? []
    }

    /// Ask for the catalog, sending the cached ETag. Returns the entries to
    /// show: new ones on 200, the cache on 304 or any failure, none on 404
    /// (the file isn't published).
    @discardableResult
    func refresh() async -> [CommunityModelEntry] {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        if let eTag = try? String(contentsOf: eTagURL, encoding: .utf8), !eTag.isEmpty,
           FileManager.default.fileExists(atPath: cacheURL.path) {
            request.setValue(eTag, forHTTPHeaderField: "If-None-Match")
        }
        do {
            let (data, response) = try await fetch(request)
            switch response.statusCode {
            case 200:
                guard let entries = Self.entries(in: data) else {
                    VocaLogger.warning(.modelManager, "The community model catalog could not be read; keeping the cached one")
                    return cachedEntries()
                }
                try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                try data.write(to: cacheURL, options: .atomic)
                if let eTag = response.value(forHTTPHeaderField: "ETag") {
                    try Data(eTag.utf8).write(to: eTagURL, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: eTagURL)
                }
                return entries
            case 304:
                return cachedEntries()
            case 404:
                // Not published (yet), or withdrawn: offer nothing.
                try? FileManager.default.removeItem(at: cacheURL)
                try? FileManager.default.removeItem(at: eTagURL)
                return []
            default:
                VocaLogger.warning(.modelManager, "Community model catalog answered HTTP \(response.statusCode)")
                return cachedEntries()
            }
        } catch {
            VocaLogger.info(.modelManager, "Community model catalog not refreshed: \(error.localizedDescription)")
            return cachedEntries()
        }
    }

    /// Entries a catalog document offers this build: its version understood,
    /// each manifest well formed, each download over https. Nil when the
    /// data isn't a catalog at all.
    static func entries(in data: Data) -> [CommunityModelEntry]? {
        guard let document = try? JSONDecoder().decode(CommunityModelCatalogDocument.self, from: data) else { return nil }
        guard document.version <= supportedVersion else { return [] }
        return document.models.filter { entry in
            CustomModelManifest.isValidID(entry.manifest.id)
                && entry.downloadURL.scheme?.lowercased() == "https"
                && (entry.archiveSHA256.map(CustomModelManifest.isHexDigest) ?? true)
        }
    }

    private static let urlSessionFetch: Fetch = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
