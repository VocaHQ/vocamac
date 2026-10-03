// Film.swift
// Frame renderer for the VocaMac promo film. Every frame is a pure function of time,
// drawn with Core Graphics: springs, staggered reveals, pop-up callouts, camera moves.

import AppKit
import CoreGraphics

let W: CGFloat = 1920, H: CGFloat = 1080
let FPS = 60
let BAR = Music.bar  // 2.5 s at 96 BPM, so every scene lands on the beat

// MARK: - Palette and easing

enum C {
    static let bg = NSColor(srgbRed: 0.030, green: 0.040, blue: 0.040, alpha: 1)
    static let green = NSColor(srgbRed: 0.49, green: 0.86, blue: 0.75, alpha: 1)
    static let teal = NSColor(srgbRed: 0.30, green: 0.72, blue: 0.80, alpha: 1)
    static let blue = NSColor(srgbRed: 0.35, green: 0.50, blue: 1.0, alpha: 1)
    static let amber = NSColor(srgbRed: 1.0, green: 0.72, blue: 0.30, alpha: 1)
    static let red = NSColor(srgbRed: 1.0, green: 0.42, blue: 0.40, alpha: 1)
    static let dim = NSColor(white: 1, alpha: 0.62)
}

func prog(_ t: Double, _ s: Double, _ d: Double) -> CGFloat { CGFloat(min(1, max(0, (t - s) / d))) }
func eo3(_ x: CGFloat) -> CGFloat { 1 - pow(1 - x, 3) }
func eo5(_ x: CGFloat) -> CGFloat { 1 - pow(1 - x, 5) }
func eio(_ x: CGFloat) -> CGFloat { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
/// Damped spring: overshoots a little, settles by x = 1.
func spring(_ x: CGFloat) -> CGFloat { x >= 1 ? 1 : (x <= 0 ? 0 : 1 - exp(-7 * x) * cos(11 * x)) }
func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

enum Align { case left, center, right }

// MARK: - Film

final class Film {
    let shots: String
    let brand: String
    var images: [String: NSImage] = [:]
    let cg: CGContext
    var g: CGContext { cg }
    var alphaNow: CGFloat = 1
    var alphaStack: [CGFloat] = []
    func saveA() { g.saveGState(); alphaStack.append(alphaNow) }
    func restoreA() { g.restoreGState(); alphaNow = alphaStack.removeLast() }
    func mulAlpha(_ a: CGFloat) { alphaNow *= a; g.setAlpha(alphaNow) }

    init(shots: String, brand: String) {
        self.shots = shots
        self.brand = brand
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        cg = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
        cg.interpolationQuality = .high
        cg.setShouldAntialias(true)
        cg.setAllowsFontSmoothing(false)
    }

    func image(_ name: String) -> NSImage {
        if let i = images[name] { return i }
        let path = FileManager.default.fileExists(atPath: name) ? name : shots + "/" + name
        guard let i = NSImage(contentsOfFile: path) else { fatalError("missing image \(path)") }
        images[name] = i
        return i
    }

    // MARK: Primitives

    func roundRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: r, cornerWidth: min(radius, r.height / 2), cornerHeight: min(radius, r.height / 2), transform: nil)
    }

    func withAlpha(_ a: CGFloat, _ body: () -> Void) {
        saveA(); mulAlpha(a); body(); restoreA()
    }

    /// Draws `body` scaled/rotated/translated about `center`.
    func xform(center: CGPoint, scale: CGFloat = 1, rotate: CGFloat = 0, dx: CGFloat = 0, dy: CGFloat = 0, alpha: CGFloat = 1, _ body: () -> Void) {
        guard alpha > 0.001 else { return }
        saveA()
        mulAlpha(alpha)
        g.translateBy(x: center.x + dx, y: center.y + dy)
        g.rotate(by: rotate)
        g.scaleBy(x: scale, y: scale)
        g.translateBy(x: -center.x, y: -center.y)
        body()
        restoreA()
    }

    @discardableResult
    func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight = .bold, color: NSColor = .white, x: CGFloat, y: CGFloat,
              align: Align = .center, alpha: CGFloat = 1, scale: CGFloat = 1, kern: CGFloat = 0, mono: Bool = false,
              dy: CGFloat = 0, draw: Bool = true) -> CGSize {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
        let a = NSAttributedString(string: s, attributes: attrs)
        let sz = a.size()
        guard draw, alpha > 0.001 else { return sz }
        let left: CGFloat
        switch align {
        case .left: left = x
        case .center: left = x - sz.width / 2
        case .right: left = x - sz.width
        }
        let center = CGPoint(x: left + sz.width / 2, y: y)
        xform(center: center, scale: scale, dy: dy, alpha: alpha) {
            a.draw(at: CGPoint(x: left, y: y - sz.height / 2))
        }
        return sz
    }

    func measure(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight = .bold, kern: CGFloat = 0, mono: Bool = false) -> CGSize {
        text(s, size, weight, x: 0, y: 0, kern: kern, mono: mono, draw: false)
    }

    /// Word-by-word rise-and-fade reveal, the core of the kinetic headlines.
    func reveal(_ words: [(String, NSColor)], _ size: CGFloat, _ weight: NSFont.Weight = .heavy, x: CGFloat, y: CGFloat,
                align: Align = .left, start: Double, stagger: Double = 0.09, lt: Double, kern: CGFloat = -2.5, rise: CGFloat = 40, spaceFactor: CGFloat = 0.26) {
        let space = size * spaceFactor
        let widths = words.map { measure($0.0, size, weight, kern: kern).width }
        let total = widths.reduce(0, +) + space * CGFloat(max(0, words.count - 1))
        var cx: CGFloat
        switch align {
        case .left: cx = x
        case .center: cx = x - total / 2
        case .right: cx = x - total
        }
        for (i, w) in words.enumerated() {
            let p = prog(lt, start + Double(i) * stagger, 0.6)
            let e = eo5(p)
            text(w.0, size, weight, color: w.1, x: cx, y: y, align: .left, alpha: eo3(min(1, p * 2)), scale: 0.92 + 0.08 * e, kern: kern, dy: (1 - e) * rise)
            cx += widths[i] + space
        }
    }

    func fill(_ path: CGPath, _ color: NSColor, alpha: CGFloat = 1) {
        saveA(); mulAlpha(alpha); g.addPath(path); g.setFillColor(color.cgColor); g.fillPath(); restoreA()
    }

    func stroke(_ path: CGPath, _ color: NSColor, width: CGFloat, alpha: CGFloat = 1) {
        saveA(); mulAlpha(alpha); g.addPath(path); g.setStrokeColor(color.cgColor); g.setLineWidth(width); g.strokePath(); restoreA()
    }

    func shadowed(blur: CGFloat = 50, dy: CGFloat = 22, alpha: CGFloat = 0.55, _ body: () -> Void) {
        saveA()
        g.setShadow(offset: CGSize(width: 0, height: -dy), blur: blur, color: NSColor.black.withAlphaComponent(alpha).cgColor)
        body()
        restoreA()
    }

    func radial(_ c: CGPoint, _ r: CGFloat, _ color: NSColor, _ a: CGFloat) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let colors = [color.withAlphaComponent(a).cgColor, color.withAlphaComponent(0).cgColor] as CFArray
        let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
        g.drawRadialGradient(grad, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
    }

    // MARK: Components

    func drawImage(_ name: String, center: CGPoint, height: CGFloat, scale: CGFloat = 1, rotate: CGFloat = 0, alpha: CGFloat = 1,
                   dx: CGFloat = 0, dy: CGFloat = 0, shadow: Bool = true) {
        let im = image(name)
        let k = height / im.size.height
        let size = CGSize(width: im.size.width * k, height: height)
        let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        xform(center: center, scale: scale, rotate: rotate, dx: dx, dy: dy, alpha: alpha) {
            let body = { im.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high]) }
            if shadow { shadowed(body) } else { body() }
        }
    }

    /// Glass pop-up label that springs in. Returns its (unscaled) rect.
    func popupWidth(_ label: String, sub: String? = nil, dot: NSColor? = C.green, size: CGFloat = 34) -> CGFloat {
        let tw = measure(label, size, .semibold).width
        let sw = sub.map { measure($0, size * 0.72, .medium).width } ?? 0
        return max(tw, sw) + size * 1.7 + (dot != nil ? size * 0.9 : 0)
    }

    @discardableResult
    func popup(_ label: String, sub: String? = nil, dot: NSColor? = C.green, cx: CGFloat = 0, left: CGFloat? = nil, cy: CGFloat, start: Double, lt: Double,
               size: CGFloat = 34, alpha: CGFloat = 1) -> CGRect {
        let e = spring(prog(lt, start, 0.6))
        let a = eo3(prog(lt, start, 0.18)) * alpha
        let w = popupWidth(label, sub: sub, dot: dot, size: size)
        let cx = left.map { $0 + w / 2 } ?? cx
        let h = size * (sub == nil ? 2.0 : 2.7)
        let rect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
        xform(center: CGPoint(x: cx, y: cy), scale: 0.55 + 0.45 * e, dy: (1 - e) * 26, alpha: a) {
            shadowed(blur: 34, dy: 14, alpha: 0.5) { fill(roundRect(rect, h / 2), NSColor(srgbRed: 0.10, green: 0.12, blue: 0.12, alpha: 0.96)) }
            stroke(roundRect(rect, h / 2), NSColor(white: 1, alpha: 0.18), width: 1.5)
            var tx = rect.minX + size * 0.85
            if let dot {
                fill(CGPath(ellipseIn: CGRect(x: tx, y: cy - size * 0.2, width: size * 0.4, height: size * 0.4), transform: nil), dot)
                tx += size * 0.9
            }
            if let sub {
                text(label, size, .semibold, x: tx, y: cy - size * 0.36, align: .left)
                text(sub, size * 0.72, .medium, color: C.dim, x: tx, y: cy + size * 0.56, align: .left)
            } else {
                text(label, size, .semibold, x: tx, y: cy, align: .left)
            }
        }
        return rect
    }

    /// A leader line from `from` to `to` with a pulsing target dot.
    func leader(from: CGPoint, to: CGPoint, start: Double, lt: Double, alpha: CGFloat = 1) {
        let p = eio(prog(lt, start, 0.45))
        guard p > 0 else { return }
        let end = CGPoint(x: lerp(from.x, to.x, p), y: lerp(from.y, to.y, p))
        let path = CGMutablePath(); path.move(to: from); path.addLine(to: end)
        saveA(); g.setLineCap(.round); stroke(path, C.green, width: 3, alpha: 0.85 * alpha); restoreA()
        if p >= 1 {
            let pulse = CGFloat((lt - start - 0.45).truncatingRemainder(dividingBy: 1.4) / 1.4)
            fill(CGPath(ellipseIn: CGRect(x: to.x - 7, y: to.y - 7, width: 14, height: 14), transform: nil), C.green, alpha: alpha)
            let r = 7 + 26 * pulse
            stroke(CGPath(ellipseIn: CGRect(x: to.x - r, y: to.y - r, width: 2 * r, height: 2 * r), transform: nil), C.green, width: 2, alpha: (1 - pulse) * 0.7 * alpha)
        }
    }

    /// A settings-window screenshot with spring entrance and an optional zoom into the UI.
    struct Zoom { var start: Double; var dur: Double; var focus: CGPoint; var to: CGFloat }
    func window(_ name: String, center: CGPoint, height: CGFloat, lt: Double, appear: Double, from: CGFloat = 140,
                zoom: Zoom? = nil, rotate: CGFloat = 0) -> (CGPoint) -> CGPoint {
        let im = image(name)
        let k = height / im.size.height
        let size = CGSize(width: im.size.width * k, height: height)
        let origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        let rect = CGRect(origin: origin, size: size)
        let e = spring(prog(lt, appear, 0.85))
        let a = eo3(prog(lt, appear, 0.3))
        let zp = zoom.map { eio(prog(lt, $0.start, $0.dur)) } ?? 0
        let z = zoom.map { 1 + ($0.to - 1) * zp } ?? 1
        let focusScreen = zoom.map { CGPoint(x: origin.x + $0.focus.x * size.width, y: origin.y + $0.focus.y * size.height) } ?? center
        let pivot = CGPoint(x: lerp(focusScreen.x, center.x, zp), y: lerp(focusScreen.y, center.y, zp))
        let map: (CGPoint) -> CGPoint = { p in
            let s = CGPoint(x: origin.x + p.x * k, y: origin.y + p.y * k)
            return CGPoint(x: pivot.x + (s.x - focusScreen.x) * z, y: pivot.y + (s.y - focusScreen.y) * z)
        }
        xform(center: center, scale: 0.9 + 0.1 * e, rotate: rotate, dx: (1 - e) * from, alpha: a) {
            shadowed(blur: 70, dy: 30, alpha: 0.6) {
                im.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            }
            if zp > 0 {
                saveA()
                g.addPath(roundRect(rect, 46 * k)); g.clip()
                g.translateBy(x: pivot.x, y: pivot.y); g.scaleBy(x: z, y: z); g.translateBy(x: -focusScreen.x, y: -focusScreen.y)
                im.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
                restoreA()
            }
        }
        return map
    }

    func ring(_ imgRect: CGRect, map: (CGPoint) -> CGPoint, start: Double, lt: Double, pad: CGFloat = 12) {
        let p = eo3(prog(lt, start, 0.4))
        guard p > 0 else { return }
        let a = map(CGPoint(x: imgRect.minX, y: imgRect.minY)), b = map(CGPoint(x: imgRect.maxX, y: imgRect.maxY))
        let r = CGRect(x: a.x - pad, y: a.y - pad, width: b.x - a.x + 2 * pad, height: b.y - a.y + 2 * pad)
        let pulse = 0.5 + 0.5 * sin(lt * 5)
        shadowed(blur: 30, dy: 0, alpha: 0) {}
        stroke(roundRect(r, 22), C.green, width: 4, alpha: p * (0.65 + 0.35 * CGFloat(pulse)))
        withAlpha(p * 0.12) { fill(roundRect(r, 22), C.green) }
    }

    func background(_ T: Double, tint: CGFloat) {
        C.bg.setFill(); g.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let t = CGFloat(T)
        radial(CGPoint(x: W * (0.72 + 0.12 * sin(t * 0.22)), y: H * (0.40 + 0.10 * cos(t * 0.17))), 980, C.green, 0.17)
        radial(CGPoint(x: W * (0.18 + 0.08 * cos(t * 0.19)), y: H * (0.85 + 0.06 * sin(t * 0.21))), 800, tint == 0 ? C.teal : C.blue, 0.11)
        radial(CGPoint(x: W * 0.5, y: H * 0.0), 700, C.green, 0.06)
    }
}
