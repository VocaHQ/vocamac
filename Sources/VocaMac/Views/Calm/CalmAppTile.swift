// CalmAppTile.swift
// VocaMac
//
// The 28-point app tile Styles, Privacy and System share: the app's icon,
// or its first letter when VocaMac can't find the app.

import AppKit
import SwiftUI

/// An app in a list or dialog: its own icon at 28 (r7) when the app is on
/// this Mac, otherwise its first letter on panel2 (the Add app dialogs).
struct CalmAppTile: View {
    let name: String
    var bundleIdentifier: String?
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let icon = CalmAppIconCache.icon(for: bundleIdentifier) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Text(name.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(CalmColor.ink2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(CalmColor.panel2))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Icons are cached: the page re-renders on every AppState change, and each
/// lookup is a LaunchServices round trip.
@MainActor
enum CalmAppIconCache {
    private static var icons: [String: NSImage] = [:]
    private static var missing: Set<String> = []

    static func icon(for bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier else { return nil }
        if let cached = icons[bundleIdentifier] { return cached }
        guard !missing.contains(bundleIdentifier),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            missing.insert(bundleIdentifier)
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleIdentifier] = image
        return image
    }
}
