// UpdateCheckerTests.swift
// VocaMac Tests

import XCTest
@testable import VocaMac

final class UpdateCheckerTests: XCTestCase {
    @MainActor
    func testNormalizeVersionStripsVPrefix() {
        let checker = UpdateChecker()
        XCTAssertEqual(checker.normalizeVersion("v0.4.0"), "0.4.0")
    }

    @MainActor
    func testNormalizeVersionPadsMissingSegments() {
        let checker = UpdateChecker()
        XCTAssertEqual(checker.normalizeVersion("1"), "1.0.0")
        XCTAssertEqual(checker.normalizeVersion("1.2"), "1.2.0")
    }

    @MainActor
    func testVersionComparisonHandlesTwoDigitMinor() {
        let checker = UpdateChecker()
        XCTAssertTrue(checker.isNewerVersion(remote: "0.10.0", current: "0.9.0"))
        XCTAssertFalse(checker.isNewerVersion(remote: "0.9.0", current: "0.10.0"))
    }

    func testGitHubReleaseDecoding() throws {
        let json = #"{"tag_name":"v0.4.0","name":"v0.4.0-beta","body":"Release notes","html_url":"https://github.com/VocaHQ/vocamac/releases/tag/v0.4.0","prerelease":false,"draft":false,"published_at":"2026-04-10T18:46:58Z","assets":[{"name":"VocaMac-0.4.0-arm64.dmg","size":1234,"browser_download_url":"https://github.com/VocaHQ/vocamac/releases/download/v0.4.0/VocaMac-0.4.0-arm64.dmg","content_type":"application/x-apple-diskimage","digest":"sha256:abc123"}]}"#

        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
        XCTAssertEqual(release.tagName, "v0.4.0")
        XCTAssertEqual(release.assets.count, 1)
        XCTAssertEqual(release.assets.first?.name, "VocaMac-0.4.0-arm64.dmg")
    }

    func testDetectHomebrewInstallFromCaskroomSymlink() throws {
        let fixture = try makeHomebrewFixture(caskToken: "vocamac", version: "0.6.2")

        let install = UpdateChecker.detectHomebrewInstall(
            bundlePath: fixture.appBundle.path,
            caskroomRoots: [fixture.caskroomRoot]
        )

        XCTAssertEqual(install?.caskToken, "vocamac")
        XCTAssertEqual(install?.upgradeCommand, "brew upgrade --cask vocamac")
    }

    func testDetectHomebrewInstallPreservesNightlyCaskToken() throws {
        let fixture = try makeHomebrewFixture(caskToken: "vocamac-nightly", version: "nightly")

        let install = UpdateChecker.detectHomebrewInstall(
            bundlePath: fixture.appBundle.path,
            caskroomRoots: [fixture.caskroomRoot]
        )

        XCTAssertEqual(install?.caskToken, "vocamac-nightly")
        XCTAssertEqual(install?.upgradeCommand, "brew upgrade --cask vocamac-nightly")
    }

    func testDetectHomebrewInstallRequiresReceipt() throws {
        let fixture = try makeHomebrewFixture(caskToken: "vocamac", version: "0.6.2", writeReceipt: false)

        let install = UpdateChecker.detectHomebrewInstall(
            bundlePath: fixture.appBundle.path,
            caskroomRoots: [fixture.caskroomRoot]
        )

        XCTAssertNil(install)
    }

    @MainActor
    func testCheckForUpdatesTransitionsToHomebrewStateWhenInstalledViaHomebrew() async {
        let checker = UpdateChecker()
        checker.overrideHomebrewInstall = .installed(HomebrewInstall(caskToken: "vocamac-nightly"))

        let mockRelease = GitHubRelease(
            tagName: "v99.99.99",
            name: "v99.99.99",
            body: "Test release",
            htmlURL: URL(string: "https://example.com")!,
            prerelease: false,
            draft: false,
            publishedAt: "2026-01-01T00:00:00Z",
            assets: [
                GitHubAsset(
                    name: "VocaMac-99.99.99-arm64.dmg",
                    size: 1234,
                    browserDownloadURL: URL(string: "https://example.com/dmg")!,
                    contentType: "application/x-apple-diskimage",
                    digest: nil
                )
            ]
        )

        await checker.checkForUpdates(releaseProvider: { mockRelease })

        if case .updateAvailableViaHomebrew(let info, let install) = checker.updateState {
            XCTAssertEqual(info.tagName, "v99.99.99")
            XCTAssertEqual(install.caskToken, "vocamac-nightly")
        } else {
            XCTFail("Expected .updateAvailableViaHomebrew but got \(String(describing: checker.updateState))")
        }
    }

    @MainActor
    func testCheckForUpdatesTransitionsToUpdateAvailableWhenNotHomebrew() async {
        let checker = UpdateChecker()
        checker.overrideHomebrewInstall = .notInstalled

        let mockRelease = GitHubRelease(
            tagName: "v99.99.99",
            name: "v99.99.99",
            body: "Test release",
            htmlURL: URL(string: "https://example.com")!,
            prerelease: false,
            draft: false,
            publishedAt: "2026-01-01T00:00:00Z",
            assets: [
                GitHubAsset(
                    name: "VocaMac-99.99.99-arm64.dmg",
                    size: 1234,
                    browserDownloadURL: URL(string: "https://example.com/dmg")!,
                    contentType: "application/x-apple-diskimage",
                    digest: nil
                )
            ]
        )

        await checker.checkForUpdates(releaseProvider: { mockRelease })

        if case .updateAvailable(let info) = checker.updateState {
            XCTAssertEqual(info.tagName, "v99.99.99")
        } else {
            XCTFail("Expected .updateAvailable but got \(String(describing: checker.updateState))")
        }
    }

    private func makeHomebrewFixture(
        caskToken: String,
        version: String,
        writeReceipt: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (caskroomRoot: URL, appBundle: URL) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("VocaMacTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let caskroomRoot = root.appendingPathComponent("Caskroom", isDirectory: true)
        let appBundle = root
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("VocaMac.app", isDirectory: true)
        let caskRoot = caskroomRoot.appendingPathComponent(caskToken, isDirectory: true)
        let metadataRoot = caskRoot.appendingPathComponent(".metadata", isDirectory: true)
        let versionRoot = caskRoot.appendingPathComponent(version, isDirectory: true)
        let stagedApp = versionRoot.appendingPathComponent("VocaMac.app", isDirectory: true)

        addTeardownBlock {
            try? fileManager.removeItem(at: root)
        }

        try fileManager.createDirectory(at: appBundle, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: metadataRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: versionRoot, withIntermediateDirectories: true)
        if writeReceipt {
            let receipt = metadataRoot.appendingPathComponent("INSTALL_RECEIPT.json")
            try Data(#"{"uninstall_artifacts":[{"app":["VocaMac.app"]}]}"#.utf8).write(to: receipt)
        }
        try fileManager.createSymbolicLink(at: stagedApp, withDestinationURL: appBundle)

        XCTAssertTrue(fileManager.fileExists(atPath: appBundle.path), file: file, line: line)
        return (caskroomRoot, appBundle)
    }
}
