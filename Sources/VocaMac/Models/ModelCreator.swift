// ModelCreator.swift
// VocaMac
//
// Who made each speech and cleanup model, so Settings can credit them.
//
// Marks in `Resources/creators/` are the unmodified monochrome SVGs from
// Lobe Icons (@lobehub/icons-static-svg 1.95.0, MIT — see
// LICENSE-lobe-icons.txt). Names and logos belong to their owners and are
// shown for attribution only. Creators without a permissively licensed mark
// get a monogram instead of a redrawn logo.

import AppKit
import SwiftUI

enum ModelCreator: String, CaseIterable, Identifiable {
    case openAI
    case huggingFace
    case nvidia
    case apple
    case alibaba
    case qwen
    case mistral
    case usefulSensors
    case sber

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .huggingFace: return "Hugging Face"
        case .nvidia: return "NVIDIA"
        case .apple: return "Apple"
        case .alibaba: return "Alibaba"
        case .qwen: return "Qwen"
        case .mistral: return "Mistral AI"
        case .usefulSensors: return "Useful Sensors"
        case .sber: return "SberDevices"
        }
    }

    /// The models VocaMac uses from this creator, for the credits list.
    var creditedModels: String {
        switch self {
        case .openAI: return "Whisper"
        case .huggingFace: return "Distil-Whisper"
        case .nvidia: return "Parakeet and Canary"
        case .apple: return "Apple Speech and Apple Intelligence"
        case .alibaba: return "SenseVoice"
        case .qwen: return "Qwen 2.5 and Qwen 3"
        case .mistral: return "Ministral 3"
        case .usefulSensors: return "Moonshine"
        case .sber: return "GigaAM"
        }
    }

    /// Where the models are published.
    var url: URL {
        switch self {
        case .openAI: return URL(string: "https://github.com/openai/whisper")!
        case .huggingFace: return URL(string: "https://github.com/huggingface/distil-whisper")!
        case .nvidia: return URL(string: "https://huggingface.co/nvidia")!
        case .apple: return URL(string: "https://developer.apple.com/documentation/speech")!
        case .alibaba: return URL(string: "https://github.com/FunAudioLLM/SenseVoice")!
        case .qwen: return URL(string: "https://huggingface.co/Qwen")!
        case .mistral: return URL(string: "https://huggingface.co/mistralai")!
        case .usefulSensors: return URL(string: "https://github.com/usefulsensors/moonshine")!
        case .sber: return URL(string: "https://github.com/salute-developers/GigaAM")!
        }
    }

    /// Bundled mark in `Resources/creators/`, or nil when a monogram stands in.
    var markName: String? {
        switch self {
        case .openAI: return "openai"
        case .huggingFace: return "huggingface"
        case .nvidia: return "nvidia"
        case .apple: return "apple"
        case .alibaba: return "alibaba"
        case .qwen: return "qwen"
        case .mistral: return "mistral"
        case .usefulSensors, .sber: return nil
        }
    }

    var monogram: String {
        switch self {
        case .usefulSensors: return "US"
        case .sber: return "S"
        default: return String(displayName.prefix(1))
        }
    }

    /// SHA-256 of the exact Lobe Icons 1.95.0 files, so a changed mark is
    /// caught in review rather than shipped.
    var expectedSHA256: String? {
        switch self {
        case .openAI: return "a595df6b423920c67a7f8f73c063e4bfb72d415948097b6cac063a2366bb5186"
        case .huggingFace: return "de7f2c60f974b75b385116ef0dc6a9fa62f2fd7bf58156b5623301a5436b91c4"
        case .nvidia: return "5a419b99e0ffdbfbe8caa7ec25581054eae03024da59cb860c54ea55ac8e7e73"
        case .apple: return "100637681febc38512bf8d43f7d5f79f2aa8caead15b256cd28b378b053fca69"
        case .alibaba: return "9ecd942970e4616933c9e1c014f58ad31ea4c1775efefc4f41b55ea166f443ee"
        case .qwen: return "dcb3ba2f2b55ccbacbade0ca0bf98921fbaf8a07848972974b4a9bf8077376cf"
        case .mistral: return "a06cfa54e7deff7f7544175b006b7f8a03fbc5624c44f7d553a44d07ea96e629"
        case .usefulSensors, .sber: return nil
        }
    }

    // MARK: - Mark Artwork

    func svgData() -> Data? {
        guard let markName else { return nil }
        let bundle = Bundle.module
        let url = bundle.url(forResource: markName, withExtension: "svg", subdirectory: "Resources/creators")
            ?? bundle.url(forResource: markName, withExtension: "svg", subdirectory: "creators")
            ?? bundle.url(forResource: markName, withExtension: "svg")
        return url.flatMap { try? Data(contentsOf: $0) }
    }

    /// The mark's single `d` attribute.
    func pathData() -> String? {
        guard let data = svgData(), let text = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"\bd="([^"]+)""#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    /// The mark as a template image macOS can tint, or nil for monograms.
    ///
    /// Drawn from the path rather than through CoreSVG, which rejects the
    /// compact arc flags some of these files use. The files set
    /// `fill-rule="evenodd"`, which carves the holes in several marks.
    func templateImage() -> NSImage? {
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        if let cached = Self.imageCache[rawValue] { return cached }
        guard let d = pathData(), let path = SVGPath.makeCGPath(from: d) else { return nil }

        let logical = NSSize(width: 24, height: 24)
        let scale: CGFloat = 3
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(logical.width * scale),
            pixelsHigh: Int(logical.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = logical

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        if let ctx = NSGraphicsContext.current?.cgContext {
            // viewBox 0 0 24 24, SVG y-down.
            ctx.translateBy(x: 0, y: logical.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: logical)
        image.addRepresentation(bitmap)
        image.isTemplate = true
        Self.imageCache[rawValue] = image
        return image
    }

    private static let cacheLock = NSLock()
    private static var imageCache: [String: NSImage] = [:]
}

extension ModelSize {
    var creator: ModelCreator {
        switch self {
        case .tiny, .base, .small, .medium,
             .largeV3, .largeV3Turbo,
             .largeV3Latest, .largeV3LatestTurbo,
             .largeV3LatestCompact, .largeV3LatestTurboCompact:
            return .openAI
        case .distilLargeV3Compact, .distilLargeV3TurboCompact:
            return .huggingFace
        case .parakeetV3, .parakeetV2, .parakeetTdtCtc110m, .canary180mFlash:
            return .nvidia
        case .appleSpeech:
            return .apple
        case .moonshineTiny, .moonshineBase:
            return .usefulSensors
        case .senseVoiceSmall:
            return .alibaba
        case .qwen3Asr06B:
            return .qwen
        case .gigaamV3:
            return .sber
        }
    }
}

extension CleanupModelKind {
    var creator: ModelCreator {
        switch self {
        case .ministral3_3b_q4_k_m:
            return .mistral
        default:
            return .qwen
        }
    }
}

/// A creator's mark on a small rounded tile, with an optional "in use" check.
struct ModelCreatorMark: View {
    let creator: ModelCreator
    var size: CGFloat = 26
    var isActive = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        ZStack {
            shape.fill(Color.primary.opacity(0.07))
            shape.strokeBorder(Color.primary.opacity(0.08))
            if let image = creator.templateImage() {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.6, height: size * 0.6)
                    .foregroundStyle(.primary)
            } else {
                Text(creator.monogram)
                    .font(.system(size: size * (creator.monogram.count > 1 ? 0.32 : 0.42), weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, VocaDesign.success)
                    .background(Circle().fill(VocaDesign.canvas).padding(-1))
                    .offset(x: size * 0.16, y: size * 0.16)
            }
        }
        .help("Made by \(creator.displayName)")
        .accessibilityElement()
        .accessibilityLabel("Made by \(creator.displayName)")
    }
}
