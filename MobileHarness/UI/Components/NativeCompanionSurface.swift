import Foundation

#if os(iOS)
    import QuartzCore
    import SwiftUI
    import UIKit

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

    @MainActor
    struct NativeCompanionSurface: UIViewRepresentable {
        var phase: VoicePhase
        var reduceMotion: Bool
        var expression: EyeExpression
        var emphasized = false
        var transitionID: String?
        var gaze: CGSize = .zero
        var faceWidth: CGFloat
        var eyeCenter: CGPoint
        var haloEnabled = true
        var active: Bool
        var generation: String?
        var lightOrigin: ListeningLightOrigin?
        var decorativeLight: DecorativeLight?
        var held = false
        var completion: (@MainActor (String, Bool) -> Void)?
        var availability: (@MainActor (Bool) -> Void)?
        var failure: (@MainActor (String?) -> Void)?
        @Environment(\.scenePhase) private var scenePhase
        func makeUIView(context: Context) -> CompanionSurfaceView { CompanionSurfaceView(haloEnabled: haloEnabled) }
        func updateUIView(_ view: CompanionSurfaceView, context: Context) {
            view.apply(self, foreground: scenePhase == .active)
        }
        static func dismantleUIView(_ view: CompanionSurfaceView, coordinator: ()) { view.dispose() }
    }

    private final class EyeAnimationReceipt: NSObject, CAAnimationDelegate, @unchecked Sendable {
        let result: @Sendable (Bool) -> Void
        init(result: @escaping @Sendable (Bool) -> Void) { self.result = result }
        func animationDidStop(_ anim: CAAnimation, finished flag: Bool) { result(flag) }
    }

    @MainActor
    final class CompanionSurfaceView: UIView {
        private let haloLayer = CAMetalLayer()
        private let face = CALayer()
        private let gazeLayer = CALayer()
        private let breath = CALayer()
        private let blink = CALayer()
        private let left = CAShapeLayer()
        private let right = CAShapeLayer()
        private var renderer: MetalHaloRenderer?
        private var pipelineReady = false
        private var disposed = false
        private var latest: NativeCompanionSurface?
        private var committed: NativeCompanionSurface?
        private var foreground = true
        private var motion = ListeningMotion()
        private var receipt: EyeAnimationReceipt?
        private let haloEnabled: Bool
        private var lastSize: CGSize = .zero

        init(haloEnabled: Bool) {
            self.haloEnabled = haloEnabled
            super.init(frame: .zero)
            isOpaque = false
            isUserInteractionEnabled = false
            clipsToBounds = false
            haloLayer.isOpaque = false
            haloLayer.pixelFormat = .bgra8Unorm
            haloLayer.framebufferOnly = true
            haloLayer.maximumDrawableCount = 3
            haloLayer.zPosition = -1
            if haloEnabled { layer.addSublayer(haloLayer) }
            layer.addSublayer(face)
            face.addSublayer(gazeLayer)
            gazeLayer.addSublayer(breath)
            breath.addSublayer(blink)
            blink.addSublayer(left)
            blink.addSublayer(right)
            for eye in [left, right] {
                eye.fillColor = UIColor(red: 0.08, green: 0.62, blue: 1, alpha: 1).cgColor
                eye.shadowColor = UIColor.systemBlue.cgColor
                eye.shadowRadius = 14
                eye.shadowOffset = .zero
                eye.shadowOpacity = 0.32
            }
            if haloEnabled {
                DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                    let result = HaloPipeline.prepared
                    Task { @MainActor [weak self] in self?.prepared(result) }
                }
            } else {
                pipelineReady = true
                HaloPipeline.prewarm()
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        deinit { renderer?.stop() }

        private func prepared(_ result: Result<HaloPipeline, Error>) {
            guard !disposed else { return }
            switch result {
            case .success(let context):
                haloLayer.device = context.device
                renderer = MetalHaloRenderer(
                    layer: haloLayer, context: context,
                    failure: { [weak self] message in Task { @MainActor in self?.latest?.failure?(message) } })
                latest?.failure?(nil)
            case .failure(let error):
                latest?.failure?("光环不可用：" + error.localizedDescription)
            }
            // Even on a renderer failure, eyes still acknowledge real expression execution.
            pipelineReady = true
            commitLatest()
        }
        func apply(_ input: NativeCompanionSurface, foreground: Bool) {
            if latest?.eyeCenter != input.eyeCenter || latest?.faceWidth != input.faceWidth { setNeedsLayout() }
            latest = input
            self.foreground = foreground
            commitLatest()
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            setNeedsLayout()
            latest?.availability?(window != nil && foreground && !disposed)
            commitLatest()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard !disposed, let input = latest, bounds.width > 0 else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let window {
                let frame = convert(window.bounds, from: window)
                let scale = window.screen.scale
                let pixels = CGSize(width: frame.width * scale, height: frame.height * scale)
                if haloLayer.frame != frame { haloLayer.frame = frame }
                if haloLayer.contentsScale != scale { haloLayer.contentsScale = scale }
                if haloLayer.drawableSize != pixels { haloLayer.drawableSize = pixels }
            } else if haloLayer.frame != bounds {
                haloLayer.frame = bounds
            }
            face.position = input.eyeCenter
            let eyeSize = CGSize(width: input.faceWidth * 0.21, height: input.faceWidth * 0.25)
            for (index, eye) in [left, right].enumerated() {
                eye.bounds = CGRect(origin: .zero, size: eyeSize)
                eye.position = CGPoint(x: (index == 0 ? -1 : 1) * input.faceWidth * 0.20, y: 0)
                eye.contentsScale = window?.screen.scale ?? traitCollection.displayScale
            }
            let changedSize = lastSize != bounds.size
            if committed == nil || changedSize {
                let pose = EyePose.pair(for: committed?.expression ?? .closed)
                setEye(left, pose: pose.0, mirrored: false, width: input.faceWidth, duration: 0, at: 0)
                setEye(right, pose: pose.1, mirrored: true, width: input.faceWidth, duration: 0, at: 0)
            }
            lastSize = bounds.size
            CATransaction.commit()
            commitLatest()
        }
        private func commitLatest() {
            guard !disposed, pipelineReady, bounds.width > 0, let input = latest else { return }
            let previous = committed
            let now = CACurrentMediaTime()
            let visible = window != nil && foreground
            latest?.availability?(visible)
            let newGeneration = input.active && (previous?.active != true || previous?.generation != input.generation)
            let lightActive = input.active || input.decorativeLight != nil
            let lightGeneration = input.decorativeLight?.id ?? input.generation
            let wasLightActive = (previous?.active ?? false) || previous?.decorativeLight != nil
            let restoringListening =
                input.active && input.decorativeLight == nil && previous?.decorativeLight != nil
                && input.generation == previous?.generation
            let newLight =
                lightActive && !restoringListening
                && (!wasLightActive
                    || (previous?.decorativeLight?.id ?? previous?.generation) != lightGeneration)
            let source =
                input.decorativeLight?.origin ?? input.lightOrigin
                ?? ListeningLightOrigin(
                    x: input.eyeCenter.x / bounds.width, y: input.eyeCenter.y / bounds.height)
            let origin = ListeningLightOrigin(
                x: (source.x * bounds.width - haloLayer.frame.minX) / max(1, haloLayer.bounds.width),
                y: (source.y * bounds.height - haloLayer.frame.minY) / max(1, haloLayer.bounds.height))
            motion.update(
                active: lightActive, generation: lightGeneration, reduceMotion: input.reduceMotion,
                origin: origin, initialOpacity: input.decorativeLight?.initialOpacity ?? 0.85,
                intensity: input.decorativeLight?.intensity ?? 1, replayEntry: !restoringListening, at: now)
            renderer?.update(
                motion: motion, size: haloLayer.bounds.size, visible: visible,
                maximumFPS: window?.screen.maximumFramesPerSecond ?? 60)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if haloEnabled, newLight, !input.reduceMotion {
                let flashOrder = CAKeyframeAnimation(keyPath: "zPosition")
                flashOrder.values = [1, 1, -1]
                flashOrder.keyTimes = [0, 0.999, 1]
                flashOrder.calculationMode = .discrete
                flashOrder.duration = 0.9
                flashOrder.beginTime = now
                haloLayer.add(flashOrder, forKey: "contactFlashOrder")
            }
            let expressionChanged =
                previous?.expression != input.expression || previous?.transitionID != input.transitionID
                || previous?.emphasized != input.emphasized || newGeneration
            if expressionChanged {
                face.removeAnimation(forKey: "receipt")
                receipt = nil
                let waking = (previous?.expression ?? .closed) == .closed && input.expression != .closed
                let duration = input.reduceMotion ? 0.2 : waking ? 0.18 : input.expression == .closed ? 0.46 : 0.65
                let poses = EyePose.pair(for: input.expression)
                setEye(left, pose: poses.0, mirrored: false, width: input.faceWidth, duration: duration, at: now)
                setEye(right, pose: poses.1, mirrored: true, width: input.faceWidth, duration: duration, at: now)
                if let id = input.transitionID, visible {
                    let callback = EyeAnimationReceipt { [weak self] finished in
                        Task { @MainActor in
                            guard let self, self.latest?.transitionID == id else { return }
                            self.latest?.completion?(id, finished)
                        }
                    }
                    receipt = callback
                    let sentinel = CABasicAnimation(keyPath: "zPosition")
                    sentinel.fromValue = 0
                    sentinel.toValue = 0
                    sentinel.duration = duration
                    sentinel.beginTime = face.convertTime(now, from: nil)
                    sentinel.delegate = callback
                    face.add(sentinel, forKey: "receipt")
                }
                if waking {
                    blink.removeAllAnimations()
                    breath.removeAllAnimations()
                }
            }
            let targetScale: CGFloat = (input.emphasized ? 1.06 : 1) * (input.held ? 0.975 : 1)
            if previous?.emphasized != input.emphasized || previous?.held != input.held || previous == nil {
                animate(
                    face, key: "transform",
                    to: NSValue(caTransform3D: CATransform3DMakeScale(targetScale, targetScale, 1)),
                    duration: 0.18, at: now)
            }
            if previous?.gaze != input.gaze || previous == nil {
                let point = CGPoint(
                    x: min(1, max(-1, input.gaze.width)) * input.faceWidth * 0.14,
                    y: min(1, max(-1, input.gaze.height)) * input.faceWidth * 0.09)
                animate(gazeLayer, key: "position", to: NSValue(cgPoint: point), duration: 0.32, at: now)
            }
            let opacity: Float = input.phase == .idle || input.phase == .failed ? 0.48 : 1
            if previous?.phase != input.phase || previous == nil {
                animate(face, key: "opacity", to: opacity, duration: 0.18, at: now)
            }
            CATransaction.commit()
            committed = input
            updateAmbient(input, visible: visible, at: now)
            if !visible, let id = input.transitionID { input.completion?(id, false) }
        }
        private func setEye(
            _ eye: CAShapeLayer, pose: EyePose, mirrored: Bool, width: CGFloat, duration: Double, at: Double
        ) {
            let path = EyeContour(smile: pose.smile, slant: pose.slant, heart: pose.heart, closure: pose.closure).path(
                in: eye.bounds)
            var transform = CATransform3DMakeTranslation(pose.x * width, pose.y * width, 0)
            transform = CATransform3DRotate(transform, pose.tilt * (mirrored ? -1 : 1) * .pi / 180, 0, 0, 1)
            transform = CATransform3DScale(transform, (mirrored ? -1 : 1) * pose.width, pose.openness, 1)
            animate(eye, key: "path", to: path, duration: duration, at: at, waking: pose.closure == 0)
            animate(eye, key: "shadowPath", to: path, duration: duration, at: at, waking: pose.closure == 0)
            animate(eye, key: "transform", to: NSValue(caTransform3D: transform), duration: duration, at: at)
            let color = pose.heart > 0 ? UIColor.systemPink : UIColor(red: 0.08, green: 0.62, blue: 1, alpha: 1)
            animate(eye, key: "fillColor", to: color.cgColor, duration: duration, at: at)
            animate(eye, key: "shadowOpacity", to: Float(pose.closure > 0 ? 0.32 : 0.65), duration: duration, at: at)
        }
        private func animate(
            _ layer: CALayer, key: String, to target: Any, duration: Double, at time: Double, waking: Bool = false
        ) {
            let current = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
            layer.setValue(target, forKeyPath: key)
            guard duration > 0, let current else {
                layer.removeAnimation(forKey: key)
                return
            }
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = current
            animation.toValue = target
            animation.duration = duration
            let maximumFPS = Float(window?.screen.maximumFramesPerSecond ?? 60)
            animation.preferredFrameRateRange = CAFrameRateRange(
                minimum: min(60, maximumFPS), maximum: maximumFPS, preferred: maximumFPS)
            animation.beginTime = layer.convertTime(time, from: nil)
            animation.timingFunction =
                waking && duration <= 0.2
                ? CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1) : CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(animation, forKey: key)
        }
        private func updateAmbient(_ input: NativeCompanionSurface, visible: Bool, at time: Double) {
            guard visible, !input.reduceMotion, input.expression != .closed else {
                blink.removeAllAnimations()
                breath.removeAllAnimations()
                return
            }
            guard blink.animation(forKey: "blink") == nil else { return }
            let blinking = CAKeyframeAnimation(keyPath: "transform.scale.y")
            blinking.values = [1, 1, 0.06, 1, 1]
            blinking.keyTimes = [0, 0.83, 0.86, 0.90, 1]
            blinking.duration = 5.3
            blinking.beginTime = blink.convertTime(time + 1.2, from: nil)
            blinking.repeatCount = .infinity
            blinking.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
            blink.add(blinking, forKey: "blink")
            let breathing = CABasicAnimation(keyPath: "transform.translation.y")
            breathing.fromValue = -2
            breathing.toValue = 2
            breathing.duration = 1.96
            breathing.beginTime = breath.convertTime(time + 1.2, from: nil)
            breathing.autoreverses = true
            breathing.repeatCount = .infinity
            breathing.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breath.add(breathing, forKey: "breath")
        }
        func dispose() {
            guard !disposed else { return }
            disposed = true
            latest?.availability?(false)
            if let id = latest?.transitionID { latest?.completion?(id, false) }
            renderer?.stop()
            renderer = nil
            face.removeAllAnimations()
            latest = nil
            committed = nil
        }
    }
#endif
