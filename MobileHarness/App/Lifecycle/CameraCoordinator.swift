import ActionRuntime
import Actions
import AgentCore
import Agents
import CoreGraphics
import Foundation
import Gateway
import OSLog
import PlatformKit
import ToolRuntime
import Tools
import UI

/// Scene-owned camera intent, independent of voice/model startup and recording state.
@MainActor
final class CameraCoordinator: CameraControlling, CameraOutputHandling, CameraControlCapability {
    static let resourceOwnerID = AgentID(rawValue: "runtime.camera")
    private let captureOwner: ExecutionOwner
    private let makeRuntime: () throws -> CameraRuntimeDependencies
    private var resourceRuntime: CameraRuntimeDependencies?
    private var captureLease: ResourceLease?
    private var leaseRenewal: Task<Void, Never>?
    private var eventSequence: UInt64 = 0
    private(set) var captureEvent: ActivityEvent?
    private var recoverRequested = false
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

    init(
        camera: AppleCamera, state: CameraState, makeRuntime: @escaping () throws -> CameraRuntimeDependencies,
        makeSession: @escaping () async throws -> VisionSession
    ) {
        self.captureOwner = ExecutionOwner(agent: Self.resourceOwnerID, incarnation: UUID(), sessionID: UUID())
        self.makeRuntime = makeRuntime
        self.state = state
        self.makeSession = makeSession
        self.camera = camera
        preview = camera.preview
    }

    func pauseVisionForModelMaintenance() async {
        visionSession = nil
        let task = visionTask
        visionTask?.cancel()
        await task?.value
        visionTask = nil
        state.skeleton = nil
        state.visionMessage = "姿态模型已停用，可在设置中重新下载"
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

    /// Tool calls reject overlap rather than replacing another command's intent.
    func setEnabled(_ enabled: Bool, invocation: ToolInvocation) async throws {
        try Task.checkCancellation()
        guard foreground else { throw CameraControlError.notForeground }
        guard worker == nil else { throw CameraControlError.busy }
        if state.isEnabled == enabled {
            if enabled, state.isVisible { return }
            if !enabled, captureLease == nil {
                guard !failed, !(await camera.isRunning()) else { throw CameraControlError.unavailable }
                try Task.checkCancellation()
                return
            }
        }
        state.isEnabled = enabled
        failed = false
        state.message = nil
        state.needsSettings = false
        reconcile()
        try await finishCameraControl(enabled: enabled)
    }

    func flip(invocation: ToolInvocation) async throws {
        try Task.checkCancellation()
        guard foreground else { throw CameraControlError.notForeground }
        guard worker == nil else { throw CameraControlError.busy }
        guard state.isEnabled else { throw CameraControlError.disabled }
        switchCamera()
        try await finishCameraControl(enabled: true)
    }

    private func finishCameraControl(enabled: Bool) async throws {
        let expectedRevision = revision
        await worker?.value
        try Task.checkCancellation()
        guard revision == expectedRevision else { throw CancellationError() }
        guard foreground else { throw CameraControlError.notForeground }
        let running = await camera.isRunning()
        try Task.checkCancellation()
        guard revision == expectedRevision else { throw CancellationError() }
        if state.needsSettings { throw CameraControlError.permissionDenied }
        guard enabled ? state.isVisible && running : captureLease == nil && !failed && !running else {
            throw CameraControlError.unavailable
        }
    }

    func setChangeThreshold(_ value: Double) {
        guard value.isFinite, (0...1).contains(value), value != state.changeThreshold else { return }
        state.changeThreshold = value
        reconcile()
    }

    func retry() {
        recoverRequested = true
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
        state.trackingMessage = nil
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
    func visionStatus(_ message: String?, sessionID: UUID) {
        guard visionSession == sessionID, foreground, state.isEnabled else { return }
        state.visionMessage = message
        if message != nil { state.skeleton = nil }
    }
    func trackingStatus(_ message: String?, sessionID: UUID) {
        guard visionSession == sessionID, foreground, state.isEnabled else { return }
        state.trackingMessage = message
    }

    func present(_ target: UITools.Gaze, invocation: ToolInvocation) throws {
        try Task.checkCancellation()
        guard visionSession == invocation.context.sessionID, foreground, state.isEnabled, state.isVisible else {
            throw CancellationError()
        }
        guard gazeSequence.map({ invocation.context.sequence > $0 }) ?? true else { return }
        gazeSequence = invocation.context.sequence
        state.gaze = CGSize(width: target.x, height: target.y)
    }

    func present(_ overlay: ToolPoseOverlay, sessionID: UUID) throws {
        try Task.checkCancellation()
        guard visionSession == sessionID, foreground, state.isEnabled, state.isVisible else {
            throw CancellationError()
        }
        guard state.skeleton.map({ overlay.sequence > $0.sequence }) ?? true else { throw ImageInputError.outOfOrder }
        state.skeleton = PoseOverlay(
            sequence: overlay.sequence, timestamp: overlay.timestamp, rotation: overlay.rotation,
            people: overlay.people.map { $0.map { PoseOverlay.Joint(x: $0.x, y: $0.y, confidence: $0.confidence) } })
    }

    private func recordCapture(_ state: ActivityEvent.State, id: UUID) {
        eventSequence &+= 1
        captureEvent = ActivityEvent(activityID: id, owner: captureOwner, state: state, sequence: eventSequence)
    }

    private func startCapture(facing: CameraFacing) async throws -> AsyncThrowingStream<CameraFrame, Error> {
        let runtime = try makeRuntime()
        resourceRuntime = runtime
        if recoverRequested {
            recoverRequested = false
            if await runtime.resources.snapshot()[.cameraCapture] == .faulted {
                try await runtime.resources.recover([.cameraCapture])
            }
        }
        let lease = try await runtime.resources.acquire(
            resources: [.cameraCapture], owner: captureOwner, duration: .seconds(60)
        ) {
            await runtime.actions.cancel(resources: $0)
        }
        captureLease = lease
        let camera = self.camera
        do {
            let frames = try await runtime.resources.run(resources: [.cameraCapture], owner: captureOwner, lease: lease)
            {
                let frames = try await camera.start(facing: facing)
                guard await camera.isRunning() else { throw CameraError.unavailable }
                return frames
            }
            recordCapture(.started, id: lease.id)
            leaseRenewal = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    guard let self, let current = self.captureLease, current.id == lease.id else { return }
                    do {
                        self.captureLease = try await runtime.resources.renew(
                            current, owner: self.captureOwner, duration: .seconds(60))
                    } catch {
                        self.recordCapture(.revoked, id: lease.id)
                        self.failed = true
                        self.state.message = "相机控制已结束，请重试"
                        self.reconcile()
                        return
                    }
                }
            }
            return frames
        } catch {
            recordCapture(.failed, id: lease.id)
            _ = await stopCapture()
            throw error
        }
    }

