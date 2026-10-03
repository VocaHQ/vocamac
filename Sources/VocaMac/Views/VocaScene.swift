// VocaScene.swift
// VocaMac
//
// The painted landscape behind onboarding, the Settings banners and the menu
// header: sky, mountains, a lake and a floating paper waveform, at one of
// four times of day.

import SwiftUI

// MARK: - Mood

/// The time of day a scene is painted at.
enum SceneMood: String, CaseIterable, Sendable {
    case dawn
    case day
    case dusk
    case night

    /// The mood for an hour of the day, 0–23.
    static func forHour(_ hour: Int) -> SceneMood {
        switch hour {
        case 5..<9: return .dawn
        case 9..<17: return .day
        case 17..<20: return .dusk
        default: return .night
        }
    }

    /// The mood outside right now, so the menu header follows the user's day.
    static func current(at date: Date = Date(), calendar: Calendar = .current) -> SceneMood {
        forHour(calendar.component(.hour, from: date))
    }

    var palette: ScenePalette {
        switch self {
        case .dawn:
            return ScenePalette(
                sky: [(0x1F3442, 0), (0x4E6470, 0.36), (0xC98A5A, 0.64), (0xF0C084, 0.78), (0xE7B47C, 1)],
                cloud: Color(hex: 0xFFD6AA).opacity(0.32),
                sunX: 290, sunY: 300, sunRadius: 30, sun: Color(hex: 0xFFE6B8), glow: Color(hex: 0xFFC480),
                far: Color(hex: 0x5A646B), mid: Color(hex: 0x36434A), near: Color(hex: 0x1D2629),
                water: Color(hex: 0x6E7671), paper: Color(hex: 0xF3EFE6), shade: Color(hex: 0x3A2E26),
                hasStars: false
            )
        case .day:
            return ScenePalette(
                sky: [(0x6F98B2, 0), (0x9DBBCB, 0.40), (0xD8E3E4, 0.76), (0xEEF0EA, 1)],
                cloud: Color.white.opacity(0.55),
                sunX: 350, sunY: 236, sunRadius: 22, sun: Color(hex: 0xFFF8E8), glow: .white,
                far: Color(hex: 0x8BA0AB), mid: Color(hex: 0x62798A), near: Color(hex: 0x344A3E),
                water: Color(hex: 0x86A4AF), paper: Color(hex: 0xF7F5EF), shade: Color(hex: 0x2F4650),
                hasStars: false
            )
        case .dusk:
            return ScenePalette(
                sky: [(0x2A2F45, 0), (0x5F4A5C, 0.36), (0xB8664A, 0.66), (0xE39A62, 0.82), (0xD98C5C, 1)],
                cloud: Color(hex: 0xF0966E).opacity(0.3),
                sunX: 290, sunY: 370, sunRadius: 36, sun: Color(hex: 0xFFD9A6), glow: Color(hex: 0xF2A066),
                far: Color(hex: 0x4C4250), mid: Color(hex: 0x33303A), near: Color(hex: 0x1B1A1F),
                water: Color(hex: 0x5E4F52), paper: Color(hex: 0xF3EFE6), shade: Color(hex: 0x2A1C18),
                hasStars: false
            )
        case .night:
            return ScenePalette(
                sky: [(0x0B1316, 0), (0x142126, 0.46), (0x22363C, 0.80), (0x2B4148, 1)],
                cloud: Color(hex: 0x7896A0).opacity(0.12),
                sunX: 360, sunY: 222, sunRadius: 14, sun: Color(hex: 0xE9E4D6), glow: Color(hex: 0xB8664A),
                far: Color(hex: 0x1C2A2F), mid: Color(hex: 0x141F23), near: Color(hex: 0x0B1214),
                water: Color(hex: 0x1A2B30), paper: Color(hex: 0xF3EFE6), shade: Color(hex: 0xB8664A),
                hasStars: true
            )
        }
    }
}

