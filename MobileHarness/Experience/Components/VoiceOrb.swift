import SwiftUI

/// Procedural drawing: no image assets, audio samples, or model objects enter the view.
@MainActor
struct VoiceOrb: View {
    let phase: AppLifecycleCoordinator.VoicePhase
    let level: Float
    let reduceMotion: Bool
    var expression: String? = nil
    var expressionID = UUID()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || phase == .idle || phase == .failed))
        { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let loading = phase == .loading
                let speaking = phase == .speaking
                let intensity = (phase == .listening || speaking) ? Double(level) : 0
                let breath = loading ? 1 + 0.06 * sin(time * 2.4) : 1
                let radius = size.width * 0.335 * breath
                let rotation = loading ? time * 1.7 : 0
                let brightness = phase == .idle || phase == .failed ? 0.42 : 0.9
                let palette: [Color] =
                    speaking
                    ? [Color(red: 0.67, green: 0.48, blue: 1), Color(red: 0.90, green: 0.79, blue: 1)]
                    : [Color(red: 0.32, green: 0.62, blue: 1), Color(red: 0.63, green: 0.68, blue: 1)]
                let gradient = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: palette), startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height))
                func point(_ angle: Double, _ distance: Double) -> CGPoint {
                    CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
                }
                for ring in 0..<3 {
                    var contour = Path()
                    for step in 0...240 {
                        let angle = Double(step) / 240 * .pi * 2
                        let wave = sin(angle * (speaking ? 3 : 5) + time * 1.5 + Double(ring))
                        let displacement = (speaking ? 4 : 3) + intensity * 13
                        let distance = radius + Double(ring - 1) * 5 + wave * displacement
                        let p = point(angle + rotation, distance)
                        if step == 0 { contour.move(to: p) } else { contour.addLine(to: p) }
                    }
                    var trace = context
                    trace.opacity = brightness * 0.28
                    trace.stroke(contour, with: gradient, lineWidth: ring == 1 ? 1 : 0.5)
                }
                var glowPath = Path()
                for index in 0..<144 {
                    let angle = Double(index) / 144 * .pi * 2
                    let wave = (sin(angle * 7 + time * 3) + sin(angle * 13 - time * 2)) * 0.25 + 0.5
                    let length = 3 + wave * 3 + intensity * (8 + wave * 35)
                    let loadingFade = loading ? 0.18 + 0.82 * Double(index) / 144 : 1
                    var bar = Path()
                    bar.move(to: point(angle + rotation, radius - length * 0.30))
                    bar.addLine(to: point(angle + rotation, radius + length))
                    glowPath.addPath(bar)
                    var sharp = context
                    sharp.opacity = brightness * loadingFade
                    sharp.stroke(bar, with: gradient, style: StrokeStyle(lineWidth: 1.15, lineCap: .round))
                }
                context.drawLayer { glow in
                    glow.opacity = brightness * 0.28
                    glow.addFilter(.blur(radius: 3))
                    glow.stroke(glowPath, with: gradient, lineWidth: 3)
                }
                if intensity > 0.04 && !reduceMotion {
                    for index in 0..<2 {
                        let progress = (time * (speaking ? 0.4 : 0.65) + Double(index) * 0.5).truncatingRemainder(
                            dividingBy: 1)
                        let distance = radius + 12 + progress * size.width * 0.12
                        let rect = CGRect(
                            x: center.x - distance, y: center.y - distance, width: distance * 2, height: distance * 2)
                        var ripple = context
                        ripple.opacity = (1 - progress) * intensity * 0.22
                        ripple.stroke(Path(ellipseIn: rect), with: gradient, lineWidth: 0.6)
                    }
                }
            }
        }
        .overlay {
            GeometryReader { geometry in
                ZStack {
                    if let expression {
                        Text(expression)
                            .font(.system(size: geometry.size.width * 0.32))
                            .shadow(color: .purple.opacity(0.35), radius: 24)
                            .id(expressionID)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.65).combined(with: .opacity))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .animation(
                    reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.65),
                    value: expressionID
                )
            }
            .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }
}
