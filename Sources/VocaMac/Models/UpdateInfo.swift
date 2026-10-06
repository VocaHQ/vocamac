// UpdateInfo.swift
// VocaMac
//
// Models for GitHub release update checks and update UI state.

import Foundation

// MARK: - GitHub API Models

struct GitHubRelease: Codable {
    let tagName: String
    let name: String
    let body: String
    let htmlURL: URL
    let prerelease: Bool
    let draft: Bool
    let publishedAt: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case prerelease
        case draft
        case publishedAt = "published_at"
        case assets
    }
}

struct GitHubAsset: Codable {
    let name: String
    let size: Int
    let browserDownloadURL: URL
    let contentType: String
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case browserDownloadURL = "browser_download_url"
        case contentType = "content_type"
        case digest
    }
}

// MARK: - Processed Update Models

struct UpdateInfo: Equatable {
    let version: String
    let tagName: String
    let releaseNotes: String
    let releasePageURL: URL
    let dmgURL: URL
    let dmgSize: Int
    let sha256: String?
}

struct HomebrewInstall: Equatable {
    let caskToken: String

    var upgradeCommand: String {
        "brew upgrade --cask \(caskToken)"
    }
}

enum UpdateState: Equatable {
    case idle
    case checking
    case updateAvailable(UpdateInfo)
    case updateAvailableViaHomebrew(info: UpdateInfo, install: HomebrewInstall)
    case upToDate
    case downloading(progress: Double, bytesDownloaded: Int64, totalBytes: Int64, estimatedSecondsRemaining: Double)
    case verifying
    case readyToInstall(dmgPath: URL)
    /// Verifying and staging the new app before quitting to swap it in.
    case installing
    /// The in-place install stopped before touching the running app; the
    /// DMG can still be opened to install by hand.
    case installFailed(dmgPath: URL, message: String)
    case error(String)
}
