#if os(iOS)

    import AgentCore
    import CallRuntime
    import CoreGraphics
    import ExecutionRuntime
    import Foundation
    import FunctionContracts
    import OSLog
    import PlatformKit
    import StorageState
    import StorageCore
    import StorageMedia
    import UI
    import UIKit

    /// Scene-owned camera intent, independent of voice/model startup and recording state.
    @MainActor
    public final class CameraCoordinator: CameraOutputHandling, CameraControlCapability {
        public static let captureResource = ResourceID(rawValue: "camera.capture")
        public static let resourceOwnerID = AgentID(rawValue: "runtime.camera")

        private let captureOwner: ExecutionOwner
        private let makeRuntime: () throws -> CameraRuntimeDependencies
        private var resourceRuntime: CameraRuntimeDependencies?
        private var captureLease: ResourceLease?
        private var leaseRenewal: Task<Void, Never>?
        private var eventSequence: UInt64 = 0
        private(set) var captureEvent: ActivityEvent?
        private let presentation: any CameraPresenting
        private var state: CameraPresentationSnapshot { presentation.snapshot }
        private var gazeSequence: UInt64?
        private let connectPerception:
            @MainActor (
                String, Bool, any CameraOutputHandling
            ) async throws -> Void
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
        private let camera: any CameraCapturing
        private var foreground = false
        private var failed = false
        private var revision = 0
        private var worker: Task<Void, Never>?
        private let photos: CapturedPhotoStore
        private let saveJPEG: @Sendable (Data) async throws -> Void

        private let photoCues: any CuePlaying
        private lazy var photoSession = CameraPhotoSession(
            camera: camera, presentation: presentation, photos: photos, photoCues: photoCues, saveJPEG: saveJPEG,
            isForeground: { [weak self] in self?.foreground ?? false },
            captureRevision: { [weak self] in self?.revision ?? -1 },
            ensureCaptureAvailable: { [weak self] in
                guard let self else { throw CancellationError() }
                guard self.worker == nil else { throw CameraControlError.busy }
                guard self.state.isEnabled else { throw CameraControlError.disabled }
                guard self.state.isVisible, self.captureLease != nil else { throw CameraControlError.unavailable }
            }, factsChanged: { [weak self] in self?.publishPublicFacts() })

        public init(
            camera: any CameraCapturing, presentation: any CameraPresenting, photos: CapturedPhotoStore,
            photoCues: any CuePlaying,
            saveJPEG: @escaping @Sendable (Data) async throws -> Void,

            makeRuntime: @escaping () throws -> CameraRuntimeDependencies,
            connectPerception:
                @escaping @MainActor (
                    String, Bool, any CameraOutputHandling
                ) async throws -> Void
        ) {
            self.saveJPEG = saveJPEG
            self.photoCues = photoCues
            self.captureOwner = ExecutionOwner(
                agent: Self.resourceOwnerID, incarnation: UUID().uuidString,
                sessionID: UUID().uuidString)
            self.makeRuntime = makeRuntime
            self.presentation = presentation
            self.connectPerception = connectPerception
            self.camera = camera
            self.photos = photos
        }

        public struct PublicFacts: Encodable, Sendable, Equatable {
            public let enabled: Bool
            public let running: Bool
            public let selectedFacing: String
            public let busy: Bool
            public let needsSettings: Bool
            public let displayedMediaID: String?
            public let savedMediaID: String?
            private enum CodingKeys: String, CodingKey {
                case enabled, running, selectedFacing, busy, needsSettings, displayedMediaID, savedMediaID
            }
            public func encode(to encoder: any Encoder) throws {
                var fields = encoder.container(keyedBy: CodingKeys.self)
                try fields.encode(enabled, forKey: .enabled)
                try fields.encode(running, forKey: .running)
                try fields.encode(selectedFacing, forKey: .selectedFacing)
                try fields.encode(busy, forKey: .busy)
                try fields.encode(needsSettings, forKey: .needsSettings)
                try fields.encode(displayedMediaID, forKey: .displayedMediaID)
                try fields.encode(savedMediaID, forKey: .savedMediaID)
            }
        }
        private var confirmedRunning = false { didSet { publishPublicFacts() } }
        private var publicFacts: StateWriter<PublishedState<PublicFacts>>?
        private var lastPublicFacts: PublicFacts?
        public private(set) var publicStateFailure: (any Error)?
        public func connectPublicState(scope: StateScope) throws {
            guard publicFacts == nil else { throw StateError.duplicate }
            publicFacts = try scope.register(
                StateKey("camera"), initial: PublishedState<PublicFacts>(availability: .unknown))
            presentation.connectFactsObserver { [weak self] in self?.publishPublicFacts() }
            publishPublicFacts()
            if let publicStateFailure { throw publicStateFailure }
        }
        private func publishPublicFacts() {
            guard let publicFacts else { return }
            let fact = PublicFacts(
                enabled: state.isEnabled, running: confirmedRunning,
                selectedFacing: state.facing == .front ? "front" : "back",
                busy: state.isBusy || state.photoBusy, needsSettings: state.needsSettings,
                displayedMediaID: state.capturedPhoto?.didReachThumbnail == true ? state.capturedPhoto?.id : nil,
                savedMediaID: state.savedMediaID)
            let availability: StateAvailability =
                state.needsSettings
                    || (state.message != nil && state.isEnabled && !state.isVisible && !state.isBusy)
                ? .unavailable : .available
            do {
                let old = try publicFacts.get()
                guard fact != lastPublicFacts || old.value.availability != availability || publicStateFailure != nil
                else { return }
                try publicFacts.set(PublishedState(fact, availability: availability), expecting: old.revision)
                lastPublicFacts = fact
                publicStateFailure = nil
            } catch {
                publicFacts.invalidate()
                publicStateFailure = error
                log.error("Camera public State publication failed: \(String(describing: error), privacy: .public)")
            }
        }

        public func readPhoto(_ id: String, source: String, sessionID: String, inputID: String) async throws -> Data {
            try await photoSession.readPhoto(id, source: source, sessionID: sessionID, inputID: inputID)
        }
        public func ignorePhoto(_ id: String?, invocation: any FunctionInput) async throws -> CameraPhotoCommandReceipt
        {
            try await photoSession.ignorePhoto(id, invocation: invocation)
        }
        public func savePhoto(_ id: String?, invocation: any FunctionInput) async throws -> CameraPhotoCommandReceipt {
            try await photoSession.savePhoto(id, invocation: invocation)
        }
        public func takePhoto(invocation: any FunctionInput) async throws -> CameraPhotoReceipt {
            try await photoSession.takePhoto(invocation: invocation)
        }

        public func pauseVisionForModelMaintenance() async {
            visionSession = nil
            await visionRestart.stop()
            presentation.clearPose()
            presentation.present(.visionMessage("姿态模型已停用，可在设置中重新下载"))
        }

        /// Tool calls reject overlap rather than replacing another command's intent.
        public func setEnabled(_ enabled: Bool, invocation: any FunctionInput) async throws {
            try Task.checkCancellation()
            guard foreground else { throw CameraControlError.notForeground }
            guard worker == nil, !photoSession.isBusy else { throw CameraControlError.busy }
            if state.isEnabled == enabled {
                if enabled, state.isVisible { return }
                if !enabled, captureLease == nil {
                    guard !failed, !(await camera.isRunning()) else { throw CameraControlError.unavailable }
                    try Task.checkCancellation()
                    return
                }
            }
            presentation.present(.isEnabled(enabled))
            failed = false
            presentation.present(.message(nil))
            presentation.present(.needsSettings(false))
            reconcile()
            try await finishCameraControl(enabled: enabled)
        }

        public func flip(_ facing: CameraActions.Facing, invocation: any FunctionInput) async throws {
            try Task.checkCancellation()
            guard foreground else { throw CameraControlError.notForeground }
            guard worker == nil, !photoSession.isBusy else { throw CameraControlError.busy }
            guard state.isEnabled else { throw CameraControlError.disabled }
            let target: CameraDirection = facing == .front ? .front : .back
            if state.facing == target, state.isVisible {
                try await finishCameraControl(enabled: true)
                return
            }
            presentation.present(.facing(target))
            failed = false
            presentation.present(.message(nil))
            presentation.present(.needsSettings(false))
            reconcile(hotSwitch: state.isVisible && captureLease != nil)
            try await finishCameraControl(enabled: true)
        }

        private func finishCameraControl(enabled: Bool) async throws {
            let expectedRevision = revision
            await worker?.value
            try Task.checkCancellation()
            guard revision == expectedRevision else { throw CancellationError() }
            guard foreground else { throw CameraControlError.notForeground }
            if let publicStateFailure { throw publicStateFailure }
            let running = await camera.isRunning()
            confirmedRunning = running
            if let publicStateFailure { throw publicStateFailure }
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
            presentation.present(.message(nil))
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
                confirmedRunning = await camera.isRunning()
                guard state.isEnabled, foreground else { continue }
                switch event {
                case .interrupted:
                    visionSession = nil
                    presentation.clearPose()
                    presentation.present(.gaze(.zero))
                    gazeSequence = nil
                    visionRestart.invalidate()
                    presentation.present(.isVisible(false))
                    presentation.present(.message("相机暂时被占用"))
                case .interruptionEnded:
                    reconcile()
                case .failed:
                    failed = true
                    presentation.present(.message("相机暂时不可用，请重试"))
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
            photoSession.cancel()
            presentation.present(.isVisible(false))
            presentation.clearPose()
            presentation.present(.gaze(.zero))
            gazeSequence = nil
            presentation.present(.visionMessage(nil))
            visionSession = nil
            visionRestart.invalidate()
            guard worker == nil else { return }
            presentation.present(.isBusy(true))
            worker = Task { await applyLatestIntent() }
        }

        private var visionDisplayToken: UIPresentationToken?
        private func startVision(_ intent: VisionIntent) -> Task<Void, Never>? {
            guard foreground, state.isEnabled, state.isVisible, revision == intent.revision else { return nil }
            let id = UUID().uuidString
            visionSession = id
            visionDisplayToken = presentation.token
            presentation.present(.visionMessage("姿态识别准备中"))
            let mirrored = intent.mirrored
            let displayToken = presentation.token
            return Task { [weak self] in
                guard let self else { return }
                do {
                    let preview = intent.frames
                    try Task.checkCancellation()
                    async let cameraOutput: Void = self.runPreview(preview, sessionID: id, token: displayToken)
                    async let poseOutput: Void = self.runPose(intent, sessionID: id, mirrored: mirrored)
                    // Model completion does not cancel the independent camera subscription.
                    _ = await (cameraOutput, poseOutput)
                } catch is CancellationError {} catch {
                    guard self.visionSession == id else { return }
                    self.presentation.present(.message("相机画面订阅失败，请重试"))
                }
            }
        }
        private func runPreview(
            _ frames: AsyncThrowingStream<CameraFrame, Error>, sessionID: String,
            token displayToken: UIPresentationToken
        ) async {
            do {
                for try await frame in frames {

                    try Task.checkCancellation()
                    guard visionSession == sessionID, foreground, state.isEnabled, state.isVisible else { return }
                    do {
                        try presentation.presentVideo(Self.displayFrame(frame), token: displayToken)
                        if frame.sequence % 120 == 0,
                            ProcessInfo.processInfo.arguments.contains("-direct-input-diagnostics")
                        {
                            print("DIRECT_CAMERA_PREVIEW accepted width=\(frame.width) height=\(frame.height)")
                        }
                    } catch CameraFramePresentationError
                        .stale
                    {
                        if frame.sequence % 120 == 0,
                            ProcessInfo.processInfo.arguments.contains("-direct-input-diagnostics")
                        {
                            print("DIRECT_CAMERA_PREVIEW stale")
                        }
                        continue
                    }
                }
            } catch is CancellationError {} catch is UIContainerError {
                if ProcessInfo.processInfo.arguments.contains("-direct-input-diagnostics") {
                    print("DIRECT_CAMERA_PREVIEW admission_closed")
                }
                // Lifecycle closure is expected and must not create another camera fault.
                return
            } catch {
                guard visionSession == sessionID else { return }
                presentation.clearFrame()
                presentation.present(.message("相机画面暂不可用，请重试"))
                log.error("Camera preview failed: \(String(describing: error), privacy: .private)")
            }
        }
        private func runPose(_ intent: VisionIntent, sessionID: String, mirrored: Bool) async {
            do {
                try Task.checkCancellation()
                try await connectPerception(sessionID, mirrored, self)
            } catch is CancellationError {} catch {
                guard visionSession == sessionID else { return }
                presentation.clearPose()
                presentation.present(.gaze(.zero))
                gazeSequence = nil
                presentation.present(.visionMessage("姿态识别暂不可用，请重试"))
                log.error("Pose pipeline failed: \(String(describing: error), privacy: .private)")
            }
        }
        private static func displayFrame(_ frame: CameraFrame) -> UI.CameraVideoFrame {
            frame.withPixelBuffer {
                UI.CameraVideoFrame(
                    pixels: $0, width: frame.width, height: frame.height,
                    rotation: frame.rotation, sequence: frame.sequence, capturedAt: frame.capturedAt)
            }
        }
        public func visionStatus(_ message: String?, sessionID: String) {
            guard visionSession == sessionID, foreground, state.isEnabled else { return }
            presentation.present(.visionMessage(message))
            if message != nil { presentation.clearPose() }
        }
        public func present(_ target: UIActions.Gaze, invocation: any FunctionInput) throws {
            try Task.checkCancellation()
            guard visionSession == invocation.context.sessionID, foreground, state.isEnabled, state.isVisible else {
                throw CancellationError()
            }
            guard gazeSequence.map({ invocation.context.sequence > $0 }) ?? true else { return }
            gazeSequence = invocation.context.sequence
            presentation.present(.gaze(CGSize(width: target.x, height: target.y)))
        }

        public func present(_ overlay: Actions.PoseOverlay, frame: CameraFrame?, sessionID: String) throws {
            try Task.checkCancellation()
            guard visionSession == sessionID, foreground, state.isEnabled, state.isVisible else {
                throw CancellationError()
            }
            guard state.skeleton.map({ overlay.sequence > $0.sequence }) ?? true else {
                throw CommunicationError.outOfOrder
            }
            guard let frame, frame.sequence == overlay.sequence, frame.rotation == overlay.rotation else {
                throw CameraFramePresentationError.stale
            }
            guard let displayToken = visionDisplayToken else { throw UIContainerError.stale }
            try presentation.present(
                frame: Self.displayFrame(frame),
                pose: UI.PoseOverlay(
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
                    }), token: displayToken)
            presentation.present(.visionMessage(nil))
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
                confirmedRunning = await camera.isRunning()
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
                            self.presentation.present(.message("相机控制已结束，请重试"))
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
            await photoSession.stopAndWait()
            leaseRenewal?.cancel()
            leaseRenewal = nil
            guard let lease = captureLease, let runtime = resourceRuntime else {
                confirmedRunning = await camera.isRunning()
                return true
            }
            captureLease = nil
            do {
                try await runtime.resources.release(lease, owner: captureOwner)
                confirmedRunning = await camera.isRunning()
                recordCapture(.stopped, id: lease.id)
                return true
            } catch CameraResourceFailure.staleLease {
                if await runtime.resources.isReleased(CameraCoordinator.captureResource) {
                    confirmedRunning = await camera.isRunning()
                    recordCapture(.revoked, id: lease.id)
                    return true
                }
            } catch {}
            confirmedRunning = await camera.isRunning()
            recordCapture(.failed, id: lease.id)
            failed = true
            presentation.present(.isVisible(false))
            presentation.present(.message("相机尚未确认停止，请重试"))
            return false
        }

        private func applyLatestIntent() async {
            defer {
                worker = nil
                presentation.present(.isBusy(false))
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
                        confirmedRunning = running
                        guard current == revision else { continue }
                        guard running else { throw CameraError.startFailed }
                        let elapsed = switchingStarted.duration(to: .now).components
                        let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
                        log.debug("Native lens switch acknowledged in \(milliseconds, privacy: .public) ms")
                        presentation.present(.isVisible(true))
                        presentation.present(.message(nil))
                        presentation.present(.needsSettings(false))
                        visionRestart.replace(
                            with: VisionIntent(frames: frames, revision: current, mirrored: facing == .front))
                        return
                    } catch {
                        guard current == revision else { continue }
                        failed = true
                        _ = await stopCapture()
                        await visionRestart.stop()
                        guard current == revision else { continue }
                        presentation.present(.message("无法切换镜头，请重试"))
                        return
                    }
                }
                guard await stopCapture() else { return }
                await visionRestart.stop()
                guard current == revision else { continue }
                if !state.isEnabled || !foreground || failed {
                    _ = await stopCapture()
                } else {
                    let authorized = await camera.requestPermission()
                    // Permission prompts may suspend/deactivate the scene or outlive a user stop.
                    guard current == revision else { continue }
                    if authorized {
                        do {
                            let frames = try await startCapture(facing: state.facing == .front ? .front : .back)
                            let running = await camera.isRunning()
                            confirmedRunning = running
                            if current == revision {
                                presentation.present(.isVisible(running))
                                presentation.present(.message(running ? nil : "相机暂时不可用，请重试"))
                                presentation.present(.needsSettings(false))
                                if running {
                                    visionRestart.replace(
                                        with: VisionIntent(
                                            frames: frames, revision: current, mirrored: state.facing == .front))
                                }
                            }
                        } catch {
                            _ = await stopCapture()
                            if current == revision {
                                presentation.present(
                                    .message(
                                        (error as? CameraError) == .unavailable
                                            ? "此设备没有可用的摄像头" : "无法开启相机，请重试"))
                            }
                        }
                    } else {
                        _ = await stopCapture()
                        if current == revision {
                            presentation.present(.message("请在设置中允许相机访问"))
                            presentation.present(.needsSettings(true))
                        }
                    }
                }
                if current == revision { return }
            }
        }
    }

#endif
