import XCTest
@testable import VocaMac

final class GatewayBinaryResolverTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("gateway-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func makeExecutable(named name: String) throws -> String {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try Data().write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testResolvesExecutableFromPATH() throws {
        let path = try makeExecutable(named: "vocagateway")

        XCTAssertEqual(
            GatewayBinaryResolver.resolveExecutablePath(
                pathEnvironment: directory.path,
                commonCandidates: []
            ),
            path
        )
    }

    func testPrefersPATHOverCommonInstallLocations() throws {
        let pathBinary = try makeExecutable(named: "vocagateway")
        let candidate = try makeExecutable(named: "injected-vocagateway")

        let resolved = GatewayBinaryResolver.resolveExecutablePath(
            pathEnvironment: directory.path,
            commonCandidates: [candidate]
        )

        XCTAssertEqual(resolved, pathBinary)
    }

    func testFallsBackToInjectedCommonCandidate() throws {
        let candidate = try makeExecutable(named: "injected-vocagateway")

        let resolved = GatewayBinaryResolver.resolveExecutablePath(
            pathEnvironment: directory.path,
            commonCandidates: [candidate]
        )

        XCTAssertEqual(resolved, candidate)
    }

    func testReturnsNilWhenPATHAndCommonCandidatesMiss() throws {
        _ = try makeExecutable(named: "something-else")

        let resolved = GatewayBinaryResolver.resolveExecutablePath(
            pathEnvironment: directory.path,
            commonCandidates: []
        )

        XCTAssertNil(resolved)
    }

    func testIgnoresNonExecutableFileOnPATH() throws {
        let url = directory.appendingPathComponent("vocagateway", isDirectory: false)
        try Data().write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        let resolved = GatewayBinaryResolver.resolveExecutablePath(
            pathEnvironment: directory.path,
            commonCandidates: []
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
}
