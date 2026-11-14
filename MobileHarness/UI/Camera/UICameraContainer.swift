import Foundation

#if os(iOS)
    import UIKit
#endif

/// Presentation facts only; state mutation stays behind CameraPresenting.
@MainActor
public struct CameraPresentationSnapshot: Sendable {
    public let gallerySession: String?
    public let previews: [CameraPreviewItem]
    public let photoCaptureRotation: Double?
    public let recording: CameraRecordingPresentation
    public let recordedVideo: CameraRecordedVideo?
    public let settings: CameraSettings
    public let countdown: Int?
    public let isEnabled: Bool
    public let perceptionEnabled: Bool
    public let lensOwner: CameraSurface?
    public let isVisible: Bool
    public let isBusy: Bool
    public let controlBusy: Bool
    public let photoBusy: Bool
    public let facing: CameraDirection
    public let message: String?
    public let needsSettings: Bool
    public let savedPreviewID: String?
    public let savedMediaID: String?
    public let skeleton: PoseOverlay?
    #if os(iOS)
        public let capturedPhoto: CapturedPhotoPresentation?
    #endif
    init(_ state: CameraState) {
        gallerySession = state.gallerySession
        previews = state.previews
        photoCaptureRotation = state.photoCaptureRotation
        recording = state.recording
        recordedVideo = state.recordedVideo
        settings = state.settings
        countdown = state.countdown
        isEnabled = state.isEnabled
        perceptionEnabled = state.perceptionEnabled
        lensOwner = state.lensOwner
        isVisible = state.isVisible
        isBusy = state.isBusy
        controlBusy = state.controlBusy
        photoBusy = state.photoBusy
        facing = state.facing
        message = state.message
        needsSettings = state.needsSettings
        savedPreviewID = state.savedPreviewID
        savedMediaID = state.savedMediaID
        skeleton = state.skeleton
        #if os(iOS)
            capturedPhoto = state.capturedPhoto
        #endif
    }
}

/// UI-owned interface; no device, model, transport or business types cross this boundary.
@MainActor
public protocol CameraPresenting: AnyObject, Sendable {
    var snapshot: CameraPresentationSnapshot { get }
    var token: UIPresentationToken { get }
    func presentVideo(_ frame: CameraVideoFrame, token: UIPresentationToken) throws
    func present(frame: CameraVideoFrame, pose: PoseOverlay, token: UIPresentationToken) throws
    #if os(iOS)
        func presentPhoto(id: String, image: UIImage, completed: @escaping @MainActor (Bool) -> Void) throws
    #endif
    func present(_ update: CameraPresentationUpdate)
    func presentVideo(_ frame: CameraVideoFrame) throws
    func present(frame: CameraVideoFrame, pose: PoseOverlay) throws
    func waitForPhotoCaptureRotation(timeout: Duration) async throws -> Double
    func clearFrame()
    func clearPose()
}

public enum CameraPreviewReadinessError: Error, Sendable, Equatable, CustomStringConvertible {
    case busy, timedOut, invalidTimeout
    case rendererFailed(String)
    public var description: String {
        switch self {
        case .busy: return "Camera first-frame operation already pending"
        case .invalidTimeout: return "Camera first-frame timeout must be between 0 and 10 seconds"
        case .timedOut: return "Timed out waiting for a valid camera frame; capture did not start"
        case .rendererFailed(let message): return "Camera preview failed: " + message
        }
    }
}

extension CameraPresenting {
    public func waitForPhotoCaptureRotation() async throws -> Double {
        try await waitForPhotoCaptureRotation(timeout: .seconds(10))
    }
}

@MainActor public protocol CameraFactsObserving: AnyObject, Sendable {
    func observeFacts() throws -> AsyncStream<CameraPresentationSnapshot>
}

/// One camera display state per UI root. Metal surfaces continue to own GPU completion.
@MainActor
public final class UICameraContainer: CameraPresenting, CameraFactsObserving {
    public let requests = UIRequests<CameraInput, String?>()

