// CalmTheme.swift
// VocaMac
//
// The v3 "Calm" design tokens: colours, type and sizes. Every Calm view
// draws with these names only, so a token change lands everywhere at once.

import AppKit
import SwiftUI

// MARK: - Colours

/// Adaptive colours from the Foundations board. Each one resolves per
/// appearance (light, dark, and their Increase Contrast variants) at draw
/// time, so views never branch on the colour scheme themselves.
///
/// Colour carries meaning only: `accent` for on / in use, `amber` for
/// problems. Everything else is ink on soft surfaces.
enum CalmColor {
    /// Window background, sidebar, Settings sheet menu.
    static let frame = Color(nsColor: CalmNSColor.frame)
    /// Page and sheet background, dialogs, lists.
    static let content = Color(nsColor: CalmNSColor.content)
    /// Grouped rows, stat cards, pick cards, the status card.
    static let panel = Color(nsColor: CalmNSColor.panel)
    /// Secondary buttons, selected nav item, segment track.
    static let panel2 = Color(nsColor: CalmNSColor.panel2)
    /// Text, primary button, switch on, selection ring.
    static let ink = Color(nsColor: CalmNSColor.ink)
    /// Secondary text, nav icons.
    static let ink2 = Color(nsColor: CalmNSColor.ink2)
    /// Descriptions, captions, inactive tabs.
    static let muted = Color(nsColor: CalmNSColor.muted)
    /// Dividers between rows (ink 8% / white 7%).
    static let line = Color(nsColor: CalmNSColor.line)
    /// Outlines of lists, fields and key caps (ink 14% / white 13%).
    static let line2 = Color(nsColor: CalmNSColor.line2)
    /// Brand teal: Ready, In use, heatmap, progress.
    static let accent = Color(nsColor: CalmNSColor.accent)
    /// Accent at 10% / 13%: In use tag, success icon circle.
    static let accentSoft = Color(nsColor: CalmNSColor.accentSoft)
    /// Warnings and destructive actions.
    static let amber = Color(nsColor: CalmNSColor.amber)
    /// Warning icon circle, Needs access tag.
    static let amberSoft = Color(nsColor: CalmNSColor.amberSoft)
    /// Switch track when off.
    static let off = Color(nsColor: CalmNSColor.off)
    /// Feature (hero) card background.
    static let hero = Color(nsColor: CalmNSColor.hero)
    /// Text on the feature card, in both appearances.
    static let heroText = Color(nsColor: CalmNSColor.heroText)
    /// Behind the Settings sheet and dialogs.
    static let scrim = Color(nsColor: CalmNSColor.scrim)
    /// The 3 pt keyboard focus ring.
    static let focus = Color(nsColor: CalmNSColor.focus)
    /// Primary button fill (same as ink).
    static let primary = Color(nsColor: CalmNSColor.ink)
    /// Text on the primary button.
    static let onPrimary = Color(nsColor: CalmNSColor.onPrimary)
    /// Primary button fill on hover.
    static let primaryHover = Color(nsColor: CalmNSColor.primaryHover)
    /// Switch knob when on.
    static let knobOn = Color(nsColor: CalmNSColor.knobOn)
    /// Switch knob when off.
    static let knobOff = Color(nsColor: CalmNSColor.knobOff)
    /// Command Mode only: its overlay and highlights.
    static let violet = Color(nsColor: CalmNSColor.violet)

    /// Heatmap scale, `heat[0]` (no words) to `heat[4]` (800+ words).
    static let heat: [Color] = CalmNSColor.heat.map { Color(nsColor: $0) }

    /// The heatmap colour for a level, clamped to 0...4.
    static func heat(_ level: Int) -> Color {
        heat[min(max(level, 0), heat.count - 1)]
    }
}

