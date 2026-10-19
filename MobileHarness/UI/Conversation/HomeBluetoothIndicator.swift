import CoreGraphics
import Foundation

/// Public safe-area estimate, not a query of the hardware or system activity's frame.
struct HomeBluetoothLayout {
    let attachesToIsland: Bool
    let size: CGSize
    let center: CGPoint
    let compactBackground: CGRect
    let glyphCenter: CGPoint
    let taskGlyphCenter: CGPoint
    static let glyphStrokeWidth: CGFloat = 1.6
    static let glyphHalfWidth: CGFloat = 5 + glyphStrokeWidth / 2

    init(viewportWidth: CGFloat, safeAreaTop: CGFloat) {
        attachesToIsland = safeAreaTop >= 59 && viewportWidth < 600
        if attachesToIsland {
            let islandWidth: CGFloat = 126
            let extensionWidth: CGFloat = 24
            let height: CGFloat = 37
            size = CGSize(width: islandWidth + extensionWidth * 2, height: height)
            center = CGPoint(x: viewportWidth / 2, y: -12 - height / 2)
            compactBackground = CGRect(x: extensionWidth, y: 0, width: islandWidth, height: height)
            glyphCenter = CGPoint(x: extensionWidth - Self.glyphHalfWidth, y: height / 2)
            taskGlyphCenter = CGPoint(x: size.width - glyphCenter.x, y: height / 2)
        } else {
            size = CGSize(width: 16, height: 24)
            center = CGPoint(x: 24, y: 16)
            compactBackground = .zero
            glyphCenter = CGPoint(x: size.width / 2, y: size.height / 2)
            taskGlyphCenter = glyphCenter
        }
    }

    var spectrumFrame: CGRect {
        CGRect(x: size.height / 2, y: size.height, width: max(0, size.width - size.height), height: 34)
    }

    func spectrumScale(expanded: Bool) -> CGFloat {
        guard attachesToIsland, spectrumFrame.width > 0 else { return 1 }
        return expanded ? 1 : (compactBackground.width - size.height) / spectrumFrame.width
    }

    var frame: CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }
}

/// Target presentation only; Core Animation owns finite gray/retraction timing.
struct HomeIslandPresentation: Equatable {
    var bluetooth: BluetoothConnectionStatus = .disconnected
    var hasTask = false
    var active = false
    var expanded: Bool { active && (bluetooth != .disconnected || hasTask) }
    var bluetoothVisible: Bool { active && bluetooth != .disconnected }
    var taskVisible: Bool { active && hasTask }
    static let transitionDuration: TimeInterval = 0.65
    static let grayDuration: TimeInterval = 0.15

    func transitionDelay(from previous: Self) -> TimeInterval {
        active && previous.bluetoothVisible && !bluetoothVisible ? Self.grayDuration : 0
    }
}

