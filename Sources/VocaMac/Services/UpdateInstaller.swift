// UpdateInstaller.swift
// VocaMac
//
// Installs a downloaded update DMG over the running app and relaunches it,
// instead of asking the user to drag the new app into Applications.

import AppKit
import Foundation
import Security

enum UpdateInstallError: LocalizedError, Equatable {
    case unsignedRunningApp
    case translocated
    case destinationNotWritable
    case mountFailed(String)
    case appNotFound
    case signatureMismatch
    case notNewer(found: String)
    case copyFailed(String)
    case helperFailed(String)
    case dictationInProgress

    var errorDescription: String? {
        switch self {
        case .unsignedRunningApp:
            return "This copy of VocaMac isn't signed with a Developer ID, so it can't verify the update."
        case .translocated:
            return "VocaMac is running from a temporary location. Move it to Applications first."
        case .destinationNotWritable:
            return "VocaMac can't replace itself in this folder."
        case .mountFailed(let detail):
            return "Couldn't open the update: \(detail)"
        case .appNotFound:
            return "The update doesn't contain VocaMac.app."
        case .signatureMismatch:
            return "The update isn't signed by the same developer as this app."
        case .notNewer(let found):
            return "The update contains version \(found), which isn't newer than this one."
        case .copyFailed(let detail):
            return "Couldn't copy the update: \(detail)"
        case .helperFailed(let detail):
            return "Couldn't start the installer: \(detail)"
        case .dictationInProgress:
            return "A dictation is still running. Install again when it's done."
        }
    }
}

/// A verified copy of the new app, staged next to the running one.
struct StagedUpdate: Equatable {
    var stagedAppURL: URL
    var version: String
}

/// Replaces the running app with the one in a downloaded DMG.
///
/// 1. Mount the DMG read-only and find `VocaMac.app`.
/// 2. Check it is signed by the same Developer ID team as the running app,
///    with the same bundle identifier, and is a newer version.
/// 3. Copy it next to the running app (same volume, so the swap is a rename).
/// 4. Start a small shell helper, then quit. The helper waits for this
///    process to exit, swaps the bundles (putting the old one back if the
///    swap fails), and opens the app again.
///
/// Anything that stops step 1–3 leaves the running app untouched; the caller
/// falls back to opening the DMG for a manual install. Because the new app
/// is signed by the same team, macOS keeps its Accessibility, Input
/// Monitoring and Microphone permissions.
/// Sendable: staging runs off the main actor.
struct UpdateInstaller: Sendable {
    var runningAppURL: URL = Bundle.main.bundleURL
    var bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.vocamac.app"
    var currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// The code-signing requirement the new app must meet, or nil when the
    /// running app can't supply one (ad-hoc or unsigned builds).
    var requirement: @Sendable () -> String? = { UpdateInstaller.developerIDRequirement() }
    var isNewer: @Sendable (_ found: String, _ current: String) -> Bool = { UpdateInstaller.isNewer($0, than: $1) }
    private var fileManager: FileManager { .default }

    static let appName = "VocaMac.app"

    // MARK: Prepare

    /// Mount, verify, and stage the update. Leaves the running app untouched.
    func stage(dmg: URL) async throws -> StagedUpdate {
        guard !runningAppURL.path.contains("/AppTranslocation/") else { throw UpdateInstallError.translocated }
        let parent = runningAppURL.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: parent.path) else { throw UpdateInstallError.destinationNotWritable }
        guard let requirement = requirement() else { throw UpdateInstallError.unsignedRunningApp }

        let mountPoint = fileManager.temporaryDirectory
            .appendingPathComponent("VocaMac-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: mountPoint) }

        // -noverify: the caller already checked the whole file's SHA-256.
        try await Self.run("/usr/bin/hdiutil", [
            "attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-noverify", "-mountpoint", mountPoint.path,
        ], failure: UpdateInstallError.mountFailed)

        let result: Result<StagedUpdate, Error>
        do {
            result = .success(try await verifyAndCopy(
                mountPoint.appendingPathComponent(Self.appName, isDirectory: true),
                into: parent,
                requirement: requirement
            ))
        } catch {
            result = .failure(error)
        }
        await Self.detach(mountPoint)
        return try result.get()
    }

