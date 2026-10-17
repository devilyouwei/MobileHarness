import CoreVideo
import Foundation
import Testing

@testable import UI

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

@Test @MainActor func rendererFailureRemainsLatchedUntilNewCameraGeneration() throws {
    let state = CameraState()
    let generation = state.videoGeneration
    state.presentRendererFailure("Renderer unavailable", generation: generation)
    state.present(.visionMessage(nil))
    #expect(state.visionMessage == "Renderer unavailable")
    #expect(throws: CameraFramePresentationError.self) { try state.presentVideo(frame(1)) }
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
    import Synchronization

    @MainActor private func awaitCameraRenderer(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(predicate())
    }

    @Test(.timeLimit(.minutes(1)), .enabled(if: MTLCreateSystemDefaultDevice() != nil)) @MainActor
    func cameraNativeMetalDrawStopAndLayerHandoff() async throws {
        _ = NSApplication.shared
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        layer.pixelFormat = .bgra8Unorm
        layer.maximumDrawableCount = 2
        layer.drawableSize = CGSize(width: 64, height: 64)
        let window = NSWindow(
            contentRect: NSRect(x: 20, y: 20, width: 64, height: 64),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        view.wantsLayer = true
        view.layer = layer
        window.contentView = view
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
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
                try await awaitCameraRenderer { renderer.completedFrameCount == 1 }
            }
            renderer.stop()
            completions.append(renderer.completion)
            previous = renderer.completion
        }
        // New workers may start before old cleanup finishes; keep Core Animation's main run loop available.
        try await awaitCameraRenderer { completions.allSatisfy { $0.wait(timeout: .now()) == .success } }
        #expect(failures.withLock { $0.isEmpty })
    }
#endif

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
    #expect(throws: UIContainerError.stopped) { try root.start() }
    #expect(throws: UIContainerError.stopped) { try root.setForeground(true) }
    #expect(throws: UIContainerError.stopped) { try presentation.presentVideo(video) }
    let replacement = UIContainer()
    try replacement.start()
    try replacement.camera.presentVideo(try frame(1))
    #expect(replacement.camera.state.videoFrame?.sequence == 1)
    #expect(root.camera.state.videoFrame == nil)
    await replacement.stop()
}

@Test @MainActor func uiCameraStatusFactsAndPoseFailureKeepIndependentVideo() async throws {
    let root = UIContainer()
    try root.start()
    let presentation: any CameraPresenting = root.camera
    var changed = 0
    presentation.connectFactsObserver { changed += 1 }
    presentation.present(.isEnabled(true))
    #expect(changed == 1)
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