#if os(iOS)
    import SwiftUI
    import UIKit

    @MainActor
    struct HomeBluetoothIndicator: View {
        let status: BluetoothConnectionStatus
        let layout: HomeBluetoothLayout
        let playbackBands: [Float]
        let speaking: Bool
        let hasTask: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.scenePhase) private var scenePhase

        var body: some View {
            HomeBluetoothSurface(
                status: status, layout: layout, playbackBands: playbackBands, speaking: speaking, hasTask: hasTask,
                active: scenePhase == .active, reduceMotion: reduceMotion
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel((hasTask ? "任务进行中，" : "") + "机械臂蓝牙，" + status.title)
            .accessibilityIdentifier("home.bluetooth.status")
            .accessibilityHidden(layout.attachesToIsland && status == .disconnected && !hasTask)
            .allowsHitTesting(false)
        }
    }

    @MainActor
    private struct HomeBluetoothSurface: UIViewRepresentable {
        let status: BluetoothConnectionStatus
        let layout: HomeBluetoothLayout
        let playbackBands: [Float]
        let speaking: Bool
        let hasTask: Bool
        let active: Bool
        let reduceMotion: Bool

        func makeUIView(context: Context) -> HomeBluetoothIslandView { HomeBluetoothIslandView() }
        func updateUIView(_ view: HomeBluetoothIslandView, context: Context) {
            view.configure(
                status: status, layout: layout, playbackBands: playbackBands, speaking: speaking, hasTask: hasTask,
                active: active, reduceMotion: reduceMotion)
        }
        static func dismantleUIView(_ view: HomeBluetoothIslandView, coordinator: ()) { view.stopAnimations() }
    }

    /// One replaceable animation per property, with no delayed worker or completion callback.
    @MainActor
    private final class HomeBluetoothIslandView: UIView {
        private let shell = CAShapeLayer()
        private let glyph = CAShapeLayer()
        private let taskGlyph = UIImageView(
            image: UIImage(
                systemName: "scope", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)))
        private let spectrum = NativeSpectrumView()
        private let spectrumClip = CAShapeLayer()
        private var playbackBands: [Float] = []
        private var speaking = false
        private var hasTask = false
        private var layout = HomeBluetoothLayout(viewportWidth: 0, safeAreaTop: 0)
        private var status = BluetoothConnectionStatus.disconnected
        private var active = false
        private var reduceMotion = false
        private var previous = HomeIslandPresentation()
        private var previousSpeaking = false
        private var previousBounds = CGRect.zero

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            shell.fillColor = UIColor.black.cgColor
            layer.addSublayer(shell)
            glyph.fillColor = nil
            glyph.lineWidth = HomeBluetoothLayout.glyphStrokeWidth
            glyph.lineCap = .round
            glyph.lineJoin = .round
            layer.addSublayer(glyph)
            taskGlyph.tintColor = .white
            taskGlyph.contentMode = .scaleAspectFit
            addSubview(taskGlyph)
            addSubview(spectrum)
            spectrum.layer.anchorPoint = CGPoint(x: 0.5, y: 0)
            spectrum.layer.mask = spectrumClip
            spectrumClip.fillColor = UIColor.white.cgColor
        }
        required init?(coder: NSCoder) { nil }

        func configure(
            status: BluetoothConnectionStatus, layout: HomeBluetoothLayout, playbackBands: [Float], speaking: Bool,
            hasTask: Bool, active: Bool, reduceMotion: Bool
        ) {
            self.playbackBands = Array(playbackBands.prefix(32))
            self.speaking = speaking
            self.hasTask = hasTask
            self.status = status
            self.layout = layout
            self.active = active
            self.reduceMotion = reduceMotion
            if !active || reduceMotion { stopAnimations() }
            setNeedsLayout()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                stopAnimations()
                previous = HomeIslandPresentation()
                previousSpeaking = false
                previousBounds = .zero
            }
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard !bounds.isEmpty else { return }
            let attached = layout.attachesToIsland
            let next = HomeIslandPresentation(bluetooth: status, hasTask: hasTask, active: active && window != nil)
            let compact = UIBezierPath(roundedRect: layout.compactBackground, cornerRadius: bounds.height / 2).cgPath
            let target = UIBezierPath(
                roundedRect: next.expanded ? bounds : layout.compactBackground, cornerRadius: bounds.height / 2
            ).cgPath
            let geometryChanged = previousBounds != bounds
            let animated = attached && next.active && !reduceMotion && (!geometryChanged || previousBounds.isEmpty)
            let shellSource = shell.presentation()?.path ?? shell.path ?? compact
            let glyphX = glyph.presentation()?.position.x ?? glyph.position.x
            let glyphAlpha = glyph.presentation()?.opacity ?? glyph.opacity
            let taskX = taskGlyph.layer.presentation()?.position.x ?? taskGlyph.layer.position.x
            let taskAlpha = taskGlyph.layer.presentation()?.opacity ?? taskGlyph.layer.opacity
            let spectrumX =
                spectrum.layer.presentation()?.transform.m11 ?? layout.spectrumScale(expanded: previous.expanded)
            let spectrumY =
                spectrum.layer.presentation()?.transform.m22 ?? (previous.active && previousSpeaking ? 1 : 0)
            let glyphTargetX = layout.glyphCenter.x + (next.bluetoothVisible ? 0 : 18)
            let taskTargetX = layout.taskGlyphCenter.x - (next.taskVisible ? 0 : 18)
            let spectrumScale = layout.spectrumScale(expanded: next.expanded)
            let spectrumVisible = next.active && speaking
            let delay = next.transitionDelay(from: previous)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shell.frame = bounds
            shell.path = target
            shell.isHidden = !attached
            glyph.bounds = CGRect(x: 0, y: 0, width: 16, height: attached ? 22 : 24)
            glyph.position = CGPoint(x: attached ? glyphTargetX : layout.glyphCenter.x, y: layout.glyphCenter.y)
            glyph.path = Self.glyphPath(size: glyph.bounds.size)
            glyph.strokeColor = (status == .disconnected ? UIColor.systemGray : UIColor.systemBlue).cgColor
            glyph.opacity = !attached || next.bluetoothVisible ? 1 : 0
            taskGlyph.bounds = CGRect(
                x: 0, y: 0, width: HomeBluetoothLayout.glyphHalfWidth * 2,
                height: HomeBluetoothLayout.glyphHalfWidth * 2)
            taskGlyph.layer.position = CGPoint(x: taskTargetX, y: layout.taskGlyphCenter.y)
            taskGlyph.layer.opacity = attached && next.taskVisible ? 1 : 0
            spectrum.bounds = CGRect(origin: .zero, size: layout.spectrumFrame.size)
            spectrum.layer.position = CGPoint(x: layout.spectrumFrame.midX, y: layout.spectrumFrame.minY)
            spectrum.layer.transform = CATransform3DMakeScale(spectrumScale, spectrumVisible ? 1 : 0, 1)
            spectrum.isHidden = !attached || !next.active
            spectrumClip.frame = spectrum.bounds
            spectrumClip.path = CGPath(rect: spectrum.bounds, transform: nil)
            CATransaction.commit()
            spectrum.update(reply: true, bands: playbackBands, active: spectrumVisible, reduceMotion: reduceMotion)

            if !animated { stopAnimations() }
            if animated {
                let begin = CACurrentMediaTime()
                if next.expanded != previous.expanded {
                    animate(shell, key: "path", from: shellSource, to: target, begin: begin, delay: delay)
                    animate(
                        spectrum.layer, key: "transform.scale.x", from: spectrumX, to: spectrumScale, begin: begin,
                        delay: delay)
                }
                if next.bluetoothVisible != previous.bluetoothVisible {
                    animate(
                        glyph, key: "position.x", from: previousBounds.isEmpty ? layout.glyphCenter.x + 18 : glyphX,
                        to: glyphTargetX, begin: begin, delay: delay)
                    animate(
                        glyph, key: "opacity", from: previousBounds.isEmpty ? 0 : glyphAlpha,
                        to: next.bluetoothVisible ? 1 : 0, begin: begin, delay: delay, spring: false)
                }
                if next.taskVisible != previous.taskVisible {
                    animate(
                        taskGlyph.layer, key: "position.x",
                        from: previousBounds.isEmpty ? layout.taskGlyphCenter.x - 18 : taskX,
                        to: taskTargetX, begin: begin)
                    animate(
                        taskGlyph.layer, key: "opacity", from: previousBounds.isEmpty ? 0 : taskAlpha,
                        to: next.taskVisible ? 1 : 0, begin: begin, spring: false)
                }
                if spectrumVisible != (previous.active && previousSpeaking) {
                    animate(
                        spectrum.layer, key: "transform.scale.y", from: spectrumY, to: spectrumVisible ? 1 : 0,
                        begin: begin, spring: false, duration: 0.24)
                }
            }
            if status.isConnecting && next.active && !reduceMotion {
                if glyph.animation(forKey: "bluetooth.connecting") == nil {
                    let pulse = CABasicAnimation(keyPath: "opacity")
                    pulse.fromValue = 0.35
                    pulse.toValue = 1
                    pulse.duration = 0.65
                    pulse.autoreverses = true
                    pulse.repeatCount = .infinity
                    pulse.beginTime =
                        CACurrentMediaTime() + (next.bluetoothVisible != previous.bluetoothVisible ? 0.65 : 0)
                    glyph.add(pulse, forKey: "bluetooth.connecting")
                }
            } else {
                glyph.removeAnimation(forKey: "bluetooth.connecting")
            }
            previous = next
            previousSpeaking = speaking
            previousBounds = bounds
        }

        func stopAnimations() {
            for target in [shell, glyph, taskGlyph.layer, spectrum.layer] { target.removeAllAnimations() }
            spectrum.stopAnimations()
        }

        private func animate(
            _ target: CALayer, key: String, from: Any, to: Any, begin: CFTimeInterval, delay: TimeInterval = 0,
            spring: Bool = true, duration: TimeInterval = HomeIslandPresentation.transitionDuration
        ) {
            let animation: CABasicAnimation
            if spring {
                let value = CASpringAnimation(keyPath: key)
                value.mass = 1
                value.stiffness = 240
                value.damping = 26
                animation = value
            } else {
                animation = CABasicAnimation(keyPath: key)
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            }
            animation.fromValue = from
            animation.toValue = to
            animation.beginTime = begin + delay
            animation.duration = duration
            animation.fillMode = .backwards
            target.add(animation, forKey: "home." + key)
        }

        private static func glyphPath(size: CGSize) -> CGPath {
            let path = UIBezierPath()
            let x = size.width / 2
            let top: CGFloat = 2
            let bottom = size.height - 2
            path.move(to: CGPoint(x: x, y: top))
            path.addLine(to: CGPoint(x: x + 5, y: top + 5))
            path.addLine(to: CGPoint(x: x - 5, y: bottom - 5))
            path.move(to: CGPoint(x: x, y: bottom))
            path.addLine(to: CGPoint(x: x + 5, y: bottom - 5))
            path.addLine(to: CGPoint(x: x - 5, y: top + 5))
            path.move(to: CGPoint(x: x, y: top))
            path.addLine(to: CGPoint(x: x, y: bottom))
            return path.cgPath
        }
    }
#endif
