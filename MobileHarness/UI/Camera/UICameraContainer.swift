import Foundation

#if os(iOS)
    import UIKit
#endif

/// Presentation facts only; state mutation stays behind CameraPresenting.
@MainActor
public struct CameraPresentationSnapshot {
    public let isEnabled: Bool
    public let isVisible: Bool
    public let isBusy: Bool
    public let controlBusy: Bool
    public let photoBusy: Bool
    public let facing: CameraDirection
    public let message: String?
    public let needsSettings: Bool
    public let savedMediaID: String?
    public let skeleton: PoseOverlay?
    #if os(iOS)
        public let capturedPhoto: CapturedPhotoPresentation?
    #endif
    init(_ state: CameraState) {
        isEnabled = state.isEnabled
        isVisible = state.isVisible
        isBusy = state.isBusy
        controlBusy = state.controlBusy
        photoBusy = state.photoBusy
        facing = state.facing
        message = state.message
        needsSettings = state.needsSettings
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
        func departPhoto(id: String, kind: PhotoDeparture.Kind) async throws
    #endif
    func present(_ update: CameraPresentationUpdate)
    func presentVideo(_ frame: CameraVideoFrame) throws
    func present(frame: CameraVideoFrame, pose: PoseOverlay) throws
    func clearFrame()
    func clearPose()
    func connectFactsObserver(_ observer: @escaping @MainActor () -> Void)
}

/// One camera display state per UI root. Metal surfaces continue to own GPU completion.
@MainActor
public final class UICameraContainer: CameraPresenting {

    public let state: CameraState
    public private(set) var isAvailable = false
    private var stopped = false
    private let admission: UIPresentationAdmission
    public var token: UIPresentationToken { admission.token }
    init(admission: UIPresentationAdmission, onFailure: @escaping UIFailureReporting) {
        self.admission = admission
        state = CameraState(onFailure: onFailure)
        state.presentationAdmission = admission
    }
    public var snapshot: CameraPresentationSnapshot { CameraPresentationSnapshot(state) }
    public func present(_ update: CameraPresentationUpdate) {
        guard !stopped else { return }
        switch update {
        case .isEnabled(true), .isVisible(true), .gaze: guard isAvailable else { return }
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
            state.capturedPhoto?.departure.setAvailable(false)
            state.capturedPhoto?.finish()
            state.present(.capturedPhoto(CapturedPhotoPresentation(id: id, image: image, completed: completed)))
        }
        public func departPhoto(id: String, kind: PhotoDeparture.Kind) async throws {
            try checkAdmission()
            guard let photo = state.capturedPhoto, photo.id == id else { throw UIContainerError.stale }
            try await photo.departure.perform(kind)
        }
    #endif
    public func presentVideo(_ frame: CameraVideoFrame) throws {
        try checkAdmission()
        try state.presentVideo(frame)

    }
    public func present(frame: CameraVideoFrame, pose: PoseOverlay) throws {
        try checkAdmission()
        try state.present(frame: frame, pose: pose)
    }
    public func clearFrame() { state.clearFrame() }
    public func clearPose() { state.clearPose() }
    public func connectFactsObserver(_ observer: @escaping @MainActor () -> Void) {
        state.connectFactsObserver(observer)
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
                state.capturedPhoto?.departure.setAvailable(false)
                state.capturedPhoto?.finish()
                state.capturedPhoto = nil
            #endif
            state.present(.isVisible(false))
        }
    }
    func stop() async {
        state.connectFactsObserver {}
        setAvailable(false)
        stopped = true
        isAvailable = false
        await state.stopPresentation()
    }
}
