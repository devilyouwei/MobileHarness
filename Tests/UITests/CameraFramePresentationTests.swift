import CoreVideo
import Foundation
import Observation
import Synchronization
import Testing

@testable import UI

#if os(iOS)
    import QuartzCore
#endif

@MainActor private func frame(_ sequence: UInt64, age: Duration = .zero) throws -> CameraVideoFrame {
    var buffer: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
    return CameraVideoFrame(
        pixels: try #require(buffer), width: 8, height: 8, rotation: 0, sequence: sequence,
        capturedAt: .now.advanced(by: .zero - age))
}

@MainActor private func awaitCameraState(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .milliseconds(500)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    try #require(predicate())
}

@Test @MainActor func cameraPreviewSurvivesPoseFailureAndAcceptsLaterFrames() throws {
    let state = CameraState()
    try state.presentVideo(frame(1))
    try state.present(frame: frame(1), pose: PoseOverlay(sequence: 1, timestamp: 0, rotation: 0, people: []))
    state.present(.visionMessage("姿态识别暂不可用"))
    #expect(state.videoFrame?.sequence == 1)
    #expect(state.skeleton == nil)
    try state.presentVideo(frame(2))
    #expect(state.videoFrame?.sequence == 2)
    #expect(state.visionMessage == "姿态识别暂不可用")
}

extension NativePresentationTests {
    @Test @MainActor func cameraPoseExpiresWithoutRemovingLiveVideo() async throws {
        let state = CameraState()
        try state.presentVideo(frame(10))
        try state.present(
            frame: frame(3, age: .milliseconds(700)),
            pose: PoseOverlay(sequence: 3, timestamp: 0, rotation: 0, people: []))
        #expect(state.videoFrame?.sequence == 10)
        #expect(state.skeleton?.sequence == 3)
        try await awaitCameraState { state.skeleton == nil }
        #expect(state.videoFrame?.sequence == 10)
        #expect(state.skeleton == nil)
    }
}

@Test @MainActor func cameraRejectsStaleVideoAndMismatchedPose() throws {
    let state = CameraState()
    try state.presentVideo(frame(5))
    #expect(throws: CameraFramePresentationError.self) { try state.presentVideo(frame(4)) }
    #expect(throws: CameraFramePresentationError.self) { try state.presentVideo(frame(6, age: .seconds(1))) }
    #expect(throws: CameraFramePresentationError.self) {
        try state.present(frame: frame(3), pose: PoseOverlay(sequence: 2, timestamp: 0, rotation: 0, people: []))
    }
    #expect(state.videoFrame?.sequence == 5)
}

extension NativePresentationTests {
    @Test @MainActor func cameraVideoExpiresAndCloseClearsBothOutputs() async throws {
        let state = CameraState()
        try state.presentVideo(frame(1, age: .milliseconds(700)))
        try await awaitCameraState { state.videoFrame == nil }
        #expect(state.videoFrame == nil)
        try state.presentVideo(frame(2))
        try state.present(frame: frame(2), pose: PoseOverlay(sequence: 2, timestamp: 0, rotation: 0, people: []))
        state.present(.isVisible(false))
        #expect(state.videoFrame == nil)
        #expect(state.skeleton == nil)
        try state.presentVideo(frame(1))
        #expect(state.videoFrame?.sequence == 1)
    }
}

@Test @MainActor func rendererFailuresRemainSurfaceLocalUntilNewCameraGeneration() throws {
    let state = CameraState()
    let generation = state.videoGeneration
    state.presentRendererFailure("Renderer unavailable", generation: generation)
    state.present(.visionMessage(nil))
    #expect(state.visionMessage == "Renderer unavailable")
    try state.presentVideo(frame(1))
    #expect(state.videoFrame?.sequence == 1)
    state.presentRendererFailure("Photo renderer unavailable", generation: generation, surface: .capture)
    #expect(state.photoRendererFailure == "Photo renderer unavailable")
    #expect(state.visionMessage == "Renderer unavailable")
    try state.presentVideo(frame(2))
    #expect(state.videoFrame?.sequence == 2)
    state.present(.isVisible(false))
    state.presentRendererFailure("Late old renderer", generation: generation)
    #expect(state.rendererFailure == nil)
    try state.presentVideo(frame(1))
    #expect(state.videoFrame?.sequence == 1)
}

