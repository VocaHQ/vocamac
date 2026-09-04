// GatewayProcessManager.swift
// VocaMac
//
// Native-first start/stop and health/pairing probes for a local VocaGateway.
// Gateway owns its logs; this manager only reveals Gateway paths or tees
// session stdout — it does not write Gateway logs under VocaMac Application Support.

import Foundation
import AppKit

/// Paths and URLs used by the local Gateway integration.
enum GatewayPaths {
    static let defaultPort = 8765
    static let loopbackBaseURL = URL(string: "http://127.0.0.1:8765")!
    static let docsURL = URL(string: "https://vocagateway.vocahq.com/")!
    static let githubURL = URL(string: "https://github.com/VocaHQ/vocagateway")!
    static let dockerDesktopURL = URL(string: "https://www.docker.com/products/docker-desktop/")!

    static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/vocagateway", isDirectory: true)
    }

    static var tokenFileURL: URL {
        configDirectory.appendingPathComponent("token", isDirectory: false)
    }

    static var configFileURL: URL {
        configDirectory.appendingPathComponent("config.json", isDirectory: false)
    }

    /// LaunchAgent log directory documented by VocaGateway on macOS.
    static var macOSLogDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VocaGateway", isDirectory: true)
    }

    static var macOSLogFileURL: URL {
        macOSLogDirectory.appendingPathComponent("gateway.log", isDirectory: false)
    }

    /// Common install locations checked after PATH.
    static var commonBinaryCandidates: [String] {
        [
            "/opt/homebrew/bin/vocagateway",
            "/usr/local/bin/vocagateway",
            "\(NSHomeDirectory())/.local/bin/vocagateway",
            "\(NSHomeDirectory())/.cargo/bin/vocagateway",
        ]
    }
}

