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

    // Thread is only published/read under the control mutex; perform(on:) is a cross-thread wake.
    private struct HaloControl: @unchecked Sendable {
        var state = HaloRenderState()
        var wakeQueued = false
        var finished = false
        var thread: Thread?
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
        let completion = DispatchGroup()
        // Render-thread-only fields.
        private var displayLink: CAMetalDisplayLink?
        private var stopped = false
        private var requestedRate: (minimum: Float, maximum: Float)?

        init(layer: CAMetalLayer, context: HaloPipeline, failure: @escaping @Sendable (String) -> Void) {
            metalLayer = layer
            self.context = context
            self.failure = failure
            super.init()
            completion.enter()
            let thread = Thread { [self] in run() }
            thread.name = "MobileHarness.CompanionMetal"
            thread.qualityOfService = .userInteractive
            control.withLock { $0.thread = thread }
            thread.start()
        }
        func update(motion: ListeningMotion, size: CGSize, visible: Bool, maximumFPS: Int) {
            let accepted = control.withLock {
                $0.state.update(motion: motion, size: size, visible: visible, maximumFPS: maximumFPS)
            }
            if accepted { scheduleRefresh() }
        }
        func stop() {
            if control.withLock({ $0.state.stop() }) { scheduleRefresh() }
        }
        private func fail(_ message: String) {
            guard control.withLock({ $0.state.fail() }) else { return }
            failure(message)
            scheduleRefresh()
        }
        private func scheduleRefresh() {
            let thread = control.withLock { state -> Thread? in
                guard !state.finished, !state.wakeQueued else { return nil }
                state.wakeQueued = true
                return state.thread
            }
            if let thread { perform(#selector(refresh), on: thread, with: nil, waitUntilDone: false) }
        }
        private func run() {
            defer { completion.leave() }
            let port = Port()
            RunLoop.current.add(port, forMode: .default)
            let link = CAMetalDisplayLink(metalLayer: metalLayer)
            link.delegate = self
            link.preferredFrameLatency = 1
            link.isPaused = true
            displayLink = link
            link.add(to: .current, forMode: .default)
            refresh()
            while !stopped { CFRunLoopRun() }
            port.invalidate()
            control.withLock {
                $0.finished = true
                $0.thread = nil
            }
        }
        @objc private func refresh() {
            guard !stopped else { return }
            let snapshot = control.withLock { state in
                state.wakeQueued = false
                return state.state
            }
            if snapshot.stopping {
                displayLink?.invalidate()
                displayLink = nil
                // GPU completion callbacks run off this thread. Never block the UI during teardown.
                for _ in 0..<3 { slots.wait() }
                // Joining borrows all permits; restore them before semaphore destruction.
                for _ in 0..<3 { slots.signal() }
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
            let snapshot = control.withLock { $0.state }
            guard snapshot.visible, !snapshot.stopping else {
                link.isPaused = true
                return
            }
            let time = update.targetPresentationTimestamp
            let fast =
                snapshot.motion.isEntering(at: time)
                || (!snapshot.motion.active && snapshot.motion.opacity(at: time) > 0)
            let maximumFPS = snapshot.maximumFPS
            let minimum = min(30, maximumFPS)
            let maximum = fast ? maximumFPS : min(60, maximumFPS)
            if requestedRate?.minimum != minimum || requestedRate?.maximum != maximum {
                link.preferredFrameRateRange = CAFrameRateRange(minimum: minimum, maximum: maximum, preferred: maximum)
                requestedRate = (minimum, maximum)
            }
            guard slots.wait(timeout: .now()) == .success else { return }
            // Drop this frame; never queue it.
            guard let command = context.queue.makeCommandBuffer() else {
                slots.signal()
                fail("无法创建光环渲染帧")
                return
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = update.drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                slots.signal()
                fail("无法创建光环渲染器")
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
            command.addCompletedHandler { [weak self, slots] buffer in
                if buffer.status == .error { self?.fail(buffer.error?.localizedDescription ?? "光环 GPU 执行失败") }
                slots.signal()
            }
            command.commit()
            if !snapshot.motion.needsFrame(at: time) { link.isPaused = true }
        }
    }
#endif
