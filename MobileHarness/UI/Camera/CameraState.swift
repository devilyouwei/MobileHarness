import CoreGraphics
import Foundation
import Observation
import Types

public enum CameraDirection: Sendable { case front, back }

@MainActor @Observable
public final class CameraState {
    public var isEnabled = true
    public var facing: CameraDirection = .front
    public var isVisible = false
    public var isBusy = false
    public var message: String?
    public var needsSettings = false
    public var skeleton: PoseOverlay?
    public var gaze: CGSize = .zero
    public var visionMessage: String?
    public var trackingMessage: String?
    public init() {}
}

/// User controls only; capture, permission and inference lifetimes belong to App.
@MainActor
public protocol CameraControlling: AnyObject {
    func toggle()
    func switchCamera()
    func retry()
}
