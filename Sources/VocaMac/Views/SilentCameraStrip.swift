// SilentCameraStrip.swift
// VocaMac
//
// What Silent Mode shows while the camera is on: the lips as a thin
// outline that brightens as they move, on dark glass by default, or over a
// mirrored camera picture when the user turns that on. Used in the overlay
// (a strip in the live panel, a round badge in the pill) and on the Silent
// Mode settings page, so what Settings previews is what the overlay shows.

import AVFoundation
import AppKit
import SwiftUI

// MARK: - Palette

enum SilentPalette {
    /// The outline: the overlay's dictation mint.
    static let outline = OverlayPalette.mint
    /// A faint halo under the outline so it reads over a bright picture.
    static let halo = Color.white.opacity(0.35)
    /// The tile behind the outline: a shade darker than the overlay's glass.
    static let tile = Color(.sRGB, red: 10 / 255, green: 15 / 255, blue: 13 / 255, opacity: 1)
    static let tileEdge = Color.white.opacity(0.08)
    /// The camera-on dot, as macOS draws its own camera indicator.
    static let cameraDot = Color(.sRGB, red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255, opacity: 1)
}

// MARK: - Outline

/// A closed contour through `points` (unit square, top-left origin),
/// scaled to the shape's rectangle.
struct SilentContourShape: Shape {
    var points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first, points.count >= 3 else { return path }
        func place(_ point: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
        }
        path.move(to: place(first))
        // Smooth through midpoints: Vision's lip points are few, and a
        // polygon reads as jitter at thirty frames a second.
        let placed = points.map(place)
        for index in placed.indices {
            let current = placed[index]
            let next = placed[(index + 1) % placed.count]
            let mid = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
            path.addQuadCurve(to: mid, control: current)
        }
        path.closeSubpath()
        return path
    }
}

/// The lips, drawn with a halo, brightening with `level`.
struct SilentLipsView: View {
    let outer: [CGPoint]
    let inner: [CGPoint]
    let level: Double
    var lineWidth: CGFloat = 1.6

    var body: some View {
        let brightness = 0.55 + 0.45 * min(max(level, 0), 1)
        ZStack {
            SilentContourShape(points: outer)
                .stroke(SilentPalette.halo, lineWidth: lineWidth + 1)
            SilentContourShape(points: outer)
                .stroke(SilentPalette.outline.opacity(0.85 * brightness), lineWidth: lineWidth)
            SilentContourShape(points: inner)
                .stroke(SilentPalette.outline.opacity(0.7 * brightness), lineWidth: lineWidth * 0.75)
        }
        .animation(.linear(duration: 1.0 / 30), value: outer)
        .accessibilityHidden(true)
    }
}

// MARK: - Camera picture

/// The camera picture, mirrored like a mirror, filling its frame.
struct SilentCameraPreview: NSViewRepresentable {
    @ObservedObject var live: SilentLiveState

    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.attach(live.makePreviewLayer?())
        return view
    }

    func updateNSView(_ view: PreviewHostView, context: Context) {
        // The camera may have started after the view appeared.
        if !view.hasPreview, live.phase.isCameraOn { view.attach(live.makePreviewLayer?()) }
    }

    final class PreviewHostView: NSView {
        private var previewLayer: CALayer?
        var hasPreview: Bool { previewLayer != nil }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func attach(_ preview: CALayer?) {
            guard let preview, previewLayer == nil else { return }
            if let capture = preview as? AVCaptureVideoPreviewLayer, let connection = capture.connection,
               connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
            preview.frame = bounds
            layer?.addSublayer(preview)
            previewLayer = preview
        }

        override func layout() {
            super.layout()
            previewLayer?.frame = bounds
        }
    }
}

// MARK: - Face tile

/// The 4:3 tile: the lips centred on glass, or over the camera picture.
struct SilentFaceTile: View {
    @ObservedObject var live: SilentLiveState
    var cornerRadius: CGFloat = 10

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchPulse = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        GeometryReader { proxy in
            ZStack {
                SilentPalette.tile
                if live.showsVideo, live.phase.isCameraOn {
                    SilentCameraPreview(live: live)
                    if let outline = live.outline {
                        let fill = aspectFill(proxy.size)
                        SilentLipsView(
                            outer: outline.outerInImage, inner: outline.innerInImage, level: live.level, lineWidth: 1.4
                        )
                        .frame(width: fill.width, height: fill.height)
                        .offset(x: fill.minX, y: fill.minY)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    }
                } else if let outline = live.outline, live.phase.hasFace {
                    // The outline's unit square stays square in a 4:3 tile.
                    SilentLipsView(outer: outline.outer, inner: outline.inner, level: live.level)
                        .aspectRatio(1, contentMode: .fit)
                        .padding(proxy.size.height * 0.06)
                }
                placeholder
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(SilentPalette.tileEdge, lineWidth: 1))
        .onAppear { searchPulse = true }
    }

