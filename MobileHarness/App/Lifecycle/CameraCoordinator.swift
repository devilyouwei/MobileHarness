import Actions
import AgentCore
import Agents
import CoreGraphics
import Foundation
import OSLog
import PlatformKit
import UI

/// Scene-owned camera intent, independent of voice/model startup and recording state.
@MainActor
final class CameraCoordinator: CameraControlling, CameraOutputHandling {
    let preview: CameraPreviewSource
    let state: CameraState
    private var gazeSequence: UInt64?
    private let makeSession: () async throws -> VisionSession
    private var visionTask: Task<Void, Never>?
    private var visionSession: UUID?
    private let log = Logger(subsystem: "dev.mobileharness", category: "CameraPipeline")
    private let camera: AppleCamera
    private var foreground = false
    private var failed = false
    private var revision = 0
    private var worker: Task<Void, Never>?

    init(camera: AppleCamera, state: CameraState, makeSession: @escaping () async throws -> VisionSession) {
        self.state = state
        self.makeSession = makeSession
        self.camera = camera
        preview = camera.preview
    }

    func toggle() {
        state.isEnabled.toggle()
        failed = false
        state.message = nil
        state.needsSettings = false
        reconcile()
    }

    func switchCamera() {
        guard state.isEnabled, !state.isBusy else { return }
        failed = false
        state.facing = state.facing == .front ? .back : .front
        state.message = nil
        reconcile()
    }

    func setChangeThreshold(_ value: Double) {
        guard value.isFinite, (0...1).contains(value), value != state.changeThreshold else { return }
        state.changeThreshold = value
        reconcile()
    }

    func retry() {
        failed = false
        state.message = nil
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
            guard state.isEnabled, foreground else { continue }
            switch event {
            case .interrupted:
                visionSession = nil
                state.skeleton = nil
                state.gaze = .zero
                gazeSequence = nil
                visionTask?.cancel()
                state.isVisible = false
                state.message = "相机暂时被占用"
            case .interruptionEnded:
                reconcile()
            case .failed:
                failed = true
                state.message = "相机暂时不可用，请重试"
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
        state.isVisible = false
        state.skeleton = nil
        state.gaze = .zero
        gazeSequence = nil
        state.visionMessage = nil
        visionSession = nil
        visionTask?.cancel()
        guard worker == nil else { return }
        state.isBusy = true
        worker = Task { await applyLatestIntent() }
    }

    private func startVision(frames: AsyncThrowingStream<CameraFrame, Error>) {
        let id = UUID()
        visionSession = id
        let threshold = state.changeThreshold
        let mirrored = state.facing == .front
        visionTask = Task { [weak self] in
            do {
                let configuration = try FrameChangeConfiguration(minimumChange: threshold, maximumRefreshInterval: 0.1)
                let session = try await self?.makeSession()
                try Task.checkCancellation()
                guard let self, let session else { throw CancellationError() }
                try await session.run(
                    frames: frames, sessionID: id, configuration: configuration,
                    mirroredGaze: mirrored, endpoint: self)
            } catch is CancellationError {} catch {
                guard let self, self.visionSession == id else { return }
                self.state.skeleton = nil
                self.state.gaze = .zero
                self.gazeSequence = nil
                self.state.visionMessage = "姿态识别暂不可用，请重试"
                self.log.error("Pose pipeline failed: \(String(describing: error), privacy: .private)")
            }
        }
    }
    func present(_ target: UIActions.Gaze, invocation: ActionInvocation) throws {
        try Task.checkCancellation()
        guard visionSession == invocation.envelope.sessionID, foreground, state.isEnabled, state.isVisible else {
            throw CancellationError()
        }
        guard gazeSequence.map({ invocation.envelope.sequence > $0 }) ?? true else { return }
        gazeSequence = invocation.envelope.sequence
        state.gaze = CGSize(width: target.x, height: target.y)
    }

    func present(_ overlay: PoseOverlay, sessionID: UUID) throws {
        try Task.checkCancellation()
        guard visionSession == sessionID, foreground, state.isEnabled, state.isVisible else {
            throw CancellationError()
        }
        guard state.skeleton.map({ overlay.sequence > $0.sequence }) ?? true else { throw ImageInputError.outOfOrder }
        state.skeleton = overlay
    }

    private func applyLatestIntent() async {
        defer {
            worker = nil
            state.isBusy = false
        }
        while true {
            let current = revision
            await camera.stop()
            await visionTask?.value
            visionTask = nil
            guard current == revision else { continue }
            if !state.isEnabled || !foreground || failed {
                await camera.stop()
            } else {
                let authorized = await AppleCamera.requestPermission()
                // Permission prompts may suspend/deactivate the scene or outlive a user stop.
                guard current == revision else { continue }
                if authorized {
                    do {
                        let frames = try await camera.start(facing: state.facing == .front ? .front : .back)
                        let running = await camera.isRunning()
                        if current == revision {
                            state.isVisible = running
                            state.message = running ? nil : "相机暂时不可用，请重试"
                            state.needsSettings = false
                            if running { startVision(frames: frames) }
                        }
                    } catch {
                        await camera.stop()
                        if current == revision {
                            state.message =
                                (error as? CameraError) == .unavailable
                                ? "此设备没有可用的摄像头" : "无法开启相机，请重试"
                        }
                    }
                } else {
                    await camera.stop()
                    if current == revision {
                        state.message = "请在设置中允许相机访问"
                        state.needsSettings = true
                    }
                }
            }
            if current == revision { return }
        }
    }
}
