import Foundation
import FunctionContracts

/// Stable speech capability port; the root-owned native session is bound weakly for its lifetime.
@MainActor
public final class SpeechExecutionEndpoint: SpeechPlaybackCapability, SpeechListeningCapability,
    SpeechListeningGestureCapability, AudioDetectionCapability, UIFeedbackCapability
{
    private let rootSessionID: String
    private weak var voice: (any VoiceOutputHandling)?
    public weak var audioDetection: AudioDetectionPresentation?
    public init(rootSessionID: String) { self.rootSessionID = rootSessionID }
    public func bind(_ value: any VoiceOutputHandling) throws {
        guard voice == nil else { throw ActionHostError.scopeClosed }
        voice = value
    }
    public func unbind(_ value: any VoiceOutputHandling) {
        if voice === value { voice = nil }
    }
    public func validateCameraControl(invocation: any FunctionInput) throws {
        guard let voice else { throw ActionHostError.scopeClosed }
        try voice.validateCameraControl(invocation: invocation)
    }
    public func validateEffects(invocation: any FunctionInput) throws {
        guard let voice else { throw ActionHostError.unauthorized }
        try voice.validateCameraControl(invocation: invocation)
    }
    public func prepareListening(pressed: Bool, invocation: any FunctionInput) async throws {
        guard let voice else { throw ActionHostError.scopeClosed }
        try await voice.prepareListening(pressed: pressed, invocation: invocation)
    }
    public func setListening(enabled: Bool, invocation: any FunctionInput) async throws {
        try Task.checkCancellation()
        guard invocation.context.sessionID == rootSessionID else { throw ActionHostError.unauthorized }
        guard let voice else { throw ActionHostError.scopeClosed }
        try await voice.setListening(enabled: enabled, invocation: invocation)
    }
    public func updateListening(
        enabled: Bool, paused: Bool, revision: UInt64, feedback: SpeechActions.ListeningFeedback,
        invocation: any FunctionInput
    ) async throws {
        guard invocation.context.sessionID == rootSessionID,
            let voice
        else { throw ActionHostError.unauthorized }
        try await voice.updateListening(
            enabled: enabled, paused: paused, revision: revision, feedback: feedback, invocation: invocation)
    }
    public func playCue(_ request: UIActions.CueRequest, invocation: any FunctionInput) async throws {
        guard let voice else { throw ActionHostError.scopeClosed }
        try await voice.playCue(request, invocation: invocation)
    }
    public func vibrate(_ request: UIActions.HapticRequest, invocation: any FunctionInput) async throws {
        guard let voice else { throw ActionHostError.scopeClosed }
        try await voice.vibrate(request, invocation: invocation)
    }
    public func play(audioID: String, invocation: any FunctionInput) async throws {
        guard let voice else { throw ActionHostError.scopeClosed }
        try await voice.play(audioID: audioID, invocation: invocation)
    }
    public func runDetection(invocation: any FunctionInput) async throws {
        try Task.checkCancellation()
        guard invocation.context.sessionID == rootSessionID,
            invocation.context.taskID == nil
        else { throw ActionHostError.unauthorized }
        guard let audioDetection, let readiness = invocation.attachment as? AudioDetectionReadiness else {
            throw ActionHostError.scopeClosed
        }
        try await audioDetection.run(readiness: readiness)
    }
}
