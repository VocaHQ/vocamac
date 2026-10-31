// CalmIcons.swift
// VocaMac
//
// The v3 line icons, model logos and the five-bar brand mark, drawn from
// the design's own SVG path data on a 20-point grid (22 for the brand).

import SwiftUI

// MARK: - Icon names

/// Every icon on the Foundations board. The raw value is the board's asset name.
enum CalmIconName: String, CaseIterable, Sendable {
    case home, notes, insights, dictionary, snippets, styles, commands, settings, help
    case general, system, models, cleanup, privacy, advanced
    case search, copy, edit, trash, close, plus
    case chevRight = "chev-right"
    case chevLeft = "chev-left"
    case chevDown = "chev-down"
    case check, warning, info, download, play, lock, update, flame, mic
    case arrowRight = "arrow-right"
    case undo, more, sort, keyboard

    /// SVG path data on the 20 × 20 grid (rects and circles converted to paths).
    var pathData: String {
        switch self {
        case .home: return "M4.5 3H7A1.5 1.5 0 0 1 8.5 4.5V7A1.5 1.5 0 0 1 7 8.5H4.5A1.5 1.5 0 0 1 3 7V4.5A1.5 1.5 0 0 1 4.5 3ZM13 3H15.5A1.5 1.5 0 0 1 17 4.5V7A1.5 1.5 0 0 1 15.5 8.5H13A1.5 1.5 0 0 1 11.5 7V4.5A1.5 1.5 0 0 1 13 3ZM4.5 11.5H7A1.5 1.5 0 0 1 8.5 13V15.5A1.5 1.5 0 0 1 7 17H4.5A1.5 1.5 0 0 1 3 15.5V13A1.5 1.5 0 0 1 4.5 11.5ZM13 11.5H15.5A1.5 1.5 0 0 1 17 13V15.5A1.5 1.5 0 0 1 15.5 17H13A1.5 1.5 0 0 1 11.5 15.5V13A1.5 1.5 0 0 1 13 11.5Z"
        case .notes: return "M5.5 3H14.5A1.5 1.5 0 0 1 16 4.5V15.5A1.5 1.5 0 0 1 14.5 17H5.5A1.5 1.5 0 0 1 4 15.5V4.5A1.5 1.5 0 0 1 5.5 3ZM7 7h6M7 10h6M7 13h3.5"
        case .insights: return "M4 16.5V10M8 16.5V4.5M12 16.5V8M16 16.5V12"
        case .dictionary: return "M4 4.8A1.8 1.8 0 0 1 5.8 3H16v11.5H5.8A1.8 1.8 0 0 0 4 16.3zM4 16.3A1.8 1.8 0 0 0 5.8 18H16M7.5 6.5h5"
        case .snippets: return "M4 5h12M4 9h12M4 13h5M12.5 12l2.5 2.5-2.5 2.5"
        case .styles: return "M12.5 4.5 15.5 7.5 7 16H4v-3zM11 6l3 3"
        case .commands: return "M3.5 16.5 12 8M10.5 6.5l3 3M15 2.8v2.4M16.2 4h-2.4M16.8 8.2v1.6M17.6 9h-1.6"
        case .settings: return "M8.6 2.8h2.8l.4 2 1.6.9 1.9-.7 1.4 2.4-1.5 1.4v1.8l1.5 1.4-1.4 2.4-1.9-.7-1.6.9-.4 2H8.6l-.4-2-1.6-.9-1.9.7-1.4-2.4 1.5-1.4V9.2L3.3 7.8l1.4-2.4 1.9.7 1.6-.9zM7.7 10A2.3 2.3 0 1 0 12.3 10A2.3 2.3 0 1 0 7.7 10Z"
        case .help: return "M3 10A7 7 0 1 0 17 10A7 7 0 1 0 3 10ZM7.9 7.9a2.2 2.2 0 1 1 3 2c-.6.3-.9.8-.9 1.4v.3M10 14.2v.1"
        case .general: return "M4 6h7M15 6h1M4 14h1M9 14h7M11 6A2 2 0 1 0 15 6A2 2 0 1 0 11 6ZM5 14A2 2 0 1 0 9 14A2 2 0 1 0 5 14Z"
        case .system: return "M4.3 4H15.7A1.5 1.5 0 0 1 17.2 5.5V12A1.5 1.5 0 0 1 15.7 13.5H4.3A1.5 1.5 0 0 1 2.8 12V5.5A1.5 1.5 0 0 1 4.3 4ZM7 16.5h6"
        case .models: return "M10 2.8 16.5 6.3v7.4L10 17.2l-6.5-3.5V6.3zM3.5 6.3 10 9.8l6.5-3.5M10 9.8v7.4"
        case .cleanup: return "M8.5 3l1.3 3.9 3.9 1.3-3.9 1.3-1.3 3.9-1.3-3.9-3.9-1.3 3.9-1.3zM14.5 11.5l.7 1.8 1.8.7-1.8.7-.7 1.8-.7-1.8-1.8-.7 1.8-.7z"
        case .privacy: return "M10 2.8 16 5v4.6c0 3.6-2.5 6.4-6 7.6-3.5-1.2-6-4-6-7.6V5zM7.5 10l1.8 1.8 3.4-3.6"
        case .advanced: return "M7 6 3 10l4 4M13 6l4 4-4 4"
        case .search: return "M3.5 9A5.5 5.5 0 1 0 14.5 9A5.5 5.5 0 1 0 3.5 9ZM13.2 13.2 17 17"
        case .copy: return "M8.5 6.5H14.5A2 2 0 0 1 16.5 8.5V14.5A2 2 0 0 1 14.5 16.5H8.5A2 2 0 0 1 6.5 14.5V8.5A2 2 0 0 1 8.5 6.5ZM13.5 6.5V5a1.5 1.5 0 0 0-1.5-1.5H5A1.5 1.5 0 0 0 3.5 5v7A1.5 1.5 0 0 0 5 13.5h1.5"
        case .edit: return "M12.5 4.5 15.5 7.5 7 16H4v-3zM11 6l3 3"
        case .trash: return "M4 6h12M8 6V4.5h4V6M5.5 6l.8 10.5h7.4L14.5 6"
        case .close: return "M5.5 5.5l9 9M14.5 5.5l-9 9"
        case .plus: return "M10 4.5v11M4.5 10h11"
        case .chevRight: return "M7.5 4.5 13 10l-5.5 5.5"
        case .chevLeft: return "M12.5 4.5 7 10l5.5 5.5"
        case .chevDown: return "M5.5 8 10 12.5 14.5 8"
        case .check: return "M4.5 10.5l3.5 3.5 7.5-8"
        case .warning: return "M10 3.5 17.5 16.5h-15zM10 8.5v3.5M10 14.3v.1"
        case .info: return "M3 10A7 7 0 1 0 17 10A7 7 0 1 0 3 10ZM10 9v4.5M10 6.6v.1"
        case .download: return "M10 3.5v9M6 9l4 4 4-4M4.5 16.5h11"
        case .play: return "M7 5.2 15 10l-8 4.8z"
        case .lock: return "M6.5 9H13.5A2 2 0 0 1 15.5 11V15A2 2 0 0 1 13.5 17H6.5A2 2 0 0 1 4.5 15V11A2 2 0 0 1 6.5 9ZM7 9V6.5a3 3 0 0 1 6 0V9"
        case .update: return "M16 10a6 6 0 0 1-10.4 4.1M4 10a6 6 0 0 1 10.4-4.1M14.6 3v3h-3M5.4 17v-3h3"
        case .flame: return "M10 2.8c.6 2.6 4.2 4.3 4.2 8.4a4.2 4.2 0 0 1-8.4 0c0-1.7.9-3 2-3.8.2 1.5 1 2.3 1.9 2.5-.6-2.6-.2-5 .3-7.1z"
        case .mic: return "M10 3a2.5 2.5 0 0 1 2.5 2.5v4a2.5 2.5 0 0 1-5 0v-4A2.5 2.5 0 0 1 10 3zM5.5 9.5a4.5 4.5 0 0 0 9 0M10 14v3"
        case .arrowRight: return "M4 10h11.5M11 5.5l4.5 4.5-4.5 4.5"
        case .undo: return "M7 5 3.5 8.5 7 12M3.5 8.5H12a4.5 4.5 0 0 1 0 9H9"
        case .more: return "M5 10h.1M10 10h.1M15 10h.1"
        case .sort: return "M6.5 4v12M3.5 7l3-3 3 3M13.5 16V4M10.5 13l3 3 3-3"
        case .keyboard: return "M2.8 5.5h14.4v9H2.8zM5.5 8.5h.1M8.5 8.5h.1M11.5 8.5h.1M14.5 8.5h.1M7 11.5h6"
        }
    }
}

