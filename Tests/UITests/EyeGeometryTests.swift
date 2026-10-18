import CoreGraphics
import Foundation
import Testing

@testable import UI

private struct EyeCubic {
    var start: CGPoint
    var control1: CGPoint
    var control2: CGPoint
    var end: CGPoint

    func point(at t: Double) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * u * start.x + 3 * u * u * t * control1.x + 3 * u * t * t * control2.x + t * t * t * end.x,
            y: u * u * u * start.y + 3 * u * u * t * control1.y + 3 * u * t * t * control2.y + t * t * t * end.y)
    }

    func blended(with other: Self, at t: Double) -> Self {
        func blend(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        return Self(
            start: blend(start, other.start), control1: blend(control1, other.control1),
            control2: blend(control2, other.control2), end: blend(end, other.end))
    }
}

private func eyeCubics(_ pose: EyePose) -> [EyeCubic] {
    let path = EyeContour(smile: pose.smile, slant: pose.slant, heart: pose.heart, closure: pose.closure).path(
        in: CGRect(x: 0, y: 0, width: 1, height: 1))
    var start = CGPoint.zero
    var curves: [EyeCubic] = []
    path.applyWithBlock { element in
        let value = element.pointee
        switch value.type {
        case .moveToPoint: start = value.points[0]
        case .addCurveToPoint:
            curves.append(
                EyeCubic(start: start, control1: value.points[0], control2: value.points[1], end: value.points[2]))
            start = value.points[2]
        default: break
        }
    }
    return curves
}

private func eyeHasSmoothBoundedOutline(_ curves: [EyeCubic]) -> Bool {
    guard curves.count == 8 else { return false }
    for index in curves.indices {
        let current = curves[index]
        let next = curves[(index + 1) % curves.count]
        guard current.end == next.start else { return false }
        let incoming = CGPoint(x: current.end.x - current.control2.x, y: current.end.y - current.control2.y)
        let outgoing = CGPoint(x: next.control1.x - next.start.x, y: next.control1.y - next.start.y)
        // A side join must neither kink nor reverse into a protruding loop.
        guard hypot(incoming.x - outgoing.x, incoming.y - outgoing.y) < 1e-9,
            hypot(incoming.x, incoming.y) > 1e-5
        else { return false }
    }
    let points = curves.flatMap { curve in (0..<12).map { curve.point(at: Double($0) / 12) } }
    guard
        points.allSatisfy({
            $0.x.isFinite && $0.y.isFinite && $0.x >= -1e-9 && $0.x <= 1 + 1e-9 && $0.y >= 0 && $0.y <= 1
        })
    else { return false }
    func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }
    var area = 0.0
    for i in points.indices {
        let a = points[i]
        let b = points[(i + 1) % points.count]
        area += a.x * b.y - a.y * b.x
        guard i + 2 < points.count else { continue }
        for j in (i + 2)..<points.count {
            if i == 0 && j == points.count - 1 { continue }
            let c = points[j]
            let d = points[(j + 1) % points.count]
            if cross(a, b, c) * cross(a, b, d) < 0 && cross(c, d, a) * cross(c, d, b) < 0 { return false }
        }
    }
    return area > 0.001
}

@Test(arguments: EyeExpression.allCases)
func eyeExpressionTransitionsKeepSmoothSides(from: EyeExpression) {
    let source = EyePose.pair(for: from)
    for to in EyeExpression.allCases {
        let target = EyePose.pair(for: to)
        for (a, b) in [(source.0, target.0), (source.1, target.1)] {
            let start = eyeCubics(a)
            let end = eyeCubics(b)
            for step in 0...16 {
                // Core Animation interpolates matching path controls, including shadowPath.
                let frame = zip(start, end).map { $0.blended(with: $1, at: Double(step) / 16) }
                #expect(eyeHasSmoothBoundedOutline(frame), "\(from) → \(to), frame \(step)")
            }
        }
    }
}

@Test func interruptedEyeTransitionKeepsSmoothSides() {
    let clear = eyeCubics(EyePose.pair(for: .clear).0)
    let love = eyeCubics(EyePose.pair(for: .love).0)
    let interrupted = zip(clear, love).map { $0.blended(with: $1, at: 0.43) }
    for expression in EyeExpression.allCases {
        let pair = EyePose.pair(for: expression)
        for pose in [pair.0, pair.1] {
            let target = eyeCubics(pose)
            for step in 0...16 {
                let frame = zip(interrupted, target).map { $0.blended(with: $1, at: Double(step) / 16) }
                #expect(eyeHasSmoothBoundedOutline(frame), "interrupted → \(expression), frame \(step)")
            }
        }
    }
}

@Test func nativeSpectrumBoundsInvalidInputAndPreservesInterpolationTopology() {
    let size = CGSize(width: 166, height: 62)
    for reply in [false, true] {
        let path = VoiceSpectrumGeometry.bars(
            size: size, bands: [.nan, .infinity, -1, 2] + Array(repeating: 1, count: 100),
            reply: reply, active: true, reduceMotion: false)
        var kinds: [CGPathElementType] = []
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            kinds.append(element.pointee.type)
            points.append(element.pointee.points[0])
        }
        #expect(kinds.count == 64)
        #expect(
            kinds.enumerated().allSatisfy {
                $0.element == ($0.offset.isMultiple(of: 2) ? .moveToPoint : .addLineToPoint)
            })
        #expect(points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        #expect(
            VoiceSpectrumGeometry.bars(
                size: size, bands: [], reply: reply, active: true, reduceMotion: false
            ).boundingBox.isInfinite == false)
    }
    #expect(
        VoiceSpectrumGeometry.bars(
            size: CGSize(width: CGFloat.infinity, height: 62), bands: [1], reply: true, active: true,
            reduceMotion: false
        ).isEmpty)
}

@Test func nativeSpectrumIdleAndReducedMotionIgnoreChangingMeterValues() {
    let size = CGSize(width: 166, height: 62)
    for reply in [false, true] {
        for mode in [(false, false), (true, true)] {
            let quiet = VoiceSpectrumGeometry.bars(
                size: size, bands: [], reply: reply, active: mode.0, reduceMotion: mode.1)
            let loud = VoiceSpectrumGeometry.bars(
                size: size, bands: Array(repeating: 1, count: 32), reply: reply, active: mode.0, reduceMotion: mode.1)
            #expect(quiet == loud)
        }
    }
}
