import AgentCore
import Foundation
import Gateway
import OSLog
import Observation
import PlatformKit
import SwiftUI

/// Scene-owned camera intent, independent of voice/model startup and recording state.
@MainActor @Observable
final class CameraCoordinator {
    let preview: CameraPreviewSource
    private(set) var isEnabled = true
    private(set) var facing: CameraFacing = .front
    private(set) var isVisible = false
    private(set) var isBusy = false
    private(set) var message: String?
    private(set) var needsSettings = false
    private(set) var skeleton: PoseOverlay?
    private(set) var visionMessage: String?
    private(set) var changeThreshold = 0.03
    private var visionTask: Task<Void, Never>?
    private var visionSession: UUID?
    private let log = Logger(subsystem: "dev.mobileharness", category: "CameraPipeline")
    private let camera: AppleCamera
    private var foreground = false
    private var failed = false
    private var revision = 0
    private var worker: Task<Void, Never>?

    init() {
        let camera = AppleCamera()
        self.camera = camera
        preview = camera.preview
    }

    func toggle() {
        isEnabled.toggle()
        failed = false
        message = nil
        needsSettings = false
        reconcile()
    }

    func switchCamera() {
        guard isEnabled, !isBusy else { return }
        failed = false
        facing = facing == .front ? .back : .front
        message = nil
        reconcile()
    }

    func setChangeThreshold(_ value: Double) {
        guard value.isFinite, (0...1).contains(value), value != changeThreshold else { return }
        changeThreshold = value
        reconcile()
    }

    func retry() {
        failed = false
        message = nil
        reconcile()
    }

    func setForeground(_ value: Bool) {
        guard foreground != value else { return }
        foreground = value
        if value { failed = false }
        reconcile()
    }

    /// One notification consumer per scene; device status is coalesced, never a frame stream.
    func observe() async {
        for await event in camera.events {
            if Task.isCancelled { break }
            guard isEnabled, foreground else { continue }
            switch event {
            case .interrupted:
                visionSession = nil
                skeleton = nil
                visionTask?.cancel()
                isVisible = false
                message = "相机暂时被占用"
            case .interruptionEnded:
                reconcile()
            case .failed:
                failed = true
                message = "相机暂时不可用，请重试"
                reconcile()
            }
        }
        setForeground(false)
        // Join the existing worker before leaving the scene. It applies the newest off intent.
        await worker?.value
    }

    /// At most one worker and one latest desired state; repeated intents replace pending state.
    /// Stop immediately masks the preview even if a native start call is still completing.
    private func reconcile() {
        revision += 1
        isVisible = false
        skeleton = nil
        visionMessage = nil
        visionSession = nil
        visionTask?.cancel()
        guard worker == nil else { return }
        isBusy = true
        worker = Task { await applyLatestIntent() }
    }

    private func startVision(frames: AsyncThrowingStream<CameraFrame, Error>) {
        let id = UUID()
        visionSession = id
        let threshold = changeThreshold
        visionTask = Task { [weak self] in
            do {
                let configuration = try FrameChangeConfiguration(minimumChange: threshold)
                try await PhotographySession.run(frames: frames, sessionID: id, configuration: configuration) {
                    [weak self] overlay, invocation in
                    guard let self else { throw CancellationError() }
                    try await self.present(overlay, sessionID: invocation.envelope.sessionID)
                }
            } catch is CancellationError {} catch {
                guard let self, self.visionSession == id else { return }
                self.skeleton = nil
                self.visionMessage = "姿态识别暂不可用，请重试"
                self.log.error("Pose pipeline failed: \(String(describing: error), privacy: .private)")
            }
        }
    }
    private func present(_ overlay: PoseOverlay, sessionID: UUID) throws {
        try Task.checkCancellation()
        guard visionSession == sessionID, foreground, isEnabled, isVisible else { throw CancellationError() }
        guard skeleton.map({ overlay.sequence > $0.sequence }) ?? true else { throw ImageInputError.outOfOrder }
        skeleton = overlay
    }

    private func applyLatestIntent() async {
        defer {
            worker = nil
            isBusy = false
        }
        while true {
            let current = revision
            await camera.stop()
            await visionTask?.value
            visionTask = nil
            guard current == revision else { continue }
            if !isEnabled || !foreground || failed {
                await camera.stop()
            } else {
                let authorized = await AppleCamera.requestPermission()
                // Permission prompts may suspend/deactivate the scene or outlive a user stop.
                guard current == revision else { continue }
                if authorized {
                    do {
                        let frames = try await camera.start(facing: facing)
                        let running = await camera.isRunning()
                        if current == revision {
                            isVisible = running
                            message = running ? nil : "相机暂时不可用，请重试"
                            needsSettings = false
                            if running { startVision(frames: frames) }
                        }
                    } catch {
                        await camera.stop()
                        if current == revision {
                            message =
                                (error as? CameraError) == .unavailable
                                ? "此设备没有可用的摄像头" : "无法开启相机，请重试"
                        }
                    }
                } else {
                    await camera.stop()
                    if current == revision {
                        message = "请在设置中允许相机访问"
                        needsSettings = true
                    }
                }
            }
            if current == revision { return }
        }
    }
}

/// State is allocated per window, before asynchronous voice/model composition.
@MainActor
struct CameraScene<Content: View>: View {
    @State private var camera = CameraCoordinator()
    @ViewBuilder let content: () -> Content
    var body: some View { CameraConversationSurface(camera: camera, content: content) }
}
