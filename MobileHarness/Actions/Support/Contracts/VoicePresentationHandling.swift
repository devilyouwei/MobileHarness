@MainActor
public protocol VoicePresentationHandling: AnyObject, Sendable {
    func present(_ text: String, invocation: any FunctionInput) throws
    func presentTranscript(_ text: String, invocation: any FunctionInput) throws
    func finishTranscript(invocation: any FunctionInput) throws
    func beginReplyTurn(invocation: any FunctionInput) throws
    func setReplyWaiting(_ enabled: Bool, requestID: String, invocation: any FunctionInput) throws
    func presentVoiceState(_ state: UIActions.VoiceState, invocation: any FunctionInput) throws
    func presentExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) async throws
    func restoreExpression(invocation: any FunctionInput) async throws
    func setExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) throws
    func observeTranscript(_ text: String, sessionID: String)
    func show(_ envelope: ActionOutputObservation) async
}
