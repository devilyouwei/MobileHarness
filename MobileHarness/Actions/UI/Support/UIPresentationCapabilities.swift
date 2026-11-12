import Foundation
import FunctionContracts

/// Typed presentation operations; completion means the endpoint accepted the update.
public protocol UIUpdateCapability: Sendable {
    func present(_ text: String, invocation: any FunctionInput) async throws
    func presentTranscript(_ text: String, invocation: any FunctionInput) async throws
    func finishTranscript(invocation: any FunctionInput) async throws
    func beginReplyTurn(invocation: any FunctionInput) async throws
    func setReplyWaiting(_ enabled: Bool, requestID: String, invocation: any FunctionInput) async throws
    func presentVoiceState(_ state: UIActions.VoiceState, invocation: any FunctionInput) async throws
    func present(_ target: UIActions.Gaze, invocation: any FunctionInput) async throws
}
