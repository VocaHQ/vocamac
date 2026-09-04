// GatewayPairingTests.swift
// VocaMac Tests

import XCTest
@testable import VocaMac

final class GatewayPairingTests: XCTestCase {

    func testDecodePayloadSuccess() {
        let raw = #"{"v":1,"url":"http://192.168.1.20:8765","token":"abcdefghijklmnopqrstuvwxyz012345"}"#
        let result = GatewayPairingDecoder.decodePayloadString(raw)
        switch result {
        case .success(let payload):
            XCTAssertEqual(payload.v, 1)
            XCTAssertEqual(payload.url, "http://192.168.1.20:8765")
            XCTAssertEqual(payload.token, "abcdefghijklmnopqrstuvwxyz012345")
        case .failure(let error):
            XCTFail("Unexpected failure: \(error)")
        }
    }

    func testDecodePayloadRejectsLoopbackLocalhost() {
        let raw = #"{"v":1,"url":"http://localhost:8765","token":"abcdefghijklmnopqrstuvwxyz012345"}"#
        let result = GatewayPairingDecoder.decodePayloadString(raw, rejectLoopback: true)
        guard case .failure(.loopbackURL) = result else {
            return XCTFail("Expected loopback rejection, got \(result)")
        }
    }

    func testDecodePayloadRejectsLoopback127() {
        let raw = #"{"v":1,"url":"http://127.0.0.1:8765","token":"abcdefghijklmnopqrstuvwxyz012345"}"#
        let result = GatewayPairingDecoder.decodePayloadString(raw, rejectLoopback: true)
        guard case .failure(.loopbackURL) = result else {
            return XCTFail("Expected loopback rejection, got \(result)")
        }
    }

    func testDecodePayloadRejectsLoopbackIPv6() {
        let raw = #"{"v":1,"url":"http://[::1]:8765","token":"abcdefghijklmnopqrstuvwxyz012345"}"#
        let result = GatewayPairingDecoder.decodePayloadString(raw, rejectLoopback: true)
        guard case .failure(.loopbackURL) = result else {
            return XCTFail("Expected ::1 loopback rejection, got \(result)")
        }
    }

    func testDecodePayloadAllowsLoopbackWhenNotRejected() {
        let raw = #"{"v":1,"url":"http://127.0.0.1:8765","token":"abcdefghijklmnopqrstuvwxyz012345"}"#
        let result = GatewayPairingDecoder.decodePayloadString(raw, rejectLoopback: false)
        guard case .success(let payload) = result else {
            return XCTFail("Expected success when loopback allowed, got \(result)")
        }
        XCTAssertTrue(GatewayPairingURL.isLoopback(payload.url))
        XCTAssertFalse(GatewayPairingURL.isPairableURL(payload.url))
    }

    func testDecodeAdminResponsePayloadAsString() {
        let payload = #"{"v":1,"url":"http://10.0.0.5:8765","token":"only-inside-payload-token-value-32"}"#
        let admin: [String: Any] = [
            "version": 1,
            "url": "http://10.0.0.5:8765",
            "payload": payload,
            "candidates": ["http://10.0.0.5:8765"],
        ]
        let result = GatewayPairingDecoder.decodeAdminJSON(admin)
        switch result {
        case .success(let decoded):
            XCTAssertEqual(decoded.token, "only-inside-payload-token-value-32")
            XCTAssertEqual(decoded.url, "http://10.0.0.5:8765")
        case .failure(let error):
            XCTFail("Unexpected failure: \(error)")
        }
    }

    func testDecodeAdminResponsePayloadAsObject() {
        let admin: [String: Any] = [
            "payload": [
                "v": 1,
                "url": "http://10.0.0.8:8765",
                "token": "object-payload-token-abcdefghijkl",
            ] as [String: Any],
        ]
        let result = GatewayPairingDecoder.decodeAdminJSON(admin)
        switch result {
        case .success(let decoded):
            XCTAssertEqual(decoded.v, 1)
            XCTAssertEqual(decoded.url, "http://10.0.0.8:8765")
            XCTAssertEqual(decoded.token, "object-payload-token-abcdefghijkl")
            XCTAssertTrue(GatewayPairingURL.isPairableURL(decoded.url))
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
        let result = GatewayPairingDecoder.decodeAdminJSON(admin)
        guard case .failure(.missingPayload) = result else {
            return XCTFail("Expected missingPayload when payload is absent, got \(result)")
        }
    }

    func testValidatedPublicURLRejectsLoopback() {
        let result = GatewayPairingURL.validatedPublicURL("http://127.0.0.1:8765")
        guard case .failure(.loopbackURL) = result else {
            return XCTFail("Expected loopback rejection")
        }
    }

    func testValidatedPublicURLAcceptsLAN() {
        let result = GatewayPairingURL.validatedPublicURL("192.168.1.50:8765")
        guard case .success(let url) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(url.host, "192.168.1.50")
        XCTAssertEqual(url.port, 8765)
    }

    func testIsLoopbackDetectsVariants() {
        XCTAssertTrue(GatewayPairingURL.isLoopback(URL(string: "http://localhost:8765")!))
        XCTAssertTrue(GatewayPairingURL.isLoopback(URL(string: "http://127.0.0.1:8765")!))
        XCTAssertTrue(GatewayPairingURL.isLoopback(URL(string: "http://127.1.2.3:8765")!))
        XCTAssertTrue(GatewayPairingURL.isLoopback(URL(string: "http://[::1]:8765")!))
        XCTAssertFalse(GatewayPairingURL.isLoopback(URL(string: "http://192.168.0.10:8765")!))
        XCTAssertFalse(GatewayPairingURL.isLoopback(URL(string: "https://gateway.tailnet.ts.net")!))
        XCTAssertTrue(GatewayPairingURL.isPairableURL("http://192.168.0.10:8765"))
        XCTAssertFalse(GatewayPairingURL.isPairableURL("http://127.0.0.1:8765"))
    }

    func testCodableRoundTrip() throws {
        let payload = GatewayPairingPayload(
            v: 1,
            url: "http://192.168.1.20:8765",
            token: "abcdefghijklmnopqrstuvwxyz012345"
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(GatewayPairingPayload.self, from: data)
        XCTAssertEqual(decoded, payload)
        XCTAssertTrue(decoded.qrPayloadString.contains("192.168.1.20"))
        XCTAssertTrue(decoded.qrPayloadString.contains("token"))
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