/// The model logos: simple line drawings, not company logos.
enum CalmLogoName: String, CaseIterable, Sendable {
    case parakeet, whisper, appleSpeech, specialized, ownServer, qwen, ministral, appleIntelligence

    /// The name the Foundations board gives the logo.
    var title: String {
        switch self {
        case .parakeet: return "Parakeet"
        case .whisper: return "Whisper"
        case .appleSpeech: return "Apple Speech"
        case .specialized: return "Specialized"
        case .ownServer: return "Your own server"
        case .qwen: return "Qwen"
        case .ministral: return "Ministral"
        case .appleIntelligence: return "Apple Intelligence"
        }
    }

    /// SVG path data on the 20 × 20 grid.
    var pathData: String {
        switch self {
        case .parakeet: return "M15.2 4.2c-1.7 0-3 1.3-3 3v1.3c0 3.1-2.6 5.6-6.2 6l-2.5.3 1.9 1.4h4.1c4.2 0 7.3-3.1 7.3-7.3V7.6l1.7-1-1.7-.7a2.9 2.9 0 0 0-1.6-1.7zM14.9 6.6v.1"
        case .whisper: return "M3 7.5h9a2.5 2.5 0 1 0-2.5-2.5M3 11h12.5a2.5 2.5 0 1 1-2.5 2.5M3 14.5h5.5"
        case .appleSpeech: return "M7 3h6a4 4 0 0 1 4 4v6a4 4 0 0 1-4 4H7a4 4 0 0 1-4-4V7a4 4 0 0 1 4-4zM7 8.5v3M10 6.5v7M13 8.5v3"
        case .specialized: return "M3.5 10a6.5 6.5 0 1 0 13 0a6.5 6.5 0 1 0-13 0M7 10a3 3 0 1 0 6 0a3 3 0 1 0-6 0M10 1.8v3M10 15.2v3M1.8 10h3M15.2 10h3"
        case .ownServer: return "M5 3.5h10a1.5 1.5 0 0 1 1.5 1.5v2.5A1.5 1.5 0 0 1 15 9H5a1.5 1.5 0 0 1-1.5-1.5V5A1.5 1.5 0 0 1 5 3.5zM5 11h10a1.5 1.5 0 0 1 1.5 1.5V15a1.5 1.5 0 0 1-1.5 1.5H5A1.5 1.5 0 0 1 3.5 15v-2.5A1.5 1.5 0 0 1 5 11zM6.5 6.2h.1M6.5 13.7h.1"
        case .qwen: return "M10 2.8 16.2 6.4v7.2L10 17.2l-6.2-3.6V6.4zM10 7l2.6 1.5v3L10 13l-2.6-1.5v-3z"
        case .ministral: return "M3 6.5c2.3-1.6 4.7-1.6 7 0s4.7 1.6 7 0M3 10.5c2.3-1.6 4.7-1.6 7 0s4.7 1.6 7 0M3 14.5c2.3-1.6 4.7-1.6 7 0s4.7 1.6 7 0"
        case .appleIntelligence: return "M3 10a7 7 0 1 0 14 0a7 7 0 1 0-14 0M10 6l1 3 3 1-3 1-1 3-1-3-3-1 3-1z"
        }
    }