@MainActor private func renderSnapshot(_ sequence: UInt64) throws -> CameraRenderSnapshot {
    CameraRenderSnapshot(
        frame: try frame(sequence), pose: nil, mirrored: false,
        size: CGSize(width: 80, height: 80), pixelSize: CGSize(width: 160, height: 160))
}

@Test @MainActor func cameraRenderCoalescesBurstAndWakesAfterDrain() throws {
    var mailbox = CameraRenderMailbox()
    for sequence in UInt64(1)...400 { #expect(true == mailbox.submit(try renderSnapshot(sequence))) }
    let taken = mailbox.take()
    let latest = try #require(taken)
    #expect(latest.frame?.sequence == 400)
    #expect(mailbox.take() == nil)
    #expect(false == mailbox.submit(latest))
    #expect(!mailbox.pending)
    var clear = latest
    clear.frame = nil
    #expect(true == mailbox.submit(clear))
    #expect(mailbox.pending)
    let cleared = mailbox.take()
    #expect(try #require(cleared).frame == nil)
    #expect(true == mailbox.submit(try renderSnapshot(401)))
    #expect(mailbox.take()?.frame?.sequence == 401)
}

@Test @MainActor func cameraRenderStopDropsPendingAndRejectsLateSubmissions() throws {
    var mailbox = CameraRenderMailbox()
    #expect(true == mailbox.submit(try renderSnapshot(1)))
    #expect(true == mailbox.stop())
    #expect(false == mailbox.stop())
    #expect(!mailbox.pending)
    #expect(mailbox.take() == nil)
    #expect(false == mailbox.submit(try renderSnapshot(2)))
}

@MainActor private func renderPose(people: Int = 1, rotation: Int = 0) -> PoseOverlay {
    let joints = (0..<17).map { index in
        PoseOverlay.Joint(x: 2000 + index * 250, y: 2500 + index * 200, confidence: 900)
    }
    return PoseOverlay(sequence: 1, timestamp: 0, rotation: rotation, people: Array(repeating: joints, count: people))
}

@Test @MainActor func cameraMeshReusesGeometryAcrossVideoFramesAndInvalidatesChanges() throws {
    var mesh = CameraSkeletonMesh()
    var snapshot = try renderSnapshot(1)
    snapshot.pose = renderPose()
    mesh.update(snapshot)
    let vertices = mesh.vertices
    let revision = mesh.revision
    #expect(!vertices.isEmpty)
    snapshot.frame = try frame(2)
    mesh.update(snapshot)
    #expect(mesh.revision == revision)
    #expect(mesh.vertices == vertices)
    snapshot.mirrored = true
    mesh.update(snapshot)
    #expect(mesh.revision != revision)
    #expect(mesh.vertices != vertices)
    // Joint disk triangle starts after the 16 bone quads; its center must mirror exactly.
    #expect(abs(mesh.vertices[96].x + vertices[96].x) < 0.0001)
    #expect(abs(mesh.vertices[96].y - vertices[96].y) < 0.0001)
    let mirroredRevision = mesh.revision
    snapshot.size.width = 120
    mesh.update(snapshot)
    #expect(mesh.revision != mirroredRevision)
    snapshot.pose = nil
    mesh.update(snapshot)
    #expect(mesh.vertices.isEmpty)
}

@Test @MainActor func cameraMeshBoundsSixPeopleAndRejectsMismatchedDirection() throws {
    var mesh = CameraSkeletonMesh()
    var snapshot = try renderSnapshot(1)
    snapshot.pose = renderPose(people: 6)
    mesh.update(snapshot)
    #expect(mesh.vertices.count == CameraSkeletonMesh.maximumVertices)
    #expect(mesh.vertices.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    snapshot.pose = renderPose(people: 7)
    mesh.update(snapshot)
    #expect(mesh.vertices.isEmpty)
    snapshot.pose = renderPose(rotation: 1)
    mesh.update(snapshot)
    #expect(mesh.vertices.isEmpty)
    snapshot.pose = renderPose()
    snapshot.size = .zero
    mesh.update(snapshot)
    #expect(mesh.vertices.isEmpty)
}

#if os(macOS)
    import AppKit
    import Metal
    import QuartzCore

    @MainActor private func awaitCameraRenderer(
        _ predicate: () -> Bool, diagnostics: () -> String = { "" }
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            while let event = NSApplication.shared.nextEvent(
                matching: .any, until: .distantPast, inMode: .default, dequeue: true)
            {
                NSApplication.shared.sendEvent(event)
            }
            NSApplication.shared.updateWindows()
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate(), "\(diagnostics())")
    }

    extension NativePresentationTests {
        @Test(.timeLimit(.minutes(1)), .enabled(if: MTLCreateSystemDefaultDevice() != nil)) @MainActor
        func cameraNativeMetalDrawStopAndLayerHandoff() async throws {
            let application = NSApplication.shared
            try #require(application.setActivationPolicy(.regular))
            application.finishLaunching()
            application.activate(ignoringOtherApps: true)
            let layer = CAMetalLayer()
            layer.device = MTLCreateSystemDefaultDevice()
            layer.pixelFormat = .bgra8Unorm
            layer.maximumDrawableCount = 2
            layer.drawableSize = CGSize(width: 64, height: 64)
            let window = NSWindow(
                contentRect: NSRect(x: 20, y: 20, width: 64, height: 64),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer {
                window.contentView = nil
                window.close()
            }
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            if let screen = NSScreen.main {
                window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 32, y: screen.visibleFrame.midY - 32))
            }
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            view.wantsLayer = true
            view.layer = layer
            layer.frame = view.bounds
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            try #require(layer.bounds.width > 0 && layer.bounds.height > 0)
            try await awaitCameraRenderer(
                { window.occlusionState.contains(.visible) },
                diagnostics: {
                    "window=\(window.windowNumber) visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) active=\(application.isActive) running=\(application.isRunning) screens=\(NSScreen.screens.count)"
                })
            var pixels: CVPixelBuffer?
            let attributes: [CFString: Any] = [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            ]
            #expect(
                CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixels)
                    == kCVReturnSuccess)
            let buffer = try #require(pixels)
            #expect(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
            if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, 0, CVPixelBufferGetDataSize(buffer)) }
            #expect(CVPixelBufferUnlockBaseAddress(buffer, []) == kCVReturnSuccess)
            let failures = Mutex<[String]>([])
            var previous: DispatchGroup?
            var completions: [DispatchGroup] = []
            for index in 0..<12 {
                let renderer = CameraMetalRenderer(layer: layer, previousCompletion: previous) { message in
                    failures.withLock { $0.append(message) }
                }
                defer { renderer.stop() }
                if index >= 2 {
                    renderer.submit(
                        CameraRenderSnapshot(
                            frame: CameraVideoFrame(
                                pixels: buffer, width: 64, height: 64, rotation: 0,
                                sequence: UInt64(index), capturedAt: .now),
                            pose: renderPose(), mirrored: index.isMultiple(of: 2),
                            size: CGSize(width: 64, height: 64), pixelSize: CGSize(width: 64, height: 64)))
                    try await awaitCameraRenderer(
                        { renderer.completedFrameCount == 1 || failures.withLock { !$0.isEmpty } },
                        diagnostics: {
                            "index=\(index) visible=\(window.occlusionState.contains(.visible)) failures=\(failures.withLock { $0 })"
                        })
                    try #require(
                        failures.withLock { $0.isEmpty }, "\(failures.withLock { $0.joined(separator: "; ") })")
                    #expect(renderer.completedFrameCount == 1)
                }
                renderer.stop()
                completions.append(renderer.completion)
                previous = renderer.completion
            }
            // New workers may start before old cleanup finishes; keep Core Animation's main run loop available.
            try await awaitCameraRenderer({ completions.allSatisfy { $0.wait(timeout: .now()) == .success } })
            #expect(failures.withLock { $0.isEmpty })
        }
    }
