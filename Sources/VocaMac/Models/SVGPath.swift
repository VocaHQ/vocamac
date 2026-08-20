// SVGPath.swift
// VocaMac
//
// Parses an official SVG path `d` into CGPath. Used only when AppKit
// cannot rasterize a currentColor mark. Path strings stay exact.

import CoreGraphics
import Foundation

enum SVGPath {
    /// Builds a CGPath from an official SVG `d` attribute. Returns nil when
    /// the string is empty or the first command is missing.
    static func makeCGPath(from d: String) -> CGPath? {
        var scanner = Scanner(d)
        let path = CGMutablePath()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastControl = CGPoint.zero
        var previous: Character?

        func markStart(_ point: CGPoint) {
            subpathStart = point
            current = point
            lastControl = point
        }

        while !scanner.isAtEnd {
            let command: Character
            if let next = scanner.nextCommand() {
                command = next
            } else if let previous {
                command = implicitCommand(after: previous)
            } else {
                return nil
            }

            switch command {
            case "M", "m":
                guard var point = scanner.nextPoint(relativeTo: command == "m" ? current : nil) else { return nil }
                path.move(to: point)
                markStart(point)
                while let next = scanner.nextPoint(relativeTo: command == "m" ? current : nil) {
                    path.addLine(to: next)
                    current = next
                    lastControl = next
                }
            case "L", "l":
                while let point = scanner.nextPoint(relativeTo: command == "l" ? current : nil) {
                    path.addLine(to: point)
                    current = point
                    lastControl = point
                }
            case "H", "h":
                while let x = scanner.nextNumber() {
                    let point = CGPoint(x: command == "h" ? current.x + x : x, y: current.y)
                    path.addLine(to: point)
                    current = point
                    lastControl = point
                }
            case "V", "v":
                while let y = scanner.nextNumber() {
                    let point = CGPoint(x: current.x, y: command == "v" ? current.y + y : y)
                    path.addLine(to: point)
                    current = point
                    lastControl = point
                }
            case "C", "c":
                while let c1 = scanner.nextPoint(relativeTo: command == "c" ? current : nil),
                      let c2 = scanner.nextPoint(relativeTo: command == "c" ? current : nil),
                      let end = scanner.nextPoint(relativeTo: command == "c" ? current : nil) {
                    path.addCurve(to: end, control1: c1, control2: c2)
                    lastControl = c2
                    current = end
                }
            case "S", "s":
                while let c2 = scanner.nextPoint(relativeTo: command == "s" ? current : nil),
                      let end = scanner.nextPoint(relativeTo: command == "s" ? current : nil) {
                    let reflected = reflect(lastControl, around: current)
                    path.addCurve(to: end, control1: reflected, control2: c2)
                    lastControl = c2
                    current = end
                }
            case "Q", "q":
                while let control = scanner.nextPoint(relativeTo: command == "q" ? current : nil),
                      let end = scanner.nextPoint(relativeTo: command == "q" ? current : nil) {
                    path.addQuadCurve(to: end, control: control)
                    lastControl = control
                    current = end
                }
            case "T", "t":
                while let end = scanner.nextPoint(relativeTo: command == "t" ? current : nil) {
                    let control = reflect(lastControl, around: current)
                    path.addQuadCurve(to: end, control: control)
                    lastControl = control
                    current = end
                }
            case "A", "a":
                while let rx = scanner.nextNumber(),
                      let ry = scanner.nextNumber(),
                      let rotation = scanner.nextNumber(),
                      let large = scanner.nextFlag(),
                      let sweep = scanner.nextFlag(),
                      let end = scanner.nextPoint(relativeTo: command == "a" ? current : nil) {
                    addArc(
                        to: path,
                        from: current,
                        to: end,
                        rx: rx,
                        ry: ry,
                        rotationDegrees: rotation,
                        largeArc: large,
                        sweep: sweep
                    )
                    current = end
                    lastControl = end
                }
            case "Z", "z":
                path.closeSubpath()
                current = subpathStart
                lastControl = subpathStart
            default:
                return nil
            }

            previous = command
        }

        return path
    }

    private static func implicitCommand(after previous: Character) -> Character {
        switch previous {
        case "M": return "L"
        case "m": return "l"
        default: return previous
        }
    }

    private static func reflect(_ control: CGPoint, around point: CGPoint) -> CGPoint {
        CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
    }

    /// W3C SVG arc endpoint parameterization to cubic beziers.
    private static func addArc(
        to path: CGMutablePath,
        from start: CGPoint,
        to end: CGPoint,
        rx: CGFloat,
        ry: CGFloat,
        rotationDegrees: CGFloat,
        largeArc: Bool,
        sweep: Bool
    ) {
        var rx = abs(rx)
        var ry = abs(ry)
        if rx == 0 || ry == 0 || start == end {
            path.addLine(to: end)
            return
        }

        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2
        let dy = (start.y - end.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let scale = sqrt(lambda)
            rx *= scale
            ry *= scale
        }

        let rxSq = rx * rx
        let rySq = ry * ry
        let x1pSq = x1p * x1p
        let y1pSq = y1p * y1p
        var factorSq = (rxSq * rySq - rxSq * y1pSq - rySq * x1pSq) / (rxSq * y1pSq + rySq * x1pSq)
        if factorSq < 0 { factorSq = 0 }
        let sign: CGFloat = largeArc == sweep ? -1 : 1
        let factor = sign * sqrt(factorSq)
        let cxp = factor * (rx * y1p) / ry
        let cyp = factor * -(ry * x1p) / rx

        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            if len == 0 { return 0 }
            var ang = acos(min(max(dot / len, -1), 1))
            if ux * vy - uy * vx < 0 { ang = -ang }
            return ang
        }

