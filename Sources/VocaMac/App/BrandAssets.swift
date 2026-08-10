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

    /// Mic-only silhouette for the menu bar (template / tintable).
    static var mark: NSImage? {
        image(named: "voca-mark")
    }

    /// Brand green `#0F6B57`.
    static let brandGreen = NSColor(red: 0.059, green: 0.420, blue: 0.341, alpha: 1.0)
}

/// Which artwork the menu bar should show for a given app status.
enum MenuBarIconStyle: Equatable {
    /// Black mark drawn as a template so macOS follows the menu bar appearance.
    case brandMarkTemplate
    /// Mark tinted with the status color (recording).
    case brandMarkTinted
    /// SF Symbol for processing / error.
    case systemSymbol(name: String)

    static func style(for status: AppStatus) -> MenuBarIconStyle {
        switch status {
        case .idle:
            return .brandMarkTemplate
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
struct BrandLogoView: View {
    let size: CGFloat

    var body: some View {
        if let logo = BrandAssets.logo {
            Image(nsImage: logo)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: size))
                .foregroundStyle(Color(nsColor: BrandAssets.brandGreen))
                .frame(width: size, height: size)
        }
    }
}
