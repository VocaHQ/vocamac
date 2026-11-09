import XCTest
@testable import VocaMac

final class GatewayBinaryResolverTests: XCTestCase {
    private var directory: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("gateway-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    private func makeExecutable(named name: String) throws -> String {
        let directory = try XCTUnwrap(directory)
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try Data().write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testResolvesExecutableFromPATH() throws {
        let path = try makeExecutable(named: "vocagateway")

        XCTAssertEqual(
            GatewayBinaryResolver.resolveExecutablePath(
                pathEnvironment: try XCTUnwrap(directory).path,
                preferredCandidates: [],
                userCandidates: []
            ),
            path
        )
    }

    func testPrefersFixedHomebrewLocationOverPATH() throws {
        _ = try makeExecutable(named: "vocagateway")
        let homebrew = try makeExecutable(named: "homebrew-vocagateway")

        let resolved = GatewayBinaryResolver.resolveExecutablePath(
            pathEnvironment: try XCTUnwrap(directory).path,
            preferredCandidates: [homebrew],
            userCandidates: []
        )

        XCTAssertEqual(resolved, homebrew)
    }

    func testPrefersPATHOverUserInstallLocations() throws {
        let pathBinary = try makeExecutable(named: "vocagateway")
        let userBinary = try makeExecutable(named: "user-vocagateway")

        let resolved = GatewayBinaryResolver.resolveExecutablePath(
            pathEnvironment: try XCTUnwrap(directory).path,
            preferredCandidates: [],
            userCandidates: [userBinary]
        )

        XCTAssertEqual(resolved, pathBinary)
    }

    func testFallsBackToUserInstallLocation() throws {
        let candidate = try makeExecutable(named: "injected-vocagateway")

        let resolved = GatewayBinaryResolver.resolveExecutablePath(
            pathEnvironment: try XCTUnwrap(directory).path,
            preferredCandidates: [],
            userCandidates: [candidate]
        )

        XCTAssertEqual(resolved, candidate)
    }

    func testReturnsNilWhenPATHAndCommonCandidatesMiss() throws {
        _ = try makeExecutable(named: "something-else")

        let resolved = GatewayBinaryResolver.resolveExecutablePath(
            pathEnvironment: try XCTUnwrap(directory).path,
            preferredCandidates: [],
            userCandidates: []
        )

        XCTAssertNil(resolved)
    }

    func testIgnoresNonExecutableFileOnPATH() throws {
        let url = try XCTUnwrap(directory).appendingPathComponent("vocagateway", isDirectory: false)
        try Data().write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        let resolved = GatewayBinaryResolver.resolveExecutablePath(
            pathEnvironment: try XCTUnwrap(directory).path,
            preferredCandidates: [],
            userCandidates: []
        )

        XCTAssertNotEqual(resolved, url.path)
    }

    func testResolveExecutablePathDoesNotSpawnWhichViaBin() throws {
        let sourceURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/VocaMac/Services/GatewayEmbedController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("whichViaBin"))

        let marker = "static func resolveExecutablePath("
        guard let start = source.range(of: marker) else {
            return XCTFail("resolveExecutablePath not found in \(sourceURL.path)")
        }
        let fromStart = source[start.lowerBound...]
        let sectionEnd = fromStart.dropFirst(marker.count).range(of: "static func ")?.lowerBound
            ?? fromStart.endIndex
        let section = String(fromStart[..<sectionEnd])
        XCTAssertFalse(section.contains("waitUntilExit"))
    }

    // MARK: Listener trust

    func testTrustsTheResolvedGatewayAndDocker() {
        XCTAssertTrue(GatewayListenerTrust.isTrusted(
            executablePath: "/opt/homebrew/bin/vocagateway", resolvedBinaryPath: nil
        ))
        XCTAssertTrue(GatewayListenerTrust.isTrusted(
            executablePath: "/some/where/vocagateway", resolvedBinaryPath: "/some/where/vocagateway"
        ))
        XCTAssertTrue(GatewayListenerTrust.isTrusted(
            executablePath: "/Applications/Docker.app/Contents/MacOS/com.docker.backend", resolvedBinaryPath: nil
        ))
    }

    func testDoesNotTrustAnotherProgramOnThePort() {
        XCTAssertFalse(GatewayListenerTrust.isTrusted(
            executablePath: "/Applications/Squatter.app/Contents/MacOS/Squatter",
            resolvedBinaryPath: "/opt/homebrew/bin/vocagateway"
        ))
        XCTAssertFalse(GatewayListenerTrust.isTrusted(
            executablePath: "/tmp/vocagateway", resolvedBinaryPath: "/opt/homebrew/bin/vocagateway"
        ))
    }

    func testFindsTheProcessListeningOnAPort() throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(socket, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(socket, 1), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(socket, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))

        XCTAssertEqual(LocalPortOwner.listeningProcessID(port: port), getpid())
        XCTAssertNotNil(LocalPortOwner.executablePath(of: getpid()))
    }
}