    /// Releasing an old lease never calls the device directly and cannot stop a replacement owner.
    private func stopCapture() async -> Bool {
        leaseRenewal?.cancel()
        leaseRenewal = nil
        guard let lease = captureLease, let runtime = resourceRuntime else { return true }
        captureLease = nil
        do {
            try await runtime.resources.release(lease, owner: captureOwner)
            recordCapture(.stopped, id: lease.id)
            return true
        } catch ResourceError.staleLease {
            let current = await runtime.resources.snapshot()[.cameraCapture]
            if current == .available
                || {
                    if case .leased = current { return true }
                    return false
                }()
            {
                recordCapture(.revoked, id: lease.id)
                return true
            }
        } catch {}
        recordCapture(.failed, id: lease.id)
        failed = true
        state.isVisible = false
        state.message = "相机尚未确认停止，请重试"
        return false
    }

    private func applyLatestIntent() async {
        defer {
            worker = nil
            state.isBusy = false
        }
        while true {
            let current = revision
            guard await stopCapture() else { return }
            await visionTask?.value
            visionTask = nil
            guard current == revision else { continue }
            if !state.isEnabled || !foreground || failed {
                _ = await stopCapture()
            } else {
                let authorized = await AppleCamera.requestPermission()
                // Permission prompts may suspend/deactivate the scene or outlive a user stop.
                guard current == revision else { continue }
                if authorized {
                    do {
                        let frames = try await startCapture(facing: state.facing == .front ? .front : .back)
                        let running = await camera.isRunning()
                        if current == revision {
                            state.isVisible = running
                            state.message = running ? nil : "相机暂时不可用，请重试"
                            state.needsSettings = false
                            if running { startVision(frames: frames) }
                        }
                    } catch {
                        _ = await stopCapture()
                        if current == revision {
                            state.message =
                                (error as? CameraError) == .unavailable
                                ? "此设备没有可用的摄像头" : "无法开启相机，请重试"
                        }
                    }
                } else {
                    _ = await stopCapture()
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