    /// Detach whatever happened; -force covers a Finder window that happens
    /// to look at the volume. One retry, because a volume still being read
    /// can refuse the first time; a volume that stays mounted is logged.
    private static func detach(_ mountPoint: URL) async {
        for attempt in 1...2 {
            do {
                try await run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"], failure: UpdateInstallError.mountFailed)
                return
            } catch {
                if attempt == 2 {
                    VocaLogger.warning(.updateChecker, "Update volume stayed mounted at \(mountPoint.path): \(error.localizedDescription)")
                } else {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    private func verifyAndCopy(_ newApp: URL, into parent: URL, requirement: String) async throws -> StagedUpdate {
        guard fileManager.fileExists(atPath: newApp.path) else { throw UpdateInstallError.appNotFound }
        guard Self.satisfies(newApp, requirement: requirement) else { throw UpdateInstallError.signatureMismatch }

        let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw UpdateInstallError.signatureMismatch
        }
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        guard isNewer(version, currentVersion) else { throw UpdateInstallError.notNewer(found: version) }

        let staged = parent.appendingPathComponent(".VocaMac-update-\(UUID().uuidString).app", isDirectory: true)
        do {
            // ditto keeps the signature, extended attributes, and symlinks
            // inside frameworks intact.
            try await Self.run("/usr/bin/ditto", [newApp.path, staged.path], failure: UpdateInstallError.copyFailed)
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }
        // Check the copy too: what gets launched is the staged bundle.
        guard Self.satisfies(staged, requirement: requirement) else {
            try? fileManager.removeItem(at: staged)
            throw UpdateInstallError.signatureMismatch
        }
        return StagedUpdate(stagedAppURL: staged, version: version)
    }

    // MARK: Swap

    /// The helper run after VocaMac quits. Paths arrive as arguments, never
    /// spliced into the script.
    ///
    /// $1 pid to wait for, $2 installed app, $3 staged app, $4 backup path,
    /// $5 command that opens the app, $6 file the outcome is written to (read
    /// by the next launch), $7 the new version.
    static let swapScript = """
    pid="$1"; current="$2"; staged="$3"; backup="$4"; opener="$5"; result="$6"; version="$7"
    report() { printf '%s\\n' "$1" > "$result" 2>/dev/null; }
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 0.2
        waited=$((waited + 1))
        if [ "$waited" -ge 300 ]; then
            rm -rf "$staged"
            report "failed: VocaMac didn't quit, so $version wasn't installed"
            exit 1
        fi
    done
    if mv "$current" "$backup"; then
        if mv "$staged" "$current"; then
            rm -rf "$backup"
            report "installed $version"
        else
            mv "$backup" "$current"
            rm -rf "$staged"
            report "failed: couldn't move $version into place; the previous version was put back"
        fi
    else
        rm -rf "$staged"
        report "failed: couldn't move the installed app aside to install $version"
    fi
    if ! "$opener" "$current"; then
        printf '%s\\n' "reopen failed" >> "$result" 2>/dev/null
    fi
    """

    /// Where the helper leaves the outcome for the next launch to read.
    static var defaultResultFile: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("VocaMac/last-update-result.txt")
    }

    /// The last helper's outcome, removed once read.
    static func consumeResult(at file: URL = defaultResultFile) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: file)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Start the swap helper. The caller quits the app right after.
    func launchSwapHelper(
        for staged: StagedUpdate,
        processID: pid_t = ProcessInfo.processInfo.processIdentifier,
        opener: String = "/usr/bin/open",
        resultFile: URL = UpdateInstaller.defaultResultFile
    ) throws -> Process {
        try? fileManager.createDirectory(at: resultFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: resultFile)
        let backup = runningAppURL.deletingLastPathComponent()
            .appendingPathComponent(".VocaMac-previous-\(UUID().uuidString).app", isDirectory: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", Self.swapScript, "vocamac-update",
            String(processID), runningAppURL.path, staged.stagedAppURL.path, backup.path, opener,
            resultFile.path, staged.version,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            // Nothing else will remove the staged copy.
            try? fileManager.removeItem(at: staged.stagedAppURL)
            throw UpdateInstallError.helperFailed(error.localizedDescription)
        }
        return process
    }

    // MARK: Signing

    /// "Signed by Apple-issued Developer ID for this team, with this bundle
    /// identifier", built from the running app's own signature. Nil for
    /// ad-hoc and unsigned builds, which have no team to compare against.
    static func developerIDRequirement() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any],
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              let identifier = info[kSecCodeInfoIdentifier as String] as? String else { return nil }
        return requirement(teamID: team, identifier: identifier)
    }

    static func requirement(teamID: String, identifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" "
            + "and certificate leaf[field.1.2.840.113635.100.6.1.13] "
            + "and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// Whether the bundle at `url` is validly signed and meets `requirement`.
    static func satisfies(_ url: URL, requirement: String) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            return false
        }
        var secRequirement: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &secRequirement) == errSecSuccess,
              let secRequirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(staticCode, flags, secRequirement) == errSecSuccess
    }

    // MARK: Versions

    /// Major.minor.patch comparison, ignoring pre-release and build suffixes,
    /// as the update check does.
    static func isNewer(_ found: String, than current: String) -> Bool {
        func parse(_ version: String) -> [Int] {
            let values = version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
            return (0..<3).map { values.indices.contains($0) ? values[$0] : 0 }
        }
        return parse(current).lexicographicallyPrecedes(parse(found))
    }

    // MARK: Processes

    /// Run a tool to completion. Waits on its termination handler rather
    /// than `waitUntilExit`, which can miss the exit when called from a
    /// concurrency thread and block forever. Errors go to a file, so a
    /// chatty tool can't fill a pipe and stall.
    private static func run(
        _ tool: String,
        _ arguments: [String],
        failure: @escaping (String) -> UpdateInstallError
    ) async throws {
        let errorFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocaMac-update-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errorFile) }
        let errors = try FileHandle(forWritingTo: errorFile)
        defer { try? errors.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: failure(error.localizedDescription))
            }
        }
        guard status == 0 else {
            let message = (try? String(contentsOf: errorFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw failure(message.isEmpty ? "\(URL(fileURLWithPath: tool).lastPathComponent) exited with \(status)" : message)
        }
    }
}