/// Resolves a `vocagateway` executable without spawning it.
enum GatewayBinaryResolver {
    /// Returns an absolute path to `vocagateway` when found on PATH or common locations.
    static func resolveExecutablePath(
        fileManager: FileManager = .default,
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> String? {
        if let fromPath = findOnPATH(
            named: "vocagateway",
            pathEnvironment: pathEnvironment,
            fileManager: fileManager
        ) {
            return fromPath
        }
        for candidate in GatewayPaths.commonBinaryCandidates {
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func findOnPATH(
        named name: String,
        pathEnvironment: String?,
        fileManager: FileManager
    ) -> String? {
        let path = pathEnvironment ?? ""
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(name)
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func isDockerCLIAvailable(
        fileManager: FileManager = .default,
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> Bool {
        let fixed = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"]
        if fixed.contains(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return true
        }
        return findOnPATH(named: "docker", pathEnvironment: pathEnvironment, fileManager: fileManager) != nil
    }
}

@MainActor
final class GatewayProcessManager: ObservableObject {
    @Published private(set) var status: GatewayRuntimeStatus = .stopped
    @Published private(set) var binaryPath: String?
    @Published private(set) var isBinaryAvailable = false
    @Published private(set) var isDockerAvailable = false
    @Published private(set) var pairingPayload: GatewayPairingPayload?
    @Published private(set) var pairingPayloadRaw: String?
    @Published private(set) var pairingCandidates: [String] = []
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var isLive = false
    @Published private(set) var isReady = false
    @Published var publicURLOverride: String = ""

    private var process: Process?
    private var stdoutPipe: Pipe?
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        refreshBinaryAvailability()
    }

    // MARK: - Discovery

    func refreshBinaryAvailability() {
        binaryPath = GatewayBinaryResolver.resolveExecutablePath()
        isBinaryAvailable = binaryPath != nil
        isDockerAvailable = GatewayBinaryResolver.isDockerCLIAvailable()
    }

    // MARK: - Lifecycle

    func start() async {
        refreshBinaryAvailability()
        guard let binaryPath else {
            let message = "VocaGateway is not installed. Install the native CLI, or use Docker as a fallback."
            status = .error(message)
            lastErrorMessage = message
            return
        }

        if isLive {
            await refreshStatus()
            return
        }

        status = .starting
        lastErrorMessage = nil
        pairingPayload = nil
        pairingPayloadRaw = nil

        do {
            try spawnNativeProcess(executable: binaryPath)
        } catch {
            status = .error(error.localizedDescription)
            lastErrorMessage = error.localizedDescription
            return
        }

        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            await refreshStatus()
            if isLive { return }
            if case .error = status { return }
        }

        if !isLive {
            let message = "Gateway did not become reachable on port \(GatewayPaths.defaultPort)."
            status = .error(message)
            lastErrorMessage = message
        }
    }

    func stop() async {
        if let process, process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning {
                process.interrupt()
            }
        }
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        self.process = nil
        self.stdoutPipe = nil

        isLive = false
        isReady = false
        pairingPayload = nil
        pairingPayloadRaw = nil
        status = .stopped
        lastErrorMessage = nil
    }

    func refreshStatus() async {
        refreshBinaryAvailability()

        let live = await probe(path: "/health/live")
        let ready = await probe(path: "/health/ready")
        isLive = live
        isReady = ready

        if !live {
            pairingPayload = nil
            pairingPayloadRaw = nil
            if process?.isRunning == true {
                if case .error = status {
                    return
                }
                status = .starting
                return
            }
            if case .error = status {
                return
            }
            status = .stopped
            return
        }

        await fetchPairing()
    }

    // MARK: - Pairing

    func fetchPairing() async {
        guard isLive else { return }

        guard let token = readBootstrapToken() else {
            let message = "Gateway is live but ~/.config/vocagateway/token is missing."
            status = .error(message)
            lastErrorMessage = message
            return
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = GatewayPaths.defaultPort
        components.path = "/v1/admin/pairing"

        let override = publicURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty {
            switch GatewayPairingCodec.validatedPublicURL(override) {
            case .success(let url):
                components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
            case .failure(let error):
                pairingPayload = nil
                pairingPayloadRaw = nil
                let message = error.localizedDescription
                status = .error(message)
                lastErrorMessage = message
                return
            }
        }

        guard let endpoint = components.url else { return }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                status = .error("Invalid pairing response.")
                return
            }
            guard http.statusCode == 200 else {
                let message = "Pairing request failed (HTTP \(http.statusCode))."
                status = .error(message)
                lastErrorMessage = message
                return
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                status = .error("Pairing response was not JSON.")
                return
            }
            if let candidates = json["candidates"] as? [String] {
                pairingCandidates = candidates
            }
            pairingPayloadRaw = json["payload"] as? String

            switch GatewayPairingCodec.decodeAdminResponse(json, rejectLoopback: true) {
            case .success(let payload):
                pairingPayload = payload
                status = isReady ? .ready : .pairable
                lastErrorMessage = nil
            case .failure(let error):
                pairingPayload = nil
                let message = error.localizedDescription
                status = .error(message)
                lastErrorMessage = message
            }
        } catch {
            let message = "Pairing request failed: \(error.localizedDescription)"
            status = .error(message)
            lastErrorMessage = message
        }
    }

    // MARK: - Actions

    func openWebUI() {
        NSWorkspace.shared.open(GatewayPaths.loopbackBaseURL)
    }

    func openGatewayDocs() {
        NSWorkspace.shared.open(GatewayPaths.docsURL)
    }

    func openDockerDesktopInstall() {
        NSWorkspace.shared.open(GatewayPaths.dockerDesktopURL)
    }

    func openGatewayRepo() {
        NSWorkspace.shared.open(GatewayPaths.githubURL)
    }

    /// Reveal Gateway's documented log path (not VocaMac Application Support).
    func openGatewayLogs() {
        let logFile = GatewayPaths.macOSLogFileURL
        let logDir = GatewayPaths.macOSLogDirectory
        let fm = FileManager.default
        if fm.fileExists(atPath: logFile.path) {
            NSWorkspace.shared.selectFile(logFile.path, inFileViewerRootedAtPath: logDir.path)
            return
        }
        if fm.fileExists(atPath: logDir.path) {
            NSWorkspace.shared.open(logDir)
            return
        }
        let configDir = GatewayPaths.configDirectory
        if fm.fileExists(atPath: configDir.path) {
            NSWorkspace.shared.open(configDir)
            return
        }
        lastErrorMessage = "No Gateway log file yet. LaunchAgent installs write to ~/Library/Logs/VocaGateway/. Session starts from VocaMac tee process stdout only."
    }

    func copyPairingURLToPasteboard() {
        guard let url = pairingPayload?.url.absoluteString else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url, forType: .string)
    }

    func readBootstrapToken() -> String? {
        let url = GatewayPaths.tokenFileURL
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Private

    private func spawnNativeProcess(executable: String) throws {
#if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = []

        var environment = ProcessInfo.processInfo.environment
        let override = publicURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty, case .success(let url) = GatewayPairingCodec.validatedPublicURL(override) {
            environment["VOCAGATEWAY_PUBLIC_URL"] = url.absoluteString
        }
        process.environment = environment

        // Tee stdout/stderr for this session only. Persisted logs stay under Gateway paths.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        stdoutPipe = pipe

        process.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                guard let self else { return }
                guard self.process === terminated else { return }
                self.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.stdoutPipe = nil
                self.isLive = false
                self.isReady = false
                if case .starting = self.status {
                    let message = "Gateway process exited while starting."
                    self.status = .error(message)
                    self.lastErrorMessage = message
                } else if case .error = self.status {
                    // keep
                } else {
                    self.status = .stopped
                }
            }
        }

        try process.run()
        self.process = process

        pipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
#else
        throw NSError(
            domain: "GatewayProcessManager",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Native Gateway process control is only available on macOS."]
        )
#endif
    }

    private func probe(path: String) async -> Bool {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = GatewayPaths.defaultPort
        components.path = path
        guard let url = components.url else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.httpMethod = "GET"
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode == 200
        } catch {
            return false
        }
    }
}
