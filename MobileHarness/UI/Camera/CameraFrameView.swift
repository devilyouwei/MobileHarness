#if os(iOS)
    import SwiftUI
    import UIKit

    /// Camera image and latest valid pose update independently with shared geometry.
    @MainActor
    public struct CameraFrameView: UIViewRepresentable {
        @Bindable private var state: CameraState
        public init(state: CameraState) { self.state = state }
        public func makeUIView(context: Context) -> CameraFrameSurface { CameraFrameSurface() }
        public func updateUIView(_ view: CameraFrameSurface, context: Context) {
            let state = state
            let generation = state.videoGeneration
            view.onFailure = { [weak state] _ in state?.presentRendererFailure("相机画面渲染不可用", generation: generation) }
            view.update(
                frame: state.videoFrame, pose: state.skeleton, mirrored: state.facing == .front, generation: generation)
        }
        public static func dismantleUIView(_ view: CameraFrameSurface, coordinator: ()) { view.stopRenderer() }
    }

    /// The main thread only owns UIKit, layout, and the latest immutable submission.
    @MainActor
    public final class CameraFrameSurface: UIView {
        public override class var layerClass: AnyClass { CAMetalLayer.self }
        private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
        private var renderer: CameraMetalRenderer?
        private var previousCompletion: DispatchGroup?
        private var cameraGeneration: UInt64?
        private var epoch: UInt64 = 0
        private var video: CameraVideoFrame?
        private var pose: PoseOverlay?
        private var mirrored = false
        private var failed = false
        public var onFailure: (@MainActor (String) -> Void)?

        public override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            metalLayer.device = CameraMetalResources.device
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.maximumDrawableCount = 2
            metalLayer.isOpaque = true
        }
        public required init?(coder: NSCoder) { nil }
        deinit { renderer?.stop() }
        public func update(frame: CameraVideoFrame?, pose: PoseOverlay?, mirrored: Bool, generation: UInt64) {
            if cameraGeneration != generation {
                stopRenderer()
                cameraGeneration = generation
                failed = false
            }
            video = frame
            self.pose = pose
            self.mirrored = mirrored
            startRenderer()
            submit()
        }
        public override func layoutSubviews() {
            super.layoutSubviews()
            let scale = window?.screen.scale ?? contentScaleFactor
            let pixels = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            // Caption layout can revisit this view without changing the camera surface.
            // Avoid touching the drawable pool or animating native layer geometry in that case.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if metalLayer.contentsScale != scale { metalLayer.contentsScale = scale }
            if metalLayer.drawableSize != pixels { metalLayer.drawableSize = pixels }
            CATransaction.commit()
            submit()
        }
        public override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else {
                stopRenderer()
                return
            }
            startRenderer()
        }
        private func startRenderer() {
            guard window != nil else { return }
            guard renderer == nil, !failed else { return }
            epoch &+= 1
            let generation = epoch
            metalLayer.isHidden = false
            renderer = CameraMetalRenderer(layer: metalLayer, previousCompletion: previousCompletion) {
                [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self, self.epoch == generation, self.renderer != nil else { return }
                    self.failed = true
                    self.stopRenderer()
                    self.video = nil
                    self.pose = nil
                    self.onFailure?(message)
                }
            }
            setNeedsLayout()
            submit()
        }
        fileprivate func stopRenderer() {
            epoch &+= 1
            metalLayer.isHidden = true
            renderer?.stop()
            if let renderer { previousCompletion = renderer.completion }
            renderer = nil
        }
        private func submit() {
            guard !failed else { return }
            renderer?.submit(
                CameraRenderSnapshot(
                    frame: video, pose: pose, mirrored: mirrored, size: bounds.size,
                    pixelSize: metalLayer.drawableSize))
        }
    }

#endif

