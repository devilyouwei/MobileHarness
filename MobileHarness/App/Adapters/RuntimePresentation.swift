import Actions
import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts

@MainActor
protocol VoiceOutputHandling: AnyObject, Sendable {
    func validateCameraControl(invocation: any FunctionInput) throws
    func play(audioID: UUID, invocation: any FunctionInput) async throws
    func present(_ text: String, invocation: any FunctionInput) throws
    func presentTranscript(_ text: String, invocation: any FunctionInput) throws
    func finishTranscript(invocation: any FunctionInput) throws
    func beginReplyTurn(invocation: any FunctionInput) throws
    func presentVoiceState(_ state: UIActions.VoiceState, invocation: any FunctionInput) throws
    func presentExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) async throws
    func restoreExpression(invocation: any FunctionInput) async throws
    func setExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) throws
    func observeSpeech(_ input: AgentInput)
    func show(_ envelope: OutputEnvelope)
}

@MainActor
protocol CameraOutputHandling: AnyObject, Sendable {
    func present(_ target: UIActions.Gaze, invocation: any FunctionInput) throws
    func present(_ overlay: PoseOverlay, sessionID: UUID) throws
    func visionStatus(_ message: String?, sessionID: UUID)
}

/// A whole role binds atomically. Closures in the handler registry never own session resources.
@MainActor
final class RuntimePresentation: UIPresentationCapability, UIUpdateCapability, SpeechPlaybackCapability,
    PosePresentationCapability, CameraControlCapability
{
    private let cameraControl: any CameraControlCapability
    init(cameraControl: any CameraControlCapability) { self.cameraControl = cameraControl }
    func setEnabled(_ enabled: Bool, invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.validateCameraControl(invocation: invocation)
        try await cameraControl.setEnabled(enabled, invocation: invocation)
    }
    func flip(invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.validateCameraControl(invocation: invocation)
        try await cameraControl.flip(invocation: invocation)
    }
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
    func play(audioID: UUID, invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try await voice.play(audioID: audioID, invocation: invocation)
    }
    func present(_ text: String, invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.present(text, invocation: invocation)
    }
    func presentTranscript(_ text: String, invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.presentTranscript(text, invocation: invocation)
    }
    func finishTranscript(invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.finishTranscript(invocation: invocation)
    }
    func beginReplyTurn(invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.beginReplyTurn(invocation: invocation)
    }
    func presentVoiceState(_ state: UIActions.VoiceState, invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.presentVoiceState(state, invocation: invocation)
    }
    func presentExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try await voice.presentExpression(emotion, invocation: invocation)
    }
    func restoreExpression(invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try await voice.restoreExpression(invocation: invocation)
    }
    func setExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.setExpression(emotion, invocation: invocation)
    }
    func present(_ target: UIActions.Gaze, invocation: any FunctionInput) async throws {
        guard let camera else { throw CommunicationError.scopeClosed }
        try camera.present(target, invocation: invocation)
    }
    func present(_ overlay: PoseOverlay, sessionID: UUID) async throws {
        guard let camera else { throw CommunicationError.scopeClosed }
        try camera.present(overlay, sessionID: sessionID)
    }
    func observe(_ input: AgentInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        voice.observeSpeech(input)
    }
    func output(_ envelope: OutputEnvelope) async {
        guard envelope.source.rawValue == "assistant" || envelope.source.rawValue == "speechPerception" else { return }
        voice?.show(envelope)
    }
}