#endif

extension NativePresentationTests {
    @Test @MainActor func uiCameraRootOwnsOnePassiveDisplayAndFencesMedia() async throws {
        let root = UIContainer()
        let presentation: any CameraPresenting = root.camera
        let other = UIContainer()
        #expect(root.camera.state !== other.camera.state)
        #expect(!root.isAvailable)
        #expect(!presentation.snapshot.isEnabled)
        #expect(root.camera.state.videoFrame == nil)
        let video = try frame(1)
        #expect(throws: UIContainerError.unavailable) { try presentation.presentVideo(video) }
        try root.start()
        try presentation.presentVideo(video)
        try presentation.present(
            frame: video, pose: PoseOverlay(sequence: 1, timestamp: 0, rotation: 0, people: []))
        #expect(root.camera.state.videoFrame?.sequence == 1)
        #expect(presentation.snapshot.skeleton?.sequence == 1)
        root.invalidate()
        #expect(!root.isAvailable)
        #expect(root.camera.state.videoFrame == nil)
        #expect(presentation.snapshot.skeleton == nil)
        #expect(throws: UIContainerError.unavailable) { try presentation.presentVideo(video) }
        #expect(throws: UIContainerError.unavailable) {
            try presentation.present(frame: video, pose: renderPose())
        }
        presentation.present(.message("已停止"))
        #expect(presentation.snapshot.message == "已停止")
        try root.start()
        #expect(!root.isAvailable)
        try root.setForeground(true)
        try presentation.presentVideo(try frame(1))
        #expect(root.camera.state.videoFrame?.sequence == 1)
        await root.stop()
        await other.stop()
    }
}