/// AppKit forms of the Calm colours, for window backgrounds and AppKit
/// drawing. Prefer `CalmColor` in SwiftUI.
enum CalmNSColor {
    static let frame = adaptive(0xEDF1EB, 0x0E1512)
    static let content = adaptive(0xFBFCFA, 0x151E1A)
    static let panel = adaptive(0xF1F4EF, 0x1B2621)
    static let panel2 = adaptive(0xE6EBE4, 0x24322B)
    static let ink = adaptive(0x182023, 0xEDF2EE)
    static let ink2 = adaptive(0x3A4744, 0xC2CDC7)
    // Increase Contrast darkens muted text toward ink2.
    static let muted = adaptive(0x5B6763, 0x93A29B, contrastLight: 0x45514D, contrastDark: 0xB1BDB7)
    // Increase Contrast doubles the outlines: the cheap, visible part of the setting.
    static let line = NSColor.calmAdaptive(
        light: rgb(0x182023, 0.08), dark: rgb(0xFFFFFF, 0.07),
        contrastLight: rgb(0x182023, 0.18), contrastDark: rgb(0xFFFFFF, 0.18)
    )
    static let line2 = NSColor.calmAdaptive(
        light: rgb(0x182023, 0.14), dark: rgb(0xFFFFFF, 0.13),
        contrastLight: rgb(0x182023, 0.34), contrastDark: rgb(0xFFFFFF, 0.32)
    )
    static let accent = adaptive(0x0F6B57, 0x55C2A0)
    static let accentSoft = NSColor.calmAdaptive(light: rgb(0x0F6B57, 0.10), dark: rgb(0x55C2A0, 0.13))
    static let amber = adaptive(0x8A4300, 0xFFB459)
    static let amberSoft = NSColor.calmAdaptive(light: rgb(0xBD5C00, 0.10), dark: rgb(0xFF9E0A, 0.12))
    static let off = adaptive(0xCBD3C9, 0x3A4943, contrastLight: 0xAEB8AC, contrastDark: 0x52645C)
    static let hero = adaptive(0x123F36, 0x0F2E27)
    static let heroText = adaptive(0xF3F6F1, 0xF3F6F1)
    static let scrim = NSColor.calmAdaptive(light: rgb(0x182023, 0.30), dark: rgb(0x000000, 0.55))
    static let focus = NSColor.calmAdaptive(light: rgb(0x0F6B57, 0.35), dark: rgb(0x55C2A0, 0.45))
    static let onPrimary = adaptive(0xFBFCFA, 0x111915)
    static let primaryHover = adaptive(0x2E3A3D, 0xFFFFFF)
    static let knobOn = adaptive(0xFFFFFF, 0x151E1A)
    static let knobOff = adaptive(0xFFFFFF, 0x9AA8A1)
    static let violet = adaptive(0x5E3BC4, 0xBBA4FF)
    static let heat: [NSColor] = [
        adaptive(0xE3E8E1, 0x212C27),
        adaptive(0xB7DACB, 0x1D4639),
        adaptive(0x79BEA4, 0x287259),
        adaptive(0x2E9478, 0x40A383),
        adaptive(0x0F6B57, 0x6FD6B4),
    ]

    private static func adaptive(
        _ light: UInt32, _ dark: UInt32, contrastLight: UInt32? = nil, contrastDark: UInt32? = nil
    ) -> NSColor {
        NSColor.calmAdaptive(
            light: rgb(light), dark: rgb(dark),
            contrastLight: contrastLight.map { rgb($0) }, contrastDark: contrastDark.map { rgb($0) }
        )
    }

    /// An sRGB colour from a 0xRRGGBB literal.
    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension NSColor {
    /// A colour that resolves per appearance. The contrast variants default
    /// to the plain ones.
    static func calmAdaptive(
        light: NSColor, dark: NSColor, contrastLight: NSColor? = nil, contrastDark: NSColor? = nil
    ) -> NSColor {
        let highLight = contrastLight ?? light
        let highDark = contrastDark ?? dark
        return NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [
                .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            ]) {
            case .darkAqua?: return dark
            case .accessibilityHighContrastAqua?: return highLight
            case .accessibilityHighContrastDarkAqua?: return highDark
            default: return light
            }
        }
    }
}

// MARK: - Type