    /// The logo for a speech engine.
    init(engine: TranscriptionEngine) {
        switch engine {
        case .whisperKit: self = .whisper
        case .parakeet: self = .parakeet
        case .appleSpeech: self = .appleSpeech
        case .sherpaOnnx: self = .specialized
        case .customEndpoint: self = .ownServer
        }
    }
}

// MARK: - Path cache

/// Parsed paths, built once. SwiftUI `Path` is a value type and `Sendable`,
/// so the lazily initialised table is safe to share.
private enum CalmPathCache {
    static let icons: [CalmIconName: Path] = Dictionary(
        uniqueKeysWithValues: CalmIconName.allCases.map { ($0, parse($0.pathData)) }
    )
    static let logos: [CalmLogoName: Path] = Dictionary(
        uniqueKeysWithValues: CalmLogoName.allCases.map { ($0, parse($0.pathData)) }
    )
    static let brand = parse("M5 9.5v3M8.3 7v8M11.6 4.5v13M14.9 7.5v7M18 9.5v3")

    private static func parse(_ data: String) -> Path {
        SVGPath.makeCGPath(from: data).map { Path($0) } ?? Path()
    }
}

// MARK: - Shapes

/// A path drawn on a square design grid, scaled to whatever frame it gets.
struct CalmGridShape: Shape {
    let path: Path
    /// The grid the path was drawn on: 20 for icons and logos, 22 for the brand mark.
    var grid: CGFloat = 20

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / grid
        let dx = rect.minX + (rect.width - grid * scale) / 2
        let dy = rect.minY + (rect.height - grid * scale) / 2
        return path.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: dx, ty: dy))
    }
}

