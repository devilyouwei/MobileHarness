import FunctionContracts
import PlatformKit

@MainActor
public protocol CameraOutputHandling: AnyObject, Sendable {
    func present(_ target: UIActions.Gaze, invocation: any FunctionInput) throws
    func present(_ overlay: Actions.PoseOverlay, frame: CameraFrame?, sessionID: String) throws
    func visionStatus(_ message: String?, sessionID: String)
}
