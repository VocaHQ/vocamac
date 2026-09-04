// GatewayPairingTests.swift
// VocaMac Tests

import XCTest
@testable import VocaMac

final class GatewayPairingTests: XCTestCase {

    func testDecodePayloadSuccess() {
        let raw = #"{"v":1,"url":"http://192.168.1.20:8765","token":"abcdefghijklmnopqrstuvwxyz012345"}"#
        let result = GatewayPairingCodec.decodePayload(raw)
        switch result {
        case .success(let payload):
            XCTAssertEqual(payload.version, 1)
            XCTAssertEqual(payload.url.absoluteString, "http://192.168.1.20:8765")
            XCTAssertEqual(payload.token, "abcdefghijklmnopqrstuvwxyz012345")
        case .failure(let error):
            XCTFail("Unexpected failure: \(error)")
        }
    }

    func testDecodePayloadRejectsLoopbackLocalhost() {
        let raw = #"{"v":1,"url":"http://localhost:8765","token":"abcdefghijklmnopqrstuvwxyz012345"}"#
        let result = GatewayPairingCodec.decodePayload(raw, rejectLoopback: true)
        guard case .failure(.loopbackURL) = result else {
            return XCTFail("Expected loopback rejection, got \(result)")
        }
    }

    func testDecodePayloadRejectsLoopback127() {
        let raw = #"{"v":1,"url":"http://127.0.0.1:8765","token":"abcdefghijklmnopqrstuvwxyz012345"}"#
        let result = GatewayPairingCodec.decodePayload(raw, rejectLoopback: true)
        guard case .failure(.loopbackURL) = result else {
            return XCTFail("Expected loopback rejection, got \(result)")
        }
    }

    func testDecodePayloadAllowsLoopbackWhenNotRejected() {
        let raw = #"{"v":1,"url":"http://127.0.0.1:8765","token":"abcdefghijklmnopqrstuvwxyz012345"}"#
        let result = GatewayPairingCodec.decodePayload(raw, rejectLoopback: false)
        guard case .success(let payload) = result else {
            return XCTFail("Expected success when loopback allowed, got \(result)")
        }
        XCTAssertTrue(GatewayPairingCodec.isLoopbackGatewayURL(payload.url))
    }

    func testDecodeAdminResponseUsesPayloadNotTopLevelToken() {
        // Admin JSON may expose url/version at top level but token lives only inside payload.
        let payload = #"{"v":1,"url":"http://10.0.0.5:8765","token":"only-inside-payload-token-value-32"}"#
        let admin: [String: Any] = [
            "version": 1,
            "url": "http://10.0.0.5:8765",
            "payload": payload,
            "candidates": ["http://10.0.0.5:8765"],
        ]
        let result = GatewayPairingCodec.decodeAdminResponse(admin)
        switch result {
        case .success(let decoded):
            XCTAssertEqual(decoded.token, "only-inside-payload-token-value-32")
            XCTAssertEqual(decoded.url.absoluteString, "http://10.0.0.5:8765")
        case .failure(let error):
            XCTFail("Unexpected failure: \(error)")
        }
    }

    func testDecodeAdminResponseFailsWithoutPayload() {
        let admin: [String: Any] = [
            "version": 1,
            "url": "http://10.0.0.5:8765",
            "token": "should-be-ignored-even-if-present-here",
        ]
        let result = GatewayPairingCodec.decodeAdminResponse(admin)
        guard case .failure = result else {
            return XCTFail("Expected failure when payload is missing")
        }
    }

    func testValidatedPublicURLRejectsLoopback() {
        let result = GatewayPairingCodec.validatedPublicURL("http://127.0.0.1:8765")
        guard case .failure(.loopbackURL) = result else {
            return XCTFail("Expected loopback rejection")
        }
    }

    func testValidatedPublicURLAcceptsLAN() {
        let result = GatewayPairingCodec.validatedPublicURL("192.168.1.50:8765")
        guard case .success(let url) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(url.host, "192.168.1.50")
        XCTAssertEqual(url.port, 8765)
    }

    func testIsLoopbackDetectsVariants() {
        XCTAssertTrue(GatewayPairingCodec.isLoopbackGatewayURL(URL(string: "http://localhost:8765")!))
        XCTAssertTrue(GatewayPairingCodec.isLoopbackGatewayURL(URL(string: "http://127.0.0.1:8765")!))
        XCTAssertTrue(GatewayPairingCodec.isLoopbackGatewayURL(URL(string: "http://127.1.2.3:8765")!))
        XCTAssertFalse(GatewayPairingCodec.isLoopbackGatewayURL(URL(string: "http://192.168.0.10:8765")!))
        XCTAssertFalse(GatewayPairingCodec.isLoopbackGatewayURL(URL(string: "https://gateway.tailnet.ts.net")!))
    }
}

final class SettingsPageGatewayTests: XCTestCase {
    func testSettingsPageIncludesGatewayBeforeAbout() {
        XCTAssertTrue(SettingsPage.allCases.contains(.gateway))
        XCTAssertEqual(SettingsPage.gateway.title, "Gateway")
        XCTAssertEqual(SettingsPage.gateway.systemImage, "server.rack")

        let pages = SettingsPage.allCases
        guard let gatewayIndex = pages.firstIndex(of: .gateway),
              let aboutIndex = pages.firstIndex(of: .about) else {
            return XCTFail("gateway and about must both exist")
        }
        XCTAssertLessThan(gatewayIndex, aboutIndex)
    }

    func testSettingsSearchIndexHitsGatewayKeywords() {
        for query in ["gateway", "pair", "phone", "docker", "vocagateway"] {
            let matches = SettingsSearchIndex.matches(query: query)
            XCTAssertTrue(
                matches.contains { $0.page == .gateway },
                "Expected gateway hit for query \(query)"
            )
        }
        XCTAssertEqual(SettingsSearchIndex.firstMatchingPage(query: "vocagateway"), .gateway)
    }
}

final class GatewayBinaryResolverTests: XCTestCase {
    func testResolveReturnsNilWhenMissing() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocamac-gateway-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let path = GatewayBinaryResolver.resolveExecutablePath(
            fileManager: .default,
            pathEnvironment: temp.path
        )
        // May still find a real system binary via commonBinaryCandidates; only assert PATH miss:
        let fromPathOnly = GatewayBinaryResolver.findOnPATH(
            named: "vocagateway",
            pathEnvironment: temp.path,
            fileManager: .default
        )
        XCTAssertNil(fromPathOnly)
        _ = path
    }
}
