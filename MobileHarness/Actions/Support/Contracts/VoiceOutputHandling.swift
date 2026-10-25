@MainActor
public protocol VoiceOutputHandling: VoicePresentationHandling {
    func prepareListening(pressed: Bool, invocation: any FunctionInput) async throws
    func validateCameraControl(invocation: any FunctionInput) throws
    func updateListening(
        enabled: Bool, paused: Bool, revision: UInt64, feedback: SpeechActions.ListeningFeedback,
        invocation: any FunctionInput) async throws
    func playCue(_ request: UIActions.CueRequest, invocation: any FunctionInput) async throws
    func vibrate(_ request: UIActions.HapticRequest, invocation: any FunctionInput) async throws
    func play(audioID: String, invocation: any FunctionInput) async throws
}

extension VoiceOutputHandling {
    public func prepareListening(pressed: Bool, invocation: any FunctionInput) async throws {
        throw ActionHostError.unsupportedContract
    }
}