/// Colors and light for one mood.
struct ScenePalette {
    /// Sky gradient stops, top to bottom: hex color and location.
    let sky: [(UInt32, CGFloat)]
    let cloud: Color
    /// Sun (or moon) centre in scene units (the scene is 480 × 600).
    let sunX: CGFloat
    let sunY: CGFloat
    let sunRadius: CGFloat
    let sun: Color
    let glow: Color
    let far: Color
    let mid: Color
    let near: Color
    let water: Color
    let paper: Color
    let shade: Color
    let hasStars: Bool
}

/// Which part of the scene a frame shows.
enum SceneFraming {
    /// The whole landscape with the paper waveform: tall panels.
    case portrait
    /// A strip across the mountains and the lake, without the waveform:
    /// wide, short banners where the waveform would be cropped to stubs.
    case horizon
}

// MARK: - View

/// A painted landscape that fills its frame, cropping like an aspect-fill
/// photo. It moves slowly while `animated` is true — clouds drift, light
/// shimmers on the water, the paper waveform breathes — and holds still
/// otherwise, and always under Reduce Motion.
struct VocaScene: View {
    let mood: SceneMood
    var animated = true
    /// Darken the top and bottom so white text over them stays legible.
    var scrim = true
    var framing: SceneFraming = .portrait

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 30 fps is plenty for motion this slow, and halves the redraws.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated || reduceMotion)) { timeline in
            Canvas { context, size in
                SceneRenderer(
                    palette: mood.palette,
                    time: timeline.date.timeIntervalSinceReferenceDate,
                    scrim: scrim,
                    framing: framing
                )
                .draw(in: &context, size: size)
            }
        }
        // Printed-on-paper grain, like the photographs on the board.
        .overlay {
            Image(nsImage: PaperGrain.tile)
                .resizable(resizingMode: .tile)
                .blendMode(.softLight)
                .opacity(0.22)
                .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Renderer

/// Draws one frame. Scene geometry lives in a 480 × 600 space that is scaled
/// to fill the canvas and centred, so any frame shape crops rather than
/// stretches.
struct SceneRenderer {
    static let sceneSize = CGSize(width: 480, height: 600)
    static let barHeights: [CGFloat] = [40, 70, 110, 150, 180, 140, 96, 64, 36]
    static let stars: [(CGFloat, CGFloat)] = [
        (0.12, 0.09), (0.27, 0.18), (0.44, 0.07), (0.63, 0.15), (0.78, 0.06),
        (0.88, 0.22), (0.06, 0.28), (0.52, 0.26), (0.35, 0.33), (0.70, 0.31),
    ]

    let palette: ScenePalette
    let time: TimeInterval
    let scrim: Bool
    var framing: SceneFraming = .portrait

    /// A 0…1 wave with the given period in seconds.
    private func wave(_ period: Double, phase: Double = 0) -> CGFloat {
        CGFloat(0.5 - 0.5 * cos((time / period + phase) * 2 * .pi))
    }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        let stops = palette.sky.map { Gradient.Stop(color: Color(hex: $0.0), location: $0.1) }
        context.fill(Path(bounds), with: .linearGradient(
            Gradient(stops: stops), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
        ))

        if palette.hasStars {
            for (index, star) in Self.stars.enumerated() {
                let opacity = 0.25 + 0.7 * wave(3.2, phase: Double(index) * 0.37)
                let rect = CGRect(x: star.0 * size.width, y: star.1 * size.height, width: 2, height: 2)
                context.fill(Path(ellipseIn: rect), with: .color(palette.paper.opacity(opacity)))
            }
        }

        drawClouds(in: context, size: size)
        drawWorld(in: context, size: size)

        if scrim {
            context.fill(Path(bounds), with: .linearGradient(
                Gradient(stops: [
                    .init(color: .black.opacity(0.42), location: 0),
                    .init(color: .black.opacity(0), location: 0.36),
                    .init(color: .black.opacity(0), location: 0.60),
                    .init(color: .black.opacity(0.48), location: 1),
                ]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
            ))
        }
    }

    private func drawClouds(in context: GraphicsContext, size: CGSize) {
        var layer = context
        layer.addFilter(.blur(radius: 14))
        let clouds: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, period: Double)] = [
            (-0.10, 0.10, 0.60, 0.09, 92), (0.40, 0.20, 0.50, 0.07, 124), (0.05, 0.30, 0.42, 0.06, 108),
        ]
        for (index, cloud) in clouds.enumerated() {
            let drift = (wave(cloud.period, phase: Double(index) * 0.3) * 0.22 - 0.08) * size.width
            let rect = CGRect(
                x: cloud.x * size.width + drift, y: cloud.y * size.height,
                width: cloud.w * size.width, height: cloud.h * size.height
            )
            layer.fill(Path(ellipseIn: rect), with: .color(palette.cloud))
        }
    }

    private func drawWorld(in context: GraphicsContext, size: CGSize) {
        // A slow push in and out, like a camera breathing.
        let push = 1 + 0.07 * wave(60)
        // Portrait shows the whole 480 × 600 scene; horizon the band around
        // the far shore. Either fills the frame's height, and a frame wider
        // than the band repeats it mirrored sideways, so a wide window reads
        // as one panorama instead of a close-up. A frame narrower than the
        // band fills its width and crops the sides.
        let band = framing == .portrait
            ? CGRect(origin: .zero, size: Self.sceneSize)
            : CGRect(x: 0, y: 320, width: 480, height: 170)
        let scale = size.height / band.height * push
        let tileWidth = band.width * scale
        let tiles = Int(max(0, (size.width / tileWidth - 1) / 2).rounded(.up))
        let sun = framing == .portrait ? CGPoint(x: palette.sunX, y: palette.sunY) : CGPoint(x: 290, y: 334)
        let worlds = (-tiles...tiles).map { index -> (index: Int, context: GraphicsContext) in
            var world = context
            world.translateBy(x: size.width / 2 + CGFloat(index) * tileWidth, y: size.height / 2)
            world.scaleBy(x: index.isMultiple(of: 2) ? scale : -scale, y: scale)
            world.translateBy(x: -band.midX, y: -band.midY)
            return (index, world)
        }
        // Layer by layer across all tiles, so one tile's lake, which runs
        // past its edge, never covers the next tile's shore.
        for world in worlds where world.index == 0 { drawSun(in: world.context, center: sun) }
        for world in worlds { drawBackdrop(in: world.context) }
        for world in worlds { drawForeground(in: world.context) }
        if framing == .portrait, let center = worlds.first(where: { $0.index == 0 }) {
            drawWaveform(in: center.context)
        }
    }

    private func drawSun(in world: GraphicsContext, center: CGPoint) {
        let glowStrength = 0.30 + 0.14 * wave(7)
        world.fill(circle(center, 150), with: .radialGradient(
            Gradient(colors: [palette.glow.opacity(glowStrength), palette.glow.opacity(0)]),
            center: center, startRadius: palette.sunRadius * 0.6, endRadius: 150
        ))
        world.fill(circle(center, palette.sunRadius), with: .color(palette.sun))
    }

    /// Ridges and the lake, in scene units.
    private func drawBackdrop(in world: GraphicsContext) {
        world.fill(ridge([
            (0, 400), (40, 362), (80, 380), (130, 328), (170, 366), (210, 340), (260, 372),
            (300, 334), (350, 362), (400, 318), (440, 350), (480, 330),
        ], base: 452), with: .color(palette.far))
        world.fill(ridge([
            (0, 432), (50, 396), (95, 420), (150, 386), (200, 426), (240, 404), (290, 432),
            (340, 398), (390, 428), (440, 404), (480, 420),
        ], base: 452), with: .color(palette.mid))
        world.fill(Path(CGRect(x: -40, y: 446, width: 560, height: 154)), with: .color(palette.water))
        // Sky light caught on the water near the far shore.
        world.fill(Path(CGRect(x: -40, y: 446, width: 560, height: 70)), with: .linearGradient(
            Gradient(colors: [palette.glow.opacity(0.22), palette.glow.opacity(0)]),
            startPoint: CGPoint(x: 0, y: 446), endPoint: CGPoint(x: 0, y: 516)
        ))

    }

    /// Glints on the water, the island and the near shore, in scene units.
    private func drawForeground(in world: GraphicsContext) {
        let glints: [(CGRect, Double, Double)] = [
            (CGRect(x: 262, y: 452, width: 56, height: 3), 3.6, 0),
            (CGRect(x: 250, y: 462, width: 80, height: 2), 4.4, 0.3),
            (CGRect(x: 270, y: 472, width: 40, height: 2), 5.2, 0.55),
            (CGRect(x: 236, y: 484, width: 30, height: 1.5), 4.4, 0.8),
        ]
        for (rect, period, phase) in glints {
            let opacity = 0.25 + 0.55 * wave(period, phase: phase)
            world.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2), with: .color(palette.sun.opacity(opacity)))
        }

        var island = Path()
        island.move(to: CGPoint(x: 310, y: 478))
        island.addCurve(to: CGPoint(x: 404, y: 478), control1: CGPoint(x: 335, y: 466), control2: CGPoint(x: 372, y: 466))
        island.closeSubpath()
        world.fill(island, with: .color(palette.near))

        var shore = Path()
        shore.move(to: CGPoint(x: 0, y: 512))
        shore.addCurve(to: CGPoint(x: 168, y: 522), control1: CGPoint(x: 60, y: 486), control2: CGPoint(x: 118, y: 496))
        shore.addCurve(to: CGPoint(x: 262, y: 600), control1: CGPoint(x: 206, y: 542), control2: CGPoint(x: 236, y: 566))
        shore.addLine(to: CGPoint(x: 0, y: 600))
        shore.closeSubpath()
        world.fill(shore, with: .color(palette.near))

    }

    /// The paper waveform floating above the lake: nine rounded bars that
    /// breathe out of step with each other, with a soft shadow beneath.
    private func drawWaveform(in context: GraphicsContext) {
        let float = -8 * wave(7)
        let centerY: CGFloat = 384 + float
        for pass in 0..<2 {
            let isShadow = pass == 0
            for (index, height) in Self.barHeights.enumerated() {
                let breathe = 1 - 0.42 * wave(2.6, phase: Double(index) * 0.115)
                let barHeight = height * 0.7 * breathe
                var rect = CGRect(
                    x: 176 + CGFloat(index) * 17, y: centerY - barHeight / 2,
                    width: 9, height: barHeight
                )
                if isShadow { rect = rect.offsetBy(dx: 3, dy: 7) }
                let color = isShadow ? palette.shade.opacity(0.45) : palette.paper
                context.fill(Path(roundedRect: rect, cornerRadius: 4.5), with: .color(color))
            }
        }
    }

    private func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    /// A filled ridge line. It runs one point past each edge as its own
    /// mirror image, so mirrored neighbouring tiles overlap exactly rather
    /// than meeting at a seam.
    private func ridge(_ points: [(CGFloat, CGFloat)], base: CGFloat) -> Path {
        var path = Path()
        guard points.count > 2, let first = points.first, let last = points.last else { return path }
        let second = points[1]
        let penultimate = points[points.count - 2]
        let extended = [(2 * first.0 - second.0, second.1)] + points + [(2 * last.0 - penultimate.0, penultimate.1)]
        path.move(to: CGPoint(x: extended[0].0, y: base))
        for point in extended { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
        path.addLine(to: CGPoint(x: extended[extended.count - 1].0, y: base))
        path.closeSubpath()
        return path
    }
}

// MARK: - Color

extension Color {
    /// An sRGB color from a 0xRRGGBB literal.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Banner

/// A page title set on a strip of scenery: the Settings page header.
///
/// The scene moves for a few seconds when the page opens and then holds
/// still, so an open Settings window costs nothing while it sits there.
struct VocaSceneBanner: View {
    let title: String
    let mood: SceneMood
    var height: CGFloat = 96

    @State private var isMoving = true

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            VocaScene(mood: mood, animated: isMoving, framing: .horizon)
            Text(title)
                .font(VocaDesign.display(32))
                .foregroundStyle(Color(nsColor: VocaPalette.ivory))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 1)
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(VocaDesign.line))
        .task(id: title) {
            isMoving = true
            try? await Task.sleep(for: .seconds(6))
            isMoving = false
        }
    }
}
