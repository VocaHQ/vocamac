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

    func testOnlyListenersReachableAtIPv4LoopbackCount() {
        let loopback: UInt32 = 0x7F00_0001
        XCTAssertTrue(LocalPortOwner.reachesIPv4Loopback(isIPv4: true, ipv4Address: loopback, ipv6Address: []))
        XCTAssertTrue(LocalPortOwner.reachesIPv4Loopback(isIPv4: true, ipv4Address: 0, ipv6Address: []))
        XCTAssertFalse(LocalPortOwner.reachesIPv4Loopback(isIPv4: true, ipv4Address: 0xC0A8_0105, ipv6Address: []))

        let any = [UInt8](repeating: 0, count: 16)
        var ipv6Loopback = any
        ipv6Loopback[15] = 1
        var mappedLoopback = any
        mappedLoopback[10] = 0xff
        mappedLoopback[11] = 0xff
        mappedLoopback[12] = 127
        mappedLoopback[15] = 1
        var mappedLAN = mappedLoopback
        mappedLAN[12] = 192
        XCTAssertTrue(LocalPortOwner.reachesIPv4Loopback(isIPv4: false, ipv4Address: 0, ipv6Address: any))
        XCTAssertTrue(LocalPortOwner.reachesIPv4Loopback(isIPv4: false, ipv4Address: 0, ipv6Address: mappedLoopback))
        XCTAssertFalse(LocalPortOwner.reachesIPv4Loopback(isIPv4: false, ipv4Address: 0, ipv6Address: ipv6Loopback))
        XCTAssertFalse(LocalPortOwner.reachesIPv4Loopback(isIPv4: false, ipv4Address: 0, ipv6Address: mappedLAN))
    }

    func testAmbiguousOwnershipIsNotTrusted() {
        XCTAssertNil(LocalPortOwner.soleOwner([]))
        XCTAssertEqual(LocalPortOwner.soleOwner([42, 42]), 42)
        XCTAssertNil(LocalPortOwner.soleOwner([42, 43]))
    }

    func testIgnoresAListenerOnlyOnIPv6Loopback() throws {
        let socket = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(socket, 0)
        defer { close(socket) }
        var yes: Int32 = 1
        setsockopt(socket, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in6()
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_addr = in6addr_loopback
        address.sin6_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(socket, 1), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(socket, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: address.sin6_port))

        // A connection to 127.0.0.1 can't reach this socket, so it must not
        // vouch for whoever holds 127.0.0.1 on the same port.
        XCTAssertNil(LocalPortOwner.listeningProcessID(port: port))
    }
}
