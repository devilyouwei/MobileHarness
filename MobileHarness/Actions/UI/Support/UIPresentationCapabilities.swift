import Foundation
import FunctionContracts
import StorageCore

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
    func present(_ overlay: PoseOverlay, sessionID: String) async throws
    func present(_ overlay: PoseOverlay, invocation: any FunctionInput) async throws
}
extension PosePresentationCapability {
    public func present(_ overlay: PoseOverlay, invocation: any FunctionInput) async throws {
        try await present(overlay, sessionID: invocation.context.sessionID)
    }
}

public protocol HistoryPresentationCapability: Sendable {
    func showHistory(invocation: any FunctionInput) async throws
}

public protocol ResourcePresentationCapability: Sendable {
    func navigate(_ destination: String, invocation: any FunctionInput) async throws
    func presentProviderResult(requestID: String, failureCode: String?, invocation: any FunctionInput) async throws
    func presentResources(_ inventory: ModelResourceInventory, generation: UInt64, invocation: any FunctionInput)
        async throws
    func presentResourcePreferenceFailure(
        _ reason: ResourcePreferenceFailureReason, message: String, invocation: any FunctionInput) async throws
    func presentResourceOperationFailure(_ message: String, invocation: any FunctionInput) async throws
    func presentResourceFailure(_ message: String, generation: UInt64, invocation: any FunctionInput) async throws
}

extension ResourcePresentationCapability {
    public func navigate(_ destination: String, invocation: any FunctionInput) async throws {
        throw ResourcePresentationError.unavailable
    }
    public func presentProviderResult(requestID: String, failureCode: String?, invocation: any FunctionInput)
        async throws
    {
        throw ResourcePresentationError.unavailable
    }
}

/// Commits diagnostic presentation; classification and toast selection remain with the caller.
public protocol RuntimeFailurePresentationCapability: Sendable {
    func recordRuntimeFailure(_ issue: RuntimeIssue, invocation: any FunctionInput) async throws
}
