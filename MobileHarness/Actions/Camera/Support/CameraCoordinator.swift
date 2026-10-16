#if os(iOS)
    import Actions
    import AgentCore
    import CallRuntime
    import CoreGraphics
    import ExecutionRuntime
    import Foundation
    import FunctionContracts
    import OSLog
    import PlatformKit
    import StorageCore
    import StorageMedia
    import UI
    import UIKit

    /// Scene-owned camera intent, independent of voice/model startup and recording state.
    @MainActor
    public final class CameraCoordinator: CameraOutputHandling, CameraControlCapability, UIFeedbackCapability {
        public static let captureResource = ResourceID(rawValue: "camera.capture")
        public static let resourceOwnerID = AgentID(rawValue: "runtime.camera")
        private let captureOwner: ExecutionOwner
        private let makeRuntime: () throws -> CameraRuntimeDependencies
        private var resourceRuntime: CameraRuntimeDependencies?
        private var captureLease: ResourceLease?
        private var leaseRenewal: Task<Void, Never>?
        private var eventSequence: UInt64 = 0
        private(set) var captureEvent: ActivityEvent?
        public let preview: CameraPreviewSource
        public let state: CameraState
        private var gazeSequence: UInt64?
        private let makeSession: () async throws -> any CameraVisionRunning
        private struct VisionIntent: Sendable {
            let frames: AsyncThrowingStream<CameraFrame, Error>
            let revision: Int
            let mirrored: Bool
        }
        private lazy var visionRestart = CameraVisionRestartWorkflow<VisionIntent> { [weak self] intent in
            self?.startVision(intent)
        }
        private var hotSwitchRevision: Int?
        private var visionSession: String?
        private let log = Logger(subsystem: "dev.mobileharness", category: "CameraPipeline")
        private let camera: AppleCamera
        private var foreground = false
        private var failed = false
        private var revision = 0
        private var worker: Task<Void, Never>?
        private var photoTask: Task<CameraPhotoReceipt, Error>?
        private var photoCommand: Task<CameraPhotoCommandReceipt, Error>?
        private var photoOwner: (id: String, owner: StorageOwner)?
        private let photos: CapturedPhotoStore
        private var presentationFinished: (id: String, success: Bool)?
        private let photoCues = NativeCuePlayback()
        private var photoFeedbackContext: ActionExecutionContext?

        public init(
            camera: AppleCamera, state: CameraState, photos: CapturedPhotoStore,
            makeRuntime: @escaping () throws -> CameraRuntimeDependencies,
            makeSession: @escaping () async throws -> any CameraVisionRunning
        ) {
            self.captureOwner = ExecutionOwner(
                agent: Self.resourceOwnerID, incarnation: UUID().uuidString,
                sessionID: UUID().uuidString)
            self.makeRuntime = makeRuntime
            self.state = state
            self.makeSession = makeSession
            self.camera = camera
            self.photos = photos
            preview = camera.preview
        }

        public func readPhoto(_ id: String, source: String, sessionID: String, inputID: String) async throws -> Data {
            try await photos.read(
                id, owner: StorageOwner(namespace: "photos", source: source, session: sessionID, input: inputID))
        }

        private func selectedPhoto(_ requested: String?) throws -> (id: String, owner: StorageOwner) {
            guard let selected = photoOwner, state.capturedPhoto?.id == selected.id,
                requested == nil || requested == selected.id,
                state.capturedPhoto?.didReachThumbnail == true
            else { throw CameraControlError.photoUnavailable }
            return selected
        }

        public func ignorePhoto(_ id: String?, invocation: any FunctionInput) async throws -> CameraPhotoCommandReceipt
        {
            try Task.checkCancellation()
            guard foreground else { throw CameraControlError.notForeground }
            guard photoTask == nil, photoCommand == nil else { throw CameraControlError.busy }
            let selected = try selectedPhoto(id)
            guard let photo = state.capturedPhoto else { throw CameraControlError.photoUnavailable }
            let task = Task<CameraPhotoCommandReceipt, Error> {
                let issues = try await departPhoto(photo, kind: .discard, invocation: invocation, commit: {})
                return CameraPhotoCommandReceipt(
                    mediaID: selected.id, state: .ignored, feedbackIssues: issues.isEmpty ? nil : issues)
            }
            photoCommand = task
            state.present(.photoBusy(true))
            defer {
                photoCommand = nil
                state.present(.photoBusy(false))
            }
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }

        public func savePhoto(_ id: String?, invocation: any FunctionInput) async throws -> CameraPhotoCommandReceipt {
            try Task.checkCancellation()
            guard foreground else { throw CameraControlError.notForeground }
            guard photoTask == nil, photoCommand == nil else { throw CameraControlError.busy }
            if let id, state.savedMediaID == id {
                return CameraPhotoCommandReceipt(mediaID: id, state: .saved, alreadySaved: true)
            }
            let selected = try selectedPhoto(id)
            guard let photo = state.capturedPhoto else { throw CameraControlError.photoUnavailable }
            state.present(.photoBusy(true))
            state.present(.photoMessage("正在保存到相册…"))
            let task = Task<CameraPhotoCommandReceipt, Error> {
                let issues = try await departPhoto(photo, kind: .save, invocation: invocation) { [self] in
                    let data = try await photos.read(selected.id, owner: selected.owner)
                    try Task.checkCancellation()
                    guard foreground, state.capturedPhoto?.id == selected.id else { throw CancellationError() }
                    do { try await ApplePhotoLibrary.saveJPEG(data) } catch ApplePhotoLibrary.Failure.permissionDenied {
                        throw CameraControlError.permissionDenied
                    } catch ApplePhotoLibrary.Failure.invalidImage {
                        throw CameraControlError.photoUnavailable
                    }
                    // An actual import remains committed if feedback subsequently fails or is cancelled.
                    state.present(.savedMediaID(selected.id))
                    state.present(.photoMessage("已保存到相册"))
                }
                return CameraPhotoCommandReceipt(
                    mediaID: selected.id, state: .saved, feedbackIssues: issues.isEmpty ? nil : issues)
            }
            photoCommand = task
            defer {
                photoCommand = nil
                state.present(.photoBusy(false))
            }
            do {
                return try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
            } catch {
                state.present(
                    .photoMessage(
                        state.savedMediaID == selected.id
                            ? "已保存到相册，退场反馈已中断" : "保存失败：" + error.localizedDescription))
                throw error
            }
        }

        private func departPhoto(
            _ photo: CapturedPhotoPresentation, kind: PhotoDeparture.Kind, invocation: any FunctionInput,
            commit: @escaping @MainActor @Sendable () async throws -> Void
        ) async throws -> [String] {
            let cue: UIActions.Cue = kind == .save ? .save : .discard
            photoFeedbackContext = invocation.context
            defer { photoFeedbackContext = nil }
            let issues = try await PhotoDispositionWorkflow.run(
                commit: commit,
                animation: { try await photo.departure.perform(kind) },
                sound: { [self] in
                    guard
                        let definition = UIModule.feedbackDefinitions(feedback: self).first(where: {
                            $0.path.function == "playCue"
                        })
                    else { throw UIActions.FeedbackError.unavailable }
                    let child = FunctionInvocation(
                        call: FunctionRequest(
                            actionPath: definition.path, parameters: ["cue": cue.rawValue, "volume": "0.85"]),
                        context: invocation.context, executionID: UUID().uuidString,
                        results: ActionReportStore())
                    let completion = try await FunctionExecutor.perform(child, definition: definition)
                    if case .report(let report) = completion, report.hasFailures || report.isCancelled {
                        throw PhotoCueFailure(description: report.failureDescription ?? "Photo cue failed")
                    }
                },
                remove: { [self] in
                    guard state.capturedPhoto?.id == photo.id else { return }
                    state.present(.capturedPhoto(nil))
                    photoOwner = nil
                    state.present(.photoMessage(nil))
                })
            if !issues.isEmpty { log.error("照片已处理，退场反馈异常：\(issues.joined(separator: "; "), privacy: .public)") }
            return issues
        }
        private struct PhotoCueFailure: Error, Sendable { let description: String }
        public func playCue(_ request: UIActions.CueRequest, invocation: any FunctionInput) async throws {
            try Task.checkCancellation()
            guard foreground, photoCommand != nil, photoFeedbackContext == invocation.context,
                request.cue == .save || request.cue == .discard
            else { throw CancellationError() }
            let samples = try await Task.detached(priority: .userInitiated) { try FeedbackTone.samples(for: request) }
                .value
            try Task.checkCancellation()
            guard foreground, photoFeedbackContext == invocation.context else { throw CancellationError() }
            try await photoCues.play(PlaybackPCM(samples: samples, sampleRate: FeedbackTone.sampleRate))
        }
        public func vibrate(_ request: UIActions.HapticRequest, invocation: any FunctionInput) async throws {
            throw UIActions.FeedbackError.unavailable
        }

        public func takePhoto(invocation: any FunctionInput) async throws -> CameraPhotoReceipt {
            try Task.checkCancellation()
            guard foreground else { throw CameraControlError.notForeground }
            guard worker == nil, photoTask == nil, photoCommand == nil else { throw CameraControlError.busy }
            guard state.isEnabled else { throw CameraControlError.disabled }
            guard state.isVisible, captureLease != nil else { throw CameraControlError.unavailable }
            let expectedRevision = revision
            let task = Task<CameraPhotoReceipt, Error> {
                let data = try await camera.capturePhoto(rotation: preview.captureRotation)
                try Task.checkCancellation()
                guard foreground, state.isVisible, revision == expectedRevision else { throw CancellationError() }
                guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
                    throw CameraControlError.unavailable
                }
                let owner = StorageOwner(
                    namespace: "photos", source: invocation.context.source,
                    session: invocation.context.sessionID, input: invocation.context.inputID)
                let id = try await photos.save(data, owner: owner)
                // Durable capture is retained if subsequent presentation or turn delivery fails.
                let receipt = try CameraPhotoReceipt(
                    mediaID: id, width: Int(image.size.width * image.scale),
                    height: Int(image.size.height * image.scale))
                try Task.checkCancellation()
                guard foreground, revision == expectedRevision else { throw CancellationError() }
                presentationFinished = nil
                photoOwner = (id, owner)
                state.present(.savedMediaID(nil))
                state.present(.photoMessage(nil))
                state.present(
                    .capturedPhoto(
                        CapturedPhotoPresentation(id: id, image: image) { [weak self] success in
                            guard let self, self.state.capturedPhoto?.id == id else { return }
                            self.presentationFinished = (id, success)
                        }))
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                do {
                    while presentationFinished?.id != id {
                        try Task.checkCancellation()
                        guard foreground, revision == expectedRevision else { throw CancellationError() }
                        guard ContinuousClock.now < deadline else { throw CameraPhotoDisplayFailure(mediaID: id) }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    guard presentationFinished?.success == true else { throw CameraPhotoDisplayFailure(mediaID: id) }
                    return receipt
                } catch {
                    if state.capturedPhoto?.id == id {
                        state.present(.capturedPhoto(nil))
                        photoOwner = nil
                    }
                    throw error
                }
            }
            photoTask = task
            state.present(.photoBusy(true))
            defer {
                photoTask = nil
                state.present(.photoBusy(false))
            }
            return try await withTaskCancellationHandler {
                let result = try await task.value
                try Task.checkCancellation()
                return result
            } onCancel: {
                task.cancel()
            }
        }

        public func pauseVisionForModelMaintenance() async {
            visionSession = nil
            await visionRestart.stop()
            state.present(.skeleton(nil))
            state.present(.visionMessage("姿态模型已停用，可在设置中重新下载"))
        }

        /// Tool calls reject overlap rather than replacing another command's intent.
        public func setEnabled(_ enabled: Bool, invocation: any FunctionInput) async throws {
            try Task.checkCancellation()
            guard foreground else { throw CameraControlError.notForeground }
            guard worker == nil, photoTask == nil, photoCommand == nil else { throw CameraControlError.busy }
            if state.isEnabled == enabled {
                if enabled, state.isVisible { return }
                if !enabled, captureLease == nil {
                    guard !failed, !(await camera.isRunning()) else { throw CameraControlError.unavailable }
                    try Task.checkCancellation()
                    return
                }
            }
            state.present(.isEnabled(enabled))
            failed = false
            state.present(.message(nil))
            state.present(.needsSettings(false))
            reconcile()
            try await finishCameraControl(enabled: enabled)
        }

        public func flip(_ facing: CameraActions.Facing, invocation: any FunctionInput) async throws {
            try Task.checkCancellation()
            guard foreground else { throw CameraControlError.notForeground }
            guard worker == nil, photoTask == nil, photoCommand == nil else { throw CameraControlError.busy }
            guard state.isEnabled else { throw CameraControlError.disabled }
            let target: CameraDirection = facing == .front ? .front : .back
            if state.facing == target, state.isVisible {
                try await finishCameraControl(enabled: true)
                return
            }
            state.present(.facing(target))
            failed = false
            state.present(.message(nil))
            state.present(.needsSettings(false))
            reconcile(hotSwitch: state.isVisible && captureLease != nil)
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

        public func retry(invocation: any FunctionInput) async throws {
            try Task.checkCancellation()
            if state.needsSettings { retry() } else { try await setEnabled(true, invocation: invocation) }
        }
        public func retry() {
            failed = false
            state.present(.message(nil))
            reconcile()
        }

        public func setForeground(_ value: Bool) {
            guard foreground != value else { return }
            foreground = value
            if !value { photoCues.stop() }
            if value { failed = false }
            reconcile()
        }

        /// One notification consumer per scene; device status is coalesced, never a frame stream.
        public func shutdown() async throws {
            setForeground(false)
            await worker?.value
            await visionRestart.stop()
            let released = await stopCapture()
            guard released, !(await camera.isRunning()) else { throw CameraControlError.unavailable }
        }

        public func observe() async {
            for await event in camera.events {
                if Task.isCancelled { break }
                guard state.isEnabled, foreground else { continue }
                switch event {
                case .interrupted:
                    visionSession = nil
                    state.present(.skeleton(nil))
                    state.present(.gaze(.zero))
                    gazeSequence = nil
                    visionRestart.invalidate()
                    state.present(.isVisible(false))
                    state.present(.message("相机暂时被占用"))
                case .interruptionEnded:
                    reconcile()
                case .failed:
                    failed = true
                    state.present(.message("相机暂时不可用，请重试"))
                    reconcile()
                }
            }
            setForeground(false)
            // Join the existing worker before leaving the scene. It applies the newest off intent.
            await worker?.value
        }

        /// At most one worker and one latest desired state; repeated intents replace pending state.
        /// Stop immediately masks the preview even if a native start call is still completing.
        private func reconcile(hotSwitch: Bool = false) {
            revision += 1
            hotSwitchRevision = hotSwitch ? revision : nil
            photoTask?.cancel()
            photoCommand?.cancel()
            state.present(.isVisible(false))
            state.present(.skeleton(nil))
            state.present(.gaze(.zero))
            gazeSequence = nil
            state.present(.visionMessage(nil))
            visionSession = nil
            visionRestart.invalidate()
            guard worker == nil else { return }
            state.present(.isBusy(true))
            worker = Task { await applyLatestIntent() }
        }

        private func startVision(_ intent: VisionIntent) -> Task<Void, Never>? {
            guard foreground, state.isEnabled, state.isVisible, revision == intent.revision else { return nil }
            let id = UUID().uuidString
            visionSession = id
            let mirrored = intent.mirrored
            return Task { [weak self] in
                do {
                    let session = try await self?.makeSession()
                    try Task.checkCancellation()
                    guard let self, let session else { throw CancellationError() }
                    try await session.run(
                        frames: intent.frames, sessionID: id,
                        mirroredGaze: mirrored, endpoint: self)
                } catch is CancellationError {} catch {
                    guard let self, self.visionSession == id else { return }
                    self.state.present(.skeleton(nil))
                    self.state.present(.gaze(.zero))
                    self.gazeSequence = nil
                    self.state.present(.visionMessage("姿态识别暂不可用，请重试"))
                    self.log.error("Pose pipeline failed: \(String(describing: error), privacy: .private)")
                }
            }
        }
        public func visionStatus(_ message: String?, sessionID: String) {
            guard visionSession == sessionID, foreground, state.isEnabled else { return }
            state.present(.visionMessage(message))
            if message != nil { state.present(.skeleton(nil)) }
        }
        public func present(_ target: UIActions.Gaze, invocation: any FunctionInput) throws {
            try Task.checkCancellation()
            guard visionSession == invocation.context.sessionID, foreground, state.isEnabled, state.isVisible else {
                throw CancellationError()
            }
            guard gazeSequence.map({ invocation.context.sequence > $0 }) ?? true else { return }
            gazeSequence = invocation.context.sequence
            state.present(.gaze(CGSize(width: target.x, height: target.y)))
        }

        public func present(_ overlay: Actions.PoseOverlay, sessionID: String) throws {
            try Task.checkCancellation()
            guard visionSession == sessionID, foreground, state.isEnabled, state.isVisible else {
                throw CancellationError()
            }
            guard state.skeleton.map({ overlay.sequence > $0.sequence }) ?? true else {
                throw CommunicationError.outOfOrder
            }
            state.present(
                .skeleton(
                    UI.PoseOverlay(
                        sequence: overlay.sequence, timestamp: overlay.timestamp, rotation: overlay.rotation,
                        people: overlay.people.map {
                            $0.map { UI.PoseOverlay.Joint(x: $0.x, y: $0.y, confidence: $0.confidence) }
                        },
                        statistics: overlay.statistics.map {
                            UI.PoseOverlay.Statistics(
                                queueMilliseconds: $0.queueMilliseconds,
                                inferenceMilliseconds: $0.inferenceMilliseconds,
                                totalMilliseconds: $0.totalMilliseconds, framesPerSecond: $0.framesPerSecond,
                                replacements: $0.replacements,
                                detectionIntervalMilliseconds: $0.detectionIntervalMilliseconds,
                                imageMotion: $0.imageMotion)
                        })))
        }

        private func recordCapture(_ state: ActivityEvent.State, id: String) {
            eventSequence &+= 1
            let causality = captureEvent.flatMap { $0.activityID == id ? $0.causality : nil } ?? .root(id: id)
            captureEvent = ActivityEvent(
                activityID: id, owner: captureOwner, state: state, sequence: eventSequence, causality: causality)
        }

        private func startCapture(facing: CameraFacing) async throws -> AsyncThrowingStream<CameraFrame, Error> {
            let runtime = try makeRuntime()
            resourceRuntime = runtime
            let lease = try await runtime.resources.acquire(
                resources: [CameraCoordinator.captureResource], owner: captureOwner, duration: .seconds(60))
            captureLease = lease
            let camera = self.camera
            do {
                let frames = try await runtime.resources.run(
                    resources: [CameraCoordinator.captureResource], owner: captureOwner, lease: lease
                ) {
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
                            self.state.present(.message("相机控制已结束，请重试"))
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
            photoTask?.cancel()
            photoCommand?.cancel()
            _ = try? await photoTask?.value
            _ = try? await photoCommand?.value
            leaseRenewal?.cancel()
            leaseRenewal = nil
            guard let lease = captureLease, let runtime = resourceRuntime else { return true }
            captureLease = nil
            do {
                try await runtime.resources.release(lease, owner: captureOwner)
                recordCapture(.stopped, id: lease.id)
                return true
            } catch CameraResourceFailure.staleLease {
                if await runtime.resources.isReleased(CameraCoordinator.captureResource) {
                    recordCapture(.revoked, id: lease.id)
                    return true
                }
            } catch {}
            recordCapture(.failed, id: lease.id)
            failed = true
            state.present(.isVisible(false))
            state.present(.message("相机尚未确认停止，请重试"))
            return false
        }

        private func applyLatestIntent() async {
            defer {
                worker = nil
                state.present(.isBusy(false))
            }
            while true {
                let current = revision
                if hotSwitchRevision == current, foreground, state.isEnabled, !failed,
                    let lease = captureLease, let runtime = resourceRuntime, await camera.isRunning()
                {
                    do {
                        let switchingStarted = ContinuousClock.now
                        let facing: CameraFacing = state.facing == .front ? .front : .back
                        let frames = try await runtime.resources.run(
                            resources: [CameraCoordinator.captureResource], owner: captureOwner, lease: lease
                        ) { [camera] in try await camera.switchCamera(facing: facing) }
                        guard current == revision else { continue }
                        let running = await camera.isRunning()
                        guard current == revision else { continue }
                        guard running else { throw CameraError.startFailed }
                        let elapsed = switchingStarted.duration(to: .now).components
                        let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
                        log.debug("Native lens switch acknowledged in \(milliseconds, privacy: .public) ms")
                        state.present(.isVisible(true))
                        state.present(.message(nil))
                        state.present(.needsSettings(false))
                        visionRestart.replace(
                            with: VisionIntent(frames: frames, revision: current, mirrored: facing == .front))
                        return
                    } catch {
                        guard current == revision else { continue }
                        failed = true
                        _ = await stopCapture()
                        await visionRestart.stop()
                        guard current == revision else { continue }
                        state.present(.message("无法切换镜头，请重试"))
                        return
                    }
                }
                guard await stopCapture() else { return }
                await visionRestart.stop()
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
                                state.present(.isVisible(running))
                                state.present(.message(running ? nil : "相机暂时不可用，请重试"))
                                state.present(.needsSettings(false))
                                if running {
                                    visionRestart.replace(
                                        with: VisionIntent(
                                            frames: frames, revision: current, mirrored: state.facing == .front))
                                }
                            }
                        } catch {
                            _ = await stopCapture()
                            if current == revision {
                                state.present(
                                    .message(
                                        (error as? CameraError) == .unavailable
                                            ? "此设备没有可用的摄像头" : "无法开启相机，请重试"))
                            }
                        }
                    } else {
                        _ = await stopCapture()
                        if current == revision {
                            state.present(.message("请在设置中允许相机访问"))
                            state.present(.needsSettings(true))
                        }
                    }
                }
                if current == revision { return }
            }
        }
    }

    private struct CameraPhotoDisplayFailure: Error, LocalizedError, ActionExecutionFailureProviding {
        public let mediaID: String
        public var executionFailureCode: ActionExecutionFailureCode { .init(rawValue: "photoPresentationFailed") }
        public var errorDescription: String? { "Photo \(mediaID) was saved, but its presentation did not complete." }
    }

#endif
