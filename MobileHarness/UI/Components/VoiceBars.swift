import CoreGraphics
import Foundation

#if os(iOS)
    import QuartzCore
    import SwiftUI
    import UIKit

    /// A stable native layer tree; meter updates only replace bounded path values.
    @MainActor
    struct VoiceBars: UIViewRepresentable {
        enum Placement { case bottom, reply }
        let placement: Placement
        let bands: [Float]
        let active: Bool
        let reduceMotion: Bool
        func makeUIView(context: Context) -> NativeSpectrumView { NativeSpectrumView() }
        func updateUIView(_ view: NativeSpectrumView, context: Context) {
            view.update(reply: placement == .reply, bands: bands, active: active, reduceMotion: reduceMotion)
        }
    }

    @MainActor
    final class NativeSpectrumView: UIView {
        private let gradient = CAGradientLayer()
        private let barMask = CAShapeLayer()
        private let glow = CAShapeLayer()
        private var reply = false
        private var bands: [Float] = []
        private var active = false
        private var reduceMotion = false
        private var renderedSize = CGSize.zero
        private var renderedReply: Bool?
        private var renderedActive: Bool?
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            backgroundColor = .clear
            layer.addSublayer(glow)
            layer.addSublayer(gradient)
            gradient.mask = barMask
            gradient.startPoint = CGPoint(x: 0, y: 0)
            gradient.endPoint = CGPoint(x: 0, y: 1)
            for shape in [barMask, glow] {
                shape.fillColor = nil
                shape.lineCap = .round
            }
            barMask.strokeColor = UIColor.white.cgColor
            glow.shadowOffset = .zero
            glow.shadowRadius = 3
            glow.shadowOpacity = 0.45
            glow.lineWidth = 4
            glow.opacity = 0.45

        }
        required init?(coder: NSCoder) { nil }
        func update(reply: Bool, bands: [Float], active: Bool, reduceMotion: Bool) {
            let bounded = Array(bands.prefix(32))
            guard
                self.reply != reply || self.bands != bounded || self.active != active
                    || self.reduceMotion != reduceMotion
            else { return }
            self.reply = reply
            self.bands = bounded
            self.active = active
            self.reduceMotion = reduceMotion
            drawBars(animated: true)
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.size != renderedSize { drawBars(animated: false) }
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { stopAnimations() }
        }
        func stopAnimations() {
            for shape in [barMask, glow] { shape.removeAllAnimations() }
        }
        private func drawBars(animated: Bool) {
            guard bounds.width > 0, bounds.height > 0 else { return }
            let sizeChanged = renderedSize != bounds.size
            let styleChanged = renderedReply != reply
            renderedSize = bounds.size
            renderedReply = reply

            let path = VoiceSpectrumGeometry.bars(
                size: bounds.size, bands: bands, reply: reply, active: active, reduceMotion: reduceMotion)
            let shadow = path.copy(strokingWithWidth: 4, lineCap: .round, lineJoin: .round, miterLimit: 0)
            let moving = animated && active && !reduceMotion && window != nil
            let previousMask = barMask.presentation()?.path ?? barMask.path
            let previousGlow = glow.presentation()?.path ?? glow.path
            let previousShadow = glow.presentation()?.shadowPath ?? glow.shadowPath
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if sizeChanged {
                gradient.frame = bounds
                barMask.frame = bounds
                glow.frame = bounds
            }
            if styleChanged {
                gradient.colors =
                    reply
                    ? [
                        UIColor(red: 0.62, green: 0.46, blue: 1, alpha: 1).cgColor,
                        UIColor(red: 0.85, green: 0.68, blue: 1, alpha: 1).cgColor,
                    ]
                    : [UIColor.cyan.cgColor, UIColor(red: 0.05, green: 0.38, blue: 1, alpha: 1).cgColor]
                let color = reply ? UIColor(red: 0.73, green: 0.57, blue: 1, alpha: 1) : .cyan
                glow.strokeColor = color.cgColor
                glow.shadowColor = color.cgColor
                barMask.lineWidth = reply ? 2 : 3
                barMask.lineCap = reply ? .butt : .round
                glow.lineCap = reply ? .butt : .round
            }
            barMask.path = path
            glow.path = path
            glow.shadowPath = shadow
            if renderedActive != active {
                layer.opacity = active ? 0.95 : 0.15
                renderedActive = active
            }
            CATransaction.commit()
            if moving {
                animate(barMask, key: "path", from: previousMask, to: path)
                animate(glow, key: "path", from: previousGlow, to: path)
                animate(glow, key: "shadowPath", from: previousShadow, to: shadow)
            } else {
                barMask.removeAllAnimations()
                glow.removeAllAnimations()
            }
        }
        private func animate(_ shape: CAShapeLayer, key: String, from: CGPath?, to: CGPath) {
            guard let from else { return }
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = 0.1
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            shape.add(animation, forKey: key)
        }
    }
#endif

/// Fixed path topology permits native interpolation without a display timer.
struct VoiceSpectrumGeometry {
    static func bars(size: CGSize, bands: [Float], reply: Bool, active: Bool, reduceMotion: Bool) -> CGPath {
        let path = CGMutablePath()
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return path }
        for index in 0..<32 {
            let measured = index < bands.count && bands[index].isFinite ? CGFloat(bands[index]) : 0
            let energy = active ? (reduceMotion ? 0.08 : min(1, max(0, measured))) : 0
            let fraction = (CGFloat(index) + 0.5) / 32
            if reply {
                // Include both edges with 2pt-wide strokes; every root lies on the same bottom edge.
                let x = 1 + CGFloat(index) / 31 * max(0, size.width - 2)
                let length = min(size.height, 2 + energy * min(30, max(0, size.height - 2)))
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: length))
            } else {
                let x = fraction * size.width
                let height = 2 + energy * max(0, size.height - 4)
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x, y: size.height - height))
            }
        }
        return path
    }
}
