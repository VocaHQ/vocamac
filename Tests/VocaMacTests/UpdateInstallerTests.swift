// UpdateInstallerTests.swift
// VocaMac Tests
//
// In-place updates: refusing unsafe installs, verifying and staging a real
// DMG, and the swap helper that runs after the app quits.

import XCTest
@testable import VocaMac

final class UpdateInstallerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// An ad-hoc signed VocaMac.app with the given version.
    private func makeApp(at url: URL, version: String, identifier: String = "com.vocamac.app") throws {
        let macOS = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("VocaMac").path)
        let info: NSDictionary = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundleExecutable": "VocaMac",
            "CFBundlePackageType": "APPL",
        ]
        info.write(to: url.appendingPathComponent("Contents/Info.plist"), atomically: true)
        XCTAssertEqual(try run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", identifier, url.path]), 0)
    }

    /// A DMG holding VocaMac.app at its root, like the release DMG.
    private func makeDMG(version: String, identifier: String = "com.vocamac.app") throws -> URL {
        let source = directory.appendingPathComponent("dmg-source", isDirectory: true)
        try makeApp(at: source.appendingPathComponent("VocaMac.app"), version: version, identifier: identifier)
        let dmg = directory.appendingPathComponent("VocaMac-\(version).dmg")
        let status = try run("/usr/bin/hdiutil", [
            "create", "-volname", "VocaMac", "-srcfolder", source.path, "-format", "UDRO", "-ov", dmg.path,
        ])
        try XCTSkipIf(status != 0, "hdiutil create is not available here")
        return dmg
    }

    /// An installer for an app installed in the test directory.
    private func installer(requirement: String? = #"identifier "com.vocamac.app""#) throws -> UpdateInstaller {
        let installed = directory.appendingPathComponent("Applications/VocaMac.app", isDirectory: true)
        try makeApp(at: installed, version: "1.0.0")
        var installer = UpdateInstaller()
        installer.runningAppURL = installed
        installer.bundleIdentifier = "com.vocamac.app"
        installer.currentVersion = "1.0.0"
        installer.requirement = { requirement }
        return installer
    }

    // MARK: - Pure parts

    func testRequirementPinsTeamAndIdentifier() {
        let requirement = UpdateInstaller.requirement(teamID: "ABCDE12345", identifier: "com.vocamac.app")
        XCTAssertTrue(requirement.contains(#"identifier "com.vocamac.app""#))
        XCTAssertTrue(requirement.contains(#"certificate leaf[subject.OU] = "ABCDE12345""#))
        XCTAssertTrue(requirement.hasPrefix("anchor apple generic"))
    }

    func testVersionComparison() {
        XCTAssertTrue(UpdateInstaller.isNewer("1.2.0", than: "1.1.9"))
        XCTAssertTrue(UpdateInstaller.isNewer("2.0", than: "1.9.9"))
        XCTAssertFalse(UpdateInstaller.isNewer("1.1.0", than: "1.1.0"))
        XCTAssertFalse(UpdateInstaller.isNewer("1.0.9", than: "1.1.0"))
        XCTAssertFalse(UpdateInstaller.isNewer("1.1.0-beta", than: "1.1.0"))
    }

    func testTheTestRunnerIsNotADeveloperIDApp() {
        // xctest is Apple-signed, not by a Developer ID team; ad-hoc local
        // builds have no team either. Either way there is nothing to pin.
        if let requirement = UpdateInstaller.developerIDRequirement() {
            XCTAssertTrue(requirement.contains("certificate leaf[subject.OU]"))
        }
    }

    // MARK: - Refusals (the running app is never touched)

    func testRefusesWithoutASigningRequirement() async throws {
        let installer = try installer(requirement: nil)
        do {
            _ = try await installer.stage(dmg: directory.appendingPathComponent("missing.dmg"))
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertEqual(error as? UpdateInstallError, .unsignedRunningApp)
        }
    }

    func testRefusesATranslocatedApp() async throws {
        var installer = try installer()
        installer.runningAppURL = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/VocaMac.app")
        do {
            _ = try await installer.stage(dmg: directory.appendingPathComponent("missing.dmg"))
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertEqual(error as? UpdateInstallError, .translocated)
        }
    }

    func testRefusesWhenTheFolderIsNotWritable() async throws {
        var installer = try installer()
        installer.runningAppURL = URL(fileURLWithPath: "/System/Applications/VocaMac.app")
        do {
            _ = try await installer.stage(dmg: directory.appendingPathComponent("missing.dmg"))
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertEqual(error as? UpdateInstallError, .destinationNotWritable)
        }
    }

    // MARK: - Staging a real DMG

    func testStagesAVerifiedNewerApp() async throws {
        let dmg = try makeDMG(version: "1.2.0")
        let installer = try installer()

        let staged = try await installer.stage(dmg: dmg)

        XCTAssertEqual(staged.version, "1.2.0")
        XCTAssertEqual(staged.stagedAppURL.deletingLastPathComponent(), installer.runningAppURL.deletingLastPathComponent())
        XCTAssertTrue(UpdateInstaller.satisfies(staged.stagedAppURL, requirement: #"identifier "com.vocamac.app""#))
        let info = NSDictionary(contentsOf: installer.runningAppURL.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(info?["CFBundleShortVersionString"] as? String, "1.0.0", "Staging leaves the running app alone")
    }

    func testRejectsAnAppSignedForSomethingElse() async throws {
        let dmg = try makeDMG(version: "1.2.0", identifier: "com.example.other")
        let installer = try installer()
        do {
            _ = try await installer.stage(dmg: dmg)
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertEqual(error as? UpdateInstallError, .signatureMismatch)
        }
        XCTAssertFalse(try stagedLeftovers().contains { $0.hasPrefix(".VocaMac-update-") })
    }

    func testRejectsAnOlderApp() async throws {
        let dmg = try makeDMG(version: "0.9.0")
        let installer = try installer()
        do {
            _ = try await installer.stage(dmg: dmg)
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertEqual(error as? UpdateInstallError, .notNewer(found: "0.9.0"))
        }
    }

    /// `Process.waitUntilExit` can miss the exit from inside an async test
    /// and block forever; poll instead.
    private func waitForExit(_ process: Process, timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            guard Date() < deadline else { return XCTFail("Process still running after \(timeout)s") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func stagedLeftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Applications").path)
    }

    // MARK: - Swap helper

    func testSwapHelperWaitsForTheAppToQuitThenSwapsAndOpens() async throws {
        let installer = try installer()
        let staged = directory.appendingPathComponent("Applications/.VocaMac-update-x.app", isDirectory: true)
        try makeApp(at: staged, version: "1.2.0")
        let opened = directory.appendingPathComponent("opened.txt")
        let opener = directory.appendingPathComponent("opener.sh")
        try "#!/bin/sh\necho \"$1\" > \"\(opened.path)\"\n".write(to: opener, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path)

        // Stand in for VocaMac: a process that exits after a moment.
        let app = Process()
        app.executableURL = URL(fileURLWithPath: "/bin/sleep")
        app.arguments = ["0.6"]
        try app.run()

        let helper = try installer.launchSwapHelper(
            for: StagedUpdate(stagedAppURL: staged, version: "1.2.0"),
            processID: app.processIdentifier,
            opener: opener.path
        )
        // Not swapped while the app is still running.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))

        try await waitForExit(app)
        try await waitForExit(helper)
        XCTAssertEqual(helper.terminationStatus, 0)

        let info = NSDictionary(contentsOf: installer.runningAppURL.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(info?["CFBundleShortVersionString"] as? String, "1.2.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(try stagedLeftovers(), ["VocaMac.app"], "No backup or staged copy left behind")
        XCTAssertEqual(
            try String(contentsOf: opened, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            installer.runningAppURL.path
        )
    }

    func testSwapHelperKeepsTheOldAppWhenTheStagedOneIsMissing() async throws {
        let installer = try installer()
        let missing = directory.appendingPathComponent("Applications/.VocaMac-update-gone.app", isDirectory: true)
        let helper = try installer.launchSwapHelper(
            for: StagedUpdate(stagedAppURL: missing, version: "1.2.0"),
            processID: 999_999,
            opener: "/usr/bin/true"
        )
        try await waitForExit(helper)

        let info = NSDictionary(contentsOf: installer.runningAppURL.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(info?["CFBundleShortVersionString"] as? String, "1.0.0")
        XCTAssertEqual(try stagedLeftovers(), ["VocaMac.app"])
    }
}
