import CoreGraphics
import Foundation

/// A small SVG path-data parser (M L H V C S Q T A Z, absolute and relative,
/// including compact number and arc-flag syntax such as `a6 6 0 013-.4`).
/// It exists so the marks can carry the exact path strings of the reference
/// QML `PathSvg` elements and be checked against them by eye.
enum SVGPath {
    static func parse(_ data: String) -> CGPath {
        var parser = Parser(Array(data.utf8))
        return parser.run()
    }

    private struct Parser {
        let s: [UInt8]
        var i = 0
        let path = CGMutablePath()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: UInt8 = 0

        init(_ s: [UInt8]) { self.s = s }

        mutating func skipSeparators() {
            while i < s.count, s[i] == 0x20 || s[i] == 0x2C || s[i] == 0x0A || s[i] == 0x0D || s[i] == 0x09 { i += 1 }
        }

        mutating func peekIsNumber() -> Bool {
            skipSeparators()
            guard i < s.count else { return false }
            let c = s[i]
            return (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2B || c == 0x2E
        }

        mutating func number() -> CGFloat {
            skipSeparators()
            let begin = i
            if i < s.count, s[i] == 0x2D || s[i] == 0x2B { i += 1 }
            var seenDot = false
            while i < s.count {
                let c = s[i]
                if c >= 0x30 && c <= 0x39 { i += 1 }
                else if c == 0x2E && !seenDot { seenDot = true; i += 1 }
                else { break }
            }
            if i < s.count, s[i] == 0x65 || s[i] == 0x45 { // exponent
                i += 1
                if i < s.count, s[i] == 0x2D || s[i] == 0x2B { i += 1 }
                while i < s.count, s[i] >= 0x30 && s[i] <= 0x39 { i += 1 }
            }
            let text = String(decoding: s[begin..<i], as: UTF8.self)
            return CGFloat(Double(text) ?? 0)
        }

        mutating func flag() -> Bool {
            skipSeparators()
            guard i < s.count else { return false }
            let c = s[i]; i += 1
            return c == 0x31
        }

        mutating func run() -> CGPath {
            while true {
                skipSeparators()
                guard i < s.count else { break }
                var cmd = s[i]
                let isLetter = (cmd >= 0x41 && cmd <= 0x5A) || (cmd >= 0x61 && cmd <= 0x7A)
                if isLetter {
                    i += 1
                } else {
                    // Implicit repeat; a repeated moveto becomes lineto.
                    cmd = lastCommand == 0x4D ? 0x4C : lastCommand == 0x6D ? 0x6C : lastCommand
                    if cmd == 0 { break }
                }
                apply(cmd)
                lastCommand = cmd
            }
            return path
        }

        mutating func point(_ relative: Bool) -> CGPoint {
            let x = number(), y = number()
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        mutating func apply(_ cmd: UInt8) {
            let rel = cmd >= 0x61
            switch cmd | 0x20 { // lowercase
            case 0x6D: // m
                current = point(rel); start = current
                path.move(to: current)
                lastControl = nil
                while peekIsNumber() { current = point(rel); path.addLine(to: current) }
            case 0x6C: // l
                repeat { current = point(rel); path.addLine(to: current) } while peekIsNumber()
                lastControl = nil
            case 0x68: // h
                repeat { let x = number(); current.x = rel ? current.x + x : x; path.addLine(to: current) } while peekIsNumber()
                lastControl = nil
            case 0x76: // v
                repeat { let y = number(); current.y = rel ? current.y + y : y; path.addLine(to: current) } while peekIsNumber()
                lastControl = nil
            case 0x63: // c
                repeat {
                    let c1 = point(rel), c2 = point(rel), p = point(rel)
                    path.addCurve(to: p, control1: c1, control2: c2)
                    lastControl = c2; current = p
                } while peekIsNumber()
            case 0x73: // s
                repeat {
                    let c1 = reflected(curve: true)
                    let c2 = point(rel), p = point(rel)
                    path.addCurve(to: p, control1: c1, control2: c2)
                    lastControl = c2; current = p
                    lastCommand = 0x43
                } while peekIsNumber()
            case 0x71: // q
                repeat {
                    let c = point(rel), p = point(rel)
                    path.addQuadCurve(to: p, control: c)
                    lastControl = c; current = p
                } while peekIsNumber()
            case 0x74: // t
                repeat {
                    let c = reflected(curve: false)
                    let p = point(rel)
                    path.addQuadCurve(to: p, control: c)
                    lastControl = c; current = p
                    lastCommand = 0x51
                } while peekIsNumber()
            case 0x61: // a
                repeat {
                    let rx = number(), ry = number(), rot = number()
                    let large = flag(), sweep = flag()
                    let p = point(rel)
                    addArc(from: current, to: p, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                    current = p
                } while peekIsNumber()
                lastControl = nil
            case 0x7A: // z
                path.closeSubpath()
                current = start
                lastControl = nil
            default:
                i = s.count // unknown command: stop rather than loop
            }
        }

        func reflected(curve: Bool) -> CGPoint {
            let prev = lastCommand | 0x20
            let matches = curve ? (prev == 0x63 || prev == 0x73) : (prev == 0x71 || prev == 0x74)
            guard matches, let c = lastControl else { return current }
            return CGPoint(x: 2 * current.x - c.x, y: 2 * current.y - c.y)
        }

        /// SVG endpoint arc → cubic Béziers (SVG spec F.6.5 / F.6.6).
        func addArc(from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
                    rotation: CGFloat, large: Bool, sweep: Bool) {
            var rx = abs(rxIn), ry = abs(ryIn)
            if p0 == p1 { return }
            if rx == 0 || ry == 0 { path.addLine(to: p1); return }
            let phi = rotation * .pi / 180
            let cosP = cos(phi), sinP = sin(phi)
            let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
            let x1 = cosP * dx + sinP * dy
            let y1 = -sinP * dx + cosP * dy
            let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
            if lambda > 1 { let r = sqrt(lambda); rx *= r; ry *= r }
            let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
            let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
            var coef = sqrt(max(0, num / den))
            if large == sweep { coef = -coef }
            let cx1 = coef * rx * y1 / ry
            let cy1 = -coef * ry * x1 / rx
            let cx = cosP * cx1 - sinP * cy1 + (p0.x + p1.x) / 2
            let cy = sinP * cx1 + cosP * cy1 + (p0.y + p1.y) / 2

            func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
                let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
                return a
            }
            let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
            var dTheta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
            if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
            if sweep && dTheta < 0 { dTheta += 2 * .pi }

            let segments = max(1, Int(ceil(abs(dTheta) / (.pi / 2))))
            let delta = dTheta / CGFloat(segments)
            let t = 4 / 3 * tan(delta / 4)
            var a = theta1
            func pointAt(_ ang: CGFloat) -> (CGPoint, CGPoint) {
                let ex = rx * cos(ang), ey = ry * sin(ang)
                let p = CGPoint(x: cosP * ex - sinP * ey + cx, y: sinP * ex + cosP * ey + cy)
                let tx = -rx * sin(ang), ty = ry * cos(ang)
                let d = CGPoint(x: cosP * tx - sinP * ty, y: sinP * tx + cosP * ty)
                return (p, d)
            }
            for k in 0..<segments {
                let (pa, da) = pointAt(a)
                let b = a + delta
                var (pb, db) = pointAt(b)
                if k == segments - 1 { pb = p1 }
                path.addCurve(to: pb,
                              control1: CGPoint(x: pa.x + t * da.x, y: pa.y + t * da.y),
                              control2: CGPoint(x: pb.x - t * db.x, y: pb.y - t * db.y))
                a = b
            }
        }
    }
}
