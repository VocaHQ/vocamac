// GatewayPairing.swift
// VocaMac
//
// Pure pairing helpers for VocaGateway: payload decode and loopback rejection.
// Foundation-only so unit tests cover the contract without process APIs.

import Foundation

/// Decoded phone-pairing document `{v,url,token}` from Gateway admin `payload`.
struct GatewayPairingPayload: Codable, Equatable {
    let v: Int
    let url: String
    let token: String

    enum CodingKeys: String, CodingKey {
        case v
        case url
        case token
    }

    var gatewayURL: URL? { URL(string: url) }

    /// Compact JSON string suitable for QR encoding (phones expect this shape).
    var qrPayloadString: String {
        let dict: [String: Any] = ["v": v, "url": url, "token": token]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"token":"\#(token)","url":"\#(url)","v":\#(v)}"#
        }
        return text
    }
}

enum GatewayPairingDecodeError: Error, Equatable, LocalizedError {
    case empty
    case invalidJSON
    case missingPayload
    case unsupportedVersion(Int?)
    case missingURL
    case missingToken
    case invalidURL(String)
    case loopbackURL(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Pairing payload is empty."
        case .invalidJSON:
            return "Pairing payload is not valid JSON."
        case .missingPayload:
            return "Admin pairing response is missing payload."
        case .unsupportedVersion(let version):
            return "Unsupported pairing version: \(version.map(String.init) ?? "missing")."
        case .missingURL:
            return "Pairing payload is missing a gateway URL."
        case .missingToken:
            return "Pairing payload is missing a bearer token."
        case .invalidURL(let raw):
            return "Pairing payload has an invalid gateway URL: \(raw)."
        case .loopbackURL(let raw):
            return "Pairing URL must not be localhost or 127.0.0.1 (got \(raw)). Set a LAN or Tailscale address."
        }
    }
}

/// Decodes `/v1/admin/pairing` admin JSON whose `payload` may be an object or a JSON string.
enum GatewayPairingDecoder {
    static let supportedVersion = 1

    /// Decode from an admin JSON object that exposes `payload` (object or string).
    static func decodeAdminJSON(
        _ json: [String: Any],
        rejectLoopback: Bool = true
    ) -> Result<GatewayPairingPayload, GatewayPairingDecodeError> {
        guard let rawPayload = json["payload"] else {
            return .failure(.missingPayload)
        }

        let object: [String: Any]
        if let asObject = rawPayload as? [String: Any] {
            object = asObject
        } else if let asString = rawPayload as? String {
            let trimmed = asString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure(.empty) }
            guard let data = trimmed.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.invalidJSON)
            }
            object = parsed
        } else if let data = try? JSONSerialization.data(withJSONObject: rawPayload),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = parsed
        } else {
            return .failure(.invalidJSON)
        }

        return decodePayloadObject(object, rejectLoopback: rejectLoopback)
    }

    /// Decode a raw payload JSON string `{v,url,token}`.
    static func decodePayloadString(
        _ raw: String,
        rejectLoopback: Bool = true
    ) -> Result<GatewayPairingPayload, GatewayPairingDecodeError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.invalidJSON)
        }
        return decodePayloadObject(object, rejectLoopback: rejectLoopback)
    }

    static func decodePayloadObject(
        _ object: [String: Any],
        rejectLoopback: Bool = true
    ) -> Result<GatewayPairingPayload, GatewayPairingDecodeError> {
        let versionValue = object["v"] ?? object["version"]
        let version: Int?
        if let intValue = versionValue as? Int {
            version = intValue
        } else if let number = versionValue as? NSNumber {
            version = number.intValue
        } else {
            version = nil
        }
        guard version == supportedVersion else {
            return .failure(.unsupportedVersion(version))
        }

        guard let urlString = (object["url"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !urlString.isEmpty else {
            return .failure(.missingURL)
        }
        guard let token = (object["token"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return .failure(.missingToken)
        }
        guard let url = URL(string: urlString), url.scheme != nil, url.host != nil else {
            return .failure(.invalidURL(urlString))
        }

        if rejectLoopback, GatewayPairingURL.isLoopback(url) {
            return .failure(.loopbackURL(urlString))
        }

        return .success(GatewayPairingPayload(v: supportedVersion, url: urlString, token: token))
    }
}

/// Loopback / pairability checks for Gateway URLs used in phone QR codes.
enum GatewayPairingURL {
    /// True when the URL host is loopback and must not appear in a phone QR.
    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" {
            return true
        }
        if host.hasPrefix("127.") { return true }
        return false
    }

    static func isLoopback(_ raw: String) -> Bool {
        guard let url = URL(string: raw) else { return false }
        return isLoopback(url)
    }

    /// True when a URL is usable for pairing QR (has scheme+host and is not loopback).
    static func isPairableURL(_ url: URL) -> Bool {
        guard url.scheme != nil, url.host != nil else { return false }
        return !isLoopback(url)
    }

    static func isPairableURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw), url.scheme != nil, url.host != nil else { return false }
        return isPairableURL(url)
    }

    /// Normalize a user-supplied public URL override for pairing.
    static func validatedPublicURL(_ raw: String) -> Result<URL, GatewayPairingDecodeError> {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.missingURL) }
        if !trimmed.contains("://") {
            trimmed = "http://\(trimmed)"
        }
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            return .failure(.invalidURL(trimmed))
        }
        if isLoopback(url) {
            return .failure(.loopbackURL(trimmed))
        }
        return .success(url)
    }
}
