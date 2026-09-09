// generate-dmg-background.swift
// VocaMac
//
// Renders Sources/VocaMac/Resources/dmg-background.png and @2x.
// Run with: swift scripts/generate-dmg-background.swift
//
// Geometry contract — keep these in sync with scripts/dist.sh and
// Tests/VocaMacTests/DMGBackgroundTests.swift:
//
//   * The Finder window is 660 × 520 points (`set the bounds … {200, 60, 860, 580}`).
//     The title bar eats ~31 of those points, so only the TOP 489 POINTS of this
//     artwork are ever on screen. Everything below `visibleHeight` is padding.
//   * Finder converts pixels to points using PNG density, so both files are
//     stamped at 144 DPI: 1320 × 1040 px (2×) and 2640 × 2080 px (4×).
//   * Finder draws the two icons itself, at 120 pt, centred on (170, 250) and
//     (490, 250) in top-left origin coordinates. Their name labels sit just
//     below, around y 316–336. The artwork must leave that band clear.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Contract

let canvasSize = CGSize(width: 660, height: 520)
/// Height actually visible inside the Finder window, once the title bar is removed.
let visibleHeight: CGFloat = 489

/// Finder-drawn icon geometry, mirrored from the AppleScript in dist.sh.
let appIconCentre = CGPoint(x: 170, y: 250)
let applicationsCentre = CGPoint(x: 490, y: 250)
let finderIconSize: CGFloat = 120
/// Bottom of the icon name labels Finder paints under each icon.
let iconLabelBottom: CGFloat = 338

// MARK: - Palette

/// Brand green `#0F6B57`, matching `BrandAssets.brandGreen`.
let brandGreen = NSColor(red: 0.059, green: 0.420, blue: 0.341, alpha: 1)
let inkPrimary = NSColor(red: 0.106, green: 0.106, blue: 0.118, alpha: 1)
let inkSecondary = NSColor(red: 0.400, green: 0.404, blue: 0.420, alpha: 1)
let inkTertiary = NSColor(red: 0.541, green: 0.545, blue: 0.565, alpha: 1)
let canvasGround = NSColor(red: 0.965, green: 0.973, blue: 0.969, alpha: 1)
let cardFill = NSColor.white.withAlphaComponent(0.72)
let cardStroke = NSColor.black.withAlphaComponent(0.07)

// MARK: - Drawing helpers

func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    NSFont.systemFont(ofSize: size, weight: weight)
}

