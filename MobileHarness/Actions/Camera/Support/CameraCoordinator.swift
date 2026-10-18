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
    import StorageState
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
        private let presentation: any CameraPresenting
        private var state: CameraPresentationSnapshot { presentation.snapshot }
        private var gazeSequence: UInt64?
        private let connectFrames:
            @MainActor (
                AsyncThrowingStream<CameraFrame, Error>, String, Bool, any CameraOutputHandling
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
        private var photoTask: Task<CameraPhotoReceipt, Error>?
        private var photoCommand: Task<CameraPhotoCommandReceipt, Error>?
        private var photoOwner: (id: String, owner: StorageOwner)?
        private let photos: CapturedPhotoStore
        private var presentationFinished: (id: String, success: Bool)?
        private let saveJPEG: @Sendable (Data) async throws -> Void
        private let nativeEvent: @Sendable (CameraEvent) async throws -> Void
        private let photoCues: any CuePlaying
        private var photoFeedbackContext: ActionExecutionContext?

        public init(
            camera: any CameraCapturing, presentation: any CameraPresenting, photos: CapturedPhotoStore,
            photoCues: any CuePlaying,
            saveJPEG: @escaping @Sendable (Data) async throws -> Void,
            nativeEvent: @escaping @Sendable (CameraEvent) async throws -> Void,
            makeRuntime: @escaping () throws -> CameraRuntimeDependencies,
            connectFrames:
                @escaping @MainActor (
                    AsyncThrowingStream<CameraFrame, Error>, String, Bool, any CameraOutputHandling
                ) async throws -> Void
        ) {
            self.saveJPEG = saveJPEG
            self.nativeEvent = nativeEvent
            self.photoCues = photoCues
            self.captureOwner = ExecutionOwner(
                agent: Self.resourceOwnerID, incarnation: UUID().uuidString,
                sessionID: UUID().uuidString)
            self.makeRuntime = makeRuntime
            self.presentation = presentation
            self.connectFrames = connectFrames
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
            presentation.present(.photoBusy(true))
            defer {
                photoCommand = nil
                presentation.present(.photoBusy(false))
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
            presentation.present(.photoBusy(true))
            presentation.present(.photoMessage("正在保存到相册…"))
            let task = Task<CameraPhotoCommandReceipt, Error> {
                let issues = try await departPhoto(photo, kind: .save, invocation: invocation) { [self] in
                    let data = try await photos.read(selected.id, owner: selected.owner)
                    try Task.checkCancellation()
                    guard foreground, state.capturedPhoto?.id == selected.id else { throw CancellationError() }
                    do { try await saveJPEG(data) } catch ApplePhotoLibrary.Failure.permissionDenied {
                        throw CameraControlError.permissionDenied
                    } catch ApplePhotoLibrary.Failure.invalidImage {
                        throw CameraControlError.photoUnavailable
                    }
                    // An actual import remains committed if feedback subsequently fails or is cancelled.
                    presentation.present(.savedMediaID(selected.id))
                    presentation.present(.photoMessage("已保存到相册"))
                }
                return CameraPhotoCommandReceipt(
                    mediaID: selected.id, state: .saved, feedbackIssues: issues.isEmpty ? nil : issues)
            }
            photoCommand = task
            defer {
                photoCommand = nil
                presentation.present(.photoBusy(false))
            }
            do {
                return try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
            } catch {
                presentation.present(
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
                animation: { [presentation] in try await presentation.departPhoto(id: photo.id, kind: kind) },
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
                    presentation.present(.capturedPhoto(nil))
                    photoOwner = nil
                    presentation.present(.photoMessage(nil))
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
                let rotation = await camera.captureRotation
                let data = try await camera.capturePhoto(rotation: rotation)
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
                presentation.present(.savedMediaID(nil))
                presentation.present(.photoMessage(nil))
                try presentation.presentPhoto(id: id, image: image) { [weak self] success in
                    guard let self, self.state.capturedPhoto?.id == id else { return }
                    self.publishPublicFacts()
                    self.presentationFinished = (id, success)
                }
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
                        presentation.present(.capturedPhoto(nil))
                        photoOwner = nil
                    }
                    throw error
                }
            }
            photoTask = task
            presentation.present(.photoBusy(true))
            defer {
                photoTask = nil
                presentation.present(.photoBusy(false))
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
            presentation.clearPose()
            presentation.present(.visionMessage("姿态模型已停用，可在设置中重新下载"))
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
            guard worker == nil, photoTask == nil, photoCommand == nil else { throw CameraControlError.busy }
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
                do { try await nativeEvent(event) } catch { presentation.present(.visionMessage("相机事件接入失败：\(error)")) }
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
            photoTask?.cancel()
            photoCommand?.cancel()
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
                    let preview = try await self.camera.subscribeFrames()
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
                    } catch CameraFramePresentationError
                        .stale
                    {
                        continue
                    }
                }
            } catch is CancellationError {} catch is UIContainerError {
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
                try await connectFrames(intent.frames, sessionID, mirrored, self)
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
            photoTask?.cancel()
            photoCommand?.cancel()
            _ = try? await photoTask?.value
            _ = try? await photoCommand?.value
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

    private struct CameraPhotoDisplayFailure: Error, LocalizedError, ActionExecutionFailureProviding {
        public let mediaID: String
        public var executionFailureCode: ActionExecutionFailureCode { .init(rawValue: "photoPresentationFailed") }
        public var errorDescription: String? { "Photo \(mediaID) was saved, but its presentation did not complete." }
    }

#endif