        let startVector = CGPoint(x: (x1p - cxp) / rx, y: (y1p - cyp) / ry)
        let theta1 = angle(1, 0, startVector.x, startVector.y)
        let endVector = CGPoint(x: (-x1p - cxp) / rx, y: (-y1p - cyp) / ry)
        var delta = angle(startVector.x, startVector.y, endVector.x, endVector.y)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let deltaEach = delta / CGFloat(segments)
        let handle = (4 / 3) * tan(deltaEach / 4)

        var t = theta1
        for _ in 0..<segments {
            let t2 = t + deltaEach
            let cos1 = cos(t)
            let sin1 = sin(t)
            let cos2 = cos(t2)
            let sin2 = sin(t2)

            let p1 = ellipsePoint(cx: cx, cy: cy, rx: rx, ry: ry, cosPhi: cosPhi, sinPhi: sinPhi, theta: t)
            let p2 = ellipsePoint(cx: cx, cy: cy, rx: rx, ry: ry, cosPhi: cosPhi, sinPhi: sinPhi, theta: t2)
            let dx1 = handle * ellipseDerivative(rx: rx, ry: ry, cosPhi: cosPhi, sinPhi: sinPhi, theta: t).dx
            let dy1 = handle * ellipseDerivative(rx: rx, ry: ry, cosPhi: cosPhi, sinPhi: sinPhi, theta: t).dy
            let dx2 = handle * ellipseDerivative(rx: rx, ry: ry, cosPhi: cosPhi, sinPhi: sinPhi, theta: t2).dx
            let dy2 = handle * ellipseDerivative(rx: rx, ry: ry, cosPhi: cosPhi, sinPhi: sinPhi, theta: t2).dy

            path.addCurve(
                to: p2,
                control1: CGPoint(x: p1.x + dx1, y: p1.y + dy1),
                control2: CGPoint(x: p2.x - dx2, y: p2.y - dy2)
            )
            t = t2
        }
    }

    private static func ellipsePoint(
        cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat,
        cosPhi: CGFloat, sinPhi: CGFloat, theta: CGFloat
    ) -> CGPoint {
        let x = rx * cos(theta)
        let y = ry * sin(theta)
        return CGPoint(x: cosPhi * x - sinPhi * y + cx, y: sinPhi * x + cosPhi * y + cy)
    }

    private static func ellipseDerivative(
        rx: CGFloat, ry: CGFloat, cosPhi: CGFloat, sinPhi: CGFloat, theta: CGFloat
    ) -> (dx: CGFloat, dy: CGFloat) {
        let dx = -rx * sin(theta)
        let dy = ry * cos(theta)
        return (cosPhi * dx - sinPhi * dy, sinPhi * dx + cosPhi * dy)
    }

    fileprivate struct Scanner {
        private let chars: [Character]
        private var index = 0

        init(_ string: String) {
            chars = Array(string)
        }

        var isAtEnd: Bool {
            var cursor = index
            while cursor < chars.count, chars[cursor].isSVGSeparator {
                cursor += 1
            }
            return cursor >= chars.count
        }

        mutating func nextCommand() -> Character? {
            skipSeparators()
            guard index < chars.count, chars[index].isSVGPathCommand else { return nil }
            let command = chars[index]
            index += 1
            return command
        }

        mutating func nextPoint(relativeTo origin: CGPoint?) -> CGPoint? {
            guard let x = nextNumber(), let y = nextNumber() else { return nil }
            if let origin {
                return CGPoint(x: origin.x + x, y: origin.y + y)
            }
            return CGPoint(x: x, y: y)
        }

        mutating func nextNumber() -> CGFloat? {
            skipSeparators()
            guard index < chars.count else { return nil }

            let start = index
            if chars[index] == "+" || chars[index] == "-" {
                index += 1
            }
            var sawDigit = false
            while index < chars.count, chars[index].isSVGDigit {
                sawDigit = true
                index += 1
            }
            if index < chars.count, chars[index] == "." {
                index += 1
                while index < chars.count, chars[index].isSVGDigit {
                    sawDigit = true
                    index += 1
                }
            }
            if sawDigit, index < chars.count, chars[index] == "e" || chars[index] == "E" {
                index += 1
                if index < chars.count, chars[index] == "+" || chars[index] == "-" {
                    index += 1
                }
                while index < chars.count, chars[index].isSVGDigit {
                    index += 1
                }
            }

            guard sawDigit, start < index else {
                index = start
                return nil
            }
            return Double(String(chars[start..<index])).map { CGFloat($0) }
        }

        mutating func nextFlag() -> Bool? {
            skipSeparators()
            guard index < chars.count, chars[index] == "0" || chars[index] == "1" else { return nil }
            let value = chars[index] == "1"
            index += 1
            return value
        }

        private mutating func skipSeparators() {
            while index < chars.count, chars[index].isSVGSeparator {
                index += 1
            }
        }
    }
}

private extension Character {
    var isSVGPathCommand: Bool {
        "MmLlHhVvCcSsQqTtAaZz".contains(self)
    }

    var isSVGDigit: Bool { isNumber }

    var isSVGSeparator: Bool {
        self == "," || isWhitespace
    }
}
