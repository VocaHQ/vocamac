// GatewayEmbedController.swift
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
    static let dockerInstallURL = URL(string: "https://docs.docker.com/desktop/setup/install/mac-install/")!
    static let vocagatewayREADME = URL(string: "https://github.com/VocaHQ/vocagateway#readme")!
    static let publicURLOverrideDefaultsKey = "vocamac.gateway.publicURLOverride"

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

    /// Fixed Homebrew install locations, checked before PATH: neither is
    /// writable without an admin or Homebrew prefix, unlike a PATH entry.
    static let preferredBinaryCandidates = [
        "/opt/homebrew/bin/vocagateway",
        "/usr/local/bin/vocagateway",
    ]

    /// Per-user install locations, checked last because anything running as
    /// the user can write to them.
    static var userBinaryCandidates: [String] {
        [
            "\(NSHomeDirectory())/.local/bin/vocagateway",
            "\(NSHomeDirectory())/.cargo/bin/vocagateway",
        ]
    }
}

/// Resolves a `vocagateway` executable without spawning it.
enum GatewayBinaryResolver {
    /// Returns an absolute path to `vocagateway`: a fixed Homebrew location
    /// first, then PATH, then per-user install folders. Settings shows the
    /// path found, so the user can see which program VocaMac would start.
    static func resolveExecutablePath(
        fileManager: FileManager = .default,
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"],
        preferredCandidates: [String] = GatewayPaths.preferredBinaryCandidates,
        userCandidates: [String] = GatewayPaths.userBinaryCandidates
    ) -> String? {
        if let preferred = preferredCandidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return preferred
        }
        if let fromPath = findOnPATH(
            named: "vocagateway",
            pathEnvironment: pathEnvironment,
            fileManager: fileManager
        ) {
            return fromPath
        }
        return userCandidates.first { fileManager.isExecutableFile(atPath: $0) }
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
final class GatewayEmbedController: ObservableObject {
    static let shared = GatewayEmbedController()

    enum Status: Equatable {
        case stopped
        case starting
        case pairable
        case ready
        case error(String)

        var title: String {
            switch self {
            case .stopped: return "Stopped"
            case .starting: return "Starting"
            case .pairable: return "Pairable"
            case .ready: return "Ready"
            case .error: return "Error"
            }
        }

        var detail: String? {
            if case .error(let message) = self { return message }
            return nil
        }

        var allowsPairing: Bool {
            switch self {
            case .pairable, .ready: return true
            default: return false
            }
        }
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var binaryPath: String?
    @Published private(set) var isBinaryAvailable = false
    @Published private(set) var isDockerAvailable = false
    @Published private(set) var pairingPayload: GatewayPairingPayload?
    @Published private(set) var pairingPayloadRaw: String?
    @Published private(set) var pairingCandidates: [String] = []
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var isLive = false
    @Published private(set) var isReady = false
    @Published var publicURLOverride: String {
        didSet {
            UserDefaults.standard.set(publicURLOverride, forKey: GatewayPaths.publicURLOverrideDefaultsKey)
        }
    }

    private var process: Process?
    private var stdoutPipe: Pipe?
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        self.publicURLOverride = UserDefaults.standard.string(forKey: GatewayPaths.publicURLOverrideDefaultsKey) ?? ""
        refreshBinaryAvailability()
    }

    // MARK: - Discovery

    func refreshBinaryAvailability() {
        // The App Store build can't start a program from outside its bundle,
        // so it doesn't look for one.
        guard AppDistribution.hasPhoneGateway else { return }
        binaryPath = GatewayBinaryResolver.resolveExecutablePath()
        isBinaryAvailable = binaryPath != nil
        isDockerAvailable = GatewayBinaryResolver.isDockerCLIAvailable()
    }

    // MARK: - Lifecycle

    func start() async {
        guard AppDistribution.hasPhoneGateway else { return }
        refreshBinaryAvailability()
        guard let binaryPath else {
            let message = "VocaGateway is not installed. Install the native CLI, or use Docker as a fallback (no MLX / Apple Silicon native engines)."
            status = .error(message)
            lastErrorMessage = message
            return
        }

        if isLive {
            await refreshStatus()
            return
        }

        // Never stack a second child on a retained process that is no longer live.
        if process != nil {
            await terminateSpawnedProcess()
            if process != nil {
                let message = "Previous Gateway process could not be stopped."
                status = .error(message)
                lastErrorMessage = message
                return
            }
        }

        status = .starting
        lastErrorMessage = nil
        pairingPayload = nil
        pairingPayloadRaw = nil

        do {
            try spawnNativeProcess(executable: binaryPath)
        } catch {
            let message = error.localizedDescription
            status = .error(message)
            lastErrorMessage = message
            await terminateSpawnedProcess()
            return
        }

        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            await refreshStatus()
            if isLive { return }
            if case .error = status {
                await terminateSpawnedProcess()
                return
            }
        }

