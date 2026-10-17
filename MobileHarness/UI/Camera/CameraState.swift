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
    public var savedMediaID: String?
    public var isEnabled = false
    public var facing: CameraDirection = .front
    public var isVisible = false
    public var isBusy = false
    public var message: String?
    public var needsSettings = false
    public var skeleton: PoseOverlay?
    public var gaze: CGSize = .zero
    public var visionMessage: String?
    @ObservationIgnored private var onFactsChanged: (@MainActor () -> Void)?
    public init() {}
    public func connectFactsObserver(_ observer: @escaping @MainActor () -> Void) { onFactsChanged = observer }
    /// Public presentation submission; this never grants native capture or motion authority.
    public func present(_ update: CameraPresentationUpdate) {
        defer {
            switch update {
            case .skeleton, .gaze, .visionMessage, .photoMessage: break
            default: onFactsChanged?()
            }
        }
        switch update {
        case .photoBusy(let value): photoBusy = value
        case .photoMessage(let value): photoMessage = value
        case .savedMediaID(let value): savedMediaID = value
        case .isEnabled(let value): isEnabled = value
        case .facing(let value): facing = value
        case .isVisible(let value): isVisible = value
        case .isBusy(let value): isBusy = value
        case .message(let value): message = value
        case .needsSettings(let value): needsSettings = value
        case .skeleton(let value): skeleton = value
        case .gaze(let value): gaze = value
        case .visionMessage(let value): visionMessage = value
        #if os(iOS)
            case .capturedPhoto(let value): capturedPhoto = value
        #endif
        }
    }

}

/// User controls only; capture, permission and inference lifetimes belong to module services.
@MainActor
public protocol CameraControlling: AnyObject {
    func toggle()
    func switchCamera()
    func retry()
    func savePhoto(_ id: String)
    func ignorePhoto(_ id: String)
}

public enum CameraPresentationUpdate {
    case photoBusy(Bool)
    case photoMessage(String?)
    case savedMediaID(String?)
    case isEnabled(Bool)
    case facing(CameraDirection)
    case isVisible(Bool)
    case isBusy(Bool)
    case message(String?)
    case needsSettings(Bool)
    case skeleton(PoseOverlay?)
    case gaze(CGSize)
    case visionMessage(String?)
    #if os(iOS)
        case capturedPhoto(CapturedPhotoPresentation?)
    #endif
}
