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
/// VocaHQ/.github `brand/vocahq/social`. `fill` is `currentColor`; AppKit
/// template rendering lets the button label color tint them. Do not
/// hard-code Discord blurple, X black, or GitHub black.
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

    /// Template image so the control's label color tints `currentColor`.
    func templateImage() -> NSImage? {
        guard let url = svgURL(), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }

    private func svgURL() -> URL? {
        let bundle = Bundle.module
        return bundle.url(forResource: rawValue, withExtension: "svg", subdirectory: "Resources/social")
            ?? bundle.url(forResource: rawValue, withExtension: "svg", subdirectory: "social")
            ?? bundle.url(forResource: rawValue, withExtension: "svg")
    }
}

/// Official VocaDesign mark, drawn at 16pt in a text button.
struct AboutSocialMarkImage: View {
    let mark: AboutSocialMark
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = mark.templateImage() {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
