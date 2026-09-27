import Actions
import SwiftUI

/// Stable eye identities; only numeric pose parameters change between emotions.
@MainActor
struct CompanionEyes: View {
    let phase: AppLifecycleCoordinator.VoicePhase
    let reduceMotion: Bool
    var expression: UIActions.Emotion? = nil
    var gaze: CGSize = .zero
    var faceWidth: CGFloat = 390
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion || scenePhase != .active)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let cycle = time.truncatingRemainder(dividingBy: 5.3)
            let distance = abs(cycle - 4.8) / 0.18
            let blink = reduceMotion || distance >= 1 ? 1 : 1 - 0.94 * (1 + cos(distance * .pi)) / 2
            HStack(spacing: faceWidth * 0.19) {
                eye(pose: EyePose.pair(for: expression ?? .clear).0, mirrored: false)
                eye(pose: EyePose.pair(for: expression ?? .clear).1, mirrored: true)
            }
            .scaleEffect(x: 1, y: blink)
            .offset(
                x: min(1, max(-1, gaze.width)) * 18,
                y: min(1, max(-1, gaze.height)) * 12 + (reduceMotion ? 0 : sin(time * 1.6) * 2)
            )
            .opacity(phase == .idle || phase == .failed ? 0.48 : 1)
            .scaleEffect(phase == .loading ? 0.88 + 0.04 * sin(time * 2) : 1)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.55), value: phase)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.3), value: gaze)
        }
        .accessibilityHidden(true)
    }

    private func eye(pose: EyePose, mirrored: Bool) -> some View {
        EyeSilhouette(smile: pose.smile, slant: pose.slant)
            .fill(Color(red: 0.08, green: 0.62, blue: 1))
            .frame(width: faceWidth * 0.21, height: faceWidth * 0.25)
            .scaleEffect(x: (mirrored ? -1 : 1) * pose.width, y: pose.openness)
            .rotationEffect(.degrees(pose.tilt * (mirrored ? -1 : 1)))
            .offset(x: pose.x * faceWidth, y: pose.y * faceWidth)
            .shadow(color: .blue.opacity(0.65), radius: 14)
            .shadow(color: .cyan.opacity(0.28), radius: 4)
            // Interruption retargets the current rendered shape, never removes/recreates an eye.
            .animation(
                reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.65, dampingFraction: 1), value: pose)
    }
}

/// Add expressions by describing the same two shapes, not swapping assets or view branches.
nonisolated private struct EyePose: Equatable {
    var smile = 0.0
    var slant = 0.0
    var openness = 1.0
    var width = 1.0
    var tilt = 0.0
    var x = 0.0
    var y = 0.0

    static func pair(for emotion: UIActions.Emotion) -> (Self, Self) {
        switch emotion {
        case .clear: return (Self(), Self())
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
            let eye = Self(smile: 0.9, openness: 0.8, width: 1.06, tilt: -9)
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

nonisolated private struct EyeSilhouette: Shape {
    var smile: Double
    var slant: Double
    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(smile, slant) }
        set {
            smile = newValue.first
            slant = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        func p(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: p(0, 0.32 + 0.24 * smile))
        path.addCurve(
            to: p(1, 0.32 + 0.24 * smile + 0.24 * slant),
            control1: p(0, -0.1 + 0.18 * smile), control2: p(1, -0.1 + 0.18 * smile + 0.3 * slant))
        path.addCurve(to: p(1, 0.72 + 0.08 * smile), control1: p(1, 0.5), control2: p(1, 0.66))
        path.addCurve(
            to: p(0, 0.72 + 0.08 * smile),
            control1: p(1, 1.1 - 0.85 * smile), control2: p(0, 1.1 - 0.85 * smile))
        path.addCurve(to: p(0, 0.32 + 0.24 * smile), control1: p(0, 0.66), control2: p(0, 0.5))
        path.closeSubpath()
        return path
    }
}

/// Each bar is one measured frequency band. No oscillator or synthetic waveform lives here.
@MainActor
struct VoiceBars: View {
    enum Placement { case bottom, reply }
    let placement: Placement
    let bands: [Float]
    let active: Bool
    let reduceMotion: Bool

    var body: some View {
        Canvas { context, size in
            let count = 32
            let step = size.width / CGFloat(count)
            var bars = Path()
            var rim = Path()
            // An open lower capsule arc, with room above and beside it for rounded-corner bars.
            func bowlPoint(_ fraction: CGFloat) -> (CGPoint, CGVector) {
                let radius: CGFloat = 19
                let halfStraight: CGFloat = 44
                let arcAngle = CGFloat.pi * 0.38
                let arcLength = radius * arcAngle
                let distance = fraction * (2 * arcLength + 2 * halfStraight)
                let angle: CGFloat
                let centerX: CGFloat
                if distance < arcLength {
                    angle = .pi / 2 + arcAngle - distance / radius
                    centerX = size.width / 2 - halfStraight
                } else if distance > arcLength + 2 * halfStraight {
                    angle = .pi / 2 - (distance - arcLength - 2 * halfStraight) / radius
                    centerX = size.width / 2 + halfStraight
                } else {
                    return (
                        CGPoint(x: size.width / 2 - halfStraight + distance - arcLength, y: 24),
                        CGVector(dx: 0, dy: 1)
                    )
                }
                let normal = CGVector(dx: cos(angle), dy: sin(angle))
                return (CGPoint(x: centerX + radius * normal.dx, y: 5 + radius * normal.dy), normal)
            }
            if placement == .reply {
                for index in 0...64 {
                    let point = bowlPoint(CGFloat(index) / 64).0
                    if index == 0 { rim.move(to: point) } else { rim.addLine(to: point) }
                }
            }
            for index in 0..<count {
                let measured = index < bands.count && bands[index].isFinite ? CGFloat(bands[index]) : 0
                let energy = active ? (reduceMotion ? 0.08 : min(1, max(0, measured))) : 0
                let height = 2 + energy * (size.height - 4)
                let x = (CGFloat(index) + 0.5) * step
                if placement == .bottom {
                    bars.move(to: CGPoint(x: x, y: size.height))
                    bars.addLine(to: CGPoint(x: x, y: size.height - height))
                } else {
                    let fraction = (CGFloat(index) + 0.5) / CGFloat(count)
                    let (root, normal) = bowlPoint(fraction)
                    let taper = 0.55 + 0.45 * min(1, min(fraction, 1 - fraction) / 0.18)
                    let length = (2 + energy * 30) * taper
                    bars.move(to: CGPoint(x: root.x - normal.dx, y: root.y - normal.dy))
                    bars.addLine(to: CGPoint(x: root.x + normal.dx * length, y: root.y + normal.dy * length))
                }
            }
            let colors: [Color] =
                placement == .bottom
                ? [.cyan, Color(red: 0.05, green: 0.38, blue: 1)]
                : [Color(red: 0.62, green: 0.46, blue: 1), Color(red: 0.85, green: 0.68, blue: 1)]
            let ink = GraphicsContext.Shading.linearGradient(
                Gradient(colors: colors), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height))
            context.opacity = active ? 0.95 : 0.15
            if placement == .reply {
                var edgeGlow = context
                edgeGlow.opacity *= 0.22
                edgeGlow.addFilter(.blur(radius: 2))
                edgeGlow.stroke(rim, with: ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            context.drawLayer { glow in
                glow.opacity = 0.45
                glow.addFilter(.blur(radius: 3))
                glow.stroke(bars, with: ink, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            context.stroke(
                bars, with: ink, style: StrokeStyle(lineWidth: placement == .bottom ? 3 : 2, lineCap: .round))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