extension NativePresentationTests {
    @Test @MainActor func uiCameraStopJoinsExpiryAndCannotReopenTheOldRoot() async throws {
        let root = UIContainer()
        try root.start()
        let presentation: any CameraPresenting = root.camera
        let video = try frame(7)
        try presentation.presentVideo(video)
        try presentation.present(frame: video, pose: PoseOverlay(sequence: 7, timestamp: 0, rotation: 0, people: []))
        let generation = root.camera.state.videoGeneration
        await root.stop()
        await root.stop()
        #expect(!root.isAvailable)
        #expect(root.camera.state.videoFrame == nil)
        #expect(presentation.snapshot.skeleton == nil)
        #expect(root.camera.state.videoGeneration > generation)
        #expect(throws: UIFailure.self) { try root.start() }
        #expect(throws: UIFailure.self) { try root.setForeground(true) }
        #expect(throws: UIContainerError.stopped) { try presentation.presentVideo(video) }
        let replacement = UIContainer()
        try replacement.start()
        try replacement.camera.presentVideo(try frame(1))
        #expect(replacement.camera.state.videoFrame?.sequence == 1)
        #expect(root.camera.state.videoFrame == nil)
        await replacement.stop()
    }
}

extension NativePresentationTests {
    @Test @MainActor func uiCameraStatusFactsAndPoseFailureKeepIndependentVideo() async throws {
        let root = UIContainer()
        try root.start()
        let presentation: any CameraPresenting = root.camera
        var changes = try root.camera.observeFacts().makeAsyncIterator()
        _ = await changes.next()
        presentation.present(.isEnabled(true))
        #expect(await changes.next()?.isEnabled == true)
        let before = presentation.snapshot
        presentation.present(.isBusy(true))
        #expect(!before.isBusy)
        #expect(presentation.snapshot.isBusy)
        let video = try frame(1)
        try presentation.presentVideo(video)
        try presentation.present(frame: video, pose: renderPose())
        presentation.present(.visionMessage("模型暂不可用"))
        #expect(presentation.snapshot.skeleton == nil)
        #expect(root.camera.state.videoFrame?.sequence == 1)
        try root.setForeground(false)
        #expect(root.camera.state.videoFrame == nil)
        #expect(throws: UIContainerError.unavailable) { try presentation.presentVideo(video) }
        await root.stop()
    }
}

