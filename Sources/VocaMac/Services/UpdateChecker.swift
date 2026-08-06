// UpdateChecker.swift
// VocaMac
//
// Checks GitHub Releases for new versions and downloads DMG updates.

import Foundation
import SwiftUI
import AppKit
import CryptoKit

enum UpdateCheckerError: LocalizedError {
    case invalidResponse
    case invalidStatusCode(Int)
    case noDMGAsset
    case failedToMoveDownload
    case checksumMismatch
    case downloadCancelled

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from update server"
        case .invalidStatusCode(let statusCode):
            return "Update check failed (HTTP \(statusCode))"
        case .noDMGAsset:
            return "No DMG asset found in latest release"
        case .failedToMoveDownload:
            return "Failed to store downloaded update"
        case .checksumMismatch:
            return "Downloaded update failed integrity verification"
        case .downloadCancelled:
            return "Download was cancelled"
        }
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published var updateState: UpdateState = .idle

    enum HomebrewInstallOverride {
        case installed(HomebrewInstall)
        case notInstalled
    }

    var homebrewInstall: HomebrewInstall? {
        if let override = overrideHomebrewInstall {
            switch override {
            case .installed(let install):
                return install
            case .notInstalled:
                return nil
            }
        }
        return Self.detectHomebrewInstall(bundlePath: Bundle.main.bundlePath)
    }

    var isHomebrewInstalled: Bool {
        homebrewInstall != nil
    }

    var overrideHomebrewInstall: HomebrewInstallOverride?

    /// Returns the UpdateInfo if the checker is in any active update flow
    /// (available, downloading, verifying, ready to install, or error after a download attempt).
    /// Used to keep banners and sheets visible during the entire update process.
    var activeUpdateInfo: UpdateInfo? {
        switch updateState {
        case .updateAvailable(let info), .updateAvailableViaHomebrew(let info, _):
            return info
        default:
            return lastKnownUpdateInfo
        }
    }

    nonisolated static let supportedHomebrewCaskTokens = ["vocamac", "vocamac-nightly"]

    nonisolated static let defaultHomebrewCaskroomRoots = [
        URL(fileURLWithPath: "/opt/homebrew/Caskroom", isDirectory: true),
        URL(fileURLWithPath: "/usr/local/Caskroom", isDirectory: true)
    ]

    nonisolated static func detectHomebrewInstall(
        bundlePath: String,
        caskroomRoots: [URL] = defaultHomebrewCaskroomRoots,
        fileManager: FileManager = .default
    ) -> HomebrewInstall? {
        let normalizedBundlePath = normalizedPath(bundlePath)

        for caskToken in supportedHomebrewCaskTokens {
            for caskroomRoot in caskroomRoots {
                let caskRoot = caskroomRoot.appendingPathComponent(caskToken, isDirectory: true)
                guard hasHomebrewReceipt(in: caskRoot, fileManager: fileManager) else { continue }

                if isPath(normalizedBundlePath, inside: caskRoot.path) ||
                    caskRootContainsBundlePath(normalizedBundlePath, caskRoot: caskRoot, fileManager: fileManager) {
                    return HomebrewInstall(caskToken: caskToken)
                }
            }
        }

        return nil
    }

    /// Stored when an update is found so views can reference it across state transitions.
    private(set) var lastKnownUpdateInfo: UpdateInfo?

    private let apiURL = URL(string: "https://api.github.com/repos/VocaHQ/vocamac/releases/latest")!
    private let checkInterval: TimeInterval = 24 * 60 * 60
    private let lastCheckKey = "vocamac.update.lastCheck"
    private let skippedVersionKey = "vocamac.update.skippedVersion"

    // MARK: - ETag Cache Keys
    /// Persisted ETag from the last successful GitHub API response.
    /// Sent as `If-None-Match` on subsequent requests so GitHub returns
    /// 304 Not Modified (free — doesn't count against the 60 req/hr limit)
    /// when the latest release hasn't changed.
    private let etagKey = "vocamac.update.etag"
    /// Raw JSON body of the last successful GitHub API response, stored so
    /// we can serve a cached result on 304 without a second network call.
    private let cachedResponseKey = "vocamac.update.cachedResponse"

    func checkOnLaunchIfNeeded() async {
        let lastCheckTime = UserDefaults.standard.double(forKey: lastCheckKey)
        let shouldCheck = Date().timeIntervalSince1970 - lastCheckTime > checkInterval
        guard shouldCheck else { return }
        await checkForUpdates()
    }

    func checkForUpdates() async {
        await checkForUpdates(releaseProvider: { try await self.fetchLatestRelease() })
    }

    func checkForUpdates(releaseProvider: () async throws -> GitHubRelease) async {
        guard updateState != .checking else { return }
        updateState = .checking

        do {
            let release = try await releaseProvider()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

            let remoteVersion = normalizeVersion(release.tagName)
            let currentVersion = normalizeVersion(currentAppVersion())

            if UserDefaults.standard.string(forKey: skippedVersionKey) == remoteVersion {
                updateState = .upToDate
                return
            }

            if isNewerVersion(remote: remoteVersion, current: currentVersion) {
                guard let info = buildUpdateInfo(from: release) else {
                    throw UpdateCheckerError.noDMGAsset
                }
                lastKnownUpdateInfo = info
                if let homebrewInstall {
                    updateState = .updateAvailableViaHomebrew(info: info, install: homebrewInstall)
                    VocaLogger.info(.updateChecker, "Update available via Homebrew cask \(homebrewInstall.caskToken): \(info.tagName)")
                } else {
                    updateState = .updateAvailable(info)
                    VocaLogger.info(.updateChecker, "Update available: \(info.tagName)")
                }
            } else {
                updateState = .upToDate
            }
        } catch {
            updateState = .error(error.localizedDescription)
            VocaLogger.error(.updateChecker, "Update check failed: \(error.localizedDescription)")
        }
    }

    func downloadUpdate(_ info: UpdateInfo) async {
        // Clean up any previously downloaded VocaMac DMGs in temp
        cleanupStaleDMGs()
        updateState = .downloading(progress: 0, bytesDownloaded: 0, totalBytes: Int64(info.dmgSize), estimatedSecondsRemaining: 0)
        VocaLogger.info(.updateChecker, "Starting download: \(info.dmgURL)")

        do {
            let fileURL = try await downloadDMG(from: info.dmgURL, totalSize: Int64(info.dmgSize), expectedSHA256: info.sha256)
            updateState = .readyToInstall(dmgPath: fileURL)
            VocaLogger.info(.updateChecker, "Update downloaded: \(fileURL.lastPathComponent)")
        } catch {
            updateState = .error(error.localizedDescription)
            VocaLogger.error(.updateChecker, "Update download failed: \(error.localizedDescription)")
        }
    }

    func openDMG(at url: URL) {
        NSWorkspace.shared.open(url)
    }

    func skipVersion(_ version: String) {
        UserDefaults.standard.set(version, forKey: skippedVersionKey)
        lastKnownUpdateInfo = nil
        updateState = .upToDate
    }

    func dismiss() {
        lastKnownUpdateInfo = nil
        updateState = .idle
    }

    func normalizeVersion(_ version: String) -> String {
        var normalized = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("v") {
            normalized.removeFirst()
        }

        let parts = normalized.split(separator: ".").map(String.init)
        switch parts.count {
        case 0:
            return "0.0.0"
        case 1:
            return "\(parts[0]).0.0"
        case 2:
            return "\(parts[0]).\(parts[1]).0"
        default:
            return "\(parts[0]).\(parts[1]).\(parts[2])"
        }
    }

    func isNewerVersion(remote: String, current: String) -> Bool {
        func parse(_ version: String) -> (Int, Int, Int) {
            let values = version.split(separator: ".").compactMap { Int($0) }
            let major = values.indices.contains(0) ? values[0] : 0
            let minor = values.indices.contains(1) ? values[1] : 0
            let patch = values.indices.contains(2) ? values[2] : 0
            return (major, minor, patch)
        }

        return parse(remote) > parse(current)
    }

    private func currentAppVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        let appVersion = currentAppVersion()
        var request = URLRequest(url: apiURL)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("VocaMac/\(appVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        // Send cached ETag so GitHub returns 304 Not Modified (rate-limit free)
        // when the release hasn't changed since our last check.
        if let cachedETag = UserDefaults.standard.string(forKey: etagKey) {
            request.setValue(cachedETag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCheckerError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            // Fresh response — persist ETag and body for future conditional requests
            if let newETag = httpResponse.value(forHTTPHeaderField: "ETag") {
                UserDefaults.standard.set(newETag, forKey: etagKey)
            }
            if let jsonString = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(jsonString, forKey: cachedResponseKey)
            }
            VocaLogger.debug(.updateChecker, "GitHub API: 200 OK — fresh release data received")
            return try JSONDecoder().decode(GitHubRelease.self, from: data)

        case 304:
            // Not Modified — serve from cache, no rate-limit cost
            VocaLogger.debug(.updateChecker, "GitHub API: 304 Not Modified — serving cached release")
            guard let cachedJSON = UserDefaults.standard.string(forKey: cachedResponseKey),
                  let cachedData = cachedJSON.data(using: .utf8) else {
                // Cache miss despite 304 (e.g. UserDefaults cleared) — clear ETag and retry next time
                UserDefaults.standard.removeObject(forKey: etagKey)
                throw UpdateCheckerError.invalidResponse
            }
            return try JSONDecoder().decode(GitHubRelease.self, from: cachedData)

        default:
            throw UpdateCheckerError.invalidStatusCode(httpResponse.statusCode)
        }
    }

    private func buildUpdateInfo(from release: GitHubRelease) -> UpdateInfo? {
        guard let dmgAsset = release.assets.first(where: { $0.name.hasSuffix(".dmg") && $0.name.contains("arm64") }) else {
            return nil
        }

        let sha256: String?
        if let digest = dmgAsset.digest, digest.hasPrefix("sha256:") {
            sha256 = String(digest.dropFirst("sha256:".count))
        } else {
            sha256 = nil
        }

        return UpdateInfo(
            version: normalizeVersion(release.tagName),
            tagName: release.tagName,
            releaseNotes: release.body,
            releasePageURL: release.htmlURL,
            dmgURL: dmgAsset.browserDownloadURL,
            dmgSize: dmgAsset.size,
            sha256: sha256
        )
    }

    private nonisolated static func hasHomebrewReceipt(in caskRoot: URL, fileManager: FileManager) -> Bool {
        let receipt = caskRoot
            .appendingPathComponent(".metadata", isDirectory: true)
            .appendingPathComponent("INSTALL_RECEIPT.json")
        return fileManager.fileExists(atPath: receipt.path)
    }

    private nonisolated static func caskRootContainsBundlePath(
        _ bundlePath: String,
        caskRoot: URL,
        fileManager: FileManager
    ) -> Bool {
        let versionDirectories = (try? fileManager.contentsOfDirectory(
            at: caskRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for versionDirectory in versionDirectories {
            let stagedApp = versionDirectory.appendingPathComponent("VocaMac.app", isDirectory: true)
            guard fileManager.fileExists(atPath: stagedApp.path) else { continue }

            let stagedPath = normalizedPath(stagedApp.path)
            let resolvedPath = normalizedPath(stagedApp.resolvingSymlinksInPath().path)
            if stagedPath == bundlePath || resolvedPath == bundlePath {
                return true
            }
        }

        return false
    }

    private nonisolated static func isPath(_ path: String, inside directoryPath: String) -> Bool {
        let normalizedDirectoryPath = normalizedPath(directoryPath)
        return path == normalizedDirectoryPath || path.hasPrefix(normalizedDirectoryPath + "/")
    }

    private nonisolated static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    // MARK: - Download with Progress

    /// Remove any leftover VocaMac DMG files from the temp directory.
    private func cleanupStaleDMGs() {
        let tmpDir = FileManager.default.temporaryDirectory
        if let contents = try? FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil) {
            for file in contents where file.pathExtension == "dmg" && file.lastPathComponent.contains("VocaMac") {
                try? FileManager.default.removeItem(at: file)
                VocaLogger.debug(.updateChecker, "Cleaned up stale DMG: \(file.lastPathComponent)")
            }
        }
    }

    /// Downloads a DMG using AsyncStream-bridged delegate for real-time progress.
    private func downloadDMG(from url: URL, totalSize: Int64, expectedSHA256: String?) async throws -> URL {
        let delegate = DownloadDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

        let task = session.downloadTask(with: url)
        task.resume()

        let startTime = Date()
        var fileURL: URL?

        for await event in delegate.events {
            switch event {
            case .progress(let bytesWritten, let totalExpected):
                let total = totalExpected > 0 ? totalExpected : totalSize
                let fraction = total > 0 ? Double(bytesWritten) / Double(total) : 0
                let elapsed = Date().timeIntervalSince(startTime)
                let speed = elapsed > 0 ? Double(bytesWritten) / elapsed : 0
                let remaining = speed > 0 ? Double(total - bytesWritten) / speed : 0
                updateState = .downloading(
                    progress: min(fraction, 1.0),
                    bytesDownloaded: bytesWritten,
                    totalBytes: total,
                    estimatedSecondsRemaining: remaining
                )
            case .completed(let url):
                fileURL = url
            case .failed(let error):
                session.finishTasksAndInvalidate()
                throw error
            }
        }

        session.finishTasksAndInvalidate()

        guard let downloadedFile = fileURL else {
            throw UpdateCheckerError.downloadCancelled
        }

        // Verify SHA-256
        if let expectedSHA256 {
            updateState = .verifying
            VocaLogger.info(.updateChecker, "Verifying SHA-256 checksum...")
            let data = try Data(contentsOf: downloadedFile, options: .mappedIfSafe)
            let hash = SHA256.hash(data: data)
            let actualSHA256 = hash.compactMap { String(format: "%02x", $0) }.joined()
            guard expectedSHA256.lowercased() == actualSHA256.lowercased() else {
                try? FileManager.default.removeItem(at: downloadedFile)
                throw UpdateCheckerError.checksumMismatch
            }
        }

        // Move to final location
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destinationURL)

        do {
            try FileManager.default.moveItem(at: downloadedFile, to: destinationURL)
        } catch {
            throw UpdateCheckerError.failedToMoveDownload
        }

        return destinationURL
    }
}

// MARK: - Download Events

private enum DownloadEvent {
    case progress(bytesWritten: Int64, totalBytes: Int64)
    case completed(URL)
    case failed(Error)
}

/// URLSession download delegate that bridges callbacks to an AsyncStream.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let events: AsyncStream<DownloadEvent>
    private let continuation: AsyncStream<DownloadEvent>.Continuation

    override init() {
        let (stream, cont) = AsyncStream.makeStream(of: DownloadEvent.self)
        self.events = stream
        self.continuation = cont
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Move file before URLSession deletes it
        let savedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".dmg")
        do {
            try FileManager.default.moveItem(at: location, to: savedURL)

            if let httpResponse = downloadTask.response as? HTTPURLResponse,
               httpResponse.statusCode != 200 {
                continuation.yield(.failed(UpdateCheckerError.invalidStatusCode(httpResponse.statusCode)))
            } else {
                continuation.yield(.completed(savedURL))
            }
        } catch {
            continuation.yield(.failed(UpdateCheckerError.failedToMoveDownload))
        }
        continuation.finish()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            continuation.yield(.failed(error))
            continuation.finish()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        continuation.yield(.progress(bytesWritten: totalBytesWritten, totalBytes: totalBytesExpectedToWrite))
    }
}
