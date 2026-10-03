// VocaPaper.swift
// VocaMac
//
// The paper itself: a fine grain over the canvas and the scenery, and the
// paper-waveform mark that stands for VocaMac in the menu bar and headers.

import AppKit
import SwiftUI

// MARK: - Grain

/// A tile of fine, fixed noise. Laid over a surface at low opacity it reads as
/// the tooth of paper rather than a flat fill. Built once; tiling it costs no
/// more than an image fill.
enum PaperGrain {
    static let tile: NSImage = {
        let side = 128
        var generator = SplitMix64(seed: 0x5EED_CAFE)
        var pixels = [UInt8](repeating: 0, count: side * side)
        for index in pixels.indices {
            pixels[index] = UInt8(truncatingIfNeeded: generator.next() >> 56)
        }
        let image = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return nil }
            return context.makeImage()
        }
        guard let image else { return NSImage(size: NSSize(width: side, height: side)) }
        // Half-size points: two pixels of noise per point on Retina reads as
        // grain, one point per pixel reads as static.
        return NSImage(cgImage: image, size: NSSize(width: side / 2, height: side / 2))
    }()

    /// A deterministic generator, so the grain is identical on every launch.
    private struct SplitMix64 {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}

/// The grain as a view: tiled noise blended softly over what is beneath.
struct PaperGrainOverlay: View {
    var intensity: Double = 1

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: PaperGrain.tile)
            .resizable(resizingMode: .tile)
            .blendMode(colorScheme == .dark ? .softLight : .multiply)
            .opacity((colorScheme == .dark ? 0.05 : 0.035) * intensity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    /// The paper canvas: the warm ground with its grain.
    func vocaPaperBackground() -> some View {
        background {
            ZStack {
                VocaDesign.canvas
                PaperGrainOverlay()
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Mark

/// The paper waveform: five rounded bars, tallest in the middle. The same
/// figure floats over the lake in every scene.
enum VocaWaveform {
    /// Bar heights as a share of the full height.
    static let bars: [CGFloat] = [0.38, 0.68, 1, 0.68, 0.38]

    /// Rects for the bars, centred in `rect`. Bars are as wide as the gaps.
    static func barRects(in rect: CGRect) -> [CGRect] {
        let count = CGFloat(bars.count)
        let pitch = rect.width / (count * 2 - 1)
        return bars.enumerated().map { index, share in
            let height = rect.height * share
            return CGRect(
                x: rect.minX + CGFloat(index) * pitch * 2,
                y: rect.midY - height / 2,
                width: pitch,
                height: height
            )
        }
    }
}

/// VocaMac's mark: a paper waveform on a petrol tile.
struct VocaMarkView: View {
    var size: CGFloat = 28

    var body: some View {
        Canvas { context, canvasSize in
            let inset = canvasSize.width * 0.24
            let area = CGRect(origin: .zero, size: canvasSize).insetBy(dx: inset, dy: inset * 1.05)
            for rect in VocaWaveform.barRects(in: area) {
                context.fill(Path(roundedRect: rect, cornerRadius: rect.width / 2), with: .color(Color(nsColor: VocaPalette.paper)))
            }
        }
        .frame(width: size, height: size)
        .background(
            LinearGradient(
                colors: [Color(nsColor: VocaPalette.petrol), Color(nsColor: VocaPalette.ink)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12))
        )
        .accessibilityHidden(true)
    }
}
