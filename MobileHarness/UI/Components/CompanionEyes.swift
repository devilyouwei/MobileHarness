import Foundation

#if os(iOS)
    import SwiftUI

    extension EnvironmentValues {
        @Entry var eyeGaze: CGSize = .zero
    }

    /// Startup/standalone eyes use the same native layer renderer as the conversation.
    @MainActor
    struct CompanionEyes: View {
        let phase: VoicePhase
        let reduceMotion: Bool
        var expression: EyeExpression? = nil
        var expressionEmphasized = false
        var expressionTransitionID: String? = nil
        var expressionCompletion: (@MainActor (String, Bool) -> Void)? = nil
        var expressionAvailability: (@MainActor (Bool) -> Void)? = nil
        var gaze: CGSize = .zero
        var faceWidth: CGFloat = 390
        var body: some View {
            GeometryReader { geometry in
                NativeCompanionSurface(
                    phase: phase, reduceMotion: reduceMotion, expression: expression ?? .clear,
                    emphasized: expressionEmphasized, transitionID: expressionTransitionID,
                    gaze: gaze, faceWidth: faceWidth,
                    eyeCenter: CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2),
                    haloEnabled: false, active: false, generation: nil,
                    completion: expressionCompletion, availability: expressionAvailability)
            }
            .accessibilityHidden(true)
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

#endif
