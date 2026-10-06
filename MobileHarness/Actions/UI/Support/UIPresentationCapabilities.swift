import Foundation
import FunctionContracts

/// Finite transition/restore acknowledgments and independent persistent-state commitment.
public protocol UIPresentationCapability: Sendable {
    func presentExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) async throws
    func restoreExpression(invocation: any FunctionInput) async throws
    func setExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) async throws
}

/// Typed presentation operations; completion means the endpoint accepted the update.
public protocol UIUpdateCapability: Sendable {
    func present(_ text: String, invocation: any FunctionInput) async throws
    func presentTranscript(_ text: String, invocation: any FunctionInput) async throws
    func finishTranscript(invocation: any FunctionInput) async throws
    func beginReplyTurn(invocation: any FunctionInput) async throws
    func presentVoiceState(_ state: UIActions.VoiceState, invocation: any FunctionInput) async throws
    func present(_ target: UIActions.Gaze, invocation: any FunctionInput) async throws
}

public protocol PosePresentationCapability: Sendable {
    func present(_ overlay: PoseOverlay, sessionID: UUID) async throws
}

public protocol HistoryPresentationCapability: Sendable {
    func showHistory(invocation: any FunctionInput) async throws
}
