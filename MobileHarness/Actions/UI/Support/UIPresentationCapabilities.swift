import ActionRuntime
import Foundation

/// Finite transition/restore acknowledgments and independent persistent-state commitment.
public protocol UIPresentationCapability: Sendable {
    func presentExpression(_ emotion: UIActions.Emotion, invocation: ActionInvocation) async throws
    func restoreExpression(invocation: ActionInvocation) async throws
    func setExpression(_ emotion: UIActions.Emotion, invocation: ActionInvocation) async throws
}

/// Typed presentation operations; completion means the endpoint accepted the update.
public protocol UIUpdateCapability: Sendable {
    func present(_ text: String, invocation: ToolInvocation) async throws
    func presentTranscript(_ text: String, invocation: ToolInvocation) async throws
    func finishTranscript(invocation: ToolInvocation) async throws
    func beginReplyTurn(invocation: ToolInvocation) async throws
    func presentVoiceState(_ state: UIActions.VoiceState, invocation: ToolInvocation) async throws
    func present(_ target: UIActions.Gaze, invocation: ToolInvocation) async throws
}

public protocol PosePresentationCapability: Sendable {
    func present(_ overlay: ToolPoseOverlay, sessionID: UUID) async throws
}

public protocol HistoryPresentationCapability: Sendable {
    func showHistory(invocation: ToolInvocation) async throws
}