extension CalmGridShape {
    /// The shape of a Calm icon.
    init(icon: CalmIconName) { self.init(path: CalmPathCache.icons[icon] ?? Path()) }
    /// The shape of a model logo.
    init(logo: CalmLogoName) { self.init(path: CalmPathCache.logos[logo] ?? Path()) }
    /// The five-bar brand mark (22-point grid).
    static var brandMark: CalmGridShape { CalmGridShape(path: CalmPathCache.brand, grid: 22) }
}

// MARK: - Views

/// A Calm line icon, stroked in the current foreground style.
///
/// ```swift
/// CalmIcon(.dictionary, size: 17)
/// CalmIcon(.plus, size: 14, weight: 2)
/// ```
/// The stroke is given on the 20-point grid, as in the SVGs (1.6 by
/// default), and scales with `size`. Icons are decorative to VoiceOver;
/// label the control that holds them.
struct CalmIcon: View {
    let name: CalmIconName
    var size: CGFloat = 16
    /// Stroke width on the 20-point grid.
    var weight: CGFloat = 1.6

    init(_ name: CalmIconName, size: CGFloat = 16, weight: CGFloat = 1.6) {
        self.name = name
        self.size = size
        self.weight = weight
    }

    var body: some View {
        CalmGridShape(icon: name)
            .stroke(style: StrokeStyle(lineWidth: weight * size / 20, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A model logo in its outlined box: content background, 1 pt line2
/// outline, radius 28% of the box.
///
/// ```swift
/// CalmLogo(.parakeet, box: 40)   // details, Foundations
/// CalmLogo(.whisper, box: 32)    // pick card
/// CalmLogo(.qwen, box: 28)       // family header
/// ```
struct CalmLogo: View {
    let name: CalmLogoName
    var box: CGFloat = 40

    init(_ name: CalmLogoName, box: CGFloat = 40) {
        self.name = name
        self.box = box
    }

    /// Glyph size for the board's three boxes (40 → 21, 32 → 18, 28 → 16).
    private var glyph: CGFloat {
        switch box {
        case 40: return 21
        case 32: return 18
        case 28: return 16
        default: return (box * 0.53).rounded()
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: (box * 0.28).rounded(), style: .continuous)
        CalmGridShape(logo: name)
            .stroke(style: StrokeStyle(lineWidth: 1.5 * glyph / 20, lineCap: .round, lineJoin: .round))
            .foregroundStyle(CalmColor.ink)
            .frame(width: glyph, height: glyph)
            .frame(width: box, height: box)
            .background(shape.fill(CalmColor.content))
            .overlay(shape.strokeBorder(CalmColor.line2, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// The VocaMac logo (the mic mark) wherever the window shows the brand:
/// `CalmBrandMark(size: 28)` in the sidebar, `CalmBrandMark(size: 72)` on
/// About. It draws the same bundled logo as the rest of the app, so the
/// window and the app icon match.
struct CalmBrandMark: View {
    var size: CGFloat = 28

    var body: some View {
        BrandLogoView(size: size)
    }
}