#if os(iOS) || os(macOS)
    import CoreVideo
    import Foundation
    @preconcurrency import Metal
    @preconcurrency import QuartzCore
    import Synchronization

    /// Compilation is lazy on the render thread, shared across surface lifetimes.
    private final class CameraMetalResources: @unchecked Sendable {
        static let device = MTLCreateSystemDefaultDevice()
        static let prepared: Result<CameraMetalResources, Error> = Result { try CameraMetalResources() }
        let pipeline: any MTLRenderPipelineState
        let overlay: any MTLRenderPipelineState
        private init() throws {
            guard let device = Self.device else { throw CameraMetalError.unavailable("Metal device") }
            let shader = """
                #include <metal_stdlib>
                using namespace metal;
                struct Vertex { float4 position [[position]]; float2 uv; };
                vertex Vertex cameraVertex(uint i [[vertex_id]]) {
                    const float2 p[] = { {-1,1}, {-1,-1}, {1,1}, {1,1}, {-1,-1}, {1,-1} };
                    Vertex v; v.position=float4(p[i],0,1); v.uv=float2((p[i].x+1)/2,(1-p[i].y)/2); return v;
                }
                fragment float4 cameraPixel(Vertex v [[stage_in]], texture2d<float> image [[texture(0)]],
                    constant float4& geometry [[buffer(0)]]) {
                    float2 uv=(v.uv-0.5)*geometry.zw+0.5;
                    if (geometry.y>0.5) uv.x=1-uv.x;
                    int r=int(geometry.x);
                    if(r==1) uv=float2(uv.y,1-uv.x);
                    else if(r==2) uv=1-uv;
                    else if(r==3) uv=float2(1-uv.y,uv.x);
                    constexpr sampler s(filter::linear,address::clamp_to_edge);
                    return image.sample(s,uv);
                }
                vertex float4 overlayVertex(const device float2 *points [[buffer(0)]], uint i [[vertex_id]]) {
                    return float4(points[i],0,1);
                }
                fragment float4 overlayPixel() { return float4(0,1,0,1); }
                """
            let library = try device.makeLibrary(source: shader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "cameraVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "cameraPixel")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            descriptor.vertexFunction = library.makeFunction(name: "overlayVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "overlayPixel")
            overlay = try device.makeRenderPipelineState(descriptor: descriptor)
        }
    }
    private enum CameraMetalError: Error { case unavailable(String) }
    /// Immutable ownership only; the completion callback never reads or mutates native pixels/textures.
    private struct CameraGPUFrame: @unchecked Sendable {
        let frame: CameraVideoFrame?
        let texture: CVMetalTexture?
    }
    // Thread is only published/read under control's mutex; perform(on:) is a cross-thread wake.
    private struct CameraRenderControl: @unchecked Sendable {
        var mailbox = CameraRenderMailbox()
        var thread: Thread?
        var wakeQueued = false
        var finished = false
    }

    /// One owner thread, one latest state, two GPU slots. No per-submission tasks.
    final class CameraMetalRenderer: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {

        private let layer: CAMetalLayer
        private let failure: @Sendable (String) -> Void
        let completion = DispatchGroup()
        private let previousCompletion: DispatchGroup?
        private let control = Mutex(CameraRenderControl())
        private let available = Mutex([0, 1])
        private let slots = DispatchSemaphore(value: 2)
        private let completedFrames = Mutex(0)
        var completedFrameCount: Int { completedFrames.withLock { $0 } }
        // Render-thread-only fields; GPU completion only returns a slot and signals failure.
        private var link: CAMetalDisplayLink?
        private var stopped = false
        private var resources: CameraMetalResources?
        private var commands: (any MTLCommandQueue)?
        private var cache: CVMetalTextureCache?
        private var buffers: [any MTLBuffer] = []
        private var bufferRevisions: [UInt64?] = [nil, nil]
        private var mesh = CameraSkeletonMesh()

        init(layer: CAMetalLayer, previousCompletion: DispatchGroup?, failure: @escaping @Sendable (String) -> Void) {
            self.layer = layer
            self.previousCompletion = previousCompletion
            self.failure = failure
            super.init()
            completion.enter()
            let thread = Thread { [self] in run() }
            thread.name = "MobileHarness.CameraMetal"
            thread.qualityOfService = .userInteractive
            control.withLock { $0.thread = thread }
            thread.start()
        }
        func submit(_ snapshot: CameraRenderSnapshot) {
            guard control.withLock({ $0.mailbox.submit(snapshot) }) else { return }

            scheduleRefresh()
        }
        func stop() {
            guard control.withLock({ $0.mailbox.stop() }) else { return }
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
        private func fail(_ message: String) {
            guard control.withLock({ $0.mailbox.stop() }) else { return }
            failure(message)
            scheduleRefresh()
        }
        private func run() {
            previousCompletion?.wait()
            defer { completion.leave() }
            let port = Port()
            RunLoop.current.add(port, forMode: .default)
            do {
                resources = try CameraMetalResources.prepared.get()
                guard let device = CameraMetalResources.device, let commands = device.makeCommandQueue() else {
                    throw CameraMetalError.unavailable("Metal command queue")
                }
                self.commands = commands
                let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
                guard status == kCVReturnSuccess else { throw CameraMetalError.unavailable("Texture cache: \(status)") }
                for _ in 0..<2 {
                    guard
                        let buffer = device.makeBuffer(
                            length: CameraSkeletonMesh.maximumVertices * MemoryLayout<SIMD2<Float>>.stride,
                            options: .storageModeShared)
                    else { throw CameraMetalError.unavailable("Skeleton buffer") }
                    buffers.append(buffer)
                }
                let link = CAMetalDisplayLink(metalLayer: layer)
                link.delegate = self
                link.preferredFrameLatency = 1
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                link.isPaused = true
                self.link = link
                link.add(to: .current, forMode: .default)
            } catch { fail("Camera renderer unavailable: \(error)") }
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
            let state = control.withLock { state in
                state.wakeQueued = false
                return (state.mailbox.stopped, state.mailbox.pending)
            }
            if state.0 {
                link?.invalidate()
                link = nil
                // Completion signals directly, independently of this run loop and the main thread.
                for _ in 0..<2 { slots.wait() }
                // Joining borrows both permits; restore them before semaphore destruction.
                for _ in 0..<2 { slots.signal() }
                buffers.removeAll()
                cache = nil
                commands = nil
                resources = nil
                stopped = true
                CFRunLoopStop(CFRunLoopGetCurrent())
            } else {
                link?.isPaused = !state.1
            }
        }
        func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
            autoreleasepool { render(link, drawable: update.drawable) }
        }
        private func release(_ slot: Int) {
            available.withLock { $0.append(slot) }
            slots.signal()
        }
        private func render(_ link: CAMetalDisplayLink, drawable: any CAMetalDrawable) {
            guard slots.wait(timeout: .now()) == .success else { return }
            guard var snapshot = control.withLock({ $0.mailbox.take() }) else {
                slots.signal()
                link.isPaused = true
                return
            }
            let slot = available.withLock { $0.removeLast() }
            var committed = false
            defer { if !committed { release(slot) } }
            guard snapshot.size.width > 0, snapshot.size.height > 0,
                snapshot.pixelSize.width > 0, snapshot.pixelSize.height > 0
            else { return }
            if let frame = snapshot.frame, frame.capturedAt.duration(to: .now) >= .milliseconds(750) {
                snapshot.frame = nil
                snapshot.pose = nil
            }
            guard let resources, let command = commands?.makeCommandBuffer() else {
                fail("Camera command buffer unavailable")
                return
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                fail("Camera render encoder unavailable")
                return
            }
            var texture: CVMetalTexture?
            if let frame = snapshot.frame {
                guard let cache else {
                    encoder.endEncoding()
                    fail("Camera texture cache unavailable")
                    return
                }
                let status = CVMetalTextureCacheCreateTextureFromImage(
                    nil, cache, frame.pixels, nil, .bgra8Unorm, CVPixelBufferGetWidth(frame.pixels),
                    CVPixelBufferGetHeight(frame.pixels), 0, &texture)
                guard status == kCVReturnSuccess, let texture, let image = CVMetalTextureGetTexture(texture) else {
                    encoder.endEncoding()
                    fail("Camera texture unavailable: \(status)")
                    return
                }
                let scale = max(
                    snapshot.size.width / CGFloat(frame.width), snapshot.size.height / CGFloat(frame.height))
                var geometry = SIMD4<Float>(
                    Float(frame.rotation), snapshot.mirrored ? 1 : 0,
                    Float(snapshot.size.width / (CGFloat(frame.width) * scale)),
                    Float(snapshot.size.height / (CGFloat(frame.height) * scale)))
                encoder.setRenderPipelineState(resources.pipeline)
                encoder.setFragmentTexture(image, index: 0)
                encoder.setFragmentBytes(&geometry, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                mesh.update(snapshot)
                if !mesh.vertices.isEmpty {
                    let buffer = buffers[slot]
                    if bufferRevisions[slot] != mesh.revision {
                        mesh.vertices.withUnsafeBytes { bytes in
                            if let base = bytes.baseAddress {
                                buffer.contents().copyMemory(from: base, byteCount: bytes.count)
                            }
                        }
                        bufferRevisions[slot] = mesh.revision
                    }
                    encoder.setRenderPipelineState(resources.overlay)
                    encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.vertices.count)
                }
            }
            encoder.endEncoding()
            let retained = CameraGPUFrame(frame: snapshot.frame, texture: texture)
            command.addCompletedHandler { [self] completion in
                withExtendedLifetime(retained) {}
                if completion.status == .completed { completedFrames.withLock { $0 += 1 } }
                release(slot)
                if completion.status == .error { fail(completion.error?.localizedDescription ?? "Camera GPU failure") }
            }
            command.present(drawable)

            command.commit()
            committed = true
            // A racing update owns a coalesced refresh; never pause over its pending value.
            if !control.withLock({ $0.mailbox.pending }) { link.isPaused = true }
        }
    }
#endif
