#if os(iOS)

    import FunctionContracts
    import CallRuntime
    import CoreGraphics
    import ExecutionRuntime
    import Foundation
    import OSLog
    import PlatformKit
    import StorageCore
    import StorageMedia
    import UI
    import UIKit

    /// Scene-owned camera intent, independent of voice/model startup and recording state.
    @MainActor
    public final class CameraCoordinator: CameraOutputHandling, CameraControlCapability, WindowContentLifecycle {
        public static let captureResource = ResourceID(rawValue: "camera.capture")
        public static let resourceOwnerID = "runtime.camera"

        private let captureOwner: ExecutionOwner
        private let makeRuntime: () throws -> CameraRuntimeDependencies
        private var resourceRuntime: CameraRuntimeDependencies?
        private var captureLease: ResourceLease?
        private var leaseRenewal: Task<Void, Never>?
        private var eventSequence: UInt64 = 0
        private(set) var captureEvent: CaptureActivityEvent?
        private let presentation: any CameraPresenting
        private var state: CameraPresentationSnapshot { presentation.snapshot }
        private var gazeSequence: UInt64?
        private let connectPerception:
            @MainActor (
                String, Bool, any CameraOutputHandling
            ) async throws -> Void
        private struct PreviewIntent: Sendable {
            let frames: AsyncThrowingStream<CameraFrame, Error>
            let revision: Int
        }
        private lazy var previewRestart = CameraVisionRestartWorkflow<PreviewIntent> { [weak self] intent in
            self?.startPreview(intent)
        }
        private var changingDemand = false
        private var windowTransition = false
        private var requestedFacing: CameraDirection = .front
        private var poseTask: Task<Void, Never>?
        private var poseWorkID: UUID?
        private var previewSession: String?
        private var demand: Bool { state.isEnabled || state.perceptionEnabled }
        private var hotSwitchRevision: Int?
        private var visionSession: String?
        private let log = Logger(subsystem: "dev.mobileharness", category: "CameraPipeline")
        private let camera: any CameraCapturing
        private var foreground = false
        private var failed = false
        private var revision = 0
        private var worker: Task<Void, Never>?
        private let photos: CapturedPhotoStore
        private let windows: WindowState?
        public func windowID() async -> String? {
            windows?.windows.first(where: { $0.content == WindowContent.camera.rawValue })?.id.uuidString
        }

        var acquireRecordingAudio: @MainActor () async throws -> Void = {}
        var releaseRecordingAudio: @MainActor (Bool) async throws -> Void = { _ in }
        private(set) var recordingAudioHeld = false
        private lazy var recordingSession = CameraRecordingSession(
            camera: camera, photos: photos, presentation: presentation,
            foreground: { [weak self] in self?.foreground ?? false },
            acquireAudio: { [weak self] in
                guard let self else { throw CameraControlError.unavailable }
                self.recordingAudioHeld = true
                try await self.acquireRecordingAudio()
            },
            releaseAudio: { [weak self] resume in
                guard let self else { return }
                self.recordingAudioHeld = false
                try await self.releaseRecordingAudio(resume)
            },
            activity: { [weak self] value in
                guard let self, let windows = self.windows,
                    let item = windows.windows.first(where: { $0.content == WindowContent.camera.rawValue })
                else { return }
                windows.setActivity(item.id, label: value)
            })
        public func startRecording(durationSeconds: Int?, invocation: any FunctionInput) async throws
            -> CameraVideoReceipt
        {
            guard foreground, state.isEnabled, state.isVisible else {
                throw CameraControlError.disabled
            }
            guard state.lensOwner == .capture else { throw CameraControlError.lensNotOwned }
            guard !photoSession.isBusy, state.capturedPhoto == nil, worker == nil, !changingDemand, !windowTransition
            else { throw CameraControlError.busy }
            changingDemand = true
            defer { changingDemand = false }
            return try await recordingSession.start(
                duration: durationSeconds ?? state.settings.durationSeconds, invocation: invocation)
        }
        public func waitForRecording(_ id: String, invocation: any FunctionInput) async throws -> CameraVideoReceipt {
            try await recordingSession.wait(id)
        }
        public func stopRecording(_ id: String, invocation: any FunctionInput) async throws -> CameraVideoReceipt {
            try await recordingSession.stop(id)
        }
        public func saveVideo(_ id: String, invocation: any FunctionInput) async throws -> CameraVideoReceipt {
            guard foreground else { throw CameraControlError.notForeground }
            return try await recordingSession.save(id)
        }
        public func ignoreVideo(_ id: String, invocation: any FunctionInput) async throws -> CameraVideoReceipt {
            guard foreground else { throw CameraControlError.notForeground }
            return try await recordingSession.ignore(id)
        }
        private let photoCues: any CuePlaying
        private lazy var photoSession = CameraPhotoSession(
            camera: camera, presentation: presentation, photos: photos, photoCues: photoCues,
            isForeground: { [weak self] in self?.foreground ?? false },
            captureRevision: { [weak self] in self?.revision ?? -1 },
            ensureCaptureAvailable: { [weak self] in
                guard let self else { throw CancellationError() }
                guard self.worker == nil else { throw CameraControlError.busy }
                guard self.state.isEnabled else { throw CameraControlError.disabled }
                guard self.state.isVisible, self.captureLease != nil else { throw CameraControlError.unavailable }
            })

        public init(
            camera: any CameraCapturing, presentation: any CameraPresenting, photos: CapturedPhotoStore,
            photoCues: any CuePlaying, windows: WindowState? = nil,

            makeRuntime: @escaping () throws -> CameraRuntimeDependencies,
            connectPerception:
                @escaping @MainActor (
                    String, Bool, any CameraOutputHandling
                ) async throws -> Void
        ) {
            self.windows = windows
            self.photoCues = photoCues
            self.captureOwner = ExecutionOwner(
                endpoint: Self.resourceOwnerID, incarnation: UUID().uuidString,
                sessionID: UUID().uuidString)
            self.makeRuntime = makeRuntime
            self.presentation = presentation
            self.connectPerception = connectPerception
            self.camera = camera
            self.photos = photos
        }

        public func stateSnapshot() async throws -> ActionsStateSnapshot {
            try Task.checkCancellation()
            return ActionsStateSnapshot(
                path: "actions.camera",
                business: [
                    "mode": .text(state.settings.mode), "delaySeconds": .count(state.settings.delaySeconds),
                    "flash": .text(state.settings.flash), "zoom": .number(state.settings.zoom),
                    "maximumZoom": .number(state.settings.maximumZoom),
                    "supportedFlash": .text(state.settings.supportedFlash.joined(separator: ",")),
                    "durationSeconds": .count(state.settings.durationSeconds),
                    "recordingPhase": .text(state.recording.phase.rawValue),
                    "recordingID": state.recording.id.map { .text($0) } ?? .unknown,
                    "countdown": state.countdown.map { .count($0) } ?? .unknown,
                    "enabled": .flag(state.isEnabled), "perceptionEnabled": .flag(state.perceptionEnabled),
                    "lensOwner": state.lensOwner.map { .text($0.rawValue) } ?? .unknown,
                    "busy": .flag(state.isBusy || state.photoBusy), "needsSettings": .flag(state.needsSettings),
                    "displayedMediaID": state.capturedPhoto?.didReachThumbnail == true
                        ? state.capturedPhoto.map { .text($0.id) } ?? .unknown : .unknown,
                    "savedMediaID": state.savedMediaID.map { .text($0) } ?? .unknown,
                    "problem": failed
                        ? .text("cameraUnavailable")
                        : state.needsSettings ? .text("cameraPermissionRequired") : .unknown,
                ],
                runtime: [
                    "foreground": .flag(foreground), "worker": .flag(worker != nil),
                    "visionConnected": .flag(visionSession != nil),
                ],
                health: failed ? .fault : .unknown,
                issues: failed ? [.init(code: "cameraFailed", impact: "cameraExecutionUnavailable")] : [])
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
            guard !changingDemand, !windowTransition, worker == nil else { throw CameraControlError.busy }
            guard !recordingSession.busy, !recordingSession.hasClip else { throw CameraControlError.busy }
            changingDemand = true
            defer { changingDemand = false }
            if state.settings.mode != "photo" {
                guard state.capturedPhoto == nil else { throw CameraControlError.busy }
                guard foreground, state.isEnabled, state.isVisible else { throw CameraControlError.disabled }
                guard state.lensOwner == .capture else { throw CameraControlError.lensNotOwned }
                try await CameraCaptureConfiguration.preparePhoto(camera: camera, presentation: presentation)
            }
            try Task.checkCancellation()
            return try await photoSession.takePhoto(delaySeconds: state.settings.delaySeconds, invocation: invocation)
        }

        public func configureCapture(_ settings: CameraCaptureSettings, invocation: any FunctionInput) async throws {
            try settings.validate()
            guard foreground, state.isEnabled, state.isVisible else { throw CameraControlError.disabled }
            guard !photoSession.isBusy, !recordingSession.busy, !recordingSession.hasClip, worker == nil,
                !changingDemand, !windowTransition
            else { throw CameraControlError.busy }
            guard state.lensOwner == .capture else { throw CameraControlError.lensNotOwned }
            changingDemand = true
            defer { changingDemand = false }
            guard state.capturedPhoto == nil || settings.mode == state.settings.mode else {
                throw CameraControlError.busy
            }
            try await CameraCaptureConfiguration.apply(settings, camera: camera, presentation: presentation)
        }
        public func cancelCapture(invocation: any FunctionInput) async throws {
            try Task.checkCancellation()
            await photoSession.cancelCountdown()
        }

        public func pauseVisionForModelMaintenance() async {
            await stopPose()
            presentation.clearPose()
            presentation.present(.visionMessage("姿态模型已停用，可在设置中重新下载"))
        }

        /// Opening rejects conflicting work; closing joins camera/photo cleanup before disposition and exit.
        public func setEnabled(_ enabled: Bool, invocation: any FunctionInput) async throws {
            guard foreground else { throw CameraControlError.notForeground }
            try await beginWindowTransition()
            defer { endWindowTransition() }
            if enabled {
                guard !photoSession.isBusy, worker == nil else { throw CameraControlError.busy }
                if let windows {
                    do {
                        _ = try await windows.present(
                            content: .camera, title: "相机", icon: .emoji("📷"),
                            sizing: .image(aspect: 3.0 / 4.0, controlsHeight: 140))
                    } catch let error as WindowError {
                        throw WindowExecutionFailure(error: error)
                    }
                }
                try await setCaptureEnabled(true, invocation: invocation)
                _ = try await presentation.waitForPhotoCaptureRotation()
                try Task.checkCancellation()
                guard foreground, state.isVisible else { throw CameraControlError.notForeground }
            } else {
                try await closeWindow(invocation: invocation)
                if let windows, let item = windows.windows.first(where: { $0.content == WindowContent.camera.rawValue })
                {
                    try await windows.change(item.id, command: .close)
                }
            }
        }
        public func beginWindowTransition() async throws {
            guard !windowTransition, !changingDemand else { throw CameraControlError.busy }
            windowTransition = true
            presentation.present(.lensHandoff(true))
            await worker?.value
            if photoSession.isBusy || recordingSession.changing {
                endWindowTransition()
                throw CameraControlError.busy
            }
        }
        public func endWindowTransition() {
            windowTransition = false
            presentation.present(.lensHandoff(false))
        }
        public func pauseWindow(invocation: any FunctionInput) async throws {
            try Task.checkCancellation()
            guard !photoSession.isBusy else { throw CameraControlError.busy }
        }
        public func resumeWindow(invocation: any FunctionInput) async throws {
            try await setCaptureEnabled(true, invocation: invocation)
        }
        public func closeWindow(invocation: any FunctionInput) async throws {
            guard foreground else { throw CameraControlError.notForeground }
            guard !photoSession.isBusy else { throw CameraControlError.busy }
            await worker?.value
            try Task.checkCancellation()
            if let id = recordingSession.id {
                if state.recording.active { _ = try await recordingSession.stop(id) }
                if recordingSession.hasClip {
                    guard let windows,
                        let item = windows.windows.first(where: { $0.content == WindowContent.camera.rawValue })
                    else { throw CameraControlError.unavailable }
                    if item.mode == .minimized { try await windows.change(item.id, command: .restore) }
                    let choice = try await windows.ask(
                        item.id,
                        prompt: .init(
                            title: "关闭前如何处理这段视频？",
                            choices: [
                                .init(id: "save", title: "保存"), .init(id: "discard", title: "忽略"),
                                .init(id: "cancel", title: "取消"),
                            ]))
                    switch choice {
                    case "save": _ = try await recordingSession.save(id)
                    case "discard": _ = try await recordingSession.ignore(id)
                    default: throw CancellationError()
                    }
                }
            }
            if let photo = state.capturedPhoto, let windows,
                let item = windows.windows.first(where: { $0.content == WindowContent.camera.rawValue })
            {
                if item.mode == .minimized { try await windows.change(item.id, command: .restore) }
                if state.savedMediaID == photo.id {
                    _ = try await ignorePhoto(photo.id, invocation: invocation)
                } else {
                    let choice = try await windows.ask(
                        item.id,
                        prompt: .init(
                            title: "关闭前如何处理这张照片？",
                            choices: [
                                .init(id: "save", title: "保存"), .init(id: "discard", title: "忽略"),
                                .init(id: "cancel", title: "取消"),
                            ]))
                    switch choice {
                    case "save": _ = try await savePhoto(photo.id, invocation: invocation)
                    case "discard": _ = try await ignorePhoto(photo.id, invocation: invocation)
                    default: throw CancellationError()
                    }
                }
            }
            try await setCaptureEnabled(false, invocation: invocation)
        }
        private func setCaptureEnabled(_ enabled: Bool, invocation: any FunctionInput) async throws {
            try await setDemand(enabled, perception: false, invocation: invocation)
        }
        public func setPerceptionEnabled(_ enabled: Bool, invocation: any FunctionInput) async throws {
            try await setDemand(enabled, perception: true, invocation: invocation)
        }
        private func setDemand(_ enabled: Bool, perception: Bool, invocation: any FunctionInput) async throws {
            try Task.checkCancellation()
            guard foreground else { throw CameraControlError.notForeground }
            guard worker == nil, !photoSession.isBusy, !changingDemand else { throw CameraControlError.busy }
            changingDemand = true
            presentation.present(.isBusy(true))
            defer {
                changingDemand = false
                presentation.present(.isBusy(worker != nil))
            }
            presentation.present(perception ? .perceptionEnabled(enabled) : .isEnabled(enabled))
            // Removing one consumer must not recover or restart a failed sibling implicitly.
            if !enabled, demand {
                if perception { await stopPose() }
                return
            }
            if demand, state.isVisible, captureLease != nil, await refreshRunning() {
                if perception {
                    await stopPose()
                    try Task.checkCancellation()
                    if foreground { startPose() }
                }
                guard foreground else { throw CameraControlError.notForeground }
                return
            }
            failed = false
            presentation.present(.message(nil))
            presentation.present(.needsSettings(false))
            reconcile()
            try await finishCameraControl(enabled: demand)
        }

        public func flip(_ facing: CameraActions.Facing, invocation: any FunctionInput) async throws {
            try await switchLens(facing, source: .capture, invocation: invocation)
        }
        public func flipPerception(_ facing: CameraActions.Facing, invocation: any FunctionInput) async throws {
            try await switchLens(facing, source: .perception, invocation: invocation)
        }
        private func switchLens(_ facing: CameraActions.Facing, source: CameraSurface, invocation: any FunctionInput)
            async throws
        {
            try Task.checkCancellation()
            guard foreground else { throw CameraControlError.notForeground }
            guard worker == nil, !photoSession.isBusy, !changingDemand else { throw CameraControlError.busy }
            guard !recordingSession.busy else { throw CameraControlError.busy }
            guard source == .capture ? state.isEnabled : state.perceptionEnabled else {
                throw CameraControlError.disabled
            }
            guard state.lensOwner == source else { throw CameraControlError.lensNotOwned }
            guard state.isVisible, captureLease != nil, !failed else { throw CameraControlError.unavailable }
            let target: CameraDirection = facing == .front ? .front : .back
            if state.facing == target, state.isVisible {
                try await finishCameraControl(enabled: true)
                return
            }
            requestedFacing = target
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
            let running = await refreshRunning()
            try Task.checkCancellation()
            guard revision == expectedRevision else { throw CancellationError() }
            if state.needsSettings { throw CameraControlError.permissionDenied }
            if enabled && running {
                let native = try await camera.photoConfiguration()
                var settings = state.settings
                settings.flash = native.flash.rawValue
                settings.zoom = native.zoom
                settings.maximumZoom = native.maximumZoom
                settings.supportedFlash = native.supportedFlash.map(\.rawValue)
                presentation.present(.settings(settings))
            }
            guard enabled ? state.isVisible && running : captureLease == nil && !failed && !running else {
                throw CameraControlError.unavailable
            }
        }

        public func retry(invocation: any FunctionInput) async throws {
            try Task.checkCancellation()
            if state.needsSettings { throw CameraControlError.permissionDenied }
            try await setEnabled(true, invocation: invocation)
        }

        public func setForeground(_ value: Bool) {
            guard foreground != value else { return }
            foreground = value
            if !value {
                recordingSession.invalidateForeground()
                photoCues.stop()
                presentation.present(.isEnabled(false))
                presentation.present(.perceptionEnabled(false))
            }
            if value { failed = false }
            reconcile()
        }

        /// One notification consumer per scene; device status is coalesced, never a frame stream.
        public func shutdown() async throws {
            setForeground(false)
            await worker?.value
            await previewRestart.stop()
            let released = await stopCapture()
            guard released, !(await refreshRunning()) else { throw CameraControlError.unavailable }
        }

        public func observe() async {
            _ = await refreshRunning()
            for await event in camera.events {
                if Task.isCancelled { break }
                _ = await refreshRunning()
                guard demand, foreground else { continue }
                switch event {
                case .interrupted:
                    await stopPose()
                    visionSession = nil
                    presentation.clearPose()
                    presentation.present(.gaze(.zero))
                    gazeSequence = nil
                    previewRestart.invalidate()
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
            poseTask?.cancel()
            previewSession = nil
            previewRestart.invalidate()
            guard worker == nil else { return }
            presentation.present(.isBusy(true))
            worker = Task { await applyLatestIntent() }
        }

        private var visionDisplayToken: UIPresentationToken?
        private func startPreview(_ intent: PreviewIntent) -> Task<Void, Never>? {
            guard foreground, demand, state.isVisible, revision == intent.revision else { return nil }
            let id = UUID().uuidString
            previewSession = id
            let displayToken = presentation.token
            startPose()
            return Task { [weak self] in
                await self?.runPreview(intent.frames, sessionID: id, token: displayToken)
            }
        }
        private func stopPose() async {
            visionSession = nil
            let old = poseTask
            let oldID = poseWorkID
            old?.cancel()
            presentation.clearPose()
            presentation.present(.gaze(.zero))
            gazeSequence = nil
            await old?.value
            if poseWorkID == oldID {
                poseTask = nil
                poseWorkID = nil
            }
        }
        private func startPose() {
            guard state.perceptionEnabled, foreground, state.isVisible, poseTask == nil else { return }
            let id = UUID().uuidString
            visionSession = id
            visionDisplayToken = presentation.token
            presentation.present(.visionMessage("姿态识别准备中"))
            let mirrored = state.facing == .front
            poseWorkID = UUID()
            poseTask = Task { [weak self] in await self?.runPose(sessionID: id, mirrored: mirrored) }
        }
        private func runPreview(
            _ frames: AsyncThrowingStream<CameraFrame, Error>, sessionID: String,
            token displayToken: UIPresentationToken
        ) async {
            do {
                for try await frame in frames {

                    try Task.checkCancellation()
                    guard previewSession == sessionID, foreground, demand, state.isVisible else { return }
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
                guard previewSession == sessionID else { return }
                presentation.clearFrame()
                presentation.present(.message("相机画面暂不可用，请重试"))
                log.error("Camera preview failed: \(String(describing: error), privacy: .private)")
            }
        }
        private func runPose(sessionID: String, mirrored: Bool) async {
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
                    rotation: frame.rotation, sequence: frame.sequence, capturedAt: frame.capturedAt,
                    portraitRotation: frame.portraitRotation)
            }
        }
        public func visionStatus(_ message: String?, sessionID: String) {
            guard visionSession == sessionID, foreground, state.perceptionEnabled else { return }
            presentation.present(.visionMessage(message))
            if message != nil { presentation.clearPose() }
        }
        public func present(_ target: UIActions.Gaze, invocation: any FunctionInput) throws {
            try Task.checkCancellation()
            guard visionSession == invocation.context.sessionID, foreground, state.perceptionEnabled, state.isVisible
            else {
                throw CancellationError()
            }
            guard gazeSequence.map({ invocation.context.sequence > $0 }) ?? true else { return }
            gazeSequence = invocation.context.sequence
            presentation.present(.gaze(CGSize(width: target.x, height: target.y)))
        }

        public func present(_ overlay: Actions.PoseOverlay, frame: CameraFrame?, sessionID: String) throws {
            try Task.checkCancellation()
            guard visionSession == sessionID, foreground, state.perceptionEnabled, state.isVisible else {
                throw CancellationError()
            }
            guard state.skeleton.map({ overlay.sequence > $0.sequence }) ?? true else {
                throw ActionHostError.outOfOrder
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

        private func recordCapture(_ state: CaptureActivityEvent.State, id: String) {
            eventSequence &+= 1
            let context =
                captureEvent.flatMap { $0.activityID == id ? $0.context : nil }
                ?? ActionExecutionContext(source: Self.resourceOwnerID, sessionID: captureOwner.sessionID, inputID: id)
            captureEvent = CaptureActivityEvent(
                activityID: id, owner: captureOwner, state: state, sequence: eventSequence, context: context)
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
                _ = await refreshRunning()
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

        private func refreshRunning() async -> Bool { await camera.isRunning() }

        /// Releasing an old lease never calls the device directly and cannot stop a replacement owner.
        private func stopCapture() async -> Bool {
            await recordingSession.background()
            await photoSession.stopAndWait()
            leaseRenewal?.cancel()
            leaseRenewal = nil
            guard let lease = captureLease, let runtime = resourceRuntime else {
                return true
            }
            captureLease = nil
            do {
                try await runtime.resources.release(lease, owner: captureOwner)
                _ = await refreshRunning()
                recordCapture(.stopped, id: lease.id)
                return true
            } catch CameraResourceFailure.staleLease {
                if await runtime.resources.isSettled(CameraCoordinator.captureResource) {
                    _ = await refreshRunning()
                    recordCapture(.revoked, id: lease.id)
                    return true
                }
            } catch {}
            // Retain unresolved ownership so a retry cannot fabricate successful cleanup.
            captureLease = lease
            _ = await refreshRunning()
            recordCapture(.failed, id: lease.id)
            failed = true
            presentation.present(.isVisible(false))
            presentation.present(.message("相机尚未确认停止，请重试"))
            return false
        }

        private func applyLatestIntent() async {
            defer {
                worker = nil
                presentation.present(.isBusy(changingDemand))
            }
            while true {
                let current = revision
                await stopPose()
                guard current == revision else { continue }
                if hotSwitchRevision == current {
                    do {
                        guard foreground, demand, !failed, let lease = captureLease,
                            let runtime = resourceRuntime, await refreshRunning()
                        else { throw CameraError.unavailable }
                        let switchingStarted = ContinuousClock.now
                        let facing: CameraFacing = requestedFacing == .front ? .front : .back
                        let frames = try await runtime.resources.run(
                            resources: [CameraCoordinator.captureResource], owner: captureOwner, lease: lease
                        ) { [camera] in try await camera.switchCamera(facing: facing) }
                        guard current == revision else { continue }
                        let running = await refreshRunning()
                        guard current == revision else { continue }
                        guard running else { throw CameraError.startFailed }
                        let elapsed = switchingStarted.duration(to: .now).components
                        let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
                        log.debug("Native lens switch acknowledged in \(milliseconds, privacy: .public) ms")
                        presentation.present(.facing(facing == .front ? .front : .back))
                        presentation.present(.isVisible(true))
                        presentation.present(.message(nil))
                        presentation.present(.needsSettings(false))
                        previewRestart.replace(
                            with: PreviewIntent(frames: frames, revision: current))
                        return
                    } catch {
                        guard current == revision else { continue }
                        failed = true
                        _ = await stopCapture()
                        await previewRestart.stop()
                        guard current == revision else { continue }
                        presentation.present(.message("无法切换镜头，请重试"))
                        return
                    }
                }
                guard await stopCapture() else { return }
                await previewRestart.stop()
                guard current == revision else { continue }
                if !demand || !foreground || failed {
                    _ = await stopCapture()
                } else {
                    let authorized = await camera.requestPermission()
                    // Permission prompts may suspend/deactivate the scene or outlive a user stop.
                    guard current == revision else { continue }
                    if authorized {
                        do {
                            let frames = try await startCapture(facing: requestedFacing == .front ? .front : .back)
                            let running = await refreshRunning()
                            if current == revision {
                                if running { presentation.present(.facing(requestedFacing)) }
                                presentation.present(.isVisible(running))
                                presentation.present(.message(running ? nil : "相机暂时不可用，请重试"))
                                presentation.present(.needsSettings(false))
                                if running {
                                    previewRestart.replace(
                                        with: PreviewIntent(
                                            frames: frames, revision: current))
                                }
                            }
                        } catch {
                            _ = await stopCapture()
                            if current == revision {
                                failed = true
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
