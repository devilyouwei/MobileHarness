import ActionRuntime
import Actions
import AgentCore
import Foundation
import ToolRuntime
import Tools

@MainActor
protocol VoiceOutputHandling: AnyObject, Sendable {
    func play(audioID: UUID, invocation: ActionInvocation) async throws
    func present(_ text: String, invocation: ToolInvocation) throws
    func presentTranscript(_ text: String, invocation: ToolInvocation) throws
    func finishTranscript(invocation: ToolInvocation) throws
    func beginReplyTurn(invocation: ToolInvocation) throws
    func presentVoiceState(_ state: UITools.VoiceState, invocation: ToolInvocation) throws
    func presentExpression(_ emotion: UIActions.Emotion, invocation: ActionInvocation) throws
    func observeSpeech(_ input: AgentInput)
    func show(_ envelope: OutputEnvelope)
}

@MainActor
protocol CameraOutputHandling: AnyObject, Sendable {
    func present(_ target: UITools.Gaze, invocation: ToolInvocation) throws
    func present(_ overlay: ToolPoseOverlay, sessionID: UUID) throws
}

/// A whole role binds atomically. Closures in the handler registry never own session resources.
@MainActor
final class RuntimePresentation: UIPresentationCapability, UIUpdateCapability, SpeechPlaybackCapability,
    PosePresentationCapability
{
    private weak var voice: (any VoiceOutputHandling)?
    private weak var camera: (any CameraOutputHandling)?
    func bindVoice(_ value: any VoiceOutputHandling) throws {
        guard voice == nil else { throw CommunicationError.scopeClosed }
        voice = value
    }
    func unbindVoice(_ value: any VoiceOutputHandling) {
        if voice === value { voice = nil }
    }
    func bindCamera(_ value: any CameraOutputHandling) throws {
        guard camera == nil else { throw CommunicationError.scopeClosed }
        camera = value
    }
    func unbindCamera(_ value: any CameraOutputHandling) {
        if camera === value { camera = nil }
    }
    func play(audioID: UUID, invocation: ActionInvocation) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try await voice.play(audioID: audioID, invocation: invocation)
    }
    func present(_ text: String, invocation: ToolInvocation) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.present(text, invocation: invocation)
    }
    func presentTranscript(_ text: String, invocation: ToolInvocation) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.presentTranscript(text, invocation: invocation)
    }
    func finishTranscript(invocation: ToolInvocation) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.finishTranscript(invocation: invocation)
    }
    func beginReplyTurn(invocation: ToolInvocation) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.beginReplyTurn(invocation: invocation)
    }
    func presentVoiceState(_ state: UITools.VoiceState, invocation: ToolInvocation) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.presentVoiceState(state, invocation: invocation)
    }
    func presentExpression(_ emotion: UIActions.Emotion, invocation: ActionInvocation) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.presentExpression(emotion, invocation: invocation)
    }
    func present(_ target: UITools.Gaze, invocation: ToolInvocation) async throws {
        guard let camera else { throw CommunicationError.scopeClosed }
        try camera.present(target, invocation: invocation)
    }
    func present(_ overlay: ToolPoseOverlay, sessionID: UUID) async throws {
        guard let camera else { throw CommunicationError.scopeClosed }
        try camera.present(overlay, sessionID: sessionID)
    }
    func observe(_ input: AgentInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        voice.observeSpeech(input)
    }
    func output(_ envelope: OutputEnvelope) async {
        guard envelope.source == .assistant || envelope.source == .speechPerception else { return }
        voice?.show(envelope)
    }
}