    /// The picture's rectangle inside a tile it fills, cropping the overflow.
    private func aspectFill(_ size: CGSize) -> CGRect {
        let aspect = max(live.imageAspect, 0.1)
        let width = max(size.width, size.height * aspect)
        let height = max(size.height, size.width / aspect)
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    @ViewBuilder
    private var placeholder: some View {
        switch live.phase {
        case .off, .starting, .searching:
            // A soft face oval where the face should be, breathing while it looks.
            Ellipse()
                .strokeBorder(Color.white.opacity(0.28), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                .frame(width: 30, height: 40)
                .opacity(reduceMotion ? 0.8 : (searchPulse ? 0.9 : 0.35))
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                    value: searchPulse
                )
                .accessibilityHidden(true)
        case .unavailable:
            Image(systemName: "video.slash")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(OverlayPalette.amber)
                .accessibilityHidden(true)
        case .tracking, .speaking:
            EmptyView()
        }
    }
}

// MARK: - Level and camera indicator

/// The articulation level as a thin bar.
struct SilentLevelBar: View {
    let level: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(SilentPalette.outline)
                    .frame(width: max(3, proxy.size.width * min(max(level, 0), 1)))
            }
        }
        .frame(height: 3)
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }
}

/// "● Camera" while the camera is on.
struct SilentCameraIndicator: View {
    let isOn: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isOn ? SilentPalette.cameraDot : Color.white.opacity(0.3))
                .frame(width: 6, height: 6)
            Text(isOn ? "Camera" : "Camera off")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(OverlayPalette.secondaryText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isOn ? "Camera on" : "Camera off")
    }
}

// MARK: - Overlay pieces

/// The live panel's Silent Mode strip: the face tile beside what the
/// camera is doing.
struct OverlaySilentStrip: View {
    @ObservedObject var live: SilentLiveState

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            SilentFaceTile(live: live)
                .frame(width: OverlayLayout.silentTileSize.width, height: OverlayLayout.silentTileSize.height)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("SILENT")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.1)
                        .foregroundStyle(SilentPalette.outline)
                    Spacer(minLength: 8)
                    SilentCameraIndicator(isOn: live.phase.isCameraOn)
                }
                Text(live.phase.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isProblem ? OverlayPalette.amber : OverlayPalette.text)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(OverlayPalette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                SilentLevelBar(level: live.phase.hasFace ? live.level : 0)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: OverlayLayout.silentTileSize.height)
        .animation(.easeOut(duration: 0.18), value: live.phase)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Silent Mode: \(live.phase.title). \(detail)")
    }

    private var isProblem: Bool {
        if case .unavailable = live.phase { return true }
        return false
    }

    /// Without the camera the recording is an ordinary dictation; say so.
    private var detail: String {
        isProblem ? "\(live.phase.detail) Typing what the microphone hears." : live.phase.detail
    }
}

/// The pill's Silent Mode badge: the lips in a circle, in place of the waveform.
struct OverlaySilentBadge: View {
    @ObservedObject var live: SilentLiveState

    var body: some View {
        ZStack {
            Circle().fill(SilentPalette.tile)
            Circle().strokeBorder(
                live.phase == .speaking ? SilentPalette.outline.opacity(0.6) : SilentPalette.tileEdge,
                lineWidth: 1
            )
            if let outline = live.outline, live.phase.hasFace {
                SilentLipsView(outer: outline.outer, inner: outline.inner, level: live.level, lineWidth: 1.2)
                    .padding(4)
            } else if case .unavailable = live.phase {
                Image(systemName: "video.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(OverlayPalette.amber)
            } else {
                Ellipse()
                    .strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(width: 11, height: 14)
            }
        }
        .frame(width: OverlayLayout.silentBadgeSize, height: OverlayLayout.silentBadgeSize)
        .animation(.easeOut(duration: 0.18), value: live.phase)
        .accessibilityLabel("Silent Mode: \(live.phase.title)")
    }
}

/// The pill's label: "Silent", or what is wrong with the camera.
struct OverlaySilentLabel: View {
    @ObservedObject var live: SilentLiveState

    var body: some View {
        switch live.phase {
        case .unavailable:
            Text("No camera").foregroundStyle(OverlayPalette.amber)
        case .searching:
            Text("Face the camera").foregroundStyle(OverlayPalette.secondaryText)
        default:
            Text("Silent").foregroundStyle(SilentPalette.outline)
        }
    }
}
