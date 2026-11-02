import CoreGraphics
import Foundation

struct EyePose: Equatable, Sendable {
    var closure = 0.0
    var heart = 0.0
    var smile = 0.0
    var slant = 0.0
    var openness = 1.0
    var width = 1.0
    var tilt = 0.0
    var x = 0.0
    var y = 0.0

    static func pair(for emotion: EyeExpression) -> (Self, Self) {
        switch emotion {
        case .clear: return (Self(), Self())
        case .loading: return (Self(), Self())
        case .closed:
            let eye = Self(closure: 1, width: 1.02)
            return (eye, eye)
        case .smile:
            let eye = Self(smile: 0.8, openness: 0.9)
            return (eye, eye)
        case .happy:
            let eye = Self(smile: 1, openness: 0.9, tilt: -4, y: -0.01)
            return (eye, eye)
        case .laugh:
            let eye = Self(smile: 1, openness: 0.62, width: 1.05, y: -0.02)
            return (eye, eye)
        case .thinking:
            return (
                Self(slant: -0.15, openness: 0.62, tilt: -7, x: 0.018, y: -0.02),
                Self(openness: 0.95, tilt: 4, x: 0.018, y: -0.03)
            )
        case .surprised:
            let eye = Self(openness: 1.2, width: 0.9, y: -0.015)
            return (eye, eye)
        case .sad:
            let eye = Self(slant: -0.7, openness: 0.72, tilt: 7, y: 0.025)
            return (eye, eye)
        case .love:
            let eye = Self(heart: 1, width: 1.06)
            return (eye, eye)
        case .angry:
            let eye = Self(slant: 0.85, openness: 0.8, tilt: -3)
            return (eye, eye)
        case .scared:
            let eye = Self(slant: -0.3, openness: 1.25, width: 0.8, tilt: 4, y: 0.012)
            return (eye, eye)
        case .playful:
            return (
                Self(smile: 0.65, tilt: -6, y: -0.01),
                Self(smile: 0.7, openness: 0.18, tilt: 8, y: 0.015)
            )
        }
    }
}

struct EyeContour: Sendable {
    var smile: Double
    var slant: Double
    var heart: Double
    var closure: Double
    private struct Knot {
        var point: CGPoint
        // The same handle on either side gives every join a continuous derivative.
        var tangent: CGPoint
    }

    func path(in rect: CGRect) -> CGPath {
        let smiling = min(1, max(0, smile))
        let leaning = min(1, max(-1, slant))
        let loving = min(1, max(0, heart))
        let closed = min(1, max(0, closure))
        let heartKnots = [
            Knot(point: CGPoint(x: 0.5, y: 0.22), tangent: CGPoint(x: 0.07, y: 0)),
            Knot(point: CGPoint(x: 0.8, y: 0.055), tangent: CGPoint(x: 0.12, y: 0)),
            Knot(point: CGPoint(x: 0.99, y: 0.36), tangent: CGPoint(x: 0, y: 0.14)),
            Knot(point: CGPoint(x: 0.79, y: 0.70), tangent: CGPoint(x: -0.1, y: 0.13)),
            Knot(point: CGPoint(x: 0.5, y: 0.98), tangent: CGPoint(x: -0.035, y: 0)),
            Knot(point: CGPoint(x: 0.21, y: 0.70), tangent: CGPoint(x: -0.1, y: -0.13)),
            Knot(point: CGPoint(x: 0.01, y: 0.36), tangent: CGPoint(x: 0, y: -0.14)),
            Knot(point: CGPoint(x: 0.2, y: 0.055), tangent: CGPoint(x: 0.12, y: 0)),
        ]
        func blend(_ a: CGPoint, _ b: CGPoint, _ fraction: Double) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
        }
        let handle = 4.0 / 3.0 * tan(.pi / 16)
        let knots = (0..<8).map { index -> Knot in
            let angle = Double(index) * .pi / 4
            let x = 0.5 + 0.5 * sin(angle)
            let y = 0.5 - 0.48 * cos(angle)
            let dx = handle * 0.5 * cos(angle)
            let dy = handle * 0.48 * sin(angle)
            let side = 2 * x - 1
            let height = 1 - 0.76 * smiling
            // Lower the selected brow instead of pushing the opposite side outside the eye bounds.
            let brow = 0.24 * (max(0, -leaning) + leaning * x)
            // Deform tangent handles with the same derivative as their anchors.
            let open = Knot(
                point: CGPoint(
                    x: x,
                    y: 0.5 + (y - 0.5) * height + smiling * (0.28 * side * side - 0.10)
                        + brow * (1 - y)),
                tangent: CGPoint(
                    x: dx,
                    y: (height - brow) * dy
                        + (smiling * 1.12 * side + leaning * 0.24 * (1 - y)) * dx))
            let lid = Knot(
                point: CGPoint(x: x, y: 0.49 + 0.06 * (y - 0.5) + 0.17 * (1 - side * side)),
                tangent: CGPoint(x: dx, y: 0.06 * dy - 0.68 * side * dx))
            let love = heartKnots[index]
            return Knot(
                point: blend(blend(open.point, love.point, loving), lid.point, closed),
                tangent: blend(blend(open.tangent, love.tangent, loving), lid.tangent, closed))
        }
        func p(_ point: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
        }
        let path = CGMutablePath()
        path.move(to: p(knots[0].point))
        for index in knots.indices {
            let start = knots[index]
            let end = knots[(index + 1) % knots.count]
            path.addCurve(
                to: p(end.point),
                control1: p(CGPoint(x: start.point.x + start.tangent.x, y: start.point.y + start.tangent.y)),
                control2: p(CGPoint(x: end.point.x - end.tangent.x, y: end.point.y - end.tangent.y)))
        }
        path.closeSubpath()
        return path
    }
}
