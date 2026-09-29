import Foundation

/// Validates persisted Settings geometry independently of AppKit windows.
enum SettingsWindowGeometry {
    static func needsReset(_ frame: CGRect, screens: [CGRect]) -> Bool {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width >= 760, frame.height >= 580 else { return true }
        return !screens.contains { screen in
            let visible = frame.intersection(screen)
            return visible.width >= 200 && visible.height >= 100
                && frame.maxY <= screen.maxY + 40 && frame.maxY >= screen.minY + 100
        }
    }
}