        if !isLive {
            let message = "Gateway did not become reachable on port \(GatewayPaths.defaultPort)."
            status = .error(message)
            lastErrorMessage = message
            await terminateSpawnedProcess()
        }
    }

    func stop() async {
        await terminateSpawnedProcess()
        // Only claim stopped after the child is gone; a surviving process stays stoppable.
        guard process == nil else { return }
        status = .stopped
        lastErrorMessage = nil
    }

    func refreshStatus() async {
        guard AppDistribution.hasPhoneGateway else { return }
        refreshBinaryAvailability()

        let live = await probe(path: "/")
        let ready = await probe(path: "/health/ready")

        if !live {
            pairingPayload = nil
            pairingPayloadRaw = nil
            if process != nil, case .error = status {
                // Reap a retained child so Stop is not disabled while it is still running.
                await terminateSpawnedProcess()
                return
            }
            if process?.isRunning == true {
                isLive = false
                isReady = false
                status = .starting
                return
            }
            isLive = false
            isReady = false
            if case .error = status {
                return
            }
            status = .stopped
            return
        }

        isLive = true
        isReady = ready
        await fetchPairing()
    }

    // MARK: - Pairing

    func fetchPairing() async {
        guard isLive else { return }

        // The admin token goes only to a gateway this Mac's user is running:
        // the one VocaMac started, or a listener whose program is the
        // installed `vocagateway` (or Docker, for the container fallback).
        // Anything else on the port, such as another account's process or a
        // sandboxed app, would otherwise be handed the token.
        guard isTrustedListener() else {
            pairingPayload = nil
            pairingPayloadRaw = nil
            let message = "Something other than VocaGateway is answering on port \(GatewayPaths.defaultPort), so VocaMac didn't send it the pairing token."
            VocaLogger.warning(.general, "Gateway pairing skipped: the listener on port \(GatewayPaths.defaultPort) isn't a known VocaGateway")
            status = .error(message)
            lastErrorMessage = message
            return
        }

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
            switch GatewayPairingURL.validatedPublicURL(override) {
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

            switch GatewayPairingDecoder.decodeAdminJSON(json, rejectLoopback: true) {
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
        NSWorkspace.shared.open(GatewayPaths.dockerInstallURL)
    }

    func openDockerFallbackDocs() {
        NSWorkspace.shared.open(GatewayPaths.dockerInstallURL)
        NSWorkspace.shared.open(GatewayPaths.vocagatewayREADME)
    }

    func openGatewayRepo() {
        NSWorkspace.shared.open(GatewayPaths.githubURL)
    }

    /// Reveal Gateway's documented log path (not VocaMac Application Support).
    func openGatewayLogs() {
        let configDir = GatewayPaths.configDirectory
        let fm = FileManager.default
        if fm.fileExists(atPath: configDir.path) {
            NSWorkspace.shared.open(configDir)
            return
        }
        let parent = configDir.deletingLastPathComponent()
        if fm.fileExists(atPath: parent.path) {
            NSWorkspace.shared.open(parent)
            return
        }
        lastErrorMessage = "Gateway config folder ~/.config/vocagateway does not exist yet. It appears after the first native Gateway start."
    }

    func copyPairingURLToPasteboard() {
        guard let url = pairingPayload?.url else { return }
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

    /// Whether the process listening on the gateway port may receive the
    /// admin token (see `fetchPairing`).
    private func isTrustedListener() -> Bool {
        let ownPID = process?.isRunning == true ? process?.processIdentifier : nil
        guard let listener = LocalPortOwner.listeningProcessID(port: GatewayPaths.defaultPort) else {
            return false
        }
        if listener == ownPID { return true }
        guard let executable = LocalPortOwner.executablePath(of: listener) else { return false }
        return GatewayListenerTrust.isTrusted(executablePath: executable, resolvedBinaryPath: binaryPath)
    }

    /// True while this controller still owns a child `Process` (running or not yet reaped).
    var hasManagedProcess: Bool { process != nil }

    // MARK: - Private

    /// SIGTERM, then SIGINT, then SIGKILL the spawned child; drop the retained Process only after exit.
    /// Does not change `status` — callers record `.stopped` or `.error`.
    private func terminateSpawnedProcess() async {
        if let process, process.isRunning {
            process.terminate()
            await waitForProcessExit(process, seconds: 2)
            if process.isRunning {
                process.interrupt()
                await waitForProcessExit(process, seconds: 2)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                await waitForProcessExit(process, seconds: 1)
            }
            // Do not abandon a surviving child; keep ownership so Stop can still target it.
            if process.isRunning {
                objectWillChange.send()
                return
            }
        }
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        self.process = nil
        self.stdoutPipe = nil
        isLive = false
        isReady = false
        pairingPayload = nil
        pairingPayloadRaw = nil
    }

    private func waitForProcessExit(_ process: Process, seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func spawnNativeProcess(executable: String) throws {
#if APP_STORE
        // The sandbox can't start a program from outside the app bundle.
        throw NSError(
            domain: "GatewayEmbedController",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The App Store version of VocaMac can't start VocaGateway."]
        )
#elseif os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = []

        var environment = ProcessInfo.processInfo.environment
        let override = publicURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty, case .success(let url) = GatewayPairingURL.validatedPublicURL(override) {
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
            domain: "GatewayEmbedController",
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

// MARK: - Listener Trust

/// Which programs may be sent the gateway's admin token.
enum GatewayListenerTrust {
    /// Docker Desktop forwards a container's port from its own backend.
    static let dockerBundlePrefixes = ["/Applications/Docker.app/"]

    static func isTrusted(executablePath: String, resolvedBinaryPath: String?) -> Bool {
        let executable = canonical(executablePath)
        var trusted = GatewayPaths.preferredBinaryCandidates + GatewayPaths.userBinaryCandidates
        if let resolvedBinaryPath { trusted.append(resolvedBinaryPath) }
        if trusted.map(canonical).contains(executable) { return true }
        return dockerBundlePrefixes.contains { executable.hasPrefix($0) }
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}

/// Finds which local process listens on a TCP port, through libproc.
///
/// Only processes this user may inspect are seen, so a port held by another
/// account (or root) reports no owner, which callers treat as untrusted.
enum LocalPortOwner {

    /// The one process that would accept a connection to `127.0.0.1:port`.
    ///
    /// Only listeners a `127.0.0.1` connection can reach count: IPv4 sockets on
    /// a loopback or wildcard address, and IPv6 sockets on the wildcard or a
    /// v4-mapped loopback address. A gateway on `::1` or a LAN address does not
    /// vouch for whoever holds `127.0.0.1`. When more than one process could
    /// take the connection (for example two `SO_REUSEPORT` listeners), the
    /// owner is ambiguous and this returns nil, which callers treat as untrusted.
    static func listeningProcessID(port: Int) -> pid_t? {
        let owners = allProcessIDs().filter { $0 > 0 && listensForIPv4Loopback(pid: $0, port: port) }
        return soleOwner(owners)
    }

    /// The single distinct owner, or nil when there is none or more than one.
    static func soleOwner(_ owners: [pid_t]) -> pid_t? {
        let distinct = Set(owners)
        return distinct.count == 1 ? distinct.first : nil
    }

    /// Whether a listening socket bound to this local address receives a
    /// TCP connection made to `127.0.0.1`.
    ///
    /// - Parameters:
    ///   - isIPv4: the socket is an IPv4 socket (`INI_IPV4`).
    ///   - ipv4Address: the IPv4 local address in host byte order.
    ///   - ipv6Address: the 16-byte IPv6 local address, used when not IPv4.
    static func reachesIPv4Loopback(isIPv4: Bool, ipv4Address: UInt32, ipv6Address: [UInt8]) -> Bool {
        if isIPv4 {
            return ipv4Address == 0 || ipv4Address >> 24 == 127
        }
        guard ipv6Address.count == 16 else { return false }
        // `::` — a dual-stack wildcard socket may take IPv4 connections.
        if ipv6Address.allSatisfy({ $0 == 0 }) { return true }
        // `::ffff:a.b.c.d` — a v4-mapped loopback or wildcard address.
        let isMapped = ipv6Address[0..<10].allSatisfy { $0 == 0 }
            && ipv6Address[10] == 0xff && ipv6Address[11] == 0xff
        guard isMapped else { return false }
        let mapped = ipv6Address[12...].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return mapped == 0 || mapped >> 24 == 127
    }

    /// The executable a process is running, if it can be read.
    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func allProcessIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        // Room for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let byteCount = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let count = proc_listallpids(&pids, byteCount)
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    private static func listensForIPv4Loopback(pid: pid_t, port: Int) -> Bool {
        let bufferBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferBytes > 0 else { return false }
        let fdCount = Int(bufferBytes) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCount)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufferBytes)
        guard filled > 0 else { return false }
        let filledCount = Int(filled) / MemoryLayout<proc_fdinfo>.stride
        for fd in fds.prefix(filledCount) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.stride)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { continue }
            guard info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            let socketInfo = tcp.tcpsi_ini
            let localPort = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: socketInfo.insi_lport)))
            guard localPort == port else { continue }
            var ipv6 = socketInfo.insi_laddr.ina_6
            let ipv6Bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            let reaches = reachesIPv4Loopback(
                isIPv4: socketInfo.insi_vflag & UInt8(INI_IPV4) != 0,
                ipv4Address: UInt32(bigEndian: socketInfo.insi_laddr.ina_46.i46a_addr4.s_addr),
                ipv6Address: ipv6Bytes
            )
            if reaches { return true }
        }
        return false
    }
}