/// Fonts from the Foundations board. Two families only: New York (serif)
/// for titles and big numbers, SF Pro for everything else. Pair a font with
/// its tracking and line spacing through `View.calmType(_:)` where the board
/// sets them.
enum CalmFont {
    /// Page title: New York 30, tracking −1%.
    static let title = Font.system(size: 30, weight: .regular, design: .serif)
    /// Feature (hero) card title: New York 32, line 1.1, tracking −1.5%.
    static let featureTitle = Font.system(size: 32, weight: .regular, design: .serif)
    /// The feature-card title in a narrow window.
    static let featureTitleCompact = Font.system(size: 28, weight: .regular, design: .serif)
    /// Serif section title: New York 22, once or twice per page.
    static let sectionSerif = Font.system(size: 22, weight: .regular, design: .serif)
    /// Big number: New York 28 (Home side card, Insights).
    static let bigNumber = Font.system(size: 28, weight: .regular, design: .serif)
    /// Stat card number: New York 30.
    static let statNumber = Font.system(size: 30, weight: .regular, design: .serif)
    /// Unit after a big number: SF 14 (draw it in ink2).
    static let bigNumberUnit = Font.system(size: 14)
    /// Group label above a panel: SF 14 / 600.
    static let groupLabel = Font.system(size: 14, weight: .semibold)
    /// Row title: SF 14 / 560.
    static let rowTitle = sf(14, weight: 560)
    /// Body text (transcripts, paragraphs): SF 14, line 1.55.
    static let body = Font.system(size: 14)
    /// Description under a row title: SF 13, muted, line 1.45.
    static let description = Font.system(size: 13)
    /// Button label: SF 13.5 / 550.
    static let button = sf(13.5, weight: 550)
    /// Small button label: SF 12.5 / 550.
    static let buttonSmall = sf(12.5, weight: 550)
    /// Feature-card main button: SF 13.5 / 600.
    static let heroButton = Font.system(size: 13.5, weight: .semibold)
    /// Caption (TODAY, SETTINGS): SF 11 / 650, +8% tracking, uppercase, muted.
    static let caption = sf(11, weight: 650)
    /// Nav item: SF 14.
    static let nav = Font.system(size: 14)
    /// Selected nav item: SF 14 / 600.
    static let navSelected = Font.system(size: 14, weight: .semibold)
    /// Sidebar brand name: SF 16 / 700, tracking −1%.
    static let brand = Font.system(size: 16, weight: .bold)
    /// Status card title: SF 13.5 / 600.
    static let statusTitle = Font.system(size: 13.5, weight: .semibold)
    /// Small supporting line (status card, notes, inline notices): SF 12.5.
    static let note = Font.system(size: 12.5)
    /// Text link: SF 13 / 550.
    static let link = sf(13, weight: 550)
    /// Sub-page back link: SF 13 (muted).
    static let backLink = Font.system(size: 13)
    /// Page description under a title: SF 14 (muted).
    static let pageDescription = Font.system(size: 14)
    /// Field label above a text field: SF 13 / 560.
    static let fieldLabel = sf(13, weight: 560)
    /// Text inside a text field: SF 14.
    static let field = Font.system(size: 14)
    /// Search field, dropdown and menu text: SF 13.5.
    static let control = Font.system(size: 13.5)
    /// Segmented option: SF 13 / 550.
    static let segment = sf(13, weight: 550)
    /// Underline tab: SF 14 (selected 600).
    static let tab = Font.system(size: 14)
    /// Selected underline tab: SF 14 / 600.
    static let tabSelected = Font.system(size: 14, weight: .semibold)
    /// Tag: SF 11.5 / 600.
    static let tag = Font.system(size: 11.5, weight: .semibold)
    /// Key cap: SF 12 / 600.
    static let keyCap = Font.system(size: 12, weight: .semibold)
    /// Key cap inline in text: SF 11 / 600.
    static let keyCapInline = Font.system(size: 11, weight: .semibold)
    /// Dialog title: SF 17 / 650.
    static let dialogTitle = sf(17, weight: 650)
    /// Feature card body: SF 14.5.
    static let heroBody = Font.system(size: 14.5)
    /// Card title (style card, saved command, tip): SF 14.5 / 600.
    static let cardTitle = Font.system(size: 14.5, weight: .semibold)
    /// Tip card and empty-state titles: SF 14 / 600 and 15 / 600.
    static let tipTitle = Font.system(size: 14, weight: .semibold)
    /// Empty state title: SF 15 / 600.
    static let emptyTitle = Font.system(size: 15, weight: .semibold)
    /// Stat card label: SF 13.5 / 560.
    static let statLabel = sf(13.5, weight: 560)
    /// List time column: SF 13 (muted); the app under it is SF 12.
    static let listTime = Font.system(size: 13)
    /// The app name under a list time: SF 12 (muted).
    static let listApp = Font.system(size: 12)

    /// SF Pro at a CSS weight (400 regular … 700 bold). SF is a variable
    /// font, so the design's in-between weights (550, 560, 650) render as
    /// drawn instead of snapping to medium or semibold.
    static func sf(_ size: CGFloat, weight css: Int) -> Font {
        Font(NSFont.systemFont(ofSize: size, weight: NSFont.Weight(rawValue: cssWeight(css))))
    }

