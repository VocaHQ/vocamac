// Scenes.swift
// The storyboard: eleven scenes on a 96 BPM grid (two bars, 5 s, each; the finale is four bars).

import AppKit
import CoreGraphics

extension Film {
    struct Scene { let start: Double; let dur: Double; let exit: Double; let draw: (Film, Double) -> Void }

    static let scenes: [Scene] = [
        Scene(start: 0, dur: 5, exit: 0.35) { $0.intro($1) },
        Scene(start: 5, dur: 5, exit: 0.35) { $0.hold($1) },
        Scene(start: 10, dur: 5, exit: 0.35) { $0.popover($1) },
        Scene(start: 15, dur: 5, exit: 0.35) { $0.models($1) },
        Scene(start: 20, dur: 5, exit: 0.35) { $0.styles($1) },
        Scene(start: 25, dur: 5, exit: 0.35) { $0.cleanup($1) },
        Scene(start: 30, dur: 5, exit: 0.35) { $0.dictionary($1) },
        Scene(start: 35, dur: 5, exit: 0.35) { $0.history($1) },
        Scene(start: 40, dur: 5, exit: 0.35) { $0.stats($1) },
        Scene(start: 45, dur: 5, exit: 0.35) { $0.privacy($1) },
        Scene(start: 50, dur: 10, exit: 1.2) { $0.finale($1) },
    ]