/// Draws `text` centred on `centreX`, with `y` measured from the TOP of the canvas
/// to the text's cap line. Returns the height consumed.
@discardableResult
func drawCentred(
    _ text: String,
    font textFont: NSFont,
    color: NSColor,
    centreX: CGFloat,
    top y: CGFloat,
    tracking: CGFloat = 0
) -> CGFloat {
    var attributes: [NSAttributedString.Key: Any] = [.font: textFont, .foregroundColor: color]
    if tracking != 0 { attributes[.kern] = tracking }
    let string = NSAttributedString(string: text, attributes: attributes)
    let size = string.size()
    // Canvas is flipped by the caller, so `y` is already a top-down coordinate.
    string.draw(at: NSPoint(x: centreX - size.width / 2, y: y))
    return size.height
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

/// The drag arrow: a shallow arc from the app icon to the Applications folder,
/// in brand green so the one action the window asks for is the one coloured thing.
func drawDragArrow(in context: CGContext) {
    let startX = appIconCentre.x + finderIconSize / 2 + 22
    let endX = applicationsCentre.x - finderIconSize / 2 - 26
    let baseY = appIconCentre.y
    let lift: CGFloat = 26

    let path = CGMutablePath()
    path.move(to: CGPoint(x: startX, y: baseY))
    path.addCurve(
        to: CGPoint(x: endX, y: baseY),
        control1: CGPoint(x: startX + (endX - startX) * 0.3, y: baseY - lift),
        control2: CGPoint(x: startX + (endX - startX) * 0.7, y: baseY - lift)
    )

    context.saveGState()
    context.setStrokeColor(brandGreen.withAlphaComponent(0.55).cgColor)
    context.setLineWidth(3)
    context.setLineCap(.round)
    context.setLineDash(phase: 0, lengths: [1, 9])
    context.addPath(path)
    context.strokePath()
    context.setLineDash(phase: 0, lengths: [])

    // Solid head so the direction reads at a glance.
    let head = CGMutablePath()
    head.move(to: CGPoint(x: endX + 12, y: baseY))
    head.addLine(to: CGPoint(x: endX - 5, y: baseY - 8))
    head.addLine(to: CGPoint(x: endX - 1, y: baseY))
    head.addLine(to: CGPoint(x: endX - 5, y: baseY + 8))
    head.closeSubpath()
    context.setFillColor(brandGreen.withAlphaComponent(0.8).cgColor)
    context.addPath(head)
    context.fillPath()
    context.restoreGState()
}

/// A capsule chip naming one permission the app asks for after install.
func drawChip(_ text: String, centre: CGPoint, in context: CGContext) -> CGFloat {
    let chipFont = font(11, .medium)
    let string = NSAttributedString(
        string: text,
        attributes: [.font: chipFont, .foregroundColor: brandGreen]
    )
    let textSize = string.size()
    let width = textSize.width + 22
    let height: CGFloat = 22
    let rect = CGRect(x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height)

    context.saveGState()
    context.setFillColor(brandGreen.withAlphaComponent(0.10).cgColor)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
    context.fillPath()
    context.restoreGState()

    string.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
    return width
}

func chipWidth(_ text: String) -> CGFloat {
    NSAttributedString(string: text, attributes: [.font: font(11, .medium)]).size().width + 22
}

// MARK: - Composition

func render(scale: CGFloat) -> CGImage? {
    let pixelWidth = Int(canvasSize.width * scale)
    let pixelHeight = Int(canvasSize.height * scale)

    guard let context = CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        // The installer background is fully opaque; dropping the alpha channel
        // keeps the committed PNGs meaningfully smaller.
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }

    // Flip to a top-left origin so every coordinate in this file matches the
    // Finder coordinates in dist.sh.
    context.translateBy(x: 0, y: CGFloat(pixelHeight))
    context.scaleBy(x: scale, y: -scale)

    let graphics = NSGraphicsContext(cgContext: context, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics

    let centreX = canvasSize.width / 2

    // ── Ground ───────────────────────────────────────────────────────────────
    // Flat, not a full-canvas gradient: continuous tone over 2640 x 2080 px
    // triples the size of the committed PNG for a difference nobody sees.
    context.setFillColor(canvasGround.cgColor)
    context.fill(CGRect(origin: .zero, size: canvasSize))

    // A single soft brand wash behind the headline, so the window reads as
    // VocaMac rather than as a generic grey installer.
    if let glow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            brandGreen.withAlphaComponent(0.10).cgColor,
            brandGreen.withAlphaComponent(0).cgColor
        ] as CFArray,
        locations: [0, 1]
    ) {
        context.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: centreX, y: 20), startRadius: 0,
            endCenter: CGPoint(x: centreX, y: 20), endRadius: 330,
            options: []
        )
    }

    // ── Header ───────────────────────────────────────────────────────────────
    drawCentred("VocaMac", font: font(34, .bold), color: inkPrimary, centreX: centreX, top: 34)
    drawCentred(
        "Private, on-device voice-to-text for macOS",
        font: font(13.5, .regular), color: inkSecondary, centreX: centreX, top: 78
    )

    // ── Install card ─────────────────────────────────────────────────────────
    // Wraps the drag target so the two Finder icons read as one action rather
    // than as two loose objects on an empty field.
    let card = CGRect(x: 34, y: 116, width: canvasSize.width - 68, height: 250)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -2), blur: 12,
                      color: NSColor.black.withAlphaComponent(0.07).cgColor)
    context.setFillColor(cardFill.cgColor)
    context.addPath(CGPath(roundedRect: card, cornerWidth: 22, cornerHeight: 22, transform: nil))
    context.fillPath()
    context.restoreGState()

    context.setStrokeColor(cardStroke.cgColor)
    context.setLineWidth(1)
    context.addPath(CGPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5),
                           cornerWidth: 22, cornerHeight: 22, transform: nil))
    context.strokePath()

    drawCentred(
        "DRAG VOCAMAC TO APPLICATIONS",
        font: font(11, .semibold), color: brandGreen, centreX: centreX, top: 140, tracking: 1.4
    )

    drawDragArrow(in: context)

    // ── Footer ───────────────────────────────────────────────────────────────
    // Naming the three permissions as chips is easier to scan than the single
    // long sentence this replaced, and it survives being read at a glance.
    drawCentred(
        "After first launch, VocaMac asks for",
        font: font(11.5, .regular), color: inkTertiary, centreX: centreX, top: 388
    )

    let chips = ["Microphone", "Accessibility", "Input Monitoring"]
    let gap: CGFloat = 8
    let totalWidth = chips.map(chipWidth).reduce(0, +) + gap * CGFloat(chips.count - 1)
    var cursor = centreX - totalWidth / 2
    for chip in chips {
        let width = chipWidth(chip)
        _ = drawChip(chip, centre: CGPoint(x: cursor + width / 2, y: 424), in: context)
        cursor += width + gap
    }

    drawCentred(
        "vocamac.com",
        font: font(12, .semibold), color: inkSecondary, centreX: centreX, top: 456
    )

    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()
}

// MARK: - Output

func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "dmg", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot create \(url.path)"])
    }
    // Finder sizes the background from PNG density, so both files claim 144 DPI
    // and differ only in pixel count. DMGBackgroundTests asserts this.
    let properties: [CFString: Any] = [
        kCGImagePropertyDPIWidth: 144,
        kCGImagePropertyDPIHeight: 144
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "dmg", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot write \(url.path)"])
    }
}

let resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Sources/VocaMac/Resources")

guard FileManager.default.fileExists(atPath: resources.path) else {
    FileHandle.standardError.write(
        Data("Run from the repository root: swift scripts/generate-dmg-background.swift\n".utf8)
    )
    exit(1)
}

for (scale, name) in [(CGFloat(2), "dmg-background.png"), (CGFloat(4), "dmg-background@2x.png")] {
    guard let image = render(scale: scale) else {
        FileHandle.standardError.write(Data("Failed to render \(name)\n".utf8))
        exit(1)
    }
    let url = resources.appendingPathComponent(name)
    try write(image, to: url)
    print("✓ \(name) — \(image.width)×\(image.height) px at 144 DPI")
}

print("Visible area is the top \(Int(visibleHeight)) pt; icon labels end near y \(Int(iconLabelBottom)).")
