import Foundation

/// Sizes for VocaMac's window and validation of its persisted frame,
/// independent of AppKit windows.
enum SettingsWindowGeometry {
    /// The window opens at this content size.
    static let defaultContentSize = CGSize(width: 1240, height: 800)
    /// The smallest content size on a roomy screen: the 1000 × 680 Settings
    /// sheet still fits inside with a margin on every side.
    static let minimumContentSize = CGSize(width: 1080, height: 740)
    /// The smallest content size the layout supports at all. On a screen
    /// too small for `minimumContentSize` (a 13" laptop at a larger-text
    /// scaling) the minimum shrinks toward this, and the Settings sheet
    /// shrinks with the window (`sheetSize(in:)`).
    static let smallestContentSize = CGSize(width: 800, height: 520)
    /// The Settings sheet's size when the window has room for it.
    static let sheetSize = CGSize(width: 1000, height: 680)
    /// Room kept between the Settings sheet and the window's edges.
    static let sheetMargin = CGSize(width: 40, height: 30)
    /// Where the v3 window remembers its frame. A new name, so frames saved
    /// by the old Settings window (often 1080 × 740) don't carry over and
    /// everyone starts at the default size.
    static let frameAutosaveName = "VocaMac.Window.v3"
    /// Frames the old Settings window saved; never read.
    static let retiredFrameAutosaveNames = ["VocaMac.Settings"]
    /// Room kept free around a window that opens on a small screen.
    static let screenMargin: CGFloat = 40

    /// The smallest content size on a screen with this visible frame:
    /// `minimumContentSize`, shrunk to fit a smaller screen, but never below
    /// `smallestContentSize`.
    static func minimumContentSize(forVisibleFrame screen: CGRect?) -> CGSize {
        guard let screen, screen.width > 0, screen.height > 0 else { return minimumContentSize }
        return CGSize(
            width: max(smallestContentSize.width, min(minimumContentSize.width, screen.width)),
            height: max(smallestContentSize.height, min(minimumContentSize.height, screen.height))
        )
    }

    /// The size the window opens at on a screen with this visible frame:
    /// the default, shrunk to leave a margin on a small screen, but never
    /// below that screen's minimum.
    static func openingContentSize(forVisibleFrame screen: CGRect?) -> CGSize {
        guard let screen, screen.width > 0, screen.height > 0 else { return defaultContentSize }
        let minimum = minimumContentSize(forVisibleFrame: screen)
        return CGSize(
            width: max(minimum.width, min(defaultContentSize.width, screen.width - screenMargin * 2)),
            height: max(minimum.height, min(defaultContentSize.height, screen.height - screenMargin * 2))
        )
    }

    /// The Settings sheet's size in a window content area of `container`:
    /// `sheetSize`, shrunk to keep `sheetMargin` free on a smaller window.
    static func sheetSize(in container: CGSize) -> CGSize {
        CGSize(
            width: max(0, min(sheetSize.width, container.width - sheetMargin.width * 2)),
            height: max(0, min(sheetSize.height, container.height - sheetMargin.height * 2))
        )
    }

    /// Whether a saved frame is unusable: collapsed, smaller than the
    /// minimum for the screen it is on (e.g. the old 860 × 620 Settings
    /// window), or off every screen.
    static func needsReset(_ frame: CGRect, screens: [CGRect]) -> Bool {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite else { return true }
        return !screens.contains { screen in
            let minimum = minimumContentSize(forVisibleFrame: screen)
            let visible = frame.intersection(screen)
            return frame.width >= minimum.width && frame.height >= minimum.height
                && visible.width >= 200 && visible.height >= 100
                && frame.maxY <= screen.maxY + 40 && frame.maxY >= screen.minY + 100
        }
    }
}