extension NativePresentationTests {
    @Test @MainActor func cameraRenewedFrameSurvivesThePreviousDeadline() async throws {
        let state = CameraState()
        try state.presentVideo(frame(1, age: .milliseconds(650)))
        // Allow the first sleep to begin before extending it with a fresh frame.
        await Task.yield()
        try state.presentVideo(frame(2))
        try await Task.sleep(for: .milliseconds(180))
        #expect(state.videoFrame?.sequence == 2)
        // The replacement still expires from its own capture time, not from the old wake.
        let deadline = ContinuousClock.now + .seconds(1)
        while state.videoFrame != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(state.videoFrame == nil)
        await state.stopPresentation()
    }
}

extension NativePresentationTests {
    @Test @MainActor func cameraEarlierCaptureDeadlineReplacesThePendingSleep() async throws {
        let state = CameraState()
        try state.presentVideo(frame(1))
        await Task.yield()
        // Sequence admission is independent of capture timestamp ordering.
        try state.presentVideo(frame(2, age: .milliseconds(700)))
        try await awaitCameraState { state.videoFrame == nil }
        await state.stopPresentation()
    }
}

extension NativePresentationTests {
    @Test @MainActor func cameraClearedDeadlineCannotExpireAReplacementSession() async throws {
        let state = CameraState()
        try state.presentVideo(frame(1, age: .milliseconds(650)))
        await Task.yield()
        state.present(.isVisible(false))
        try state.presentVideo(frame(1))
        try state.present(frame: frame(1), pose: PoseOverlay(sequence: 1, timestamp: 0, rotation: 0, people: []))
        try await Task.sleep(for: .milliseconds(180))
        #expect(state.videoFrame?.sequence == 1)
        #expect(state.skeleton?.sequence == 1)
        await state.stopPresentation()
        await state.stopPresentation()
        #expect(state.videoFrame == nil)
        #expect(state.skeleton == nil)
    }
}

@Test @MainActor func cameraDeadlineDoesNotRetainItsPresentationOwner() throws {
    weak var released: CameraState?
    do {
        let state = CameraState()
        released = state
        try state.presentVideo(frame(1))
        try state.present(frame: frame(1), pose: PoseOverlay(sequence: 1, timestamp: 0, rotation: 0, people: []))
    }
    #expect(released == nil)
}

#if os(iOS)
    extension NativePresentationTests {
        @Test @MainActor func haloStopJoinsWithoutFramesAndReleasesTheRenderer() async throws {
            let context = try await Task.detached { try HaloPipeline.prepared.get() }.value
            for _ in 0..<3 {
                let layer = CAMetalLayer()
                layer.device = context.device
                weak var released: MetalHaloRenderer?
                let completion: DispatchGroup
                do {
                    let renderer = MetalHaloRenderer(layer: layer, context: context, failure: { _ in })
                    released = renderer
                    completion = renderer.completion
                    renderer.stop()
                    renderer.stop()
                }
                let deadline = ContinuousClock.now + .seconds(3)
                while completion.wait(timeout: .now()) != .success, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(completion.wait(timeout: .now()) == .success)
                // Completion leaves immediately before the thread releases its last owner.
                while released != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                #expect(released == nil)
            }
        }
    }
#endif

@Suite(.serialized) struct NativePresentationTests {}