    /// Maps a CSS font weight onto AppKit's weight scale, interpolating
    /// between the named weights.
    static func cssWeight(_ css: Int) -> CGFloat {
        let stops: [(css: Int, appKit: CGFloat)] = [
            (100, NSFont.Weight.ultraLight.rawValue), (200, NSFont.Weight.thin.rawValue),
            (300, NSFont.Weight.light.rawValue), (400, NSFont.Weight.regular.rawValue),
            (500, NSFont.Weight.medium.rawValue), (600, NSFont.Weight.semibold.rawValue),
            (700, NSFont.Weight.bold.rawValue), (800, NSFont.Weight.heavy.rawValue),
            (900, NSFont.Weight.black.rawValue),
        ]
        guard let first = stops.first, let last = stops.last else { return 0 }
        if css <= first.css { return first.appKit }
        if css >= last.css { return last.appKit }
        for (lower, upper) in zip(stops, stops.dropFirst()) where css <= upper.css {
            let fraction = CGFloat(css - lower.css) / CGFloat(upper.css - lower.css)
            return lower.appKit + (upper.appKit - lower.appKit) * fraction
        }
        return last.appKit
    }
}

/// A complete text style: font plus the tracking and line spacing the
/// board gives it. Apply with `View.calmType(_:)`.
enum CalmType {
    case title
    case featureTitle
    case sectionSerif
    case bigNumber
    case groupLabel
    case rowTitle
    case body
    case description
    case button
    case caption
    case pageDescription
    case note

    /// The font for this style.
    var font: Font {
        switch self {
        case .title: return CalmFont.title
        case .featureTitle: return CalmFont.featureTitle
        case .sectionSerif: return CalmFont.sectionSerif
        case .bigNumber: return CalmFont.bigNumber
        case .groupLabel: return CalmFont.groupLabel
        case .rowTitle: return CalmFont.rowTitle
        case .body: return CalmFont.body
        case .description: return CalmFont.description
        case .button: return CalmFont.button
        case .caption: return CalmFont.caption
        case .pageDescription: return CalmFont.pageDescription
        case .note: return CalmFont.note
        }
    }

    /// Letter spacing in points (CSS em × size).
    var tracking: CGFloat {
        switch self {
        case .title: return -0.3
        case .featureTitle: return -0.48
        case .caption: return 0.88
        default: return 0
        }
    }

    /// Extra space between lines, matching the CSS line-height.
    var lineSpacing: CGFloat {
        switch self {
        case .body: return 5          // 14 × 1.55 ≈ 21.7 line
        case .description: return 3   // 13 × 1.45 ≈ 18.9 line
        case .note: return 2.5        // 12.5 × 1.5
        case .pageDescription: return 3
        default: return 0
        }
    }

    /// Space above and below the text so a block is as tall as the
    /// design's CSS line box (SwiftUI only adds `lineSpacing` between lines).
    var lineBoxPadding: CGFloat {
        switch self {
        case .body: return 2.5
        case .description, .pageDescription: return 1
        case .title: return 1.5
        default: return 0
        }
    }

    /// Captions are set in capitals.
    var isUppercase: Bool { self == .caption }
}

extension View {
    /// Applies a Calm text style: font, tracking, line spacing and, for
    /// captions, capitals and the muted colour.
    func calmType(_ style: CalmType) -> some View {
        modifier(CalmTypeModifier(style: style))
    }
}

private struct CalmTypeModifier: ViewModifier {
    let style: CalmType

    func body(content: Content) -> some View {
        content
            .font(style.font)
            .tracking(style.tracking)
            .lineSpacing(style.lineSpacing)
            .padding(.vertical, style.lineBoxPadding)
            .textCase(style.isUppercase ? .uppercase : nil)
            .foregroundStyle(style.defaultColor)
    }
}

private extension CalmType {
    var defaultColor: Color {
        switch self {
        case .description, .caption, .pageDescription: return CalmColor.muted
        default: return CalmColor.ink
        }
    }
}

// MARK: - Sizes

/// Sizes and spacing from the Foundations board, in points.
enum CalmMetrics {
    // MARK: Spacing steps

    /// The spacing scale: 4, 8, 10, 12, 14, 18, 22, 24, 26, 40.
    enum Space {
        static let s4: CGFloat = 4
        static let s8: CGFloat = 8
        static let s10: CGFloat = 10
        static let s12: CGFloat = 12
        static let s14: CGFloat = 14
        static let s18: CGFloat = 18
        static let s22: CGFloat = 22
        static let s24: CGFloat = 24
        static let s26: CGFloat = 26
        static let s40: CGFloat = 40
    }

    // MARK: Radii

    /// Corner radii: key 6, small button 8, button 9, content 12, panel 14, sheet 16.
    enum Radius {
        static let key: CGFloat = 6
        static let menuItem: CGFloat = 6
        static let segmentOption: CGFloat = 7
        static let smallButton: CGFloat = 8
        static let iconButton: CGFloat = 8
        static let button: CGFloat = 9
        static let field: CGFloat = 9
        static let nav: CGFloat = 9
        static let menu: CGFloat = 10
        static let content: CGFloat = 12
        static let panel: CGFloat = 14
        static let list: CGFloat = 14
        static let dialog: CGFloat = 14
        static let window: CGFloat = 14
        static let sheet: CGFloat = 16
        static let hero: CGFloat = 16
    }