    /// Renders the frame at global time `T` into `cg`.
    func frame(at T: Double) {
        alphaNow = 1; alphaStack = []; g.setAlpha(1)
        saveA()
        g.translateBy(x: 0, y: H); g.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: g, flipped: true)
        let idx = Film.scenes.lastIndex { T >= $0.start } ?? 0
        let sc = Film.scenes[idx]
        let lt = T - sc.start
        background(T, tint: CGFloat(idx % 2))
        let entry = eo3(prog(lt, 0, 0.9))
        let exit = eio(prog(lt, sc.dur - sc.exit, sc.exit))
        let cam = (1.03 - 0.03 * entry) + 0.02 * CGFloat(lt / sc.dur) - 0.035 * exit
        xform(center: CGPoint(x: W / 2, y: H / 2), scale: cam, alpha: min(1, CGFloat(lt) / 0.12) * (1 - exit)) {
            sc.draw(self, lt)
        }
        restoreA()
    }

    // MARK: 1. Intro

    func intro(_ lt: Double) {
        let c = CGPoint(x: W / 2, y: 400)
        for i in 0..<3 {
            let p = prog(lt, 0.5 + Double(i) * 0.4, 1.8)
            let r = 120 + 420 * eo3(p)
            stroke(CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil), C.green, width: 3, alpha: (1 - p) * 0.55 * (p > 0 ? 1 : 0))
        }
        let e = spring(prog(lt, 0.25, 0.95))
        radial(c, 420, C.green, 0.25 * eo3(prog(lt, 0.3, 1.0)))
        xform(center: c, scale: 0.2 + 0.8 * e, rotate: (1 - e) * -0.5, alpha: eo3(prog(lt, 0.25, 0.25))) {
            drawImage(brand, center: c, height: 240, shadow: true)
        }
        let letters = Array("VocaMac").map { (String($0), NSColor.white) }
        reveal(letters, 160, .heavy, x: W / 2, y: 650, align: .center, start: 1.1, stagger: 0.07, lt: lt, kern: -3, rise: 60, spaceFactor: 0)
        reveal([("Your", C.dim), ("voice,", C.dim), ("your", C.dim), ("Mac,", C.dim), ("your", C.dim), ("privacy.", C.green)],
               44, .medium, x: W / 2, y: 770, align: .center, start: 2.3, stagger: 0.12, lt: lt, kern: 0, rise: 24)
    }

    // MARK: 2. Hold a key. Speak.

    func hold(_ lt: Double) {
        reveal([("Hold", .white), ("a", .white), ("key.", .white)], 122, x: 140, y: 290, start: 0.3, lt: lt)
        reveal([("Speak.", C.green)], 122, x: 140, y: 430, start: 1.0, lt: lt)
        reveal([("Push-to-talk.", C.dim), ("Release", C.dim), ("to", C.dim), ("transcribe.", C.dim)], 36, .medium, x: 140, y: 545, start: 1.7, stagger: 0.07, lt: lt, kern: 0, rise: 20)

        // Key cap
        let kc = CGPoint(x: 300, y: 790)
        let appear = spring(prog(lt, 1.2, 0.7))
        let press = spring(prog(lt, 1.9, 0.3)) * (1 - eo3(prog(lt, 4.2, 0.25)))
        radial(kc, 340, C.green, 0.45 * press)
        for i in 0..<3 {
            let ph = CGFloat(((lt - 1.9) * 0.85 + Double(i) / 3).truncatingRemainder(dividingBy: 1))
            if lt > 1.9 && lt < 4.4 {
                let r = 130 + 190 * ph
                stroke(CGPath(ellipseIn: CGRect(x: kc.x - r, y: kc.y - r, width: 2 * r, height: 2 * r), transform: nil), C.green, width: 3, alpha: (1 - ph) * 0.55 * press)
            }
        }
        xform(center: kc, scale: (0.4 + 0.6 * appear) * (1 - 0.06 * press), dy: 10 * press, alpha: eo3(prog(lt, 1.2, 0.2))) {
            let r = CGRect(x: kc.x - 115, y: kc.y - 115, width: 230, height: 230)
            shadowed(blur: 40, dy: 18 - 10 * press, alpha: 0.6) { fill(roundRect(r, 48), NSColor(srgbRed: 0.17, green: 0.19, blue: 0.19, alpha: 1)) }
            stroke(roundRect(r, 48), NSColor(white: 1, alpha: 0.14 + 0.35 * press), width: 2)
            withAlpha(press * 0.9) { stroke(roundRect(r, 48), C.green, width: 4) }
            text("⌥", 120, .light, x: kc.x, y: kc.y - 8)
            text("option", 26, .medium, color: C.dim, x: r.minX + 28, y: r.maxY - 34, align: .left)
        }
        text("Hold Right Option", 30, .medium, color: C.dim, x: kc.x, y: 950, alpha: eo3(prog(lt, 1.6, 0.4)))

        // Document card
        let card = CGRect(x: 930, y: 200, width: 850, height: 560)
        let ce = spring(prog(lt, 0.7, 0.85))
        xform(center: CGPoint(x: card.midX, y: card.midY), scale: 0.92 + 0.08 * ce, dx: (1 - ce) * 130, alpha: eo3(prog(lt, 0.7, 0.3))) {
            shadowed(blur: 70, dy: 30, alpha: 0.6) { fill(roundRect(card, 30), NSColor(srgbRed: 0.085, green: 0.095, blue: 0.095, alpha: 1)) }
            stroke(roundRect(card, 30), NSColor(white: 1, alpha: 0.10), width: 1.5)
            for (i, col) in [C.red, C.amber, C.green].enumerated() {
                fill(CGPath(ellipseIn: CGRect(x: card.minX + 30 + CGFloat(i) * 32, y: card.minY + 28, width: 18, height: 18), transform: nil), col, alpha: 0.9)
            }
            text("Standup notes", 26, .medium, color: C.dim, x: card.midX, y: card.minY + 37)
            let words = "Meeting notes for tomorrow morning standup: three items — the release, the docs, and the website.".split(separator: " ").map(String.init)
            flow(words, 40, x: card.minX + 44, y: card.minY + 130, maxWidth: card.width - 88, lineHeight: 66, start: 4.3, stagger: 0.055, lt: lt)
            let caretOn = Int(lt * 2) % 2 == 0 || lt < 4.3
            if caretOn && lt > 1.4 {
                let cy = card.minY + 130 + (lt > 5 ? 66 : 0)
                _ = cy
                withAlpha(lt > 4.3 ? 0 : 1) { fill(CGPath(rect: CGRect(x: card.minX + 44, y: card.minY + 108, width: 4, height: 46), transform: nil), C.green) }
            }
        }

        // Recording pill over the card while the key is held
        let pillIn = spring(prog(lt, 2.0, 0.6)), pillOut = eo3(prog(lt, 4.15, 0.25))
        if lt > 2.0 && pillOut < 1 {
            recordingPill(center: CGPoint(x: card.midX, y: card.maxY - 110), scale: (0.5 + 0.5 * pillIn) * (1 - 0.3 * pillOut), alpha: (1 - pillOut) * eo3(prog(lt, 2.0, 0.15)), lt: lt)
        }
    }

    func recordingPill(center: CGPoint, scale: CGFloat, alpha: CGFloat, lt: Double) {
        xform(center: center, scale: scale, alpha: alpha) {
            let r = CGRect(x: center.x - 170, y: center.y - 48, width: 340, height: 96)
            shadowed(blur: 40, dy: 16, alpha: 0.6) { fill(roundRect(r, 48), NSColor(srgbRed: 0.15, green: 0.16, blue: 0.16, alpha: 1)) }
            stroke(roundRect(r, 48), C.green, width: 4)
            let mic = CGPoint(x: r.minX + 62, y: center.y)
            fill(CGPath(ellipseIn: CGRect(x: mic.x - 34, y: mic.y - 34, width: 68, height: 68), transform: nil), NSColor(white: 1, alpha: 0.08))
            // simple mic glyph
            fill(roundRect(CGRect(x: mic.x - 7, y: mic.y - 19, width: 14, height: 26), 7), C.green)
            let arc = CGMutablePath(); arc.addArc(center: CGPoint(x: mic.x, y: mic.y - 2), radius: 13, startAngle: 0, endAngle: .pi, clockwise: false)
            saveA(); g.setLineCap(.round); stroke(arc, C.green, width: 3.5); restoreA()
            fill(CGPath(rect: CGRect(x: mic.x - 1.8, y: mic.y + 11, width: 3.6, height: 8), transform: nil), C.green)
            let profile: [CGFloat] = [0.42, 0.68, 0.92, 0.70, 1.0, 0.78, 0.88, 0.60, 0.38]
            for i in 0..<9 {
                let amp = 0.35 + 0.65 * abs(sin(CGFloat(lt) * 8.5 + CGFloat(i) * 0.95))
                let h = 8 + 44 * profile[i] * amp
                fill(roundRect(CGRect(x: r.minX + 128 + CGFloat(i) * 21, y: center.y - h / 2, width: 9, height: h), 4.5), C.green)
            }
        }
    }

    /// Wraps words into lines and pops each in.
    func flow(_ words: [String], _ size: CGFloat, x: CGFloat, y: CGFloat, maxWidth: CGFloat, lineHeight: CGFloat, start: Double, stagger: Double, lt: Double,
              color: NSColor = NSColor(white: 0.93, alpha: 1)) {
        let space = size * 0.28
        var cx: CGFloat = 0, cy: CGFloat = 0
        for (i, w) in words.enumerated() {
            let ww = measure(w, size, .regular).width
            if cx + ww > maxWidth { cx = 0; cy += lineHeight }
            let p = prog(lt, start + Double(i) * stagger, 0.35)
            text(w, size, .regular, color: color, x: x + cx, y: y + cy, align: .left, alpha: eo3(p), scale: 0.96 + 0.04 * eo3(p), dy: (1 - eo3(p)) * 14)
            cx += ww + space
        }
    }

    // MARK: 3. Popover

    func popover(_ lt: Double) {
        reveal([("Everything", .white)], 100, x: 140, y: 290, start: 0.3, lt: lt)
        reveal([("at", .white), ("a", .white), ("glance.", C.green)], 100, x: 140, y: 425, start: 0.55, lt: lt)
        reveal([("Status,", C.dim), ("model,", C.dim), ("mic,", C.dim), ("last", C.dim), ("dictation.", C.dim)],
               34, .medium, x: 140, y: 545, start: 1.2, stagger: 0.07, lt: lt, kern: 0, rise: 18)

        let center = CGPoint(x: 1130, y: 545)
        let e = spring(prog(lt, 0.4, 0.9))
        let k: CGFloat = 820 / 990
        let top = center.y - 410
        drawImage("popover-panel.png", center: center, height: 820, scale: 0.86 + 0.14 * e, alpha: eo3(prog(lt, 0.4, 0.25)), dy: (1 - e) * -170)
        let edge = center.x + 380 * k + 6
        let rows: [(String, String, CGFloat, Double)] = [("Active model", "Parakeet v3", 60, 1.6), ("Microphone and style", "Applies to your next dictation", 293, 2.2), ("Last dictation", "Copy it in one click", 545, 2.8)]
        for (label, sub, imgY, s) in rows {
            let ty = top + imgY * k
            let r = popup(label, sub: sub, cx: 1700, cy: ty + 20, start: s, lt: lt, size: 32)
            leader(from: CGPoint(x: r.minX, y: r.midY), to: CGPoint(x: edge - 40, y: ty), start: s + 0.2, lt: lt)
        }
    }

    // MARK: 4. Engines

    func models(_ lt: Double) {
        reveal([("Pick", .white), ("your", .white)], 100, x: 140, y: 260, start: 0.3, lt: lt)
        reveal([("engine.", C.green)], 100, x: 140, y: 390, start: 0.6, lt: lt)
        reveal([("Local", C.dim), ("engines", C.dim), ("run", C.dim), ("on", C.dim), ("your", C.dim), ("Mac.", C.dim)], 34, .medium, x: 140, y: 500, start: 1.0, stagger: 0.07, lt: lt, kern: 0, rise: 18)
        let engines: [(String, NSColor)] = [("Whisper", C.blue), ("Parakeet", C.green), ("Apple Speech", NSColor(white: 0.9, alpha: 1)), ("ONNX models", C.amber)]
        for (i, en) in engines.enumerated() {
            popup(en.0, dot: en.1, left: 140, cy: 610 + CGFloat(i) * 92, start: 1.3 + Double(i) * 0.25, lt: lt, size: 36)
        }
        let map = window("settings-models.png", center: CGPoint(x: 1400, y: 545), height: 900, lt: lt, appear: 0.5,
                         zoom: Zoom(start: 2.9, dur: 0.9, focus: CGPoint(x: 0.55, y: 0.61), to: 1.5))
        ring(CGRect(x: 505, y: 925, width: 1150, height: 172), map: map, start: 3.7, lt: lt)
        popup("In use: Parakeet v3", sub: "Runs on the Neural Engine", cx: 1400, cy: 1000, start: 3.9, lt: lt, size: 30)
    }

    // MARK: 5. Writing styles

    func styles(_ lt: Double) {
        reveal([("Every", .white), ("app,", .white)], 100, x: 140, y: 260, start: 0.3, lt: lt)
        reveal([("its", C.green), ("own", C.green), ("style.", C.green)], 100, x: 140, y: 390, start: 0.6, lt: lt)
        reveal([("Code", C.dim), ("stays", C.dim), ("code.", C.dim), ("Email", C.dim), ("reads", C.dim), ("like", C.dim), ("email.", C.dim)], 34, .medium, x: 140, y: 500, start: 1.0, stagger: 0.07, lt: lt, kern: 0, rise: 18)
        let rows: [(String, NSColor)] = [("Xcode  →  Code", C.green), ("Terminal  →  Terminal", C.amber), ("Messages  →  Chat", C.blue), ("Mail  →  Email", C.teal), ("Notes  →  Notes", NSColor(white: 0.92, alpha: 1))]
        for (i, r) in rows.enumerated() {
            popup(r.0, dot: r.1, left: 140, cy: 590 + CGFloat(i) * 84, start: 1.3 + Double(i) * 0.25, lt: lt, size: 32)
        }
        let map = window("settings-writing-styles.png", center: CGPoint(x: 1400, y: 545), height: 900, lt: lt, appear: 0.5,
                         zoom: Zoom(start: 3.0, dur: 0.9, focus: CGPoint(x: 0.55, y: 0.62), to: 1.32))
        ring(CGRect(x: 483, y: 776, width: 1196, height: 590), map: map, start: 3.8, lt: lt, pad: 8)
    }

    // MARK: 6. Cleanup

    func cleanup(_ lt: Double) {
        withAlpha(1 - eo3(prog(lt, 2.7, 0.3))) {
            reveal([("Say", .white), ("it", .white), ("messy.", .white)], 104, x: W / 2, y: 165, align: .center, start: 0.3, lt: lt)
        }
        reveal([("Type", C.green), ("it", C.green), ("clean.", C.green)], 104, x: W / 2, y: 165, align: .center, start: 3.0, lt: lt)
        // The first headline hands over to the second.
        let cx = W / 2
        let a = eo3(prog(lt, 0.9, 0.5))
        text("YOU SAY", 24, .semibold, color: C.dim, x: cx, y: 350, alpha: a, kern: 5)
        let parts: [(String, Bool)] = [("um so ", true), ("I think we should ship the fix ", false), ("tomorrow, oh no, ", true), ("Wednesday", false)]
        let size: CGFloat = 52
        let widths = parts.map { measure($0.0, size, .medium).width }
        let total = widths.reduce(0, +)
        var x = cx - total / 2
        let strike = eio(prog(lt, 2.0, 0.5)), fade = eo3(prog(lt, 2.5, 0.5))
        for (i, p) in parts.enumerated() {
            let col: NSColor = p.1 ? NSColor(white: 1, alpha: 1 - 0.72 * fade) : .white
            text(p.0, size, .medium, color: p.1 && strike > 0 ? C.red : col, x: x, y: 430, align: .left, alpha: a, dy: (1 - a) * 20)
            if p.1 && strike > 0 {
                let w = measure(p.0.trimmingCharacters(in: .whitespaces), size, .medium).width
                let path = CGMutablePath(); path.move(to: CGPoint(x: x, y: 432)); path.addLine(to: CGPoint(x: x + w * strike, y: 432))
                saveA(); g.setLineCap(.round); stroke(path, C.red, width: 5, alpha: (1 - 0.6 * fade) * a); restoreA()
            }
            x += widths[i]
        }
        // Arrow
        let ap = eo3(prog(lt, 2.6, 0.5))
        if ap > 0 {
            let top: CGFloat = 500, bottom = top + 70 * ap
            let path = CGMutablePath(); path.move(to: CGPoint(x: cx, y: top)); path.addLine(to: CGPoint(x: cx, y: bottom))
            path.move(to: CGPoint(x: cx - 18, y: bottom - 18)); path.addLine(to: CGPoint(x: cx, y: bottom)); path.addLine(to: CGPoint(x: cx + 18, y: bottom - 18))
            saveA(); g.setLineCap(.round); g.setLineJoin(.round); stroke(path, C.green, width: 5, alpha: ap); restoreA()
        }
        text("VOCAMAC TYPES", 24, .semibold, color: C.green, x: cx, y: 630, alpha: eo3(prog(lt, 3.0, 0.4)), kern: 5)
        let e = eo3(prog(lt, 3.0, 0.5))
        radial(CGPoint(x: cx, y: 715), 520, C.green, 0.22 * e)
        reveal("I think we should ship the fix Wednesday.".split(separator: " ").map { (String($0), NSColor.white) }, 68, .bold, x: cx, y: 715, align: .center, start: 3.1, stagger: 0.09, lt: lt, kern: -1, rise: 28)
        popup("On-device Smart Cleanup", sub: "Fillers, repeats and spoken corrections, resolved locally", cx: cx, cy: 890, start: 3.9, lt: lt, size: 32)
    }

    // MARK: 7. Dictionary

    func dictionary(_ lt: Double) {
        drawImage("settings-dictionary.png", center: CGPoint(x: 1420, y: 540), height: 980, alpha: 0.06 * eo3(prog(lt, 0.2, 0.6)), shadow: false)
        reveal([("Your", .white), ("words,", .white)], 92, x: 140, y: 260, start: 0.3, lt: lt)
        reveal([("spelled", C.green), ("your", C.green), ("way.", C.green)], 92, x: 140, y: 385, start: 0.6, lt: lt)
        reveal([("Works", C.dim), ("with", C.dim), ("every", C.dim), ("speech", C.dim), ("engine.", C.dim)], 34, .medium, x: 140, y: 495, start: 1.1, stagger: 0.08, lt: lt, kern: 0, rise: 18)
        let pairs = [("get hub", "GitHub"), ("voca mac", "VocaMac"), ("swift ui", "SwiftUI"), ("core ml", "Core ML")]
        for (i, p) in pairs.enumerated() {
            let s = 0.8 + Double(i) * 0.32
            let e = spring(prog(lt, s, 0.7))
            let card = CGRect(x: 1070, y: 210 + CGFloat(i) * 172, width: 720, height: 132)
            xform(center: CGPoint(x: card.midX, y: card.midY), scale: 0.9 + 0.1 * e, dx: (1 - e) * 150, alpha: eo3(prog(lt, s, 0.25))) {
                shadowed(blur: 50, dy: 22, alpha: 0.5) { fill(roundRect(card, 34), NSColor(srgbRed: 0.10, green: 0.115, blue: 0.115, alpha: 0.97)) }
                stroke(roundRect(card, 34), NSColor(white: 1, alpha: 0.12), width: 1.5)
                let fix = eio(prog(lt, s + 0.55, 0.35))
                text(p.0, 40, .medium, color: NSColor(white: 1, alpha: 0.85 - 0.5 * fix), x: card.minX + 44, y: card.midY, align: .left)
                let w = measure(p.0, 40, .medium).width
                if fix > 0 {
                    let path = CGMutablePath(); path.move(to: CGPoint(x: card.minX + 44, y: card.midY + 2)); path.addLine(to: CGPoint(x: card.minX + 44 + w * fix, y: card.midY + 2))
                    saveA(); g.setLineCap(.round); stroke(path, C.red, width: 4, alpha: 0.8); restoreA()
                }
                text("→", 44, .semibold, color: C.green, x: card.midX - 20, y: card.midY, alpha: eo3(prog(lt, s + 0.45, 0.3)))
                let pop = spring(prog(lt, s + 0.7, 0.55))
                text(p.1, 52, .bold, x: card.maxX - 50, y: card.midY, align: .right, alpha: eo3(prog(lt, s + 0.7, 0.2)), scale: 0.7 + 0.3 * pop)
            }
        }
    }

    // MARK: 8. History

    func history(_ lt: Double) {
        reveal([("Never", .white), ("lose", .white)], 100, x: 140, y: 260, start: 0.3, lt: lt)
        reveal([("what", C.green), ("you", C.green), ("said.", C.green)], 100, x: 140, y: 385, start: 0.6, lt: lt)
        reveal([("Saved", C.dim), ("before", C.dim), ("it", C.dim), ("is", C.dim), ("transcribed.", C.dim)], 34, .medium, x: 140, y: 495, start: 1.1, stagger: 0.08, lt: lt, kern: 0, rise: 18)
        let chips: [(String, Double, Int)] = [("Search", 1.4, 0), ("Replay", 1.65, 0), ("Retry", 1.9, 0), ("Copy", 2.15, 1), ("Stored on your Mac", 2.4, 1)]
        var xs: [CGFloat] = [140, 140]
        for c in chips {
            let w = popupWidth(c.0, size: 34)
            popup(c.0, left: xs[c.2], cy: 600 + CGFloat(c.2) * 96, start: c.1, lt: lt, size: 34)
            xs[c.2] += w + 22
        }
        let map = window("settings-history.png", center: CGPoint(x: 1400, y: 545), height: 900, lt: lt, appear: 0.5,
                         zoom: Zoom(start: 3.0, dur: 0.9, focus: CGPoint(x: 0.55, y: 0.64), to: 1.35))
        ring(CGRect(x: 483, y: 800, width: 1196, height: 236), map: map, start: 3.8, lt: lt, pad: 8)
    }

    // MARK: 9. Stats

    func stats(_ lt: Double) {
        reveal([("Stats", .white), ("that", .white), ("stay", .white), ("local.", C.green)], 104, x: W / 2, y: 160, align: .center, start: 0.3, lt: lt)
        let cards: [(Double, String, String, Double)] = [(48260, "", "words dictated", 0.9), (148, "", "words per minute", 1.15), (9, " days", "current streak", 1.4)]
        for (i, c) in cards.enumerated() {
            let cx = 480 + CGFloat(i) * 480
            let e = spring(prog(lt, c.3, 0.7))
            let rect = CGRect(x: cx - 220, y: 300, width: 440, height: 280)
            xform(center: CGPoint(x: cx, y: 440), scale: 0.85 + 0.15 * e, dy: (1 - e) * 60, alpha: eo3(prog(lt, c.3, 0.25))) {
                shadowed(blur: 50, dy: 22, alpha: 0.5) { fill(roundRect(rect, 40), NSColor(srgbRed: 0.10, green: 0.115, blue: 0.115, alpha: 0.97)) }
                stroke(roundRect(rect, 40), NSColor(white: 1, alpha: 0.12), width: 1.5)
                let v = c.0 * Double(eo3(prog(lt, c.3 + 0.2, 1.4)))
                let f = NumberFormatter(); f.numberStyle = .decimal
                let s = (f.string(from: NSNumber(value: Int(v.rounded()))) ?? "0")
                text(s, 96, .heavy, x: cx, y: 425, kern: -2)
                if !c.1.isEmpty { text(c.1, 34, .semibold, color: C.green, x: cx + measure(s, 96, .heavy, kern: -2).width / 2 + 58, y: 445) }
                text(c.2, 30, .medium, color: C.dim, x: cx, y: 520)
            }
        }
        // Activity bars
        let data: [CGFloat] = [412, 655, 320, 890, 1204, 733, 1510, 968, 1122, 640, 1375, 1890, 1042, 1268]
        let base: CGFloat = 900, maxH: CGFloat = 200
        text("LAST 14 DAYS", 22, .semibold, color: C.dim, x: W / 2, y: 965, alpha: eo3(prog(lt, 2.2, 0.4)), kern: 5)
        for (i, d) in data.enumerated() {
            let p = eo5(prog(lt, 2.0 + Double(i) * 0.06, 0.7))
            let h = max(6, d / 1890 * maxH) * p
            let x = W / 2 - CGFloat(data.count) * 46 / 2 + CGFloat(i) * 46
            fill(roundRect(CGRect(x: x, y: base - h, width: 30, height: h), 9), C.green, alpha: i == data.count - 1 ? 1 : 0.45)
        }
        text("Stored on your Mac. Never uploaded.", 32, .medium, color: C.dim, x: W / 2, y: 1030, alpha: eo3(prog(lt, 3.2, 0.5)))
    }

    // MARK: 10. Privacy

    func privacy(_ lt: Double) {
        let c = CGPoint(x: W / 2, y: 330)
        for i in 0..<3 {
            let p = prog(lt, 0.4 + Double(i) * 0.5, 2.0)
            let r = 110 + 260 * eo3(p)
            stroke(CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil), C.green, width: 3, alpha: (1 - p) * 0.5 * (p > 0 ? 1 : 0))
        }
        radial(c, 380, C.green, 0.22 * eo3(prog(lt, 0.3, 0.8)))
        let e = spring(prog(lt, 0.25, 0.9))
        xform(center: c, scale: 0.3 + 0.7 * e, alpha: eo3(prog(lt, 0.25, 0.25))) { lock(center: c, lt: lt) }
        reveal([("On-device", .white), ("by", .white), ("default.", C.green)], 108, x: W / 2, y: 585, align: .center, start: 0.9, lt: lt)
        let chips = [("No cloud account required", 1.9), ("No subscription", 2.2), ("Open source · AGPL-3.0", 2.5)]
        let widths = chips.map { popupWidth($0.0, size: 32) }
        let gap: CGFloat = 26
        var x = W / 2 - (widths.reduce(0, +) + gap * 2) / 2
        for (i, ch) in chips.enumerated() {
            popup(ch.0, left: x, cy: 740, start: ch.1, lt: lt, size: 32)
            x += widths[i] + gap
        }
        text("Local models keep your audio on this Mac.", 36, .medium, color: C.dim, x: W / 2, y: 870, alpha: eo3(prog(lt, 3.2, 0.5)), dy: (1 - eo3(prog(lt, 3.2, 0.5))) * 16)
    }

    func lock(center c: CGPoint, lt: Double) {
        let body = CGRect(x: c.x - 105, y: c.y - 20, width: 210, height: 170)
        // Shackle
        let sh = CGMutablePath()
        sh.move(to: CGPoint(x: c.x - 62, y: c.y - 20))
        sh.addLine(to: CGPoint(x: c.x - 62, y: c.y - 62))
        sh.addArc(center: CGPoint(x: c.x, y: c.y - 62), radius: 62, startAngle: .pi, endAngle: 0, clockwise: false)
        sh.addLine(to: CGPoint(x: c.x + 62, y: c.y - 20))
        saveA(); g.setLineCap(.round); g.setLineJoin(.round)
        stroke(sh, NSColor(srgbRed: 0.38, green: 0.70, blue: 0.60, alpha: 1), width: 30)
        restoreA()
        shadowed(blur: 40, dy: 16, alpha: 0.5) { fill(roundRect(body, 38), C.green) }
        fill(CGPath(ellipseIn: CGRect(x: c.x - 19, y: c.y + 42, width: 38, height: 38), transform: nil), NSColor(srgbRed: 0.05, green: 0.16, blue: 0.13, alpha: 1))
        fill(roundRect(CGRect(x: c.x - 7, y: c.y + 66, width: 14, height: 44), 7), NSColor(srgbRed: 0.05, green: 0.16, blue: 0.13, alpha: 1))
    }

    // MARK: 11. Finale

    func finale(_ lt: Double) {
        let cards: [(String, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            ("settings-models.png", 300, 300, -0.14, 440), ("settings-writing-styles.png", 1620, 260, 0.12, 440),
            ("settings-cleanup.png", 230, 800, 0.10, 420), ("settings-history.png", 1690, 800, -0.10, 420),
            ("settings-dictionary.png", 880, 20, -0.05, 380), ("settings-stats.png", 1040, 1110, 0.06, 380),
        ]
        for (i, c) in cards.enumerated() {
            let s = 0.15 + Double(i) * 0.12
            let e = spring(prog(lt, s, 0.95))
            let a = eo3(prog(lt, s, 0.3)) * 0.42
            let center = CGPoint(x: c.1, y: c.2)
            let from = CGPoint(x: W / 2, y: H / 2)
            let bob = 9 * CGFloat(sin(lt * 0.9 + Double(i)))
            drawImage(c.0, center: CGPoint(x: lerp(from.x, center.x, e), y: lerp(from.y, center.y, e) + bob), height: c.4,
                      scale: 0.15 + 0.85 * e, rotate: c.3 * e, alpha: a)
        }
        radial(CGPoint(x: W / 2, y: H / 2 + 20), 900, C.bg, 0.92 * eo3(prog(lt, 0.6, 0.8)))
        let logoC = CGPoint(x: W / 2, y: 300)
        let le = spring(prog(lt, 1.2, 0.9))
        radial(logoC, 360, C.green, 0.22 * eo3(prog(lt, 1.2, 0.8)))
        xform(center: logoC, scale: 0.25 + 0.75 * le, rotate: (1 - le) * 0.5, alpha: eo3(prog(lt, 1.2, 0.25))) {
            drawImage(brand, center: logoC, height: 190, shadow: true)
        }
        reveal(Array("VocaMac").map { (String($0), NSColor.white) }, 136, .heavy, x: W / 2, y: 490, align: .center, start: 1.6, stagger: 0.06, lt: lt, kern: -3, rise: 50, spaceFactor: 0)
        let e2 = eo5(prog(lt, 2.5, 0.6))
        text("vocamac.com", 64, .semibold, color: C.green, x: W / 2, y: 600, alpha: e2, kern: -1, dy: (1 - e2) * 24)
        let cmd = "brew tap vocahq/vocamac && brew install --cask vocamac"
        let ce = spring(prog(lt, 3.3, 0.7))
        let cw = measure(cmd, 30, .medium, mono: true).width + 80
        let box = CGRect(x: W / 2 - cw / 2, y: 690, width: cw, height: 84)
        xform(center: CGPoint(x: W / 2, y: box.midY), scale: 0.8 + 0.2 * ce, alpha: eo3(prog(lt, 3.3, 0.25))) {
            fill(roundRect(box, 20), NSColor(white: 1, alpha: 0.07))
            stroke(roundRect(box, 20), C.green, width: 1.8, alpha: 0.6)
            text(cmd, 30, .medium, color: C.green, x: W / 2, y: box.midY, mono: true)
        }
        text("Free  ·  Open source  ·  Apple Silicon  ·  macOS 14+", 32, .medium, color: C.dim, x: W / 2, y: 860, alpha: eo3(prog(lt, 4.1, 0.5)), dy: (1 - eo3(prog(lt, 4.1, 0.5))) * 14)
    }
}
