// AboutSocialMark.swift
// VocaMac
//
// Official Talk-to-us marks from VocaDesign. Source of truth:
// VocaHQ/.github brand/vocahq/social @ 61c8eee.
// Consume those files. Do not redraw path data. Do not replace them
// with SF Symbols.

import AppKit
import Foundation
import SwiftUI

/// Official Discord, X, GitHub, and mail marks for Settings About.
///
/// Files live in `Resources/social/` and are the exact SVG bytes from
/// VocaHQ/.github `brand/vocahq/social`. On disk, `fill` stays
/// `currentColor`. AppKit does not honor that, so drawing substitutes
/// black in memory, rasters a template image, and tints it Settings teal.
enum AboutSocialMark: String, CaseIterable, Identifiable {
    case github
    case discord
    case x
    case mail

    var id: String { rawValue }

    /// Visible button label. X is X, not Twitter.
    var visibleLabel: String {
        switch self {
        case .github: return "Report a bug or idea"
        case .discord: return "Discord"
        case .x: return "X"
        case .mail: return "Email"
        }
    }

    var url: URL {
        switch self {
        case .github:
            return URL(string: "https://github.com/VocaHQ/vocamac/issues")!
        case .discord:
            return URL(string: "https://discord.gg/UMJduhcqn")!
        case .x:
            return URL(string: "https://x.com/vocahq")!
        case .mail:
            return URL(string: "mailto:hello@vocahq.com")!
        }
    }

    /// SHA-256 of the exact VocaHQ/.github main (61c8eee) files.
    var expectedSHA256: String {
        switch self {
        case .discord:
            return "195092f3091352d662ceb1e9580877b03a943da0e1ec94a19f6aabac7dbf6dd7"
        case .github:
            return "1c1dd44a826db8b7d589cc48e9e8af2f395e960632c3ad978df8a00b2a56fc36"
        case .mail:
            return "32fd07b258990f4cba26476fb4f7b4649b9d5e0317000a8a183fa3fe29609972"
        case .x:
            return "0897f679c620010f09771464d39341d91f5a30a1370e126338b9a03bef47df34"
        }
    }

    /// Secondary Talk to us row, after the GitHub primary action.
    static var talkRowMarks: [AboutSocialMark] { [.discord, .x, .mail] }

    /// Exact bundled SVG bytes, or `nil` if the resource is missing.
    func svgData() -> Data? {
        guard let url = svgURL() else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Official `d` attribute from the bundled SVG. Exact path string.
    func officialPathData() -> String? {
        guard let text = String(data: svgData() ?? Data(), encoding: .utf8) else { return nil }
        guard let regex = try? NSRegularExpression(pattern: #"\bd="([^"]+)""#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    /// Template image so Settings teal can tint the official mark.
    ///
    /// Loads the official bytes, swaps `currentColor` to `#000000` in
    /// memory only, rasters that, and caches the result. If AppKit still
    /// returns an empty image, rasters the official path `d` instead.
    func templateImage() -> NSImage? {
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        if let cached = Self.imageCache[rawValue] {
            return cached
        }
        guard let official = svgData(),
              let svg = String(data: official, encoding: .utf8),
              let drawable = svg.replacingOccurrences(of: "currentColor", with: "#000000").data(using: .utf8)
        else {
            return nil
        }

        if let image = Self.rasterizedTemplate(fromSVG: drawable), Self.hasVisiblePixels(image) {
            image.isTemplate = true
            Self.imageCache[rawValue] = image
            return image
        }

        if let d = officialPathData(),
           let image = Self.rasterizedTemplate(fromPath: d),
           Self.hasVisiblePixels(image) {
            image.isTemplate = true
            Self.imageCache[rawValue] = image
            return image
        }

        return nil
    }

    private static let cacheLock = NSLock()
    private static var imageCache: [String: NSImage] = [:]
    private static let logicalSize = NSSize(width: 24, height: 24)
    private static let rasterScale: CGFloat = 2

    private func svgURL() -> URL? {
        let bundle = Bundle.module
        return bundle.url(forResource: rawValue, withExtension: "svg", subdirectory: "Resources/social")
            ?? bundle.url(forResource: rawValue, withExtension: "svg", subdirectory: "social")
            ?? bundle.url(forResource: rawValue, withExtension: "svg")
    }

    private static func rasterizedTemplate(fromSVG data: Data) -> NSImage? {
        guard let source = NSImage(data: data) else { return nil }
        source.size = logicalSize
        return rasterizedTemplate { rect in
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    private static func rasterizedTemplate(fromPath d: String) -> NSImage? {
        guard let cgPath = SVGPath.makeCGPath(from: d) else { return nil }
        return rasterizedTemplate { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.saveGState()
            // Official viewBox is 0 0 24 24, SVG y-down.
            ctx.translateBy(x: 0, y: rect.height)
            ctx.scaleBy(x: rect.width / logicalSize.width, y: -rect.height / logicalSize.height)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(cgPath)
            ctx.fillPath(using: .winding)
            ctx.restoreGState()
        }
    }

    private static func rasterizedTemplate(draw: (NSRect) -> Void) -> NSImage? {
        let pixels = NSSize(
            width: logicalSize.width * rasterScale,
            height: logicalSize.height * rasterScale
        )
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixels.width),
            pixelsHigh: Int(pixels.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = logicalSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        draw(NSRect(origin: .zero, size: logicalSize))
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: logicalSize)
        image.addRepresentation(bitmap)
        return image
    }

    private static func hasVisiblePixels(_ image: NSImage) -> Bool {
        guard image.size.width > 0, image.size.height > 0,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let bytes = rep.bitmapData else {
            return false
        }
        let samples = max(rep.samplesPerPixel, 1)
        let alphaIndex = samples - 1
        for row in 0..<rep.pixelsHigh {
            let rowStart = row * rep.bytesPerRow
            for column in 0..<rep.pixelsWide {
                let offset = rowStart + column * samples
                if bytes[offset + alphaIndex] > 0 {
                    return true
                }
            }
        }
        return false
    }
}

/// Official VocaDesign mark, drawn at 16pt in a text button.
///
/// Talk-to-us icons tint with Settings teal `#0F6B57` through template
/// rendering so they match About links. Pass `tint: nil` on a filled
/// control so the button label color wins. Do not bake `#0F6B57` into
/// the SVG files.
struct AboutSocialMarkImage: View {
    let mark: AboutSocialMark
    var size: CGFloat = 16
    var tint: Color? = BrandAssets.settingsTeal

    var body: some View {
        Group {
            if let tint {
                markImage.foregroundStyle(tint)
            } else {
                markImage
            }
        }
    }

    @ViewBuilder
    private var markImage: some View {
        if let image = mark.templateImage(), image.size.width > 0, image.size.height > 0 {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else if let d = mark.officialPathData() {
            OfficialSVGPathShape(d: d)
                .fill(tint ?? Color.primary)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            // Last resort only. templateImage() should already have drawn
            // the official path. Do not substitute an SF Symbol here.
            Color.clear
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

/// SwiftUI shape from an official SVG `d` string. Not a redraw.
struct OfficialSVGPathShape: Shape {
    let d: String

    func path(in rect: CGRect) -> Path {
        guard let cgPath = SVGPath.makeCGPath(from: d) else { return Path() }
        var path = Path(cgPath)
        let box = CGRect(x: 0, y: 0, width: 24, height: 24)
        let transform = CGAffineTransform(a: rect.width / box.width, b: 0, c: 0, d: rect.height / box.height, tx: rect.minX, ty: rect.minY)
        return path.applying(transform)
    }
}