    // MARK: Window and sidebar

    /// The window opens at this content size.
    static let windowDefaultSize = SettingsWindowGeometry.defaultContentSize
    /// Smallest content size the layout supports; the window's real minimum
    /// is larger on a screen with room (`SettingsWindowGeometry`).
    static let windowMinSize = SettingsWindowGeometry.smallestContentSize
    static let sidebarWidth: CGFloat = 224
    static let sidebarPadding = EdgeInsets(top: 16, leading: 12, bottom: 14, trailing: 12)
    /// Space kept above the brand for the window's traffic lights.
    static let trafficLightReserve: CGFloat = 34
    static let navItemPadding = EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
    static let navItemSpacing: CGFloat = 2
    static let navIconSize: CGFloat = 17
    static let navIconGap: CGFloat = 11
    /// The content area sits inset this far from the window's top, right and bottom.
    static let contentInset: CGFloat = 10

    // MARK: Pages

    /// Page column max width for lists and feeds.
    static let pageMaxWidthList: CGFloat = 940
    /// Page column max width for forms.
    static let pageMaxWidthForm: CGFloat = 860
    static let pageTopPadding: CGFloat = 44
    static let pageSidePadding: CGFloat = 48
    static let pageBottomPadding: CGFloat = 40
    /// Gap between blocks on a page (the board allows 22–26).
    static let pageGap: CGFloat = 26
    /// Gap between a group label and its panel.
    static let groupLabelGap: CGFloat = 10

    // MARK: Settings sheet

    /// The sheet's size in a roomy window; it shrinks to fit a smaller one.
    static let sheetSize = SettingsWindowGeometry.sheetSize
    static let sheetMenuWidth: CGFloat = 236
    static let sheetMenuPadding = EdgeInsets(top: 24, leading: 14, bottom: 16, trailing: 14)
    static let sheetBodyPadding = EdgeInsets(top: 40, leading: 48, bottom: 40, trailing: 48)
    static let sheetGap: CGFloat = 24

    // MARK: Panels, rows, lists

    static let rowInset: CGFloat = 22
    static let rowVerticalPadding: CGFloat = 17
    static let rowSpacing: CGFloat = 16
    static let listRowPadding = EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 18)
    static let listCompactRowPadding = EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 14)
    /// Width of a list's time / app column.
    static let listTimeColumn: CGFloat = 70

    // MARK: Dialogs

    static let dialogWidth: CGFloat = 440
    /// Dialogs that hold a list.
    static let dialogListWidth: CGFloat = 520
    static let confirmDialogWidth: CGFloat = 400
    static let dialogPadding: CGFloat = 24
    static let dialogGap: CGFloat = 18
    /// The least space between a dialog and the window's edges.
    static let dialogWindowMargin: CGFloat = 24
    /// The tallest a list inside a dialog grows before it scrolls.
    static let dialogListMaxHeight: CGFloat = 300

    // MARK: Controls

    static let buttonHeight: CGFloat = 34
    static let buttonPadding: CGFloat = 16
    static let smallButtonHeight: CGFloat = 28
    static let smallButtonPadding: CGFloat = 12
    static let iconButtonSize: CGFloat = 32
    static let switchSize = CGSize(width: 40, height: 24)
    static let switchKnob: CGFloat = 18
    static let segmentHeight: CGFloat = 34
    static let segmentOptionHeight: CGFloat = 28
    static let fieldHeight: CGFloat = 36
    static let multilineFieldMinHeight: CGFloat = 88
    /// Where a multi-line field stops growing and starts to scroll.
    static let multilineFieldMaxHeight: CGFloat = 220
    static let keyCapHeight: CGFloat = 24
    static let keyCapInlineHeight: CGFloat = 21
    static let tagHeight: CGFloat = 22
    static let iconCircle: CGFloat = 28
    static let focusRingWidth: CGFloat = 3

    // MARK: Cards

    static let heroPadding = EdgeInsets(top: 30, leading: 34, bottom: 30, trailing: 34)
    static let heroGap: CGFloat = 14
    /// Below this width a feature card tightens (the 1080-wide window), so
    /// it doesn't take half of a short page.
    static let heroCompactWidth: CGFloat = 780
    static let heroCompactPadding = EdgeInsets(top: 24, leading: 28, bottom: 24, trailing: 28)
    static let heroCompactGap: CGFloat = 12
}
