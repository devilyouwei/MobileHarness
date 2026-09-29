import Actions
import AgentCore
import Foundation
import Tools

@MainActor
protocol VoiceOutputHandling: AnyObject, Sendable {
    func speak(_ invocation: ActionInvocation) async throws
    func present(_ text: String, invocation: ActionInvocation) throws
    func presentTranscript(_ text: String, invocation: ActionInvocation) throws
    func finishTranscript(invocation: ActionInvocation) throws
    func beginReplyTurn(invocation: ActionInvocation) throws
    func presentVoiceState(_ state: UIActions.VoiceState, invocation: ActionInvocation) throws
    func presentExpression(_ emotion: UIActions.Emotion, invocation: ActionInvocation) throws
    func observeSpeech(_ input: AgentInput)
    func show(_ envelope: OutputEnvelope)
}

@MainActor
protocol CameraOutputHandling: AnyObject, Sendable {
    func present(_ target: UIActions.Gaze, invocation: ActionInvocation) throws
    func present(_ overlay: PoseOverlay, sessionID: UUID) throws
}

/// A whole role binds atomically. Closures in the handler registry never own session resources.
@MainActor
final class RuntimePresentation {
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
    func speak(_ invocation: ActionInvocation) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try await voice.speak(invocation)
    }
    func printText(_ invocation: ActionInvocation) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try await UIActions.print(invocation: invocation) { try await voice.present($0, invocation: $1) }
    }
    func setTranscript(_ invocation: ActionInvocation) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try await UIActions.setTranscript(invocation: invocation) {
            try await voice.presentTranscript($0, invocation: $1)
        }
    }
    func finishTranscript(_ invocation: ActionInvocation) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try await UIActions.finishTranscript(invocation: invocation) {
            try await voice.finishTranscript(invocation: $0)
        }
    }
    func beginReplyTurn(_ invocation: ActionInvocation) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try await UIActions.beginReplyTurn(invocation: invocation) { try await voice.beginReplyTurn(invocation: $0) }
    }
    func setVoiceState(_ invocation: ActionInvocation) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try await UIActions.setVoiceState(invocation: invocation) {
            try await voice.presentVoiceState($0, invocation: $1)
        }
    }
    func express(_ invocation: ActionInvocation) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try await UIActions.express(invocation: invocation) { try await voice.presentExpression($0, invocation: $1) }
    }
    func moveEyes(_ invocation: ActionInvocation) async throws {
        guard let camera else { throw CommunicationError.scopeClosed }
        try await UIActions.moveEyes(invocation: invocation) { try await camera.present($0, invocation: $1) }
    }
    func showPose(_ call: ToolCall, envelope: OutputEnvelope) async throws {
        guard let camera else { throw CommunicationError.scopeClosed }
        try await UITools.showPose(call: call, envelope: envelope) {
            try await camera.present($0, sessionID: $1.sessionID)
        }
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