@MainActor private func orientedFrame(
    _ sequence: UInt64 = 1, rotation: Int, portraitRotation: Int? = 1,
    capturedAt: ContinuousClock.Instant = .now
) throws -> CameraVideoFrame {
    var pixels: CVPixelBuffer?
    try #require(CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &pixels) == kCVReturnSuccess)
    return CameraVideoFrame(
        pixels: try #require(pixels), width: rotation % 2 == 0 ? 320 : 180,
        height: rotation % 2 == 0 ? 180 : 320, rotation: rotation, sequence: sequence,
        capturedAt: capturedAt, portraitRotation: portraitRotation)
}

@Test(arguments: [false, true]) @MainActor func cameraPortraitPreviewDoesNotZoomWhenGravityChanges(_ mirrored: Bool)
    throws
{
    // The same sensor point expressed in the four gravity-upright coordinate systems.
    let modelPoints = [
        CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.7, y: 0.2),
        CGPoint(x: 0.8, y: 0.7), CGPoint(x: 0.3, y: 0.8),
    ]
    for rotation in 0...3 {
        let geometry = CameraPreviewGeometry(
            frame: try orientedFrame(rotation: rotation), size: CGSize(width: 180, height: 320), orientation: .portrait)
        #expect(geometry.imageSize == CGSize(width: 180, height: 320))
        #expect(geometry.displayRotation == 1)
        #expect(geometry.crop == CGSize(width: 1, height: 1))
        let point = geometry.project(modelPoints[rotation], mirrored: mirrored)
        #expect(abs(point.x - (mirrored ? 54 : 126)) < 0.0001)
        #expect(abs(point.y - 64) < 0.0001)
    }
}

@Test @MainActor func cameraPreviewUsesActualInterfaceAxesForEveryCaptureRotation() throws {
    let modelPoints = [
        CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.7, y: 0.2),
        CGPoint(x: 0.8, y: 0.7), CGPoint(x: 0.3, y: 0.8),
    ]
    let cases: [(CameraInterfaceOrientation, Int, CGSize, CGPoint)] = [
        (.portrait, 1, CGSize(width: 180, height: 320), CGPoint(x: 0.7, y: 0.2)),
        (.portraitUpsideDown, 3, CGSize(width: 180, height: 320), CGPoint(x: 0.3, y: 0.8)),
        (.landscapeLeft, 2, CGSize(width: 320, height: 180), CGPoint(x: 0.8, y: 0.7)),
        (.landscapeRight, 0, CGSize(width: 320, height: 180), CGPoint(x: 0.2, y: 0.3)),
    ]
    for (orientation, displayRotation, size, expected) in cases {
        for rotation in 0...3 {
            let geometry = CameraPreviewGeometry(
                frame: try orientedFrame(rotation: rotation), size: size, orientation: orientation)
            #expect(geometry.imageSize == size && geometry.displayRotation == displayRotation)
            let point = geometry.project(modelPoints[rotation], mirrored: false)
            #expect(abs(point.x - expected.x * size.width) < 0.0001)
            #expect(abs(point.y - expected.y * size.height) < 0.0001)
        }
    }
}

@Test @MainActor func cameraAspectFillCropIsStableWithPortraitLockAndNonmatchingViewport() throws {
    for rotation in 0...3 {
        let geometry = CameraPreviewGeometry(
            frame: try orientedFrame(rotation: rotation), size: CGSize(width: 100, height: 300), orientation: .portrait)
        #expect(abs(geometry.crop.width - 100.0 / 168.75) < 0.0001)
        #expect(geometry.crop.height == 1)
    }
}

@Test @MainActor func cameraFramesWithoutSensorReferencePreserveExplicitUprightGeometry() throws {
    let geometry = CameraPreviewGeometry(
        frame: try orientedFrame(rotation: 1, portraitRotation: nil), size: CGSize(width: 180, height: 320),
        orientation: .landscapeRight)
    #expect(geometry.displayRotation == 1)
    #expect(geometry.imageSize == CGSize(width: 180, height: 320))
    let point = geometry.project(CGPoint(x: 0.2, y: 0.3), mirrored: true)
    #expect(abs(point.x - 144) < 0.0001 && abs(point.y - 96) < 0.0001)
}

