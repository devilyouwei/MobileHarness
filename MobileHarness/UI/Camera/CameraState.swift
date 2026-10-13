import CoreGraphics
import Foundation
import Observation

public enum CameraDirection: Sendable { case front, back }

@MainActor @Observable
public final class CameraState {
    #if os(iOS)
        public var capturedPhoto: CapturedPhotoPresentation?
    #endif
    public var photoBusy = false
    public var photoMessage: String?
    public var savedPhotoID: UUID?
    public var isEnabled = false
    public var facing: CameraDirection = .front
    public var isVisible = false
    public var isBusy = false
    public var message: String?
    public var needsSettings = false
    public var skeleton: PoseOverlay?
    public var gaze: CGSize = .zero
    public var visionMessage: String?
    public init() {}
}

/// User controls only; capture, permission and inference lifetimes belong to App.
@MainActor
public protocol CameraControlling: AnyObject {
    func toggle()
    func switchCamera()
    func retry()
    func savePhoto(_ id: UUID)
    func ignorePhoto(_ id: UUID)
}
