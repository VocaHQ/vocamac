// BrandAssets.swift
// VocaMac

import AppKit
import SwiftUI

/// Provides the Voca brand artwork bundled with the app.
enum BrandAssets {
    /// Loads a bundled image from the Swift package resource bundle.
    static func image(named name: String, fileExtension: String = "png") -> NSImage? {
        let bundle = Bundle.module
        let url = bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "Resources")
            ?? bundle.url(forResource: name, withExtension: fileExtension)
        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }

    /// The circular Voca logo used in app-facing surfaces (About, onboarding).
    static var logo: NSImage? {
        image(named: "voca-logo-512")
    }

    /// Mic-only silhouette for the menu bar (tintable).
    static var mark: NSImage? {
        image(named: "voca-mark")
    }

    /// Brand color — the Quiet Wonder petrol, so the mark reads as part of
    /// the interface rather than a second accent fighting it.
    static let brandColor = VocaPalette.petrol
}

/// Which artwork the menu bar should show for a given app status.
enum MenuBarIconStyle: Equatable {
    /// SF Symbol drawn as a template so macOS follows the menu bar appearance.
    case systemSymbolTemplate(name: String)
    /// The Voca mic mark tinted with the brand color while recording (mic hot).
    case brandMarkTinted
    /// SF Symbol for processing, error and Command Mode.
    case systemSymbol(name: String)

    static func style(for status: AppStatus, isCommandMode: Bool = false) -> MenuBarIconStyle {
        // A wand while Command Mode listens or rewrites, so the menu bar says
        // an edit of the selection is under way rather than a dictation.
        if isCommandMode, status == .recording || status == .processing {
            return .systemSymbol(name: "wand.and.stars")
        }
        switch status {
        case .idle:
            return .systemSymbolTemplate(name: "mic.fill")
        case .recording:
            return .brandMarkTinted
        case .processing:
            return .systemSymbol(name: "ellipsis.circle")
        case .error:
            return .systemSymbol(name: "exclamationmark.triangle")
        }
    }
}

/// Renders the canonical Voca logo with a safe fallback for development builds.
///
/// Decorative: every use sits beside a visible "VocaMac" label, so the logo is
/// hidden from VoiceOver rather than read out twice.
struct BrandLogoView: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let logo = BrandAssets.logo {
                Image(nsImage: logo)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: size))
                    .foregroundStyle(Color(nsColor: BrandAssets.brandColor))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Renders the official standalone Voca mark as a monochrome template.
struct BrandMarkView: View {
    let size: CGFloat

    var body: some View {
        if let mark = BrandAssets.mark {
            Image(nsImage: mark)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "waveform")
                .font(.system(size: size))
                .accessibilityHidden(true)
        }
    }
}