@Test @MainActor func cameraInterfaceAndSensorReferenceChangesInvalidateMailboxAndMesh() throws {
    let instant = ContinuousClock.now
    var snapshot = CameraRenderSnapshot(
        frame: try orientedFrame(rotation: 0, capturedAt: instant), pose: renderPose(), mirrored: false,
        size: CGSize(width: 180, height: 320), pixelSize: CGSize(width: 180, height: 320))
    var mailbox = CameraRenderMailbox()
    var mesh = CameraSkeletonMesh()
    #expect(true == mailbox.submit(snapshot))
    mesh.update(snapshot)
    #expect(abs(mesh.vertices[96].x - 0.5) < 0.0001 && abs(mesh.vertices[96].y - 0.6) < 0.0001)
    let firstRevision = mesh.revision
    snapshot.orientation = .landscapeRight
    #expect(true == mailbox.submit(snapshot))
    mesh.update(snapshot)
    #expect(mesh.revision != firstRevision)
    let secondRevision = mesh.revision
    snapshot.frame = try orientedFrame(rotation: 0, portraitRotation: 3, capturedAt: instant)
    #expect(true == mailbox.submit(snapshot))
    mesh.update(snapshot)
    #expect(mesh.revision != secondRevision)
}

@Test @MainActor func cameraGazeAndSkeletonUseTheSameMirroredDisplayAxes() throws {
    for mirrored in [false, true] {
        let basis = CameraPreviewBasis(rotation: 0, portraitRotation: 1)
        let gaze = basis.gaze(
            CGSize(width: mirrored ? -0.4 : 0.4, height: 0.2), orientation: .portrait, mirrored: mirrored)
        #expect(abs(gaze.width - (mirrored ? 0.2 : -0.2)) < 0.0001)
        #expect(abs(gaze.height - 0.4) < 0.0001)
        let identity = CameraPreviewBasis(rotation: 1, portraitRotation: nil)
        let original = CGSize(width: -0.4, height: 0.2)
        #expect(identity.gaze(original, orientation: .landscapeLeft, mirrored: mirrored) == original)
    }
    let state = CameraState()
    try state.presentVideo(orientedFrame(rotation: 0))
    state.present(.gaze(CGSize(width: 0.4, height: 0.2)))
    #expect(abs(state.displayGaze.width - 0.2) < 0.0001 && abs(state.displayGaze.height + 0.4) < 0.0001)
    // Front-facing input was already mirrored by its producer; a newer video alone keeps the same basis.
    let basis = state.previewBasis
    try state.presentVideo(orientedFrame(2, rotation: 0))
    #expect(state.previewBasis == basis)
    state.clearFrame()
    #expect(state.previewBasis == nil)
}

@Test @MainActor func cameraRejectsInvalidCaptureAndPortraitRotationMetadata() throws {
    let state = CameraState()
    #expect(throws: CameraFramePresentationError.self) { try state.presentVideo(orientedFrame(rotation: -1)) }
    #expect(throws: CameraFramePresentationError.self) {
        try state.presentVideo(orientedFrame(rotation: 0, portraitRotation: 4))
    }
    try state.presentVideo(orientedFrame(rotation: 0))
}

@Test @MainActor func cameraVideoUpdatesDoNotInvalidateTheGazePresentationBasis() throws {
    let state = CameraState()
    try state.presentVideo(orientedFrame(rotation: 0))
    let changes = Mutex(0)
    withObservationTracking {
        _ = state.displayGaze
    } onChange: {
        changes.withLock { $0 += 1 }
    }
    try state.presentVideo(orientedFrame(2, rotation: 0))
    #expect(changes.withLock { $0 } == 0)
    state.presentInterfaceOrientation(.landscapeRight, generation: state.videoGeneration)
    #expect(changes.withLock { $0 } == 1)
    state.clearFrame()
}

