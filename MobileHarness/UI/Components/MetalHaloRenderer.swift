#if os(iOS)
    import Foundation
    @preconcurrency import Metal
    @preconcurrency import QuartzCore
    import Synchronization

    /// Cached compiled shader. Initialization is restricted to background preparation.
    final class HaloPipeline: @unchecked Sendable {
        let device: any MTLDevice
        let queue: any MTLCommandQueue
        let pipeline: any MTLRenderPipelineState
        static let prepared: Result<HaloPipeline, Error> = Result { try HaloPipeline() }
        private init() throws {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
                throw NSError(domain: "CompanionGraphics", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal 不可用"])
            }
            let library = try device.makeDefaultLibrary(bundle: .module)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "haloVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "haloFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            self.device = device
            self.queue = queue
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        }
        static func prewarm() { DispatchQueue.global(qos: .userInteractive).async { _ = prepared } }
    }

    private struct HaloControl: Sendable {
        var motion = ListeningMotion()
        var size = SIMD2<Float>(1, 1)
        var visible = false
        var wakeQueued = false
        var stopping = false
        var maximumFPS: Float = 60
    }
    private struct HaloUniforms {
        var size: SIMD2<Float>
        var origin: SIMD2<Float>
        var time: Float
        var opacity: Float
        var animated: Float
        var padding: Float = 0
    }

    /// One owner thread; latest-state slot and three GPU frames are the entire bounded workload.
    /// QuartzCore/Metal objects stay on this thread after preparation; control crosses via Mutex.
    final class MetalHaloRenderer: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
        private let metalLayer: CAMetalLayer
        private let context: HaloPipeline
        private let control = Mutex(HaloControl())
        private let slots = DispatchSemaphore(value: 3)
        private let failure: @Sendable (String) -> Void
        private var renderThread: Thread!
        // Render-thread-only fields.
        private var displayLink: CAMetalDisplayLink?
        private var stopped = false

        init(layer: CAMetalLayer, context: HaloPipeline, failure: @escaping @Sendable (String) -> Void) {
            metalLayer = layer
            self.context = context
            self.failure = failure
            super.init()
            renderThread = Thread { [self] in run() }
            renderThread.name = "MobileHarness.CompanionMetal"
            renderThread.qualityOfService = .userInteractive
            renderThread.start()
        }
        func update(motion: ListeningMotion, size: CGSize, visible: Bool, maximumFPS: Int) {
            let accepted = control.withLock { state in
                guard !state.stopping else { return false }
                state.motion = motion
                state.size = SIMD2(Float(max(1, size.width)), Float(max(1, size.height)))
                state.visible = visible
                state.maximumFPS = Float(maximumFPS)
                return true
            }
            guard accepted else { return }
            scheduleRefresh()
        }
        func stop() {
            let accepted = control.withLock { state in
                guard !state.stopping else { return false }
                state.stopping = true
                return true
            }
            guard accepted else { return }
            scheduleRefresh()
        }
        private func scheduleRefresh() {
            let wake = control.withLock { state in
                guard !state.wakeQueued else { return false }
                state.wakeQueued = true
                return true
            }
            if wake { perform(#selector(refresh), on: renderThread, with: nil, waitUntilDone: false) }
        }
        private func run() {
            let port = Port()
            RunLoop.current.add(port, forMode: .default)
            let link = CAMetalDisplayLink(metalLayer: metalLayer)
            link.delegate = self
            link.preferredFrameLatency = 1
            link.isPaused = true
            displayLink = link
            link.add(to: .current, forMode: .default)
            refresh()
            while !stopped { RunLoop.current.run(until: Date(timeIntervalSinceNow: 60)) }
            port.invalidate()
            renderThread = nil
        }
        @objc private func refresh() {
            guard !stopped else { return }
            let snapshot = control.withLock { state in
                state.wakeQueued = false
                return state
            }
            if snapshot.stopping {
                displayLink?.invalidate()
                displayLink = nil
                // GPU completion callbacks run off this thread. Never block the UI during teardown.
                for _ in 0..<3 { slots.wait() }
                stopped = true
                CFRunLoopStop(CFRunLoopGetCurrent())
            } else {
                // One final transparent frame clears the old field; frame callback decides when to pause.
                displayLink?.isPaused = !snapshot.visible
            }
        }
        func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
            autoreleasepool { render(link, update: update) }
        }
        private func render(_ link: CAMetalDisplayLink, update: CAMetalDisplayLink.Update) {
            let snapshot = control.withLock { $0 }
            guard snapshot.visible, !snapshot.stopping else {
                link.isPaused = true
                return
            }
            let time = update.targetPresentationTimestamp
            let fast =
                snapshot.motion.isEntering(at: time)
                || (!snapshot.motion.active && snapshot.motion.opacity(at: time) > 0)
            let maximumFPS = snapshot.maximumFPS
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: min(30, maximumFPS), maximum: fast ? maximumFPS : min(60, maximumFPS),
                preferred: fast ? maximumFPS : min(60, maximumFPS))
            guard slots.wait(timeout: .now()) == .success else { return }  // Drop this frame; never queue it.
            guard let command = context.queue.makeCommandBuffer() else {
                slots.signal()
                failure("无法创建光环渲染帧")
                link.isPaused = true
                return
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = update.drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                slots.signal()
                failure("无法创建光环渲染器")
                link.isPaused = true
                return
            }
            var uniforms = HaloUniforms(
                size: snapshot.size, origin: SIMD2(Float(snapshot.motion.origin.x), Float(snapshot.motion.origin.y)),
                time: Float(snapshot.motion.elapsed(at: time)),
                opacity: Float(snapshot.motion.opacity(at: time) * snapshot.motion.intensity),
                animated: snapshot.motion.reduceMotion ? 0 : 1)
            encoder.setRenderPipelineState(context.pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<HaloUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.present(update.drawable)
            command.addCompletedHandler { [slots, failure] buffer in
                slots.signal()
                if buffer.status == .error { failure(buffer.error?.localizedDescription ?? "光环 GPU 执行失败") }
            }
            command.commit()
            if !snapshot.motion.needsFrame(at: time) { link.isPaused = true }
        }
    }
#endif
