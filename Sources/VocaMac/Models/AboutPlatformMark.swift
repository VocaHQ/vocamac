// AboutPlatformMark.swift
// VocaMac
//
// Official platform marks used by the VocaHQ family links.

import AppKit
import Foundation
import SwiftUI

/// Official platform artwork from VocaHQ/.github.
enum AboutPlatformMark: String, CaseIterable, Identifiable {
    case apple
    case android
    case windows
    case linux

    var id: String { rawValue }

    /// SHA-256 of the bundled canonical VocaHQ platform SVG.
    var expectedSHA256: String {
        switch self {
        case .apple: return "aab854e12a2a1a639c90662705452313b06b22c670bcfeeb49975a065d792afc"
        case .android: return "1862ad78b96e213c0ebd7366bdc4164c7d96b77ccd144fa90297bfe659165cea"
        case .windows: return "a2e1f084391d7acdf89e7d6c0c9a87247aaa1d60bee30b35a30a5283a14df357"
        case .linux: return "7107327b049ef9192577392d15810fead852a664f48d7f7034fe46e9a09fa8ef"
        }
    }

    func svgData() -> Data? {
        guard let url = svgURL() else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Official path data from the bundled 24-point SVG.
    func officialPathData() -> String? {
        guard let text = String(data: svgData() ?? Data(), encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"\bd="([^"]+)""#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    func templateImage() -> NSImage? {
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        if let cached = Self.imageCache[rawValue] {
            return cached
        }
        guard let pathData = officialPathData(),
              let path = SVGPath.makeCGPath(from: pathData) else { return nil }
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.translateBy(x: 0, y: rect.height)
            context.scaleBy(x: rect.width / 24, y: -rect.height / 24)
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(path)
            context.fillPath(using: .winding)
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        Self.imageCache[rawValue] = image
        return image
    }

    private func svgURL() -> URL? {
        let bundle = Bundle.module
        return bundle.url(forResource: rawValue, withExtension: "svg", subdirectory: "Resources/platform")
            ?? bundle.url(forResource: rawValue, withExtension: "svg", subdirectory: "platform")
            ?? bundle.url(forResource: rawValue, withExtension: "svg")
    }

    private static let cacheLock = NSLock()
    private static var imageCache: [String: NSImage] = [:]
}

/// A VocaHQ product represented by its platform rather than a raw URL.
struct AboutFamilyProduct: Identifiable, Equatable {
    let title: String
    let platform: String
    let url: URL
    let marks: [AboutPlatformMark]
    let systemImage: String?

    var id: String { title }

    static let all: [AboutFamilyProduct] = [
        AboutFamilyProduct(
            title: "VocaLinux",
            platform: "Linux",
            url: URL(string: "https://vocalinux.com")!,
            marks: [.linux],
            systemImage: nil
        ),
        AboutFamilyProduct(
            title: "VocaMac",
            platform: "macOS",
            url: URL(string: "https://vocamac.com")!,
            marks: [.apple],
            systemImage: nil
        ),
        AboutFamilyProduct(
            title: "VocaWin",
            platform: "Windows",
            url: URL(string: "https://vocawin.com")!,
            marks: [.windows],
            systemImage: nil
        ),
        AboutFamilyProduct(
            title: "VocaPhone",
            platform: "iOS & Android",
            url: URL(string: "https://vocaphone.vocahq.com")!,
            marks: [.apple, .android],
            systemImage: nil
        ),
        AboutFamilyProduct(
            title: "VocaGateway",
            platform: "Self-hosted",
            url: URL(string: "https://vocagateway.vocahq.com")!,
            marks: [],
            systemImage: "server.rack"
        ),
    ]
}

/// Canonical organization and project links shown on the About screen.
enum AboutLinks {
    static let headquarters = URL(string: "https://vocahq.com")!
    static let contributors = URL(
        string: "https://github.com/VocaHQ/vocamac#:~:text=about%20GitHub%20Sponsors-,Contributors,-9"
    )!
}

/// A platform mark that follows the current macOS foreground style.
struct AboutPlatformMarkImage: View {
    let mark: AboutPlatformMark
    var size: CGFloat = 24

    var body: some View {
        if let image = mark.templateImage() {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}