@Test @MainActor func cameraSensorReferenceChangeClearsOldSkeletonAndRejectsOldAttachments() throws {
    let state = CameraState()
    try state.presentVideo(orientedFrame(rotation: 0))
    try state.present(frame: orientedFrame(rotation: 0), pose: renderPose())
    #expect(state.skeleton != nil)
    try state.presentVideo(orientedFrame(2, rotation: 0, portraitRotation: 3))
    #expect(state.skeleton == nil)
    let stalePose = PoseOverlay(sequence: 2, timestamp: 0, rotation: 0, people: [])
    #expect(throws: CameraFramePresentationError.self) {
        try state.present(frame: orientedFrame(2, rotation: 0), pose: stalePose)
    }
    state.clearFrame()
}

@Test @MainActor func cameraInterfaceReportsRejectRetiredSourceAndStoppedOwner() async throws {
    let root = UIContainer()
    try root.start()
    let state = root.camera.state
    let generation = state.videoGeneration
    state.presentInterfaceOrientation(.landscapeLeft, generation: generation)
    #expect(state.interfaceOrientation == .landscapeLeft)
    state.present(.isVisible(false))
    state.presentInterfaceOrientation(.portraitUpsideDown, generation: generation)
    #expect(state.interfaceOrientation == .landscapeLeft)
    state.presentInterfaceOrientation(.portrait, generation: state.videoGeneration)
    #expect(state.interfaceOrientation == .portrait)
    await root.stop()
    state.presentInterfaceOrientation(.landscapeRight, generation: state.videoGeneration)
    #expect(state.interfaceOrientation == .portrait)
}

@Test @MainActor func photoAspectObservationDoesNotInvalidateOnEachVideoFrame() throws {
    let state = CameraState()
    try state.presentVideo(frame(1))
    let changes = Mutex(0)
    withObservationTracking {
        _ = state.photoAspect
    } onChange: {
        changes.withLock { $0 += 1 }
    }
    try state.presentVideo(frame(2))
    #expect(changes.withLock { $0 } == 0)
    try state.presentVideo(orientedFrame(3, rotation: 0))
    #expect(changes.withLock { $0 } == 1)
    let aspect = state.photoAspect
    state.presentInterfaceOrientation(.landscapeLeft, generation: state.videoGeneration)
    #expect(state.photoAspect == aspect)
}

@Test @MainActor func cameraPhotoFitRetainsAllFourImageCornersAcrossOrientationAndMirroring() throws {
    for orientation in CameraInterfaceOrientation.allCases {
        let geometry = CameraPreviewGeometry(
            frame: try orientedFrame(rotation: 0), size: CGSize(width: 400, height: 300),
            orientation: orientation, fitsImage: true)
        for mirrored in [true, false] {
            for point in [CGPoint.zero, CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)] {
                let visible = geometry.project(point, mirrored: mirrored)
                #expect(visible.x >= -0.0001 && visible.x <= 400.0001)
                #expect(visible.y >= -0.0001 && visible.y <= 300.0001)
            }
        }
    }
}

@Test @MainActor func shutterOrientationMatchesWindowInsteadOfGravityAndFreezesAtCapture() throws {
    for reference in [1, 3] {
        for orientation in CameraInterfaceOrientation.allCases {
            let state = CameraState()
            for gravity in 0..<4 {
                try state.presentVideo(
                    orientedFrame(UInt64(gravity + 1), rotation: gravity, portraitRotation: reference))
                state.presentPhotoOrientation(orientation, generation: state.videoGeneration)
                let shutter = CameraPresentationSnapshot(state).photoCaptureRotation
                #expect(shutter == Double((reference + orientation.rawValue) % 4 * 90))
                // A later Face-only layout/rotation cannot alter the photo window's captured basis.
                state.presentInterfaceOrientation(.landscapeRight, generation: state.videoGeneration)
                #expect(CameraPresentationSnapshot(state).photoCaptureRotation == shutter)
            }
        }
    }
    #expect(CameraPresentationSnapshot(CameraState()).photoCaptureRotation == nil)
}