    public func stateSnapshot() async throws -> UIStateSnapshot {
        try Task.checkCancellation()
        return UIStateSnapshot(
            path: "ui.camera",
            business: [
                "mode": .text(state.settings.mode),
                "countdown": state.countdown.map { .count($0) } ?? .unknown,
                "recordingPhase": .text(state.recording.phase.rawValue),
                "recordingID": state.recording.id.map { .text($0) } ?? .unknown,
                "perceptionEnabled": .flag(state.perceptionEnabled),
                "lensOwner": state.lensOwner.map { .text($0.rawValue) } ?? .unknown,
                "enabled": .flag(state.isEnabled), "visible": .flag(state.isVisible),
                "busy": .flag(state.isBusy || state.controlBusy || state.photoBusy),
                "facing": .text(state.facing == .front ? "front" : "back"), "needsSettings": .flag(state.needsSettings),
            ],
            runtime: ["available": .flag(state.isPresentationAvailable)])
    }

    public let state: CameraState
    public private(set) var isAvailable = false
    private var stopped = false
    private var factObservers: [UUID: AsyncStream<CameraPresentationSnapshot>.Continuation] = [:]
    private struct PreviewWaiter {
        let id: UUID
        let token: UIPresentationToken
        let generation: UInt64
        let continuation: CheckedContinuation<Result<Double, any Error>, Never>
    }
    private var previewWaiter: PreviewWaiter?
    var hasPendingPreviewWaiter: Bool { previewWaiter != nil }
    private let admission: UIPresentationAdmission
    public var token: UIPresentationToken { admission.token }
    init(admission: UIPresentationAdmission, onFailure: @escaping UIFailureReporting) {
        self.admission = admission
        state = CameraState(onFailure: onFailure)
        state.presentationAdmission = admission
        state.connectFactsObserver { [weak self] in
            guard let self else { return }
            self.resolvePreviewWaiter()
            for observer in self.factObservers.values { observer.yield(self.snapshot) }
        }
    }
    public var snapshot: CameraPresentationSnapshot { CameraPresentationSnapshot(state) }
    public func present(_ update: CameraPresentationUpdate) {
        guard !stopped else { return }
        switch update {
        case .isEnabled(true), .perceptionEnabled(true), .isVisible(true), .gaze: guard isAvailable else { return }
        default: break
        }
        state.present(update)
    }
    public func presentVideo(_ frame: CameraVideoFrame, token: UIPresentationToken) throws {
        try admission.requireLive(token)
        try presentVideo(frame)
    }
    public func present(frame: CameraVideoFrame, pose: PoseOverlay, token: UIPresentationToken) throws {
        try admission.requireLive(token)
        try present(frame: frame, pose: pose)
    }
    #if os(iOS)
        public func presentPhoto(id: String, image: UIImage, completed: @escaping @MainActor (Bool) -> Void) throws {
            try checkAdmission()
            state.capturedPhoto?.finish()
            state.present(.capturedPhoto(CapturedPhotoPresentation(id: id, image: image, completed: completed)))
        }
    #endif
    public func presentVideo(_ frame: CameraVideoFrame) throws {
        try checkAdmission()
        try state.presentVideo(frame)
        resolvePreviewWaiter()
    }
    public func present(frame: CameraVideoFrame, pose: PoseOverlay) throws {
        try checkAdmission()
        try state.present(frame: frame, pose: pose)
    }
    /// Waits for admitted frame geometry, not a fixed warm-up delay or GPU completion.
    public func waitForPhotoCaptureRotation(timeout: Duration) async throws -> Double {
        try Task.checkCancellation()
        try checkAdmission()
        try admission.requireLive()
        guard timeout > .zero, timeout <= .seconds(10) else { throw CameraPreviewReadinessError.invalidTimeout }
        guard previewWaiter == nil else { throw CameraPreviewReadinessError.busy }
        if let failure = state.photoRendererFailure { throw CameraPreviewReadinessError.rendererFailed(failure) }
        if let rotation = state.photoCaptureRotation { return rotation }
        let id = UUID()
        let deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.finishPreviewWaiter(id, result: .failure(CameraPreviewReadinessError.timedOut))
        }
        let result: Result<Double, any Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .failure(CancellationError()))
                } else {
                    previewWaiter = PreviewWaiter(
                        id: id, token: token, generation: state.videoGeneration, continuation: continuation)
                    resolvePreviewWaiter()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishPreviewWaiter(id, result: .failure(CancellationError()))
            }
        }
        deadline.cancel()
        await deadline.value
        try Task.checkCancellation()
        return try result.get()
    }
    private func finishPreviewWaiter(_ id: UUID, result: Result<Double, any Error>) {
        guard let waiter = previewWaiter, waiter.id == id else { return }
        previewWaiter = nil
        waiter.continuation.resume(returning: result)
    }
    private func resolvePreviewWaiter() {
        guard let waiter = previewWaiter else { return }
        do {
            try checkAdmission()
            try admission.requireLive(waiter.token)
            guard waiter.generation == state.videoGeneration else { throw UIContainerError.stale }
            if let failure = state.photoRendererFailure { throw CameraPreviewReadinessError.rendererFailed(failure) }
            if let rotation = state.photoCaptureRotation { finishPreviewWaiter(waiter.id, result: .success(rotation)) }
        } catch {
            finishPreviewWaiter(waiter.id, result: .failure(error))
        }
    }
    public func clearFrame() { state.clearFrame() }
    public func clearPose() { state.clearPose() }
    public func observeFacts() throws -> AsyncStream<CameraPresentationSnapshot> {
        guard !stopped else { throw UIContainerError.stopped }
        guard factObservers.count < 16 else { throw UIRequestError.capacityExceeded }
        let id = UUID()
        let pair = AsyncStream<CameraPresentationSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        factObservers[id] = pair.continuation
        pair.continuation.yield(snapshot)
        pair.continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.factObservers[id] = nil } }
        return pair.stream
    }
    private func checkAdmission() throws {
        guard !stopped else { throw UIContainerError.stopped }
        guard isAvailable else { throw UIContainerError.unavailable }
    }
    func setAvailable(_ active: Bool) {
        guard !stopped else { return }
        isAvailable = active
        if !active {
            #if os(iOS)
                state.capturedPhoto?.finish()
                state.capturedPhoto = nil
            #endif
            state.present(.isVisible(false))
        }
    }
    func stop() async {
        if let waiter = previewWaiter { finishPreviewWaiter(waiter.id, result: .failure(UIContainerError.stopped)) }
        state.connectFactsObserver {}
        for observer in factObservers.values { observer.finish() }
        factObservers.removeAll()
        setAvailable(false)
        stopped = true
        isAvailable = false
        await state.stopPresentation()
    }
}

public struct CameraInput: Sendable {
    public let previewSession: String?
    public enum Operation: String, Sendable {
        case open, close, flip, retry, takePhoto, savePhoto, configure, cancelCapture, startRecording,
            stopRecording, saveVideo, ignoreVideo, perceptionOpen, perceptionClose,
            perceptionFlip, perceptionRetry
    }
    public let operation: Operation
    public let recordingID: String?
    public let settings: CameraSettings?
    public let facing: CameraDirection?
    public let previewID: String?
    public init(
        _ operation: Operation, facing: CameraDirection? = nil, previewID: String? = nil,
        settings: CameraSettings? = nil,
        recordingID: String? = nil, previewSession: String? = nil
    ) {
        self.previewSession = previewSession
        self.operation = operation
        self.settings = settings
        self.recordingID = recordingID
        self.facing = facing
        self.previewID = previewID
    }
}
