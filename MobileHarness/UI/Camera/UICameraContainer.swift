import Foundation

/// Presentation facts only; state mutation stays behind CameraPresenting.
@MainActor public struct CameraPresentationSnapshot {
    public let isEnabled: Bool
    public let isVisible: Bool
    public let isBusy: Bool
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
@MainActor public protocol CameraPresenting: AnyObject, Sendable {
    var snapshot: CameraPresentationSnapshot { get }
    func present(_ update: CameraPresentationUpdate)
    func presentVideo(_ frame: CameraVideoFrame) throws
    func present(frame: CameraVideoFrame, pose: PoseOverlay) throws
    func clearFrame()
    func clearPose()
    func connectFactsObserver(_ observer: @escaping @MainActor () -> Void)
}

/// One camera display state per UI root. Metal surfaces continue to own GPU completion.
@MainActor public final class UICameraContainer: CameraPresenting {
    public let state: CameraState
    public private(set) var isAvailable = false
    private var stopped = false
    init() { state = CameraState() }
    public var snapshot: CameraPresentationSnapshot { CameraPresentationSnapshot(state) }
    public func present(_ update: CameraPresentationUpdate) { state.present(update) }
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
        if !active { state.present(.isVisible(false)) }
    }
    func stop() async {
        stopped = true
        isAvailable = false
        state.connectFactsObserver {}
        await state.stopPresentation()
    }
}
